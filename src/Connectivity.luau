-- Detached directed-corner connectivity for polygon meshes; no mutable mesh references.
local U = require(script.Parent.Util)
local C = {}
local function cornerKey(face, i)
	return face .. ":" .. i
end
local function canonical(vertices)
	local start = 1
	for i, v in vertices do
		if v < vertices[start] then
			start = i
		end
	end
	local forward, backward = {}, {}
	for j = 0, #vertices - 1 do
		forward[j + 1] = vertices[(start + j - 1) % #vertices + 1]
		backward[j + 1] = vertices[(start - j - 1) % #vertices + 1]
	end
	local a, b = table.concat(forward, ":"), table.concat(backward, ":")
	return a < b and a or b
end
function C.index(mesh, options)
	options = options or {}
	assert(type(options) == "table", "Connectivity options must be a table")
	assert(type(mesh.vertices) == "table" and type(mesh.faces) == "table", "Connectivity requires a mesh")
	local limit = U.integer(options.maxElements or 2000000, 1)
	local total = U.count(mesh.vertices) + U.count(mesh.faces)
	assert(total <= limit, "Connectivity element budget exceeded")
	for _, face in mesh.faces do
		assert(type(face.vertices) == "table", "Connectivity requires polygon faces")
		total += #face.vertices
		assert(total <= limit, "Connectivity element budget exceeded")
	end
	local work = 0
	local function visit()
		work += 1
		assert(work <= limit, "Connectivity element budget exceeded")
		if options.checkpoint and work % 1024 == 0 then
			options.checkpoint(work / limit)
		end
	end
	if options.checkpoint then
		options.checkpoint(0)
	end
	local index = { vertices = {}, edges = {}, faces = {}, corners = {}, boundary = {}, duplicateFaces = {} }
	for _, id in U.keys(mesh.vertices) do
		visit()
		U.integer(id, 1)
		assert(U.vector(mesh.vertices[id]), "Connectivity requires finite vertex positions")
		index.vertices[id] = { position = mesh.vertices[id], edges = {}, corners = {}, fans = {} }
	end
	local faceKeys = {}
	for _, fid in U.keys(mesh.faces) do
		visit()
		U.integer(fid, 1)
		local source = mesh.faces[fid]
		assert(
			type(source.vertices) == "table" and #source.vertices >= 3,
			"Connectivity requires polygon faces"
		)
		local face = { vertices = table.clone(source.vertices), corners = {} }
		index.faces[fid] = face
		local seen = {}
		for i, v in face.vertices do
			visit()
			assert(index.vertices[v] and not seen[v], "Connectivity face has missing or repeated vertex")
			seen[v] = true
			local nextId = face.vertices[i % #face.vertices + 1]
			assert(index.vertices[nextId], "Connectivity face has missing vertex")
			local key, ck = U.edge(v, nextId), cornerKey(fid, i)
			local e = index.edges[key]
			if not e then
				e = { a = math.min(v, nextId), b = math.max(v, nextId), corners = {}, faces = {} }
				index.edges[key] = e
				table.insert(index.vertices[v].edges, key)
				table.insert(index.vertices[nextId].edges, key)
			end
			table.insert(e.corners, ck)
			table.insert(e.faces, fid)
			face.corners[i] = ck
			index.corners[ck] = {
				face = fid,
				index = i,
				vertex = v,
				to = nextId,
				edge = key,
				next = cornerKey(fid, i % #face.vertices + 1),
				previous = cornerKey(fid, (i - 2) % #face.vertices + 1),
			}
			table.insert(index.vertices[v].corners, ck)
		end
		local key = canonical(face.vertices)
		if faceKeys[key] then
			index.duplicateFaces[fid] = faceKeys[key]
		else
			faceKeys[key] = fid
		end
	end
	for key, e in index.edges do
		if #e.corners == 1 then
			index.boundary[key] = true
		elseif #e.corners == 2 then
			local a, b = index.corners[e.corners[1]], index.corners[e.corners[2]]
			if a.vertex == b.to and a.to == b.vertex then
				a.twin = e.corners[2]
				b.twin = e.corners[1]
			end
		end
	end
	for v, entry in index.vertices do
		table.sort(entry.edges)
		local seen = {}
		for _, seed in entry.corners do
			if not seen[seed] then
				local fan, cursor = { seed }, 1
				local seenEdges = {}
				seen[seed] = true
				while cursor <= #fan do
					local h = index.corners[fan[cursor]]
					cursor += 1
					for _, key in { h.edge, index.corners[h.previous].edge } do
						if not seenEdges[key] then
							seenEdges[key] = true
							for _, ck in index.edges[key].corners do
								local linked = index.corners[ck].vertex == v and ck or index.corners[ck].next
								if not seen[linked] then
									seen[linked] = true
									table.insert(fan, linked)
								end
							end
						end
					end
				end
				table.sort(fan)
				table.insert(entry.fans, fan)
			end
		end
	end
	index.elements = work
	return index
end
local function traceBoundaries(index)
	local outgoing, incoming, ambiguous = {}, {}, {}
	for key in index.boundary do
		local h = index.corners[index.edges[key].corners[1]]
		outgoing[h.vertex] = outgoing[h.vertex] or {}
		table.insert(outgoing[h.vertex], h)
		incoming[h.to] = incoming[h.to] or {}
		table.insert(incoming[h.to], h)
	end
	for v, edges in outgoing do
		if #edges ~= 1 or #(incoming[v] or {}) ~= 1 then
			ambiguous[v] = true
		end
	end
	for v, edges in incoming do
		if #edges ~= 1 or #(outgoing[v] or {}) ~= 1 then
			ambiguous[v] = true
		end
	end
	if next(ambiguous) then
		return {}, ambiguous
	end
	local seen, loops = {}, {}
	for _, seed in U.keys(index.boundary) do
		if not seen[seed] then
			local loop = { vertices = {}, edges = {}, corners = {}, closed = true }
			local h = index.corners[index.edges[seed].corners[1]]
			repeat
				seen[h.edge] = true
				table.insert(loop.vertices, h.vertex)
				table.insert(loop.edges, h.edge)
				table.insert(loop.corners, cornerKey(h.face, h.index))
				h = outgoing[h.to][1]
			until seen[h.edge]
			assert(h.edge == seed, "Boundary traversal invariant failed")
			table.insert(loops, loop)
		end
	end
	return loops, ambiguous
end
local function analysis(index)
	local result = {
		vertices = U.count(index.vertices),
		edges = U.count(index.edges),
		faces = U.count(index.faces),
		boundaryEdges = U.count(index.boundary),
		nonmanifoldEdges = {},
		windingEdges = {},
		nonmanifoldVertices = {},
		looseVertices = {},
		zeroLengthEdges = {},
		duplicateFaces = U.copy(index.duplicateFaces),
		components = {},
	}
	for key, e in index.edges do
		if #e.faces > 2 then
			result.nonmanifoldEdges[key] = true
		elseif #e.faces == 2 and not index.corners[e.corners[1]].twin then
			result.windingEdges[key] = true
		end
		if index.vertices[e.a].position == index.vertices[e.b].position then
			result.zeroLengthEdges[key] = true
		end
	end
	for v, entry in index.vertices do
		if #entry.corners == 0 then
			result.looseVertices[v] = true
		end
		local boundary, invalidEdge = 0, false
		for _, key in entry.edges do
			if index.boundary[key] then
				boundary += 1
			end
			if result.nonmanifoldEdges[key] then
				invalidEdge = true
			end
		end
		if #entry.fans > 1 or (boundary ~= 0 and boundary ~= 2) or invalidEdge then
			result.nonmanifoldVertices[v] = true
		end
	end
	result.boundaryLoops, result.ambiguousBoundaryVertices = traceBoundaries(index)
	local visited, faceComponents = {}, {}
	for _, seed in U.keys(index.faces) do
		if not visited[seed] then
			local component = {
				vertices = {},
				edges = {},
				faces = {},
				boundaryLoops = 0,
				manifold = true,
				consistentlyWound = true,
			}
			local queue, cursor = { seed }, 1
			visited[seed] = true
			while cursor <= #queue do
				local fid = queue[cursor]
				cursor += 1
				component.faces[fid] = true
				faceComponents[fid] = #result.components + 1
				for _, ck in index.faces[fid].corners do
					local h = index.corners[ck]
					component.vertices[h.vertex] = true
					local firstEdgeVisit = not component.edges[h.edge]
					component.edges[h.edge] = true
					if result.nonmanifoldVertices[h.vertex] or result.nonmanifoldEdges[h.edge] then
						component.manifold = false
					end
					if result.windingEdges[h.edge] then
						component.consistentlyWound = false
					end
					if firstEdgeVisit then
						for _, other in index.edges[h.edge].faces do
							if not visited[other] then
								visited[other] = true
								table.insert(queue, other)
							end
						end
					end
				end
			end
			component.eulerCharacteristic = U.count(component.vertices)
				- U.count(component.edges)
				+ U.count(component.faces)
			table.insert(result.components, component)
		end
	end
	for _, loop in result.boundaryLoops do
		local component = result.components[faceComponents[index.corners[loop.corners[1]].face]]
		component.boundaryLoops += 1
	end
	for _, component in result.components do
		if
			component.manifold
			and component.consistentlyWound
			and not next(result.ambiguousBoundaryVertices)
		then
			local genus = (2 - component.boundaryLoops - component.eulerCharacteristic) / 2
			if genus >= 0 and genus % 1 == 0 then
				component.genus = genus
			end
		end
	end
	result.eulerCharacteristic = result.vertices - result.edges + result.faces
	result.manifold = not next(result.nonmanifoldEdges) and not next(result.nonmanifoldVertices)
	result.consistentlyWound = not next(result.windingEdges)
	result.valid = result.manifold
		and result.consistentlyWound
		and not next(result.zeroLengthEdges)
		and not next(result.duplicateFaces)
	result.closed = result.valid and result.faces > 0 and result.boundaryEdges == 0
	return result
end
function C.analyze(mesh, options)
	return analysis(C.index(mesh, options))
end
function C.boundaries(mesh, options)
	local loops, ambiguous = traceBoundaries(C.index(mesh, options))
	return loops, { complete = next(ambiguous) == nil, ambiguousVertices = ambiguous }
end
return C
