-- Private transactional face-local knife networks with conforming shared edges.
local U = require(script.Parent.Util)
local Core = require(script.Parent.MeshEditCore)
local P = require(script.Parent.Predicates)
local Planar = require(script.Parent.Planar)
return function(mesh, strokes, options)
	options = options or {}
	assert(type(strokes) == "table", "Knife strokes must be an array")
	local edit = Core.begin(mesh, options)
	local planeTolerance = options.planeTolerance or 1e-5
	assert(
		type(planeTolerance) == "number" and U.finite(planeTolerance) and planeTolerance >= 0,
		"Nonnegative plane tolerance required"
	)
	local maxPoints = U.integer(options.maxPathPoints or 10000, 1)
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local work, pointCount, contexts, edgeCuts = 0, 0, {}, {}
	local function visit()
		work += 1
		assert(work <= maxWork, "Knife network work budget exceeded")
		edit.checkpoint()
	end
	local function context(fid)
		if contexts[fid] then
			return contexts[fid]
		end
		local face = mesh.faces[fid]
		local normal = mesh:faceNormal(fid)
		local origin = mesh.vertices[face.vertices[1]]
		local axis = math.abs(normal.X) > math.abs(normal.Y)
				and (math.abs(normal.X) > math.abs(normal.Z) and "X" or "Z")
			or (math.abs(normal.Y) > math.abs(normal.Z) and "Y" or "Z")
		local a, b =
			axis == "X" and "Y" or (axis == "Y" and "Z" or "X"),
			axis == "X" and "Z" or (axis == "Y" and "X" or "Y")
		local function project(p)
			return Vector2.new(p[a], p[b])
		end
		local function lift(p)
			local dropped = origin[axis]
				- (normal[a] * (p.X - origin[a]) + normal[b] * (p.Y - origin[b])) / normal[axis]
			return axis == "X" and Vector3.new(dropped, p.X, p.Y)
				or (axis == "Y" and Vector3.new(p.Y, dropped, p.X) or Vector3.new(p.X, p.Y, dropped))
		end
		local polygon = {}
		for i, id in face.vertices do
			visit()
			assert(
				math.abs((mesh.vertices[id] - origin):Dot(normal)) <= planeTolerance,
				"Knife networks require planar source faces"
			)
			polygon[i] = project(mesh.vertices[id])
		end
		local triangles = mesh:faceTriangles(fid, {
			validateSimple = true,
			maxVertices = options.maxFaceVertices or 2000,
			maxWork = options.maxFaceWork or 5000000,
		})
		local c = {
			project = project,
			lift = lift,
			polygon = polygon,
			triangles = triangles,
			normal = normal,
			origin = origin,
			paths = {},
			strokes = {},
			orientation = P.polygonOrientation(polygon),
		}
		contexts[fid] = c
		return c
	end
	local function endpoint(fid, spec)
		local face = mesh.faces[fid]
		if spec.corner then
			local i = U.integer(spec.corner, 1)
			assert(
				i <= #face.vertices and spec.edge == nil and spec.t == nil,
				"Invalid knife corner endpoint"
			)
			return face.vertices[i]
		end
		local i, t = U.integer(spec.edge, 1), spec.t
		assert(
			i <= #face.vertices and type(t) == "number" and U.finite(t) and t > 0 and t < 1,
			"Knife edge endpoints require t in (0,1)"
		)
		local a, b = face.vertices[i], face.vertices[i % #face.vertices + 1]
		local key, x, y = U.edge(a, b), math.min(a, b), math.max(a, b)
		local u = a == x and t or 1 - t
		local px, py = mesh.vertices[x], mesh.vertices[y]
		local p = Vector3.new(px.X + (py.X - px.X) * u, px.Y + (py.Y - px.Y) * u, px.Z + (py.Z - px.Z) * u)
		assert(p ~= px and p ~= py, "Knife intersection collapses at native precision")
		edgeCuts[key] = edgeCuts[key] or {}
		for _, cut in edgeCuts[key] do
			if cut.t == u or edit.out.vertices[cut.id] == p then
				return cut.id
			end
		end
		local id = edit.vertex(p, { { x, 1 - u }, { y, u } })
		table.insert(edgeCuts[key], { t = u, id = id })
		return id
	end
	for sid, stroke in strokes do
		assert(
			type(stroke) == "table"
				and mesh.faces[stroke.face]
				and type(stroke.path) == "table"
				and #stroke.path >= 2,
			"Knife network stroke requires an existing face and at least two points"
		)
		local fid, c, path = stroke.face, context(stroke.face), {}
		pointCount += #stroke.path
		assert(pointCount <= maxPoints, "Knife network path point budget exceeded")
		for i, spec in stroke.path do
			visit()
			if type(spec) == "table" then
				path[i] = c.project(edit.out.vertices[endpoint(fid, spec)])
			else
				assert(
					U.vector(spec) and math.abs((spec - c.origin):Dot(c.normal)) <= planeTolerance,
					"Knife points must lie in the face plane"
				)
				path[i] = c.project(spec)
				assert(
					P.pointInPolygon2D(path[i], c.polygon) == "inside",
					"Free knife points must be strictly interior; specify boundary corner or edge/t"
				)
			end
		end
		table.insert(c.paths, path)
		table.insert(c.strokes, sid)
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
		edit.maps.edge[U.edge(previous, tonumber(endpoints[2]))] = { { key, 1 } }
	end
	edit.report.faceMap, edit.report.paths, edit.report.networks = {}, {}, {}
	edit.report.constructionError = 0
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		local boundary, refs, changed = {}, {}, false
		for i, a in face.vertices do
			visit()
			local j = i % #face.vertices + 1
			local b = face.vertices[j]
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
		local c = contexts[fid]
		if c then
			local polygon, known = {}, {}
			for i, id in boundary do
				local p = c.project(edit.out.vertices[id])
				polygon[i] = p
				known[p.X] = known[p.X] or {}
				assert(not known[p.X][p.Y], "Distinct face boundary vertices collapse in projection")
				known[p.X][p.Y] = { id = id, refs = refs[i] }
			end
			local domain = Planar.constrain(polygon, {}, c.paths, {
				maxVertices = options.maxNetworkVertices or 10000,
				maxSegments = options.maxNetworkSegments or 20000,
				maxTriangles = options.maxNetworkTriangles or 20000,
				maxWork = maxWork,
				maxTriangulationWork = options.maxFaceWork or maxWork,
				maxConstructionError = options.maxConstructionError,
				_visit = visit,
			})
			local ids, cornerRefs = {}, {}
			local onBoundary = {}
			for _, id in domain.boundaryLoops[1] do
				onBoundary[id] = true
			end
			for i, p in domain.points do
				visit()
				local existing = known[p.X] and known[p.X][p.Y]
				if existing then
					ids[i], cornerRefs[i] = existing.id, existing.refs
				else
					assert(not onBoundary[i], "Knife network creates an unspecified boundary intersection")
					local vr, cr
					for _, tri in c.triangles do
						visit()
						local a, b, d = c.polygon[tri[1]], c.polygon[tri[2]], c.polygon[tri[3]]
						local sign, den = P.orient2D(a, b, d)
						local sa, wa = P.orient2D(b, d, p)
						local sb, wb = P.orient2D(d, a, p)
						local sc, wc = P.orient2D(a, b, p)
						if sa * sign >= 0 and sb * sign >= 0 and sc * sign >= 0 then
							vr, cr = {}, {}
							for k, w in { wa / den, wb / den, wc / den } do
								table.insert(vr, { face.vertices[tri[k]], math.max(0, w) })
								table.insert(cr, { fid, tri[k], math.max(0, w) })
							end
							break
						end
					end
					assert(vr, "Knife network interior interpolation failed")
					ids[i], cornerRefs[i] = edit.vertex(c.lift(p), vr), cr
				end
			end
			local faceMap = {}
			for i, tri in domain.triangles do
				local a, b, d = tri[1], tri[2], tri[3]
				if c.orientation < 0 then
					b, d = d, b
				end
				faceMap[i] = edit.face(
					{ ids[a], ids[b], ids[d] },
					{ cornerRefs[a], cornerRefs[b], cornerRefs[d] },
					face.material,
					{ { fid, 1 } },
					i == 1 and fid or nil
				)
			end
			local constraints = {}
			for _, edge in domain.constrainedEdges do
				local globalStrokes = {}
				for k in edge.paths do
					globalStrokes[c.strokes[k]] = true
				end
				constraints[U.edge(ids[edge.a], ids[edge.b])] = {
					boundary = edge.boundary,
					strokes = globalStrokes,
				}
			end
			for k, path in domain.paths do
				local vertices = {}
				for i, id in path do
					vertices[i] = ids[id]
				end
				edit.report.paths[c.strokes[k]] = vertices
			end
			edit.report.faceMap[fid] = faceMap
			edit.report.networks[fid] = {
				points = ids,
				constrainedEdges = constraints,
				constructionError = domain.constructionError,
				recoveredEdges = domain.recoveredEdges,
				edgeFlips = domain.edgeFlips,
				work = domain.work,
			}
			edit.report.constructionError = math.max(edit.report.constructionError, domain.constructionError)
		elseif changed then
			edit.face(boundary, refs, face.material, { { fid, 1 } }, fid)
			edit.report.faceMap[fid] = { fid }
		end
	end
	edit.report.work, edit.report.complete = work, true
	return edit.finish()
end
