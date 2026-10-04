local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local FaceVarying = require(script.Parent.SubdivisionFaceVarying)
local Limit = require(script.Parent.SubdivisionLimit)
local S = {}
local EDGE_CREASE = "subdivision_edge_sharpness"
local VERTEX_CREASE = "subdivision_vertex_sharpness"
local function sharpness(value)
	assert(
		type(value) == "number" and U.finite(value) and value >= 0 and value <= 10,
		"Subdivision sharpness must be in [0,10]"
	)
	return value
end
local function decay(value)
	return value == 10 and 10 or math.max(0, value - 1)
end
function S.crease(mesh, edges, vertices)
	local out = mesh:clone()
	out.attributes = out.attributes or {}
	for _, entry in { { EDGE_CREASE, "edge", edges }, { VERTEX_CREASE, "vertex", vertices } } do
		if entry[3] then
			local name, domain, values = entry[1], entry[2], entry[3]
			local channel = out.attributes[name]
				or { domain = domain, dataType = "number", default = 0, interpolation = "max", values = {} }
			assert(
				channel.domain == domain
					and channel.dataType == "number"
					and channel.default == 0
					and channel.interpolation == "max",
				"Conflicting subdivision crease channel"
			)
			for key, value in values do
				channel.values[key] = sharpness(value)
			end
			out.attributes[name] = channel
		end
	end
	A.validate(out)
	out.revision += 1
	return out
end
local function configuration(options)
	options = options or {}
	local boundary = options.boundary or "edge"
	local method = options.creasing or "uniform"
	assert(
		boundary == "edge" or boundary == "edgeAndCorner" or boundary == "fixed",
		"Unknown subdivision boundary rule"
	)
	assert(method == "uniform" or method == "chaikin", "Unknown creasing method")
	local maxVertices = U.integer(options.maxVertices or 250000, 1)
	local maxFaces = U.integer(options.maxFaces or 250000, 1)
	return {
		boundary = boundary,
		creasing = method,
		maxVertices = maxVertices,
		maxFaces = maxFaces,
		checkpoint = options.checkpoint,
		cancelled = options.cancelled,
		faceVarying = FaceVarying.configure(options),
	}
