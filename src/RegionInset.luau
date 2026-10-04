-- Boundary miter inset on a selected surface region, with planar crossing checks.
local U = require(script.Parent.Util)
local Core = require(script.Parent.MeshEditCore)
local C = require(script.Parent.Connectivity)
local P = require(script.Parent.Predicates)
local Planar = require(script.Parent.Planar)
return function(mesh, selected, width, options)
	options = options or {}
	assert(type(width) == "number" and U.finite(width) and width > 0, "Positive finite inset width required")
	local depth = options.depth or 0
	local miterLimit = options.miterLimit or 8
	assert(type(depth) == "number" and U.finite(depth), "Finite inset depth required")
	assert(
		type(miterLimit) == "number" and U.finite(miterLimit) and miterLimit >= 1,
		"Inset miter limit must be at least one"
	)
	local faces = Core.selection(mesh, selected)
	local edit = Core.begin(mesh, options)
	local subset = { vertices = mesh.vertices, faces = {} }
	local faceNormals, vertexNormals = {}, {}
	for _, fid in faces do
		subset.faces[fid] = mesh.faces[fid]
		local n, area = mesh:faceNormal(fid)
		faceNormals[fid] = n
		for _, v in mesh.faces[fid].vertices do
			vertexNormals[v] = (vertexNormals[v] or Vector3.zero) + n * area
		end
	end
	local loops, boundaryReport = C.boundaries(subset, options)
	assert(boundaryReport.complete, "Inset region has an ambiguous boundary")
	local boundaryCount = 0
	for _, loop in loops do
		boundaryCount += #loop.vertices
	end
	local maxBoundary = U.integer(options.maxBoundaryVertices or 2000, 3)
	assert(boundaryCount <= maxBoundary, "Inset boundary budget exceeded")
	local index = C.index(subset, options)
	for id, n in vertexNormals do
		assert(n.Magnitude > 0, "Inset vertex has cancelling region normals")
		vertexNormals[id] = n.Unit
	end
	local map, maximumMiter = {}, 0
	for _, loop in loops do
		for i, id in loop.vertices do
			local previous = (i - 2) % #loop.vertices + 1
			local before, after = loop.vertices[previous], loop.vertices[i % #loop.vertices + 1]
			local h1, h2 = index.corners[loop.corners[previous]], index.corners[loop.corners[i]]
			local n1 = faceNormals[h1.face]:Cross((mesh.vertices[id] - mesh.vertices[before]).Unit)
			local n2 = faceNormals[h2.face]:Cross((mesh.vertices[after] - mesh.vertices[id]).Unit)
			local normal = vertexNormals[id]
			n1 -= normal * n1:Dot(normal)
			n2 -= normal * n2:Dot(normal)
			local a, b, c = n1:Dot(n1), n1:Dot(n2), n2:Dot(n2)
			assert(a > 0 and c > 0, "Inset boundary is normal to its region tangent plane")
			local determinant = a * c - b * b
			local displacement
			if determinant > a * c * 1e-10 then
				displacement = n1 * (width * (c - b) / determinant) + n2 * (width * (a - b) / determinant)
			else
				local sum = n1 + n2
				assert(sum.Magnitude > 0 and sum:Dot(n1) > 0, "Inset boundary reverses direction")
				displacement = sum * (width / sum:Dot(n1))
				assert(
					math.abs(displacement:Dot(n2) - width) <= width * 1e-5,
					"Incompatible inset boundary constraints"
				)
			end
			local miter = displacement.Magnitude / width
			assert(miter <= miterLimit, "Inset miter exceeds limit")
			maximumMiter = math.max(maximumMiter, miter)
			map[id] = edit.vertex(mesh.vertices[id] + displacement + normal * depth, { { id, 1 } })
		end
	end
	for id, n in vertexNormals do
		if not map[id] and depth ~= 0 then
			edit.out:setPosition(id, mesh.vertices[id] + n * depth)
		end
	end
	for _, fid in faces do
		local f = mesh.faces[fid]
		local vs, refs = {}, {}
		for i, id in f.vertices do
			vs[i] = map[id] or id
			refs[i] = { { fid, i, 1 } }
		end
		edit.face(vs, refs, f.material, { { fid, 1 } }, fid)
		for i, id in f.vertices do
			local other = f.vertices[i % #f.vertices + 1]
			local key = U.edge(map[id] or id, map[other] or other)
			edit.maps.edge[key] = { { U.edge(id, other), 1 } }
		end
	end
	local sides = {}
	for _, loop in loops do
		for _, ck in loop.corners do
			local h = index.corners[ck]
			local f = mesh.faces[h.face]
			local i, j = h.index, h.index % #f.vertices + 1
			local a, b = h.vertex, h.to
			local fid = edit.face(
				{ a, b, map[b], map[a] },
				{ { { h.face, i, 1 } }, { { h.face, j, 1 } }, { { h.face, j, 1 } }, { { h.face, i, 1 } } },
				f.material,
				{ { h.face, 1 } }
			)
			table.insert(sides, fid)
		end
	end
	local planar = #faces > 0
	local planarTolerance = options.planarTolerance or 1e-5
	assert(
		type(planarTolerance) == "number" and U.finite(planarTolerance) and planarTolerance >= 0,
		"Nonnegative planar tolerance required"
	)
	if planar then
		local normal = faceNormals[faces[1]]
		local origin = mesh.vertices[mesh.faces[faces[1]].vertices[1]]
		for id in vertexNormals do
			if math.abs((mesh.vertices[id] - origin):Dot(normal)) > planarTolerance then
				planar = false
				break
			end
		end
		if planar and #loops > 0 then
			local axis = math.abs(normal.X) > math.abs(normal.Y)
					and (math.abs(normal.X) > math.abs(normal.Z) and "X" or "Z")
				or (math.abs(normal.Y) > math.abs(normal.Z) and "Y" or "Z")
			local function project(p)
				p -= normal * (p - origin):Dot(normal)
				return axis == "X" and Vector2.new(p.Y, p.Z)
					or (axis == "Y" and Vector2.new(p.Z, p.X) or Vector2.new(p.X, p.Y))
			end
			local polygons, sourcePolygons = {}, {}
			for _, loop in loops do
				local old, new = {}, {}
				for i, id in loop.vertices do
					old[i] = project(mesh.vertices[id])
					new[i] = project(edit.out.vertices[map[id]])
				end
				assert(
					P.polygonOrientation(old) == P.polygonOrientation(new),
					"Inset collapsed a boundary loop"
				)
				table.insert(polygons, old)
				table.insert(polygons, new)
			end
			local hits = Planar.intersections(polygons, {
				maxVertices = 2 * maxBoundary,
				maxWork = options.maxWork or 5000000,
				maxIntersections = 1,
				checkpoint = options.checkpoint,
			})
			assert(#hits == 0, "Inset boundaries intersect or touch")
			for _, fid in faces do
				local polygon = {}
				for _, id in mesh.faces[fid].vertices do
					table.insert(polygon, project(mesh.vertices[id]))
				end
				table.insert(sourcePolygons, polygon)
			end
			local work = 0
			local maxWork = U.integer(options.maxWork or 5000000, 1)
			for _, newId in map do
				local p = project(edit.out.vertices[newId])
				local inside = false
				for _, polygon in sourcePolygons do
					work += #polygon
					assert(work <= maxWork, "Inset classification budget exceeded")
					if P.pointInPolygon2D(p, polygon) ~= "outside" then
						inside = true
						break
					end
				end
				assert(inside, "Inset boundary left its source region")
			end
		end
	end
	edit.report.insetVertices, edit.report.boundaryLoops, edit.report.sides = map, loops, sides
	edit.report.planarChecks, edit.report.maximumMiter = planar and #loops > 0, maximumMiter
	return edit.finish()
end
