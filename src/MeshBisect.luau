-- Private conforming triangle-fragment plane cut and nested-loop cap builder.
local U = require(script.Parent.Util)
local C = require(script.Parent.Connectivity)
local Core = require(script.Parent.MeshEditCore)
local A = require(script.Parent.AttributeCore)
local P = require(script.Parent.Predicates)
local Planar = require(script.Parent.Planar)
return function(mesh, origin, normal, options)
	options = options or {}
	assert(
		U.vector(origin) and U.vector(normal) and normal.Magnitude > 0 and U.finite(normal.Magnitude),
		"Finite bisect origin and nonzero normal required"
	)
	local keep, tolerance = options.keep or "both", options.tolerance or 0
	assert(
		keep == "both" or keep == "positive" or keep == "negative",
		"Bisect keep must be both, positive or negative"
	)
	assert(
		type(tolerance) == "number" and U.finite(tolerance) and tolerance >= 0,
		"Nonnegative plane tolerance required"
	)
	assert(
		not options.cap or keep ~= "both" and mesh:validate().closed,
		"Bisect caps require a closed source and one retained side"
	)
	local limit = U.integer(options.maxCutTriangles or 500000, 1)
	if options.material ~= nil then
		U.integer(options.material, 1)
	end
	local edit, index = Core.begin(mesh, options), C.index(mesh, options)
	normal = normal.Unit
	local distances, classes, intersections, planeVertices = {}, {}, {}, {}
	for _, id in U.keys(mesh.vertices) do
		local p = mesh.vertices[id]
		local d = (p.X - origin.X) * normal.X + (p.Y - origin.Y) * normal.Y + (p.Z - origin.Z) * normal.Z
		assert(U.finite(d), "Plane distance overflow")
		if math.abs(d) <= tolerance then
			distances[id], classes[id], planeVertices[id] = 0, 0, true
			if d ~= 0 then
				edit.out:setPosition(id, p - normal * d)
			end
		else
			distances[id], classes[id] = d, d > 0 and 1 or -1
		end
		edit.checkpoint()
	end
	local function crossing(fid, i, j)
		local f = mesh.faces[fid]
		local a, b = f.vertices[i], f.vertices[j]
		local key = U.edge(a, b)
		local t = distances[a] / (distances[a] - distances[b])
		local id = intersections[key]
		if not id then
			-- Canonical endpoint arithmetic ensures adjacent faces share one native vertex.
			local x, y = math.min(a, b), math.max(a, b)
			local u = distances[x] / (distances[x] - distances[y])
			local px, py = edit.out.vertices[x], edit.out.vertices[y]
			local p =
				Vector3.new(px.X + (py.X - px.X) * u, px.Y + (py.Y - px.Y) * u, px.Z + (py.Z - px.Z) * u)
			id = edit.vertex(p, { { x, 1 - u }, { y, u } })
			assert(
				p ~= px and p ~= py,
				"Plane intersection collapses at native precision; choose an explicit tolerance"
			)
			intersections[key], planeVertices[id] = id, true
			if index.edges[key] then
				edit.maps.edge[U.edge(a, id)], edit.maps.edge[U.edge(id, b)] = { { key, 1 } }, { { key, 1 } }
			end
		end
		return { id = id, refs = { { fid, i, 1 - t }, { fid, j, t } } }
	end
	local triangleCount = 0
	edit.report.faceMap, edit.report.caps = {}, {}
	for _, fid in U.keys(mesh.faces) do
		local f, positive, negative = mesh.faces[fid], false, false
		for _, id in f.vertices do
			positive = positive or classes[id] > 0
			negative = negative or classes[id] < 0
		end
		if positive and negative then
			local pieces = {}
			for _, tri in
				mesh:faceTriangles(fid, {
					validateSimple = true,
					maxVertices = options.maxFaceVertices or 2000,
					maxWork = options.maxFaceWork or 5000000,
				})
			do
				triangleCount += 1
				assert(triangleCount <= limit, "Bisect triangle budget exceeded")
				local coplanar = classes[f.vertices[tri[1]]] == 0
					and classes[f.vertices[tri[2]]] == 0
					and classes[f.vertices[tri[3]]] == 0
				for _, side in keep == "both" and { 1, -1 } or { keep == "positive" and 1 or -1 } do
					local polygon, hasInterior = {}, coplanar and (keep ~= "both" or side == 1)
					for k, i in tri do
						local j = tri[k % 3 + 1]
						local a, b = f.vertices[i], f.vertices[j]
						if classes[a] * side >= 0 then
							table.insert(polygon, { id = a, refs = { { fid, i, 1 } } })
							hasInterior = hasInterior or classes[a] * side > 0
						end
						if classes[a] * classes[b] < 0 then
							table.insert(polygon, crossing(fid, i, j))
							hasInterior = true
						end
					end
					if #polygon >= 3 and hasInterior then
						table.insert(pieces, polygon)
					end
				end
				edit.checkpoint()
			end
			edit.report.faceMap[fid] = {}
			for k, polygon in pieces do
				local vs, refs = {}, {}
				for i, item in polygon do
					vs[i], refs[i] = item.id, item.refs
				end
				local nf = edit.face(vs, refs, f.material, { { fid, 1 } }, k == 1 and fid or nil)
				table.insert(edit.report.faceMap[fid], nf)
			end
			if #pieces == 0 then
				edit.out:removeFace(fid)
			end
		elseif keep == "positive" and negative or keep == "negative" and positive then
			edit.out:removeFace(fid)
			edit.report.faceMap[fid] = {}
		elseif tolerance > 0 then
			edit.report.replacedFaces[fid] = true
		end
	end
	local loops = {}
	if options.cap then
		local cutIndex = C.index(edit.out, options)
		-- A tangential cut can leave a detached coplanar face but no retained solid.
		-- Do not cap that sheet into two coincident sides of a zero-volume shell.
		local visited = {}
		edit.report.discardedCoplanarFaces = {}
		for _, seed in U.keys(edit.out.faces) do
			if not visited[seed] then
				local component, stack, coplanar = {}, { seed }, true
				visited[seed] = true
				while #stack > 0 do
					local fid = table.remove(stack)
					table.insert(component, fid)
					for _, ck in cutIndex.faces[fid].corners do
						local c = cutIndex.corners[ck]
						coplanar = coplanar and planeVertices[c.vertex] == true
						for _, neighbor in cutIndex.edges[c.edge].faces do
							if not visited[neighbor] then
								visited[neighbor] = true
								table.insert(stack, neighbor)
							end
						end
					end
					edit.checkpoint()
				end
				if coplanar then
					for _, fid in component do
						edit.out:removeFace(fid)
						edit.report.discardedCoplanarFaces[fid] = true
					end
				end
			end
		end
		if next(edit.report.discardedCoplanarFaces) then
			cutIndex = C.index(edit.out, options)
		end
		local nextVertex, incoming = {}, {}
		for _, key in U.keys(cutIndex.edges) do
			local e = cutIndex.edges[key]
			if #e.corners == 1 then
				assert(planeVertices[e.a] and planeVertices[e.b], "Cap encountered a nonplanar open boundary")
				local c = cutIndex.corners[e.corners[1]]
				assert(
					not nextVertex[c.to] and not incoming[c.vertex],
					"Cap boundary branches or touches itself"
				)
				nextVertex[c.to], incoming[c.vertex] = c.vertex, true
			end
		end
		local seen = {}
		for _, start in U.keys(nextVertex) do
			if not seen[start] then
				local loop, v = {}, start
				repeat
					assert(v and not seen[v], "Cap boundary is not a simple closed loop")
					seen[v] = true
					table.insert(loop, v)
					v = nextVertex[v]
				until v == start
				assert(#loop >= 3, "Degenerate cap loop")
				table.insert(loops, loop)
			end
		end
		if #loops > 0 then
			local x, y = U.frame(normal)
			local projected, areas, lookup = {}, {}, {}
			for i, loop in loops do
				projected[i] = {}
				for j, id in loop do
					local d = edit.out.vertices[id] - origin
					local p = Vector2.new(d:Dot(x), d:Dot(y))
					assert(not lookup[p] or lookup[p] == id, "Cap vertices collapse in planar projection")
					lookup[p], projected[i][j] = id, p
				end
				local _, area = P.polygonOrientation(projected[i])
				areas[i] = area
			end
			local hits, check = Planar.intersections(projected, options)
			assert(check.complete and #hits == 0, "Cap loops intersect or touch")
			local parents, depths = {}, {}
			for i, loop in projected do
				for j, other in projected do
					if
						i ~= j
						and P.pointInPolygon2D(loop[1], other) == "inside"
						and (not parents[i] or math.abs(areas[j]) < math.abs(areas[parents[i]]))
					then
						parents[i] = j
					end
				end
			end
			for i in projected do
				local depth, parent = 0, parents[i]
				while parent do
					depth += 1
					assert(depth < #loops, "Cyclic cap containment")
					parent = parents[parent]
				end
				depths[i] = depth
			end
			for i, outer in projected do
				if depths[i] % 2 == 0 then
					local holes = {}
					for j, hole in projected do
						if parents[j] == i then
							assert(
								areas[i] * areas[j] < 0,
								"Nested cap loops have incompatible shell orientations"
							)
							table.insert(holes, hole)
						end
					end
					local domain = Planar.triangulate(outer, holes, options)
					for _, tri in domain.triangles do
						local vs, refs, uv = {}, {}, {}
						for k = 1, 3 do
							local p = domain.points[tri[areas[i] > 0 and k or 4 - k]]
							vs[k], refs[k], uv[k] = assert(lookup[p]), {}, p
						end
						local nf = edit.face(vs, refs, options.material or 1, nil)
						for k, p in uv do
							edit.out.faces[nf].corners[k].uv = p
						end
						table.insert(edit.report.caps, nf)
					end
				end
			end
		end
	end
	edit.out:removeUnused()
	-- The discarded half may remove one of a split edge's correspondence targets.
	for domain, map in edit.maps do
		local keys = A.keys(edit.out, domain)
		for key in map do
			if not keys[key] then
				map[key] = nil
			end
		end
	end
	local planeEdges = {}
	for key, edge in edit.out:topology().edges do
		if planeVertices[edge.a] and planeVertices[edge.b] then
			planeEdges[key] = true
		end
	end
	edit.report.planeEdges, edit.report.intersections, edit.report.capLoops, edit.report.cutTriangles =
		planeEdges, intersections, loops, triangleCount
	return edit.finish()
end
