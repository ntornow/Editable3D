-- Private immutable UV charts and scalar-double measurements of native corners.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local P = require(script.Parent.Predicates)
local C = {}
function C.vector(value)
	return typeof(value) == "Vector2" and U.finite(value.X) and U.finite(value.Y)
end
function C.prepare(source, settings)
	local options = U.copy(settings or {})
	local maxVertices = U.integer(options.maxVertices or 250000, 1)
	local maxFaces = U.integer(options.maxFaces or 250000, 1)
	local maxCorners = U.integer(options.maxCorners or 1000000, 1)
	local maxWork = U.integer(options.maxWork or 20000000, 1)
	local maxFaceVertices = U.integer(options.maxFaceVertices or 2000, 3)
	assert(
		U.count(source.vertices) <= maxVertices and U.count(source.faces) <= maxFaces,
		"UV allocation budget exceeded"
	)
	local corners = 0
	for _, face in source.faces do
		corners += #face.vertices
		assert(corners <= maxCorners and #face.vertices <= maxFaceVertices, "UV corner budget exceeded")
	end
	for _, name in { "cancelled", "checkpoint" } do
		assert(options[name] == nil or type(options[name]) == "function", "UV callback must be a function")
	end
	for _, name in { "requireComplete", "checkOverlaps" } do
		assert(options[name] == nil or type(options[name]) == "boolean", "UV flags must be boolean")
	end
	local size = options.textureSize or Vector2.one
	assert(C.vector(size), "Finite UV texture size required")
	for _, value in { size.X, size.Y } do
		assert(
			value % 1 == 0 and value >= 1 and value <= 65536,
			"UV texture dimensions must be integers in [1,65536]"
		)
	end
	local mesh = source:clone()
	A.validate(mesh)
	local context = { mesh = mesh, options = options, size = size, work = 0, maxWork = maxWork }
	function context.visit(n)
		context.work += n or 1
		assert(context.work <= maxWork, "UV work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "UV operation cancelled")
	end
	function context.checkpoint(stage)
		context.visit(0)
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = context.work })
		end
	end
	context.checkpoint("begin")
	context.visit(U.count(mesh.vertices) + U.count(mesh.faces) + corners)
	for _, position in mesh.vertices do
		assert(U.vector(position), "Finite UV source geometry required")
	end
	local connectivity = require(script.Parent.Connectivity).analyze(mesh)
	assert(
		next(connectivity.nonmanifoldEdges) == nil
			and next(connectivity.windingEdges) == nil
			and next(connectivity.nonmanifoldVertices) == nil
			and next(connectivity.duplicateFaces) == nil
			and next(connectivity.zeroLengthEdges) == nil,
		"UV charts require oriented manifold geometry"
	)
	local topology = mesh:topology()
	local seams = options.seams or {}
	assert(type(seams) == "table", "UV seams must be an edge boolean set")
	for key, value in seams do
		assert(topology.edges[key] and type(value) == "boolean", "Invalid UV seam edge")
	end
	local parents, cornerByVertex = {}, {}
	for _, fid in U.keys(mesh.faces) do
		parents[fid], cornerByVertex[fid] = fid, {}
		for i, id in mesh.faces[fid].vertices do
			cornerByVertex[fid][id] = i
		end
	end
	local function find(id)
		while parents[id] ~= id do
			parents[id] = parents[parents[id]]
			id = parents[id]
		end
		return id
	end
	local boundaries = {}
	for key, edge in topology.edges do
		context.visit(1)
		local joined = #edge.faces == 2 and seams[key] ~= true
		if joined then
			for _, vertex in { edge.a, edge.b } do
				local a, b = edge.faces[1], edge.faces[2]
				local x = mesh.faces[a].corners[cornerByVertex[a][vertex]].uv
				local y = mesh.faces[b].corners[cornerByVertex[b][vertex]].uv
				joined = joined and C.vector(x) and C.vector(y) and x == y
			end
		end
		if joined then
			local a, b = find(edge.faces[1]), find(edge.faces[2])
			parents[math.max(a, b)] = math.min(a, b)
		else
			boundaries[key] = true
		end
	end
	local islands, byId, faceToIsland = {}, {}, {}
	for _, fid in U.keys(mesh.faces) do
		local id = find(fid)
		faceToIsland[fid] = id
		if not byId[id] then
			byId[id] = {
				id = id,
				faces = {},
				corners = {},
				triangles = {},
				missing = {},
				minimum = { math.huge, math.huge },
				maximum = { -math.huge, -math.huge },
				uvArea = 0,
				surfaceArea = 0,
				positiveTriangles = 0,
				negativeTriangles = 0,
				degenerateTriangles = 0,
			}
			table.insert(islands, byId[id])
		end
		table.insert(byId[id].faces, fid)
	end
	table.sort(islands, function(a, b)
		return a.id < b.id
	end)
	local selected = options.islands
	if selected then
		assert(type(selected) == "table", "UV island selection must be a boolean set")
		for id, value in selected do
			assert(byId[id] and type(value) == "boolean", "Invalid UV island ID")
		end
	end
	local triangles = {}
	for _, island in islands do
		island.selected = selected == nil or selected[island.id] == true
		for _, fid in island.faces do
			local face = mesh.faces[fid]
			for i, corner in face.corners do
				context.visit(1)
				table.insert(island.corners, { face = fid, corner = i })
				if C.vector(corner.uv) then
					local x, y = corner.uv.X, corner.uv.Y
					island.minimum[1], island.minimum[2] =
						math.min(island.minimum[1], x), math.min(island.minimum[2], y)
					island.maximum[1], island.maximum[2] =
						math.max(island.maximum[1], x), math.max(island.maximum[2], y)
				else
					table.insert(island.missing, { face = fid, corner = i })
				end
			end
			for _, tri in
				mesh:faceTriangles(fid, {
					validateSimple = true,
					maxVertices = maxFaceVertices,
					maxWork = maxWork,
					_visit = context.visit,
				})
			do
				context.visit(1)
				local entry = C.measure(mesh, {
					face.vertices[tri[1]],
					face.vertices[tri[2]],
					face.vertices[tri[3]],
					face = fid,
					corners = tri,
				}, size)
				entry.island = island.id
				entry.index = #triangles + 1
				table.insert(triangles, entry)
				table.insert(island.triangles, entry)
				island.surfaceArea += entry.surfaceArea
				if entry.orientation then
					island.uvArea += entry.uvArea
					local name = entry.orientation > 0 and "positiveTriangles"
						or entry.orientation < 0 and "negativeTriangles"
						or "degenerateTriangles"
					island[name] += 1
				end
			end
		end
		island.density = island.surfaceArea > 0
				and math.sqrt(island.uvArea * size.X * size.Y / island.surfaceArea)
			or 0
		island.mixedOrientation = island.positiveTriangles > 0 and island.negativeTriangles > 0
		if #island.corners == #island.missing then
			island.minimum, island.maximum = nil, nil
		end
	end
	context.islands, context.byId, context.faceToIsland, context.boundaries, context.triangles =
		islands, byId, faceToIsland, boundaries, triangles
	context.checkpoint("islands")
	return context