end
local function creaseState(m, top, options)
	A.validate(m)
	local edgeChannel = (m.attributes or {})[EDGE_CREASE]
	local vertexChannel = (m.attributes or {})[VERTEX_CREASE]
	for _, entry in { { edgeChannel, "edge" }, { vertexChannel, "vertex" } } do
		local channel = entry[1]
		if channel then
			assert(
				channel.domain == entry[2]
					and channel.dataType == "number"
					and channel.default == 0
					and channel.interpolation == "max",
				"Invalid subdivision crease channel"
			)
			for _, value in channel.values do
				sharpness(value)
			end
		end
	end
	local state = { edges = {}, vertices = {}, children = {}, childVertices = {} }
	for key, e in top.edges do
		state.edges[key] = #e.faces == 1 and 10 or (edgeChannel and A.read(edgeChannel, key) or 0)
	end
	for v in m.vertices do
		local faces = top.vertexFaces[v]
		if #faces > 0 then
			local queue, seen = { faces[1] }, { [faces[1]] = true }
			local cursor = 1
			while cursor <= #queue do
				local face = m.faces[queue[cursor]]
				cursor += 1
				local index = table.find(face.vertices, v)
				for _, other in
					{
						face.vertices[index % #face.vertices + 1],
						face.vertices[(index - 2) % #face.vertices + 1],
					}
				do
					for _, fid in top.edges[U.edge(v, other)].faces do
						if not seen[fid] then
							seen[fid] = true
							table.insert(queue, fid)
						end
					end
				end
			end
			assert(#queue == #faces, "Subdivision requires connected vertex fans")
		end
		local boundary, sum, count = 0, 0, 0
		for other in top.neighbors[v] do
			local key = U.edge(v, other)
			if #top.edges[key].faces == 1 then
				boundary += 1
			end
			local value = state.edges[key]
			if value > 0 and value < 10 then
				sum += value
				count += 1
			end
		end
		assert(boundary == 0 or boundary == 2, "Nonmanifold boundary vertex")
		local value = vertexChannel and A.read(vertexChannel, v) or 0
		if
			boundary > 0
			and (
				options.boundary == "fixed"
				or (options.boundary == "edgeAndCorner" and #top.vertexFaces[v] == 1)
			)
		then
			value = 10
		end
		state.vertices[v], state.childVertices[v] = value, decay(value)
		local children = {}
		state.children[v] = children
		for other in top.neighbors[v] do
			local parent = state.edges[U.edge(v, other)]
			if options.creasing == "chaikin" and parent > 0 and parent < 10 and count > 1 then
				children[other] = math.max(0, (3 * parent + (sum - parent) / (count - 1)) / 4 - 1)
			else
				children[other] = decay(parent)
			end
		end
	end
	return state
end
local function vertexMask(mesh, v, smooth, vertexSharp, edges)
	local adjacent = {}
	for _, other in U.keys(edges) do
		if edges[other] > 0 then
			table.insert(adjacent, other)
		end
	end
	local p = mesh.vertices[v]
	if vertexSharp > 0 or #adjacent > 2 then
		return p
	end
	if #adjacent == 2 then
		return p * 0.75 + (mesh.vertices[adjacent[1]] + mesh.vertices[adjacent[2]]) * 0.125
	end
	return smooth
end
local function averageCorners(corners)
	local c = {}
	for _, key in { "uv", "color", "alpha", "tangent", "tangentSign" } do
		local sum, n = nil, 0
		for _, a in corners do
			if a[key] then
				sum = sum and U.mix(sum, a[key], 1 / (n + 1)) or a[key]
				n += 1
			end
		end
		c[key] = sum
	end
	return c
end
local function step(m, options)
	local top = m:topology()
	local faceVaryingChannels = FaceVarying.prepare(m, options.faceVarying)
	local nextFaces = 0
	for _, f in m.faces do
		nextFaces += #f.vertices
	end
	assert(
		nextFaces <= options.maxFaces
			and U.count(m.vertices) + U.count(top.edges) + U.count(m.faces) <= options.maxVertices,
		"Subdivision allocation budget exceeded"
	)
	local creases = creaseState(m, top, options)
	local out = Mesh.new()
	local fp, ep, vp = {}, {}, {}
	for fid, f in m.faces do
		local p = Vector3.zero
		for _, v in f.vertices do
			p += m.vertices[v]
		end
		fp[fid] = p / #f.vertices
	end
	for key, e in top.edges do
		assert(
			#e.faces <= 2 and (#e.faces < 2 or e.directions[1] ~= e.directions[2]),
			"Subdivision requires consistently wound manifold edges"
		)
		local p = m.vertices[e.a] + m.vertices[e.b]
		local smooth = #e.faces == 2 and (p + fp[e.faces[1]] + fp[e.faces[2]]) / 4 or p / 2
		ep[key] = smooth:Lerp(p / 2, math.min(creases.edges[key], 1))
	end
	for v, p in m.vertices do
		local ns = top.neighbors[v]
		local boundary = {}
		local edgeSum = Vector3.zero
		local n = 0
		for other in ns do
			local e = top.edges[U.edge(v, other)]
			if #e.faces == 1 then
				table.insert(boundary, other)
			end
			edgeSum += (p + m.vertices[other]) / 2
			n += 1
		end
		if #boundary > 0 then
			assert(#boundary == 2, "Nonmanifold boundary vertex")
			vp[v] = p * 0.75 + (m.vertices[boundary[1]] + m.vertices[boundary[2]]) * 0.125
		elseif n > 0 then
			local fsum = Vector3.zero
			for _, fid in top.vertexFaces[v] do
				fsum += fp[fid]
			end
			vp[v] = (fsum / #top.vertexFaces[v] + 2 * edgeSum / n + (n - 3) * p) / n
		else
			vp[v] = p
		end
	end
	for v, smooth in vp do
		local parents, sum, count = {}, 0, 0
		local vertexSharp = creases.vertices[v]
		if vertexSharp > 0 and creases.childVertices[v] == 0 then
			sum += vertexSharp
			count += 1
		end
		for other in top.neighbors[v] do
			local value = creases.edges[U.edge(v, other)]
			parents[other] = value
			if value > 0 and creases.children[v][other] == 0 then
				sum += value
				count += 1
			end
		end
		local parentMask = vertexMask(m, v, smooth, vertexSharp, parents)
		local childMask = vertexMask(m, v, smooth, creases.childVertices[v], creases.children[v])
		vp[v] = childMask:Lerp(parentMask, count == 0 and 0 or math.min(1, sum / count))
	end
	local vids, eids, fids = {}, {}, {}
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = { vertex = false, edge = false, face = false, corner = false },
	}
	for _, v in U.keys(vp) do
		vids[v] = out:addVertex(vp[v])
		maps.vertex[vids[v]] = { { v, 1 } }
		out.weights[vids[v]] = U.copy(m.weights[v])
	end
	for _, key in U.keys(ep) do
		eids[key] = out:addVertex(ep[key])
		local e = top.edges[key]
		maps.vertex[eids[key]] = { { e.a, 1 }, { e.b, 1 } }
		maps.edge[U.edge(vids[e.a], eids[key])] = { { key, 1 } }
		maps.edge[U.edge(eids[key], vids[e.b])] = { { key, 1 } }
	end
	for _, fid in U.keys(fp) do
		fids[fid] = out:addVertex(fp[fid])
		local refs = {}
		for _, v in m.faces[fid].vertices do
			table.insert(refs, { v, 1 })
		end
		maps.vertex[fids[fid]] = refs
	end
	local childFaces = {}
	for _, fid in U.keys(m.faces) do
		local f = m.faces[fid]
		childFaces[fid] = {}
		local fc = averageCorners(f.corners)
		for i, v in f.vertices do
			local j = i % #f.vertices + 1
			local k = (i - 2) % #f.vertices + 1
			local newFace = out:addFace(
				{ vids[v], eids[U.edge(v, f.vertices[j])], fids[fid], eids[U.edge(f.vertices[k], v)] },
				{
					f.corners[i],
					averageCorners({ f.corners[i], f.corners[j] }),
					fc,
					averageCorners({ f.corners[k], f.corners[i] }),
				},
				f.material
			)
			maps.face[newFace] = { { fid, 1 } }
			childFaces[fid][i] = newFace
			maps.corner[newFace .. ":1"] = { { fid .. ":" .. i, 1 } }
			maps.corner[newFace .. ":2"] = { { fid .. ":" .. i, 1 }, { fid .. ":" .. j, 1 } }
			local refs = {}
			for c = 1, #f.vertices do
				table.insert(refs, { fid .. ":" .. c, 1 })
			end
			maps.corner[newFace .. ":3"] = refs
			maps.corner[newFace .. ":4"] = { { fid .. ":" .. k, 1 }, { fid .. ":" .. i, 1 } }
		end
	end
	A.transfer(m, out, maps)
	FaceVarying.apply(m, out, top, creases, childFaces, options.faceVarying, faceVaryingChannels)
	-- Creases decay by ancestry, rather than generic scalar interpolation.
	local nextEdge = out.attributes[EDGE_CREASE]
	if nextEdge then
		nextEdge.values = {}
		for key, e in top.edges do
			local a, b = creases.children[e.a][e.b], creases.children[e.b][e.a]
			if #e.faces == 1 then
				local authored = A.read(m.attributes[EDGE_CREASE], key)
				a, b = decay(authored), decay(authored)
			end
			if a > 0 then
				nextEdge.values[U.edge(vids[e.a], eids[key])] = a
			end
			if b > 0 then
				nextEdge.values[U.edge(vids[e.b], eids[key])] = b
			end
		end
	end
	local nextVertex = out.attributes[VERTEX_CREASE]
	if nextVertex then
		nextVertex.values = {}
		for v in creases.childVertices do
			local value = decay(A.read(m.attributes[VERTEX_CREASE], v))
			if value > 0 then
				nextVertex.values[vids[v]] = value
			end
		end
	end
	-- Interpolate vertex weights and scalar selection groups with the same topology.
	local function blend(tables)
		local r = {}
		for _, t in tables do
			for key, w in t do
				r[key] = (r[key] or 0) + w / #tables
			end
		end
		return r
	end
	for key, e in top.edges do
		out.weights[eids[key]] = blend({ m.weights[e.a] or {}, m.weights[e.b] or {} })
	end
	for fid, f in m.faces do
		local list = {}
		for _, v in f.vertices do
			table.insert(list, m.weights[v] or {})
		end
		out.weights[fids[fid]] = blend(list)
	end
	for name, g in m.groups do
		local ng = {}
		out.groups[name] = ng
		for v, id in vids do
			ng[id] = g[v] or 0
		end
		for key, e in top.edges do
			ng[eids[key]] = ((g[e.a] or 0) + (g[e.b] or 0)) / 2
		end
		for fid, f in m.faces do
			local sum = 0
			for _, v in f.vertices do
				sum += g[v] or 0
			end
			ng[fids[fid]] = sum / #f.vertices
		end
	end
	local normalEdges = {}
	local normalChannel = out.attributes.sharp_edge
	if normalChannel then
		assert(
			normalChannel.domain == "edge" and normalChannel.dataType == "boolean",
			"Sharp normal attribute must be edge boolean"
		)
		for key in out:topology().edges do
			if A.read(normalChannel, key) then
				normalEdges[key] = true
			end
		end
	end
	if nextEdge then
		for key, value in nextEdge.values do
			if value == 10 then
				normalEdges[key] = true
			end
		end
	end
	return out:recalculateNormals(nil, next(normalEdges) and normalEdges or nil)
end
function S.prepareLimit(mesh, options)
	options = table.clone(options or {})
	assert(
		options.exactConstrainedJets == nil or type(options.exactConstrainedJets) == "boolean",
		"exactConstrainedJets must be boolean"
	)
	assert(
		options.exactConstrainedNormals == nil or type(options.exactConstrainedNormals) == "boolean",
		"exactConstrainedNormals must be boolean"
	)
	assert(
		options.exactPolynomialNormals == nil or type(options.exactPolynomialNormals) == "boolean",
		"exactPolynomialNormals must be boolean"
	)
	if options.exactConstrainedNormals or options.exactPolynomialNormals then
		options.maxNormalPolynomialDegree = U.integer(options.maxNormalPolynomialDegree or 128, 1)
		assert(
			options.maxNormalPolynomialDegree <= 512,
			"Normal polynomial degree budget must not exceed 512"
		)
		options.maxNormalTarskiQueries = U.integer(options.maxNormalTarskiQueries or 100000, 1)
		options.maxNormalProjectionPolynomials = U.integer(options.maxNormalProjectionPolynomials or 256, 1)
		options.maxWork = U.integer(options.maxWork or 500000000, 1)
		options.maxNormalKrylovDegree = U.integer(options.maxNormalKrylovDegree or 128, 1)
		options.maxNormalSubspaceDimension = U.integer(options.maxNormalSubspaceDimension or 128, 1)
		options.maxNormalPrimes = U.integer(options.maxNormalPrimes or 128, 1)
		options.maxNormalCells = U.integer(options.maxNormalCells or 10000, 1)
		options.maxNormalDepth = U.integer(options.maxNormalDepth or 16, 0)
		options.maxRootDepth = U.integer(options.maxRootDepth or 128, 1)
		options.maxRootNodes = U.integer(options.maxRootNodes or 100000, 1)
		options.normalTolerance = options.normalTolerance or 1e-5
		assert(
			U.finite(options.normalTolerance) and options.normalTolerance > 0,
			"Normal tolerance must be finite and positive"
		)
	end
	if options.exactConstrainedJets or options.exactConstrainedNormals or options.exactPolynomialNormals then
		options.maxExactBits = U.integer(options.maxExactBits or 8192, 1)
		options.maxExactCoefficients = U.integer(
			options.maxExactCoefficients
				or (
					(options.exactConstrainedNormals or options.exactPolynomialNormals) and 20000000
					or 1000000
				),
			1
		)
		options.maxKrylovDegree = U.integer(options.maxKrylovDegree or 128, 1)
	end
	local config = configuration(options)
	assert(
		U.count(mesh.vertices) <= config.maxVertices and U.count(mesh.faces) <= config.maxFaces,
		"Limit input allocation budget exceeded"
	)
	assert(not options.cancelled or not options.cancelled(), "Limit evaluation cancelled")
	local corners, maxCorners = 0, U.integer(options.maxCorners or 1000000, 1)
	for _, p in mesh.vertices do
		assert(U.vector(p), "Limit evaluation requires finite native positions")
	end
	for _, face in mesh.faces do
		corners += #face.vertices
		assert(corners <= maxCorners, "Limit input corner budget exceeded")
		local seen = {}
		assert(#face.vertices >= 3, "Limit faces require at least three vertices")
		for _, id in face.vertices do
			assert(mesh.vertices[id] and not seen[id], "Malformed limit face")
			seen[id] = true
		end
	end
	local top = mesh:topology()
	for _, e in top.edges do
		assert(
			#e.faces <= 2 and (#e.faces < 2 or e.directions[1] ~= e.directions[2]),
			"Limit evaluation requires consistently wound manifold edges"
		)
	end
	return Limit.prepare(mesh, options, config, creaseState(mesh, top, config))
end
function S.limit(mesh, face, u, v, options)
	return S.prepareLimit(mesh, options):evaluate(face, u, v, options and options.corner)
end
function S.catmullClark(mesh, levels, options)
	U.integer(levels or 1, 0)
	assert((levels or 1) <= 16, "Subdivision level budget exceeded")
	options = configuration(options)
	local out = mesh:clone()
	for level = 1, levels or 1 do
		assert(not options.cancelled or not options.cancelled(), "Subdivision cancelled")
		if options.checkpoint then
			options.checkpoint((level - 1) / (levels or 1))
		end
		out = step(out, options)
	end
	return out
end
function S.multires(mesh, levels, options)
	U.integer(levels, 0)
	assert(levels <= 16, "Subdivision level budget exceeded")
	options = configuration(options)
	local stack = { mesh:clone() }
	for level = 1, levels do
		assert(not options.cancelled or not options.cancelled(), "Subdivision cancelled")
		if options.checkpoint then
			options.checkpoint((level - 1) / levels)
		end
		table.insert(stack, step(stack[#stack], options))
	end
	local multires = { levels = stack, active = #stack }
	function multires:get()
		return self.levels[self.active]:clone()
	end
	function multires:select(n)
		assert(self.levels[n])
		self.active = n
		return self:get()
	end
	local function frames(m)
		local topology = m:topology()
		local result = {}
		local normals = {}
		for fid, f in m.faces do
			local n, a = m:faceNormal(fid)
			for _, v in f.vertices do
				normals[v] = (normals[v] or Vector3.zero) + n * a
			end
		end
		for id, p in m.vertices do
			local n = U.unit(normals[id], Vector3.yAxis)
			local first = U.keys(topology.neighbors[id])[1]
			local t = first and m.vertices[first] - p or Vector3.xAxis
			t = t - n * t:Dot(n)
			if t.Magnitude < 1e-10 then
				t = U.frame(n)
			end
			t = U.unit(t)
			result[id] = { t, n:Cross(t), n }
		end
		return result
	end
	function multires:commit(edited)
		options.faceVarying.work = 0
		local index = self.active
		local old = self.levels[index]
		assert(
			U.count(old.vertices) == U.count(edited.vertices) and U.count(old.faces) == U.count(edited.faces),
			"Multires edit must preserve topology"
		)
		for id, f in old.faces do
			assert(
				edited.faces[id]
					and table.concat(f.vertices, ",") == table.concat(edited.faces[id].vertices, ","),
				"Multires topology changed"
			)
		end
		local previousOld, previousNew = old, edited:clone()
		local replacements = { [index] = previousNew }
		for level = index + 1, #self.levels do
			assert(not options.cancelled or not options.cancelled(), "Subdivision cancelled")
			local originalFine = self.levels[level]
			options.faceVarying.first = level == 2
			local oldBase = step(previousOld, options)
			options.faceVarying.first = level == 2
			local newBase = step(previousNew, options)
			local oldFrames, newFrames = frames(oldBase), frames(newBase)
			local fine = newBase:clone()
			for id, p in originalFine.vertices do
				local residual = p - oldBase.vertices[id]
				local a, b = oldFrames[id], newFrames[id]
				fine.vertices[id] += b[1] * residual:Dot(a[1]) + b[2] * residual:Dot(a[2]) + b[3] * residual:Dot(
					a[3]
				)
			end
			local normalEdges = {}
			local edgeCrease = fine.attributes[EDGE_CREASE]
			local sharp = fine.attributes.sharp_edge
			for key in fine:topology().edges do
				if (edgeCrease and A.read(edgeCrease, key) == 10) or (sharp and A.read(sharp, key)) then
					normalEdges[key] = true
				end
			end
			fine:recalculateNormals(nil, next(normalEdges) and normalEdges or nil)
			replacements[level] = fine
			previousOld, previousNew = originalFine, fine
		end
		for level, m in replacements do
			self.levels[level] = m
		end
		return self:get()
	end
	return multires
end
return S
