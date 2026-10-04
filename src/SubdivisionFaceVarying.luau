-- Private per-channel corner topology and Catmull-Clark data stencils.
local A = require(script.Parent.AttributeCore)
local U = require(script.Parent.Util)
local F = {}
local PREFIX = "subdivision_fvar_topology:"
local modes =
	{ smooth = true, corners = true, junctions = true, concave = true, boundaries = true, linear = true }
local builtins = { uv = "Vector2", color = "Color3", alpha = "number" }

local function channel(mesh, token)
	local kind = builtins[token]
	if kind then
		local values = {}
		for fid, face in mesh.faces do
			for i, corner in face.corners do
				local value = corner[token]
				assert(
					A.finite(value, kind),
					"Requested face-varying field must be finite on every corner: " .. token
				)
				values[fid .. ":" .. i] = value
			end
		end
		return {
			domain = "corner",
			dataType = kind,
			default = kind == "number" and 0 or kind == "Vector2" and Vector2.zero or Color3.new(),
			interpolation = "linear",
			values = values,
		},
			nil
	end
	assert(
		type(token) == "string" and token:sub(1, 10) == "attribute:",
		"Face-varying channel must be uv/color/alpha or attribute:name"
	)
	local name = token:sub(11)
	assert(name:sub(1, #PREFIX) ~= PREFIX, "Face-varying topology channels are reserved")
	local c = assert((mesh.attributes or {})[name], "Requested face-varying attribute is missing: " .. name)
	assert(
		c.domain == "corner" and c.interpolation == "linear",
		"Smooth face-varying attributes require the corner domain and linear numeric data"
	)
	A.schema(c)
	return c, name
end

function F.configure(options)
	local selected = options.faceVarying or {}
	local seams = options.faceVaryingSeams or {}
	assert(type(selected) == "table" and type(seams) == "table", "Face-varying options must be dictionaries")
	local copied, cut = {}, {}
	for token, mode in selected do
		assert(type(token) == "string" and modes[mode], "Unknown face-varying interpolation rule")
		copied[token] = mode
	end
	for token, value in seams do
		assert(
			type(token) == "string" and (type(value) == "table" or type(value) == "string"),
			"Face-varying seams require an edge set or edge boolean channel name"
		)
		cut[token] = U.copy(value)
		copied[token] = copied[token] or "linear"
	end
	return {
		modes = copied,
		seams = cut,
		first = true,
		work = 0,
		maxValues = U.integer(options.maxFaceVaryingValues or 1000000, 1),
		maxWork = U.integer(options.maxFaceVaryingWork or 20000000, 1),
		cancelled = options.cancelled,
		checkpoint = options.faceVaryingCheckpoint,
	}
end

local function topology(mesh, top, c, token, seams, ctx)
	local parent, location, halfEdges = {}, {}, {}
	local ids = (mesh.attributes or {})[PREFIX .. token]
	if ids then
		assert(
			ids.domain == "corner"
				and ids.dataType == "number"
				and ids.interpolation == "nearest"
				and ids.default == 0,
			"Conflicting face-varying topology schema"
		)
	end
	local function root(key)
		local p = parent[key]
		while p ~= parent[p] do
			p = parent[p]
		end
		while key ~= p do
			local nextKey = parent[key]
			parent[key] = p
			key = nextKey
		end
		return p
	end
	local function union(a, b)
		a, b = root(a), root(b)
		if a ~= b then
			if a < b then
				parent[b] = a
			else
				parent[a] = b
			end
		end
	end
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		for i, v in face.vertices do
			ctx.visit()
			local key = fid .. ":" .. i
			parent[key] = key
			location[key] = { face = fid, corner = i, vertex = v }
			if ids then
				-- New corners from other builders use the schema default: a fresh chart.
				U.integer(A.read(ids, key), 0)
			end
			local nextIndex = i % #face.vertices + 1
			local e = U.edge(v, face.vertices[nextIndex])
			halfEdges[e] = halfEdges[e] or {}
			table.insert(halfEdges[e], {
				face = fid,
				corner = i,
				a = key,
				b = fid .. ":" .. nextIndex,
				va = v,
				vb = face.vertices[nextIndex],
			})
		end
	end
	local cut = {}
	if type(seams) == "string" then
		local attribute = assert((mesh.attributes or {})[seams], "Face-varying seam channel is missing")
		assert(
			attribute.domain == "edge" and attribute.dataType == "boolean",
			"Face-varying seam channel must be edge boolean"
		)
		for key in top.edges do
			if A.read(attribute, key) then
				cut[key] = true
			end
		end
	else
		for key, value in seams or {} do
			assert(
				top.edges[key] and type(value) == "boolean",
				"Face-varying seam set contains a missing edge or nonboolean"
			)
			if value then
				cut[key] = true
			end
		end
	end
	local continuous = {}
	for key, pair in halfEdges do
		if #pair == 2 and not cut[key] then
			local a, b = pair[1], pair[2]
			local aa, ab = a.a, a.b
			local ba, bb = b.va == a.va and b.a or b.b, b.va == a.va and b.b or b.a
			local same = A.read(c, aa) == A.read(c, ba) and A.read(c, ab) == A.read(c, bb)
			if ids then
				same = same and A.read(ids, aa) == A.read(ids, ba) and A.read(ids, ab) == A.read(ids, bb)
			end
			if same then
				union(aa, ba)
				union(ab, bb)
				continuous[key] = true
			end
		end
	end
	local vertices, byCorner, counts, group = {}, {}, {}, {}
	for _, key in U.keys(parent) do
		ctx.visit()
		local r = root(key)
		if not group[r] then
			local id = #vertices + 1
			group[r] = id
			local original = location[key].vertex
			vertices[id] = { ref = key, original = original, faces = {}, edges = {} }
			counts[original] = (counts[original] or 0) + 1
		end
		byCorner[key] = group[r]
	end
	local edges, faces, byHalf = {}, {}, {}
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		local f = { vertices = {}, edges = {} }
		faces[fid] = f
		for i in face.vertices do
			local key = fid .. ":" .. i
			local id = byCorner[key]
			f.vertices[i] = id
			table.insert(vertices[id].faces, fid)
		end
		for i, a in f.vertices do
			ctx.visit()
			local j = i % #f.vertices + 1
			local b = f.vertices[j]
			local original = U.edge(face.vertices[i], face.vertices[j])
			local key = original .. (continuous[original] and "" or "/" .. fid)
			if not edges[key] then
				edges[key] = { a = a, b = b, original = original, faces = {} }
				table.insert(vertices[a].edges, key)
				table.insert(vertices[b].edges, key)
			end
			table.insert(edges[key].faces, fid)
			f.edges[i] = key
			byHalf[fid .. ":" .. i] = key
		end
	end
	return {
		vertices = vertices,
		edges = edges,
		faces = faces,
		counts = counts,
		byCorner = byCorner,
		byHalf = byHalf,
	}
end

local function stencils(chart, geometric, mode, ctx)
	local function add(out, mask, weight)
		for key, value in mask do
			ctx.visit()
			out[key] = (out[key] or 0) + value * weight
		end
	end
	local function combine(a, b, factor)
		local out = {}
		add(out, a, 1 - factor)
		add(out, b, factor)
		return out
	end
	local base, faceMask, edgeMask, vertexMask = {}, {}, {}, {}
	for id, vertex in chart.vertices do
		base[id] = { [vertex.ref] = 1 }
	end
	for fid, face in chart.faces do
		local mask = {}
		for _, v in face.vertices do
			add(mask, base[v], 1 / #face.vertices)
		end
		faceMask[fid] = mask
	end
	for key, edge in chart.edges do
		local midpoint = {}
		add(midpoint, base[edge.a], 0.5)
		add(midpoint, base[edge.b], 0.5)
		local value = geometric.edges[edge.original]
		if mode == "linear" or #edge.faces == 1 or value >= 1 then
			edgeMask[key] = midpoint
		else
			local smooth = {}
			add(smooth, midpoint, 0.5)
			for _, fid in edge.faces do
				add(smooth, faceMask[fid], 0.25)
			end
			edgeMask[key] = combine(smooth, midpoint, value)
		end
	end
	for id, vertex in chart.vertices do
		local boundary, parents, children = {}, {}, {}
		local sharp = geometric.vertices[vertex.original]
		local childSharp = geometric.childVertices[vertex.original]
		for _, key in vertex.edges do
			local edge = chart.edges[key]
			local other = edge.a == id and edge.b or edge.a
			local originalOther = chart.vertices[other].original
			parents[key] = #edge.faces == 1 and 10 or geometric.edges[edge.original]
			children[key] = #edge.faces == 1 and 10 or geometric.children[vertex.original][originalOther]
			if #edge.faces == 1 then
				table.insert(boundary, key)
			end
		end
		assert(#boundary == 0 or #boundary == 2, "Face-varying data must have connected manifold corner fans")
		local pin = mode == "linear"
			or (
				#boundary > 0
				and (
					mode == "boundaries"
					or (mode ~= "smooth" and #vertex.faces == 1)
					or ((mode == "junctions" or mode == "concave") and chart.counts[vertex.original] >= 3)
					or (
						mode == "concave"
						and (
							#vertex.faces > 2
							or chart.edges[boundary[1]].original == chart.edges[boundary[2]].original
						)
					)
				)
			)
		if pin then
			sharp, childSharp = 10, 10
		end
		local smooth = {}
		if #boundary == 2 then
			add(smooth, base[id], 0.75)
			for _, key in boundary do
				local e = chart.edges[key]
				add(smooth, base[e.a == id and e.b or e.a], 0.125)
			end
		else
			local n = #vertex.edges
			assert(n >= 2, "Face-varying interior vertex requires at least two incident edges")
			add(smooth, base[id], (n - 3) / n)
			for _, fid in vertex.faces do
				add(smooth, faceMask[fid], 1 / (n * #vertex.faces))
			end
			for _, key in vertex.edges do
				local e = chart.edges[key]
				add(smooth, base[id], 1 / (n * n))
				add(smooth, base[e.a == id and e.b or e.a], 1 / (n * n))
			end
		end
		local function mask(vertexSharp, values)
			local adjacent = {}
			for _, key in U.keys(values) do
				if values[key] > 0 then
					adjacent[#adjacent + 1] = key
				end
			end
			if vertexSharp > 0 or #adjacent > 2 then
				return base[id]
			end
			if #adjacent ~= 2 then
				return smooth
			end
			local out = {}
			add(out, base[id], 0.75)
			for _, key in adjacent do
				local e = chart.edges[key]
				add(out, base[e.a == id and e.b or e.a], 0.125)
			end
			return out
		end
		local sum, count = 0, 0
		if sharp > 0 and childSharp == 0 then
			sum += sharp
			count += 1
		end
		for key, value in parents do
			if value > 0 and children[key] == 0 then
				sum += value
				count += 1
			end
		end
		vertexMask[id] = combine(
			mask(childSharp, children),
			mask(sharp, parents),
			count == 0 and 0 or math.min(1, sum / count)
		)
	end
	return vertexMask, edgeMask, faceMask
end

function F.prepare(source, config)
	local selected = table.clone(config.modes)
	for name in source.attributes or {} do
		if name:sub(1, #PREFIX) == PREFIX then
			local token = name:sub(#PREFIX + 1)
			selected[token] = selected[token] or "linear"
		end
	end
	if not next(selected) then
		return selected
	end
	local corners = 0
	for _, face in source.faces do
		corners += #face.vertices
	end
	assert(
		corners * 10 * U.count(selected) <= config.maxValues,
		"Face-varying value allocation budget exceeded"
	)
	return selected
end

function F.apply(source, target, top, geometric, childFaces, config, selected)
	if not next(selected) then
		config.first = false
		return
	end
	local ctx = {}
	local token
	local function check(stage)
		assert(not config.cancelled or not config.cancelled(), "Subdivision cancelled")
		if config.checkpoint then
			config.checkpoint({ stage = stage, work = config.work, channel = token })
		end
	end
	ctx.visit = function()
		config.work += 1
		assert(config.work <= config.maxWork, "Face-varying work budget exceeded")
		if config.work % 256 == 0 then
			check("refine")
		end
	end
	for _, name in U.keys(selected) do
		token = name
		check("channel")
		local c, attribute = channel(source, token)
		local chart = topology(source, top, c, token, config.first and config.seams[token] or nil, ctx)
		local vm, em, fm = stencils(chart, geometric, selected[token], ctx)
		local values, identities = {}, {}
		local function value(mask)
			local refs = {}
			for _, key in U.keys(mask) do
				ctx.visit()
				assert(U.finite(mask[key]) and mask[key] >= -1e-12, "Invalid face-varying stencil")
				if mask[key] > 0 then
					refs[#refs + 1] = { key, mask[key] }
				end
			end
			return A.blend(c, refs)
		end
		local vv, ev, fv, vi, ei, fi = {}, {}, {}, {}, {}, {}
		local nextId = 0
		for id in chart.vertices do
			nextId += 1
			vi[id] = nextId
			vv[id] = value(vm[id])
		end
		for _, key in U.keys(chart.edges) do
			nextId += 1
			ei[key] = nextId
			ev[key] = value(em[key])
		end
		for _, fid in U.keys(chart.faces) do
			nextId += 1
			fi[fid] = nextId
			fv[fid] = value(fm[fid])
		end
		for fid, face in chart.faces do
			for i, v in face.vertices do
				local before = (i - 2) % #face.vertices + 1
				local nextEdge, previousEdge = face.edges[i], face.edges[before]
				local child = childFaces[fid][i]
				local data = { vv[v], ev[nextEdge], fv[fid], ev[previousEdge] }
				local indices = { vi[v], ei[nextEdge], fi[fid], ei[previousEdge] }
				for j = 1, 4 do
					ctx.visit()
					local key = child .. ":" .. j
					identities[key] = indices[j]
					if attribute then
						if data[j] ~= c.default then
							values[key] = data[j]
						end
					else
						target.faces[child].corners[j][token] = data[j]
					end
				end
			end
		end
		if attribute then
			target.attributes[attribute].values = values
		end
		target.attributes[PREFIX .. token] = {
			domain = "corner",
			dataType = "number",
			default = 0,
			interpolation = "nearest",
			values = identities,
		}
	end
	config.first = false
	check("finish")
	A.validate(target)
end
return F