end
function C.measure(mesh, triangle, size)
	local entry = {
		face = triangle.face,
		corners = table.clone(triangle.corners),
		vertices = { triangle[1], triangle[2], triangle[3] },
	}
	local a, b, c = mesh.vertices[triangle[1]], mesh.vertices[triangle[2]], mesh.vertices[triangle[3]]
	local x, y, z = b.X - a.X, b.Y - a.Y, b.Z - a.Z
	local u, v, w = c.X - a.X, c.Y - a.Y, c.Z - a.Z
	local length = math.sqrt(x * x + y * y + z * z)
	local cx, cy, cz = y * w - z * v, z * u - x * w, x * v - y * u
	local twiceArea = math.sqrt(cx * cx + cy * cy + cz * cz)
	assert(length > 0 and twiceArea > 0, "Degenerate UV source triangle")
	entry.surfaceArea = twiceArea / 2
	local face = mesh.faces[triangle.face]
	local p, q, r =
		face.corners[triangle.corners[1]].uv,
		face.corners[triangle.corners[2]].uv,
		face.corners[triangle.corners[3]].uv
	if not (C.vector(p) and C.vector(q) and C.vector(r)) then
		return entry
	end
	entry.uv = { p, q, r }
	local orientation, determinant = P.orient2D(p, q, r)
	entry.orientation, entry.uvArea = orientation, math.abs(determinant) / 2
	entry.minimum = { math.min(p.X, q.X, r.X), math.min(p.Y, q.Y, r.Y) }
	entry.maximum = { math.max(p.X, q.X, r.X), math.max(p.Y, q.Y, r.Y) }
	local xx, yy = (x * u + y * v + z * w) / length, twiceArea / length
	local j11, j21 = (q.X - p.X) * size.X / length, (q.Y - p.Y) * size.Y / length
	local j12, j22 = ((r.X - p.X) * size.X - j11 * xx) / yy, ((r.Y - p.Y) * size.Y - j21 * xx) / yy
	local aa, bb, ab = j11 * j11 + j21 * j21, j12 * j12 + j22 * j22, j11 * j12 + j21 * j22
	local largest = math.max(math.abs(aa - bb), math.abs(2 * ab))
	local discriminant = largest > 0
			and largest * math.sqrt(((aa - bb) / largest) ^ 2 + (2 * ab / largest) ^ 2)
		or 0
	local maximum = math.sqrt((aa + bb + discriminant) / 2)
	local minimum = maximum > 0 and math.abs(determinant) * size.X * size.Y / twiceArea / maximum or 0
	entry.maximumStretch, entry.minimumStretch = maximum, minimum
	entry.anisotropy = minimum > 0 and maximum / minimum or math.huge
	return entry
end
function C.summary(context)
	local complete = true
	for _, island in context.islands do
		complete = complete and #island.missing == 0
	end
	return {
		complete = complete,
		islands = U.copy(context.islands),
		faceToIsland = U.copy(context.faceToIsland),
		seams = U.copy(context.boundaries),
		textureSize = context.size,
		work = context.work,
	}
end
return C
