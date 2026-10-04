-- Ordered loop/ring walks. Poles and non-quads terminate traversal explicitly.
local U = require(script.Parent.Util)
local Connectivity = require(script.Parent.Connectivity)
local function setup(mesh, key, options)
	options = options or {}
	local index = Connectivity.index(mesh, options)
	assert(index.edges[key], "Unknown loop edge")
	local limit = U.integer(options.maxSteps or 250000, 1)
	local steps = 0
	if options.checkpoint then
		options.checkpoint(0)
	end
	local function visit()
		steps += 1
		if options.checkpoint and steps % 256 == 0 then
			options.checkpoint(math.min(1, steps / limit))
		end
		return steps <= limit
	end
	return index, visit
end
local function goodEdge(index, key)
	local e = index.edges[key]
	return #e.faces == 1 or (#e.faces == 2 and index.corners[e.corners[1]].twin ~= nil)
end
local function opposite(index, key, v)
	local entry = index.vertices[v]
	if #entry.fans ~= 1 then
		return nil, "disconnected_fan"
	end
	local boundary = {}
	for _, ek in entry.edges do
		if not goodEdge(index, ek) then
			return nil, "nonmanifold_or_winding"
		end
		if index.boundary[ek] then
			table.insert(boundary, ek)
		end
	end
	if index.boundary[key] then
		if #boundary ~= 2 then
			return nil, "ambiguous_boundary"
		end
		return boundary[1] == key and boundary[2] or boundary[1]
	end
	if #boundary > 0 then
		return nil, "boundary"
	end
	if #entry.edges ~= 4 then
		return nil, "pole"
	end
	for _, ck in entry.corners do
		if #index.faces[index.corners[ck].face].vertices ~= 4 then
			return nil, "non_quad"
		end
	end
	local forbidden = {}
	for _, fid in index.edges[key].faces do
		forbidden[fid] = true
	end
	local result
	for _, ek in entry.edges do
		if ek ~= key then
			local shares = false
			for _, fid in index.edges[ek].faces do
				if forbidden[fid] then
					shares = true
				end
			end
			if not shares then
				if result then
					return nil, "ambiguous_continuation"
				end
				result = ek
			end
		end
	end
	return result, not result and "pole" or nil
end
local function regularStop(reason)
	return reason == nil or reason == "pole" or reason == "boundary" or reason == "non_quad"
end
local function finish(edges, vertices, faces, closed, ends, complete)
	local selection, vertexSelection, faceSelection = {}, {}, {}
	for _, key in edges do
		selection[key] = true
	end
	for _, id in vertices do
		vertexSelection[id] = true
	end
	for _, id in faces do
		faceSelection[id] = true
	end
	return {
		edges = edges,
		vertices = vertices,
		faces = faces,
		selection = selection,
		edgeSelection = selection,
		vertexSelection = vertexSelection,
		faceSelection = faceSelection,
		closed = closed,
		simple = U.count(vertexSelection) == #vertices,
		ends = ends,
		complete = complete,
	}
end
local function edgeLoop(mesh, key, options)
	local index, visit = setup(mesh, key, options)
	local seed = index.edges[key]
	assert(goodEdge(index, key), "Loop seed must have consistently wound manifold incidence")
	local seen = { [key] = true }
	local function walk(v)
		local edges, vertices = {}, {}
		local incoming = key
		while true do
			if not visit() then
				return edges, vertices, false, "step_budget"
			end
			local nextKey, reason = opposite(index, incoming, v)
			if not nextKey then
				return edges, vertices, false, reason
			end
			if nextKey == key then
				return edges, vertices, true, nil
			end
			if seen[nextKey] then
				return edges, vertices, false, "revisited_edge"
			end
			seen[nextKey] = true
			table.insert(edges, nextKey)
			local e = index.edges[nextKey]
			v = e.a == v and e.b or e.a
			table.insert(vertices, v)
			incoming = nextKey
		end
	end
	local right, rv, closed, stopRight = walk(seed.b)
	local edges, vertices = { key }, { seed.a, seed.b }
	for _, e in right do
		table.insert(edges, e)
	end
	for _, v in rv do
		table.insert(vertices, v)
	end
	if closed then
		table.remove(vertices)
		return finish(edges, vertices, {}, true, {}, true)
	end
	local left, lv, closedLeft, stopLeft = walk(seed.a)
	assert(not closedLeft, "Loop traversal joined an already visited branch")
	local orderedEdges, orderedVertices = {}, {}
	for i = #left, 1, -1 do
		table.insert(orderedEdges, left[i])
	end
	for _, e in edges do
		table.insert(orderedEdges, e)
	end
	for i = #lv, 1, -1 do
		table.insert(orderedVertices, lv[i])
	end
	for _, v in vertices do
		table.insert(orderedVertices, v)
	end
	return finish(
		orderedEdges,
		orderedVertices,
		{},
		false,
		{ stopLeft, stopRight },
		regularStop(stopLeft) and regularStop(stopRight)
	)
end
local function edgeRing(mesh, key, options)
	local index, visit = setup(mesh, key, options)
	local seed = index.edges[key]
	assert(goodEdge(index, key), "Ring seed must have consistently wound manifold incidence")
	local seen = { [key] = true }
	local function walk(fid)
		local edges, faces = {}, {}
		local incoming = key
		if not fid then
			return edges, faces, false, "boundary"
		end
		while true do
			if not visit() then
				return edges, faces, false, "step_budget"
			end
			local f = index.faces[fid]
			if #f.corners ~= 4 then
				return edges, faces, false, "non_quad"
			end
			local nextKey
			for i, ck in f.corners do
				if index.corners[ck].edge == incoming then
					nextKey = index.corners[f.corners[(i + 1) % 4 + 1]].edge
					break
				end
			end
			assert(nextKey, "Ring incidence invariant failed")
			table.insert(faces, fid)
			if nextKey == key then
				return edges, faces, true, nil
			end
			if seen[nextKey] then
				return edges, faces, false, "revisited_edge"
			end
			seen[nextKey] = true
			table.insert(edges, nextKey)
			if not goodEdge(index, nextKey) then
				return edges, faces, false, "nonmanifold_or_winding"
			end
			local e = index.edges[nextKey]
			if #e.faces == 1 then
				return edges, faces, false, "boundary"
			end
			fid = e.faces[1] == fid and e.faces[2] or e.faces[1]
			incoming = nextKey
		end
	end
	local right, rf, closed, stopRight = walk(seed.faces[1])
	local edges = { key }
	for _, e in right do
		table.insert(edges, e)
	end
	if closed then
		return finish(edges, {}, rf, true, {}, true)
	end
	local left, lf, closedLeft, stopLeft = walk(seed.faces[2])
	assert(not closedLeft, "Ring traversal joined an already visited branch")
	local orderedEdges, faces = {}, {}
	for i = #left, 1, -1 do
		table.insert(orderedEdges, left[i])
	end
	for _, e in edges do
		table.insert(orderedEdges, e)
	end
	for i = #lf, 1, -1 do
		table.insert(faces, lf[i])
	end
	for _, f in rf do
		table.insert(faces, f)
	end
	return finish(
		orderedEdges,
		{},
		faces,
		false,
		{ stopLeft, stopRight },
		regularStop(stopLeft) and regularStop(stopRight)
	)
end
return { edgeLoop = edgeLoop, edgeRing = edgeRing }
