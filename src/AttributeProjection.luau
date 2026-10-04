-- Private transactional data projection with face-anchored connected corner charts.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local C = require(script.Parent.Connectivity)
local Edit = require(script.Parent.MeshEditCore)
local Seams = require(script.Parent.AttributeSeams)
local Index = require(script.Parent.ProjectionIndex)
return function(source, target, options)
	options = options or {}
	A.validate(source)
	A.validate(target)
	local factor = options.factor or 1
	assert(
		type(factor) == "number" and U.finite(factor) and factor >= 0 and factor <= 1,
		"Projection factor must lie in [0,1]"
	)
	local maximum = options.maxDistance or math.huge
	assert(
		type(maximum) == "number" and maximum >= 0 and maximum == maximum,
		"Nonnegative projection distance required"
	)
	local cornerMode = options.cornerMode or "chart"
	assert(cornerMode == "chart" or cornerMode == "nearest", "Unknown corner projection mode")
	local unmatched = options.unmatched or "error"
	assert(unmatched == "error" or unmatched == "keep", "Unknown unmatched projection policy")
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local maxQueries = U.integer(options.maxQueries or 2000000, 1)
	for _, name in { "uvTolerance", "attributeTolerance" } do
		assert(
			options[name] == nil
				or type(options[name]) == "number" and U.finite(options[name]) and options[name] >= 0,
			"Nonnegative finite projection seam tolerance required"
		)
	end
	local report = {
		complete = true,
		work = 0,
		queries = 0,
		sourceCharts = 0,
		maxSourceDistance = 0,
		matched = { vertex = 0, edge = 0, face = 0, corner = 0 },
		unmatched = { vertex = {}, edge = {}, face = {}, corner = {} },
		maps = {
			vertex = {},
			edge = {},
			face = {},
			corner = {},
			identity = { vertex = false, edge = false, face = false, corner = false },
		},
	}
	local function checkpoint()
		assert(not options.cancelled or not options.cancelled(), "Attribute projection cancelled")
		if options.checkpoint then
			options.checkpoint({
				stage = "project",
				work = report.work,
				queries = report.queries,
				maxWork = maxWork,
			})
		end
	end
	local function visit()
		report.work += 1
		assert(report.work <= maxWork, "Attribute projection work budget exceeded")
		if report.work % 256 == 0 then
			checkpoint()
		end
	end
	checkpoint()
	local topologyOptions = {
		maxElements = options.maxElements,
		checkpoint = function()
			checkpoint()
		end,
	}
	local sourceIndex, targetIndex = C.index(source, topologyOptions), C.index(target, topologyOptions)
	assert(
		source:validate().valid and target:validate().valid,
		"Projection requires valid source and target topology"
	)
	local targetKeys = {
		vertex = targetIndex.vertices,
		edge = targetIndex.edges,
		face = targetIndex.faces,
		corner = targetIndex.corners,
	}
	local masks = options.masks or {}
	for domain, mask in masks do
		assert(
			targetKeys[domain] and type(mask) == "table",
			"Projection masks require target domain dictionaries"
		)
		for key, weight in mask do
			assert(targetKeys[domain][key], "Projection mask refers to missing element")
			assert(
				type(weight) == "boolean"
					or type(weight) == "number" and U.finite(weight) and weight >= 0 and weight <= 1,
				"Projection mask values must lie in [0,1]"
			)
		end
	end
	local function amount(domain, key)
		if not masks[domain] then
			return factor
		end
		local value = masks[domain][key]
		return factor * (value == true and 1 or type(value) == "number" and value or 0)
	end
	local names = options.names or U.keys(source.attributes)
	local selected, needed, channels = {}, {}, {}
	for _, name in names do
		assert(not selected[name], "Duplicate projection channel")
		local channel = assert(source.attributes[name], "Missing source projection channel")
		selected[name], needed[channel.domain], channels[name] = true, true, channel
		local existing = target.attributes[name]
		assert(
			not existing
				or existing.domain == channel.domain
					and existing.dataType == channel.dataType
					and existing.default == channel.default
					and existing.interpolation == channel.interpolation,
			"Incompatible projection channel schema: " .. name
		)
	end
	local copyCorners, copyMaterials = options.corners ~= false, options.materials ~= false
	local copyGroups, copyWeights = options.groups ~= false, options.weights ~= false
	needed.vertex = needed.vertex or copyGroups or copyWeights
	needed.corner = needed.corner or copyCorners
	needed.face = needed.face or copyMaterials or needed.corner
	local faceSelection = {}
	if options.sourceFaces then
		for fid, value in options.sourceFaces do
			assert(source.faces[fid], "Missing selected source face")
			if value == true or type(value) == "number" and value > 0 then
				faceSelection[fid] = true
			end
		end
	else
		for fid in source.faces do
			faceSelection[fid] = true
		end
	end
	local labels, neighbors = {}, {}
	local featureNames = { sharp_edge = true, uv_seam = true, subdivision_edge_sharpness = true }
	for _, name in options.seamAttributes or {} do
		assert(source.attributes[name], "Missing projection seam channel")
		featureNames[name] = true
	end
	for name in featureNames do
		local channel = source.attributes[name]
		if channel then
			assert(
				channel.domain == "edge" and (channel.dataType == "number" or channel.dataType == "boolean"),
				"Projection seam channels must be scalar edge data"
			)
		end
	end
	for _, edge in sourceIndex.edges do
		visit()
		if #edge.faces == 2 and faceSelection[edge.faces[1]] and faceSelection[edge.faces[2]] then
			local fa, fb = edge.faces[1], edge.faces[2]
			local connected = true
			for _, id in { edge.a, edge.b } do
				connected = connected
					and Seams.same(
						source,
						fa,
						table.find(source.faces[fa].vertices, id),
						fb,
						table.find(source.faces[fb].vertices, id),
						options
					)
			end
			for name in featureNames do
				local channel = source.attributes[name]
				if channel then
					local value = A.read(channel, U.edge(edge.a, edge.b))
					if value == true or type(value) == "number" and value > 0 then
						connected = false
					end
				end
			end
			if connected then
				neighbors[fa], neighbors[fb] = neighbors[fa] or {}, neighbors[fb] or {}
				table.insert(neighbors[fa], fb)
				table.insert(neighbors[fb], fa)
			end
		end
	end
	for _, seed in U.keys(faceSelection) do
		if labels[seed] then
			continue
		end
		report.sourceCharts += 1
		local queue, cursor = { seed }, 1
		labels[seed] = report.sourceCharts
		while cursor <= #queue do
			visit()
			local fid = queue[cursor]
			cursor += 1
			for _, neighbor in neighbors[fid] or {} do
				if not labels[neighbor] then
					labels[neighbor] = report.sourceCharts
					table.insert(queue, neighbor)
				end
			end
		end
	end
	local triangles, charts, edges = {}, {}, {}
	for fid in faceSelection do
		charts[labels[fid]] = charts[labels[fid]] or {}
	end
	for _, fid in U.keys(faceSelection) do
		local face = source.faces[fid]
		for _, corners in source:faceTriangles(fid, { maxWork = maxWork, checkpoint = checkpoint }) do
			visit()
			local t = {
				face.vertices[corners[1]],
				face.vertices[corners[2]],
				face.vertices[corners[3]],
				face = fid,
				corners = corners,
			}
			local a, b, c = source.vertices[t[1]], source.vertices[t[2]], source.vertices[t[3]]
			local item = {
				a = a,
				b = b,
				c = c,
				triangle = t,
				face = fid,
				chart = labels[fid],
				order = #triangles + 1,
				lo = a:Min(b):Min(c),
				hi = a:Max(b):Max(c),
				center = (a + b + c) / 3,
			}
			table.insert(triangles, item)
			table.insert(charts[item.chart], item)
		end
	end
	for _, key in U.keys(sourceIndex.edges) do
		local edge, active = sourceIndex.edges[key], false
		for _, fid in edge.faces do
			active = active or faceSelection[fid]
		end
		if active then
			local a, b = source.vertices[edge.a], source.vertices[edge.b]
			table.insert(edges, {
				a = a,
				b = b,
				key = key,
				order = #edges + 1,
				lo = a:Min(b),
				hi = a:Max(b),
				center = (a + b) / 2,
			})
		end
	end
	local surfaceTree = Index.build(table.clone(triangles), visit)
	local edgeTree = needed.edge and Index.build(edges, visit) or nil
	local chartTrees = {}
	if needed.corner and cornerMode == "chart" then
		for id, items in charts do
			chartTrees[id] = Index.build(items, visit)
		end
	end
	local rankCache, rankOrder = {}, {}
	report.chartTieSearches, report.chartTieReferences = 0, 0
	local function preference(anchor)
		return function(a, b)
			if a.face == b.face then
				return a.order < b.order
			end
			if a.face == anchor then
				return true
			end
			if b.face == anchor then
				return false
			end
			local ranks = rankCache[anchor]
			if not ranks then
				report.chartTieSearches += 1
				ranks = { [anchor] = 0 }
				local queue, cursor = { anchor }, 1
				while cursor <= #queue do
					visit()
					local fid = queue[cursor]
					cursor += 1
					for _, neighbor in neighbors[fid] or {} do
						visit()
						if ranks[neighbor] == nil then
							ranks[neighbor] = ranks[fid] + 1
							table.insert(queue, neighbor)
						end
					end
				end
				report.chartTieReferences += #queue
				if #rankOrder == 16 then
					rankCache[table.remove(rankOrder, 1)] = nil
				end
				table.insert(rankOrder, anchor)
				rankCache[anchor] = ranks
			end
			local x, y = ranks[a.face] or math.huge, ranks[b.face] or math.huge
			return x == y and a.order < b.order or x < y
		end
	end
	local function query(tree, point, domain, key, prefer)
		report.queries += 1
		assert(report.queries <= maxQueries, "Attribute projection query budget exceeded")
		local hit = Index.closest(tree, point, maximum, visit, prefer)
		if not hit then
			report.complete = false
			report.unmatched[domain][key] = true
			assert(
				unmatched ~= "error",
				"Attribute projection exceeds source distance or has no selected source: "
					.. domain
					.. " "
					.. tostring(key)
			)
			return nil
		end
		report.matched[domain] += 1
		report.maxSourceDistance = math.max(report.maxSourceDistance, hit.distance)
		return hit
	end
	local function refs(hit, domain)
		if domain == "face" then
			return { { hit.item.face, 1 } }
		end
		if domain == "edge" then
			return { { hit.item.key, 1 } }
		end
		local t, bary = hit.item.triangle, { hit.barycentric.X, hit.barycentric.Y, hit.barycentric.Z }
		local result = {}
		for i = 1, 3 do
			local weight = math.max(0, bary[i])
			if weight > 0 then
				table.insert(
					result,
					{ domain == "vertex" and t[i] or hit.item.face .. ":" .. t.corners[i], weight }
				)
			end
		end
		return result
	end
	local maps, faceHits, cornerHits = report.maps, {}, {}
	if needed.vertex then
		for _, id in U.keys(target.vertices) do
			if amount("vertex", id) > 0 then
				local hit = query(surfaceTree, target.vertices[id], "vertex", id)
				if hit then
					maps.vertex[id] = refs(hit, "vertex")
				end
			end
		end
	end
	if needed.face then
		for _, fid in U.keys(target.faces) do
			local face, active = target.faces[fid], amount("face", fid) > 0
			if needed.corner then
				for i in face.vertices do
					active = active or amount("corner", fid .. ":" .. i) > 0
				end
			end
			if active then
				local center = Vector3.zero
				for _, id in face.vertices do
					center += target.vertices[id] / #face.vertices
				end
				local hit = query(surfaceTree, center, "face", fid)
				if hit then
					maps.face[fid], faceHits[fid] = refs(hit, "face"), hit
				end
			end
		end
	end
	if needed.corner then
		for _, fid in U.keys(target.faces) do
			local anchor = faceHits[fid]
			for i, id in target.faces[fid].vertices do
				local key = fid .. ":" .. i
				if amount("corner", key) > 0 then
					local tree = surfaceTree
					if cornerMode == "chart" then
						tree = anchor and chartTrees[anchor.item.chart] or nil
					end
					local hit = query(
						tree,
						target.vertices[id],
						"corner",
						key,
						cornerMode == "chart" and anchor and preference(anchor.item.face) or nil
					)
					if hit then
						maps.corner[key], cornerHits[key] = refs(hit, "corner"), hit
					end
				end
			end
		end
	end
	if needed.edge then
		for _, key in U.keys(targetIndex.edges) do
			if amount("edge", key) > 0 then
				local e = targetIndex.edges[key]
				local hit = query(edgeTree, (target.vertices[e.a] + target.vertices[e.b]) / 2, "edge", key)
				if hit then
					maps.edge[key] = refs(hit, "edge")
				end
			end
		end
	end
	local out = target:clone()
	local function blend(a, b, t, kind, mode)
		if t >= 1 or a == nil then
			return b
		end
		return A.blend({
			dataType = kind,
			default = a,
			values = { a, b },
			interpolation = mode or ((kind == "boolean" or kind == "string") and "nearest" or "linear"),
		}, { { 1, 1 - t }, { 2, t } })
	end
	for _, name in names do
		local channel = channels[name]
		local result = out.attributes[name] or U.copy(channel)
		if not out.attributes[name] then
			result.values = {}
		end
		for key, references in maps[channel.domain] do
			visit()
			local t = amount(channel.domain, key)
			if t > 0 then
				local value = blend(
					A.read(result, key),
					A.blend(channel, references),
					t,
					channel.dataType,
					channel.interpolation
				)
				if value == result.default then
					result.values[key] = nil
				else
					result.values[key] = value
				end
			end
		end
		out.attributes[name] = result
	end
	if copyWeights or copyGroups then
		local transferred = { weights = {}, groups = {} }
		A.vertexData(source, transferred, maps.vertex)
		if copyGroups then
			for name in source.groups do
				out.groups[name] = out.groups[name] or {}
			end
		end
		for id in maps.vertex do
			visit()
			local t = amount("vertex", id)
			if copyWeights then
				local weights = {}
				for bone, value in out.weights[id] or {} do
					weights[bone] = value * (1 - t)
				end
				for bone, value in transferred.weights[id] or {} do
					weights[bone] = (weights[bone] or 0) + value * t
				end
				local total = 0
				for _, value in weights do
					assert(
						U.finite(value) and value >= 0,
						"Projection skin weights must be finite and nonnegative"
					)
					total += value
				end
				assert(U.finite(total), "Projection skin weight overflow")
				if total > 0 then
					for bone, value in weights do
						weights[bone] = value / total
					end
				end
				out.weights[id] = weights
			end
			if copyGroups then
				for name, values in transferred.groups do
					out.groups[name][id] = (out.groups[name][id] or 0) * (1 - t) + values[id] * t
					assert(U.finite(out.groups[name][id]), "Projection group value must be finite")
				end
			end
		end
	end
	if copyMaterials then
		for fid, hit in faceHits do
			if amount("face", fid) > 0.5 then
				out.faces[fid].material = source.faces[hit.item.face].material
			end
		end
	end
	if copyCorners then
		for key, hit in cornerHits do
			visit()
			local ck = targetIndex.corners[key]
			local cr = {}
			for _, r in maps.corner[key] do
				local s = sourceIndex.corners[r[1]]
				table.insert(cr, { s.face, s.index, r[2] })
			end
			local sampled = Edit.corner(source, cr)
			local result = out.faces[ck.face].corners[ck.index]
			for name, value in sampled do
				result[name] = blend(result[name], value, amount("corner", key), typeof(value))
			end
			if result.normal then
				result.normal = U.unit(result.normal)
			end
			if result.tangent then
				if result.normal then
					result.tangent -= result.normal * result.tangent:Dot(result.normal)
				end
				result.tangent = U.unit(result.tangent)
			end
		end
	end
	A.validate(out)
	out.revision += 1
	checkpoint()
	return out, report
end
