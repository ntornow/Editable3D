-- Private finite face-local knife paths with shared edge intersections.
local U = require(script.Parent.Util)
local Core = require(script.Parent.MeshEditCore)
local P = require(script.Parent.Predicates)
return function(mesh, strokes, options)
	options = options or {}
	assert(type(strokes) == "table", "Knife strokes must be an array")
	local edit = Core.begin(mesh, options)
	local planeTolerance = options.planeTolerance or 1e-5
	assert(
		type(planeTolerance) == "number" and U.finite(planeTolerance) and planeTolerance >= 0,
		"Nonnegative plane tolerance required"
	)
	local maxPoints, maxWork =
		U.integer(options.maxPathPoints or 2000, 1), U.integer(options.maxWork or 5000000, 1)
	local pointCount, work, edgeCuts, paths, pathRefs = 0, 0, {}, {}, {}
	local function visit()
		work += 1
		assert(work <= maxWork, "Knife work budget exceeded")
		edit.checkpoint()
	end
	local function projection(normal)
		local axis = math.abs(normal.X) > math.abs(normal.Y)
				and (math.abs(normal.X) > math.abs(normal.Z) and "X" or "Z")
			or (math.abs(normal.Y) > math.abs(normal.Z) and "Y" or "Z")
		return function(p)
			return axis == "X" and Vector2.new(p.Y, p.Z)
				or (axis == "Y" and Vector2.new(p.Z, p.X) or Vector2.new(p.X, p.Y))
		end
	end
	local function endpoint(fid, spec)
		local f = mesh.faces[fid]
		assert(type(spec) == "table", "Knife endpoints must specify corner or edge/t")
		if spec.corner then
			local i = U.integer(spec.corner, 1)
			assert(i <= #f.vertices and spec.edge == nil and spec.t == nil, "Invalid knife corner endpoint")
			return f.vertices[i], { { fid, i, 1 } }
		end
		local i = U.integer(spec.edge, 1)
		local t = spec.t
		assert(
			i <= #f.vertices and type(t) == "number" and U.finite(t) and t > 0 and t < 1,
			"Knife edge endpoints require t in (0,1)"
		)
		local j = i % #f.vertices + 1
		local a, b = f.vertices[i], f.vertices[j]
		local key = U.edge(a, b)
		local x, y = math.min(a, b), math.max(a, b)
		local u = a == x and t or 1 - t
		local px, py = mesh.vertices[x], mesh.vertices[y]
		local p = Vector3.new(px.X + (py.X - px.X) * u, px.Y + (py.Y - px.Y) * u, px.Z + (py.Z - px.Z) * u)
		assert(p ~= px and p ~= py, "Knife intersection collapses at native precision")
		edgeCuts[key] = edgeCuts[key] or {}
		for _, cut in edgeCuts[key] do
			if math.abs(cut.t - u) <= 1e-12 or edit.out.vertices[cut.id] == p then
				local localT = a == x and cut.t or 1 - cut.t
				return cut.id, { { fid, i, 1 - localT }, { fid, j, localT } }
			end
		end
		local id = edit.vertex(p, { { x, 1 - u }, { y, u } })
		table.insert(edgeCuts[key], { t = u, id = id })
		return id, { { fid, i, 1 - t }, { fid, j, t } }
	end
	for _, stroke in strokes do
		assert(
			type(stroke) == "table"
				and mesh.faces[stroke.face]
				and type(stroke.path) == "table"
				and #stroke.path >= 2,
			"Knife stroke requires an existing face and boundary-to-boundary path"
		)
		local fid, path = stroke.face, stroke.path
		assert(not paths[fid], "One knife path per source face per call; compose calls for further cuts")
		pointCount += #path
		assert(pointCount <= maxPoints, "Knife path point budget exceeded")
		local f = mesh.faces[fid]
		local normal = mesh:faceNormal(fid)
		local origin = mesh.vertices[f.vertices[1]]
		local project = projection(normal)
		local polygon = {}
		for i, id in f.vertices do
			assert(
				math.abs((mesh.vertices[id] - origin):Dot(normal)) <= planeTolerance,
				"Knife requires planar source faces"
			)
			polygon[i] = project(mesh.vertices[id])
		end
		local triangles = mesh:faceTriangles(fid, {
			validateSimple = true,
			maxVertices = options.maxFaceVertices or 2000,
			maxWork = options.maxFaceWork or 5000000,
		})
		local ids, refs = {}, {}
		ids[1], refs[1] = endpoint(fid, path[1])
		for i = 2, #path - 1 do
			local p = path[i]
			assert(
				U.vector(p) and math.abs((p - origin):Dot(normal)) <= planeTolerance,
				"Knife interior points must lie in the face plane"
			)
			p -= normal * (p - origin):Dot(normal)
			local q = project(p)
			assert(
				P.pointInPolygon2D(q, polygon) == "inside",
				"Knife interior points must be strictly inside the face"
			)
			local vr, cr
			for _, tri in triangles do
				visit()
				local a, b, c = polygon[tri[1]], polygon[tri[2]], polygon[tri[3]]
				local sign, den = P.orient2D(a, b, c)
				local sa, wa = P.orient2D(b, c, q)
				local sb, wb = P.orient2D(c, a, q)
				local sc, wc = P.orient2D(a, b, q)
				if sa * sign >= 0 and sb * sign >= 0 and sc * sign >= 0 then
					vr, cr = {}, {}
					for k, w in { wa / den, wb / den, wc / den } do
						table.insert(vr, { f.vertices[tri[k]], math.max(0, w) })
						table.insert(cr, { fid, tri[k], math.max(0, w) })
					end
					break
				end
			end
			assert(vr, "Knife interior interpolation failed")
			ids[i], refs[i] = edit.vertex(p, vr), cr
		end
		ids[#path], refs[#path] = endpoint(fid, path[#path])
		assert(ids[1] ~= ids[#path], "Knife path endpoints must be distinct")
		paths[fid], pathRefs[fid] = ids, refs
	end
	for key, cuts in edgeCuts do
		table.sort(cuts, function(a, b)
			return a.t < b.t
		end)
		local endpoints = string.split(key, ":")
		local previous = tonumber(endpoints[1])
		for _, cut in cuts do
			edit.maps.edge[U.edge(previous, cut.id)] = { { key, 1 } }
			previous = cut.id
		end
		edit.maps.edge[U.edge(previous, tonumber(endpoints[2]) :: number)] = { { key, 1 } }
	end
	edit.report.faceMap = {}
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		local boundary, refs, changed = {}, {}, false
		for i, a in f.vertices do
			local j = i % #f.vertices + 1
			local b = f.vertices[j]
			table.insert(boundary, a)
			table.insert(refs, { { fid, i, 1 } })
			local cuts = edgeCuts[U.edge(a, b)]
			if cuts then
				changed = true
				for k = 1, #cuts do
					local cut = cuts[a < b and k or #cuts - k + 1]
					local t = a < b and cut.t or 1 - cut.t
					table.insert(boundary, cut.id)
					table.insert(refs, { { fid, i, 1 - t }, { fid, j, t } })
				end
			end
		end
		local path = paths[fid]
		if path then
			local project = projection(mesh:faceNormal(fid))
			local points, line = {}, {}
			for i, id in boundary do
				points[i] = project(edit.out.vertices[id])
			end
			for i, id in path do
				line[i] = project(edit.out.vertices[id])
			end
			for i = 1, #line - 1 do
				assert(line[i] ~= line[i + 1], "Knife path contains a zero-length segment")
				assert(
					P.pointInPolygon2D((line[i] + line[i + 1]) / 2, points) == "inside",
					"Knife segment leaves or follows the boundary"
				)
				for j, a in points do
					visit()
					local nextJ = j % #points + 1
					local hit = P.intersectSegments2D(line[i], line[i + 1], a, points[nextJ])
					if hit.kind ~= "none" then
						local allowed = false
						for _, k in { i, i + 1 } do
							if
								(k == 1 or k == #path)
								and (path[k] == boundary[j] or path[k] == boundary[nextJ])
								and hit.kind == "point"
								and hit.point == line[k]
							then
								allowed = true
							end
						end
						assert(allowed, "Knife path crosses or touches the boundary away from its endpoints")
					end
				end
				for j = i + 1, #line - 1 do
					visit()
					local hit = P.intersectSegments2D(line[i], line[i + 1], line[j], line[j + 1])
					assert(
						hit.kind == "none" or j == i + 1 and hit.kind == "point" and hit.point == line[j],
						"Knife path crosses or retraces itself"
					)
				end
			end
			local a, b = assert(table.find(boundary, path[1])), assert(table.find(boundary, path[#path]))
			local sign = P.polygonOrientation(points)
			local faces = {}
			for side = 1, 2 do
				local start, finish = side == 1 and a or b, side == 1 and b or a
				local vs, cr = {}, {}
				local cursor = start
				while true do
					table.insert(vs, boundary[cursor])
					table.insert(cr, refs[cursor])
					if cursor == finish then
						break
					end
					cursor = cursor % #boundary + 1
				end
				for k = 2, #path - 1 do
					local i = side == 1 and #path - k + 1 or k
					table.insert(vs, path[i])
					table.insert(cr, pathRefs[fid][i])
				end
				local polygon = {}
				for i, id in vs do
					polygon[i] = project(edit.out.vertices[id])
				end
				assert(
					#vs >= 3 and P.polygonOrientation(polygon) == sign,
					"Knife produces a degenerate or reversed region"
				)
				table.insert(faces, edit.face(vs, cr, f.material, { { fid, 1 } }, side == 1 and fid or nil))
			end
			edit.report.faceMap[fid] = faces
		elseif changed then
			edit.face(boundary, refs, f.material, { { fid, 1 } }, fid)
		end
		visit()
	end
	edit.report.paths, edit.report.edgeCuts, edit.report.work = paths, edgeCuts, work
	return edit.finish()
end
