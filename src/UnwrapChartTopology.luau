-- Private corner quotient for a cut chart, including endpoint-pair representability.
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local Connectivity = require(script.Parent.Connectivity)
local T = {}
function T.build(source, topology, faces, kept, visit)
	local included, nodes, parents, references = {}, {}, {}, {}
	for _, fid in faces do
		included[fid], nodes[fid] = true, {}
		for i, vertex in source.faces[fid].vertices do
			visit(1)
			local node = #references + 1
			parents[node] = node
			references[node] = { face = fid, corner = i, vertex = vertex }
			nodes[fid][vertex] = node
		end
	end
	local function find(node)
		while parents[node] ~= node do
			parents[node] = parents[parents[node]]
			node = parents[node]
		end
		return node
	end
	local edges = {}
	for _, fid in faces do
		local loop = source.faces[fid].vertices
		for i, vertex in loop do
			local key = U.edge(vertex, loop[i % #loop + 1])
			edges[key] = true
		end
	end
	for _, key in U.keys(edges) do
		visit(1)
		local edge = topology.edges[key]
		if kept[key] and #edge.faces == 2 and included[edge.faces[1]] and included[edge.faces[2]] then
			for _, vertex in { edge.a, edge.b } do
				local a, b = find(nodes[edge.faces[1]][vertex]), find(nodes[edge.faces[2]][vertex])
				parents[math.max(a, b)] = math.min(a, b)
			end
		end
	end
	local chart = Mesh.new()
	local roots, cornerMap, faceMap, vertexMap = {}, {}, {}, {}
	for _, fid in faces do
		local face = source.faces[fid]
		local loop = {}
		cornerMap[fid] = {}
		for i, vertex in face.vertices do
			visit(1)
			local root = find(nodes[fid][vertex])
			if not roots[root] then
				local id = chart:addVertex(source.vertices[vertex])
				roots[root], vertexMap[id] = id, vertex
			end
			loop[i] = roots[root]
			cornerMap[fid][i] = loop[i]
		end
		local id = chart:addFace(loop, face.corners, face.material)
		faceMap[id] = fid
	end
	local collapsed = {}
	for _, key in U.keys(edges) do
		visit(1)
		local edge = topology.edges[key]
		if not kept[key] and #edge.faces == 2 and included[edge.faces[1]] and included[edge.faces[2]] then
			local a, b = edge.faces[1], edge.faces[2]
			if
				find(nodes[a][edge.a]) == find(nodes[b][edge.a])
				and find(nodes[a][edge.b]) == find(nodes[b][edge.b])
			then
				table.insert(collapsed, key)
			end
		end
	end
	visit(U.count(chart.vertices) + U.count(chart.faces) + #references)
	local analysis = Connectivity.analyze(chart, { maxElements = 2 * #references + #faces + 1 })
	local disk = analysis.valid
		and #analysis.components == 1
		and analysis.eulerCharacteristic == 1
		and #analysis.boundaryLoops == 1
		and analysis.boundaryEdges >= 3
	return {
		mesh = chart,
		faces = table.clone(faces),
		faceMap = faceMap,
		vertexMap = vertexMap,
		cornerMap = cornerMap,
		topology = analysis,
		disk = disk,
		collapsedSeams = collapsed,
	}
end
return T
