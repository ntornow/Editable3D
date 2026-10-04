-- Private UV corner nodes and reference differentials for one existing island.
local U = require(script.Parent.Util)
local R = {}
function R.prepare(context, island, topology, pins, selection)
	local mesh, options, visit = context.mesh, context.options, context.visit
	local parents, references, cornerNodes, vertexNodes = {}, {}, {}, {}
	for _, fid in island.faces do
		cornerNodes[fid], vertexNodes[fid] = {}, {}
		for i, vertex in mesh.faces[fid].vertices do
			visit(1)
			local id = #references + 1
			parents[id] = id
			references[id] = { face = fid, corner = i, key = fid .. ":" .. i }
			cornerNodes[fid][i], vertexNodes[fid][vertex] = id, id
		end
	end
	local function find(id)
		while parents[id] ~= id do
			parents[id] = parents[parents[id]]
			id = parents[id]
		end
		return id
	end
	local edges, boundary = {}, {}
	for _, fid in island.faces do
		local loop = mesh.faces[fid].vertices
		for i, vertex in loop do
			visit(1)
			edges[U.edge(vertex, loop[i % #loop + 1])] = true
		end
	end
	for _, key in U.keys(edges) do
		visit(1)
		local edge = topology.edges[key]
		if not context.boundaries[key] then
			for _, vertex in { edge.a, edge.b } do
				local a, b =
					find(vertexNodes[edge.faces[1]][vertex]), find(vertexNodes[edge.faces[2]][vertex])
				parents[math.max(a, b)] = math.min(a, b)
			end
		else
			for _, fid in edge.faces do
				if vertexNodes[fid] then
					boundary[vertexNodes[fid][edge.a]], boundary[vertexNodes[fid][edge.b]] = true, true
				end
			end
		end
	end
	local roots, nodes, map = {}, {}, {}
	for id, reference in references do
		visit(1)
		local root = find(id)
		local index = roots[root]
		if not index then
			index = #nodes + 1
			roots[root] = index
			local uv = mesh.faces[reference.face].corners[reference.corner].uv
			table.insert(nodes, { uv = uv, references = {}, pinned = false })
		end
		local node = nodes[index]
		table.insert(node.references, reference)
		node.pinned = node.pinned
			or pins[reference.key] == true
			or selection ~= nil and selection[reference.key] ~= true
		node.boundary = node.boundary or boundary[id] == true
		map[reference.face] = map[reference.face] or {}
		map[reference.face][reference.corner] = index
	end
	local pinned = {}
	for id, node in nodes do
		visit(1)
		node.pinned = node.pinned or options.pinBoundary ~= false and node.boundary
		if node.pinned then
			table.insert(pinned, id)
		end
	end
	local automatic = {}
	local function anchor(id)
		nodes[id].pinned = true
		table.insert(pinned, id)
		table.insert(automatic, id)
	end
	if #pinned == 0 then
		anchor(1)
	end
	local first = pinned[1]
	local distinct = false
	for _, id in pinned do
		distinct = distinct or nodes[id].uv ~= nodes[first].uv
	end
	if not distinct then
		local farthest, distance = first, 0
		for id, node in nodes do
			visit(1)
			local x, y =
				(node.uv.X - nodes[first].uv.X) * context.size.X,
				(node.uv.Y - nodes[first].uv.Y) * context.size.Y
			local d = x * x + y * y
			if d > distance then
				farthest, distance = id, d
			end
		end
		assert(distance > 0, "Distinct UV anchors required")
		anchor(farthest)
	end
	local origin = { island.minimum[1], island.minimum[2] }
	local span = math.max(
		(island.maximum[1] - origin[1]) * context.size.X,
		(island.maximum[2] - origin[2]) * context.size.Y
	)
	assert(U.finite(span) and span > 0, "Finite UV relaxation span required")
	local density = options.density or island.density
	local referenceScale = density / span
	local coordinates, movable = {}, {}
	for id, node in nodes do
		visit(1)
		coordinates[2 * id - 1] = (node.uv.X - origin[1]) * context.size.X / span
		coordinates[2 * id] = (node.uv.Y - origin[2]) * context.size.Y / span
		if not node.pinned then
			table.insert(movable, id)
		end
	end
	local triangles = {}
	for _, triangle in island.triangles do
		visit(1)
		local positions, ids = {}, {}
		for i, id in triangle.vertices do
			positions[i] = mesh.vertices[id]
			ids[i] = map[triangle.face][triangle.corners[i]]
		end
		local targets = {}
		local length, xx, yy
		for i, a in positions do
			local b, c = positions[i % 3 + 1], positions[(i + 1) % 3 + 1]
			local x, y, z = b.X - a.X, b.Y - a.Y, b.Z - a.Z
			local u, v, w = c.X - a.X, c.Y - a.Y, c.Z - a.Z
			local cx, cy, cz = y * w - z * v, z * u - x * w, x * v - y * u
			local twice = math.sqrt(cx * cx + cy * cy + cz * cz)
			targets[i] = math.atan2(twice, x * u + y * v + z * w)
			if i == 1 then
				length = math.sqrt(x * x + y * y + z * z)
				xx = (x * u + y * v + z * w) / length
				yy = twice / length
			end
		end
		table.insert(triangles, {
			nodes = ids,
			target = targets,
			orientation = triangle.orientation,
			weight = triangle.surfaceArea / island.surfaceArea,
			gx = { -1 / length / referenceScale, 1 / length / referenceScale, 0 },
			gy = {
				(xx / length - 1) / yy / referenceScale,
				-xx / length / yy / referenceScale,
				1 / yy / referenceScale,
			},
		})
	end
	return {
		nodes = nodes,
		coordinates = coordinates,
		movable = movable,
		triangles = triangles,
		origin = origin,
		span = span,
		density = density,
		pinned = pinned,
		automaticPins = automatic,
	}
end
return R
