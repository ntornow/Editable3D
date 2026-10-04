-- Private planar segment arrangement and edge-exchange constraint recovery.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local Planar = require(script.Parent.Planar)
return function(outer, holes, paths, options)
	options = options or {}
	holes = holes or {}
	paths = paths or {}
	assert(type(paths) == "table", "Constraint paths must be an array")
	local maxVertices = U.integer(options.maxVertices or 10000, 3)
	local maxSegments = U.integer(options.maxSegments or 20000, 1)
	local maxTriangles = U.integer(options.maxTriangles or 20000, 1)
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local work = 0
	local function visit()
		work += 1
		assert(work <= maxWork, "Planar constraint work budget exceeded")
		if options._visit then
			options._visit()
		end
		if options.checkpoint and work % 256 == 0 then
			options.checkpoint(work / maxWork)
		end
	end
	if options.checkpoint then
		options.checkpoint(0)
	end
	local child =
		{ maxVertices = maxVertices, maxWork = options.maxTriangulationWork or maxWork, _visit = visit }
	local initial = Planar.triangulate(outer, holes, child)
	local points, lookup = {}, {}
	local function register(p)
		assert(
			typeof(p) == "Vector2" and U.finite(p.X) and U.finite(p.Y),
			"Finite native planar points required"
		)
		lookup[p.X] = lookup[p.X] or {}
		local id = lookup[p.X][p.Y]
		if id then
			return id
		end
		assert(#points < maxVertices, "Planar constraint vertex budget exceeded")
		table.insert(points, p)
		id = #points
		lookup[p.X][p.Y] = id
		return id
	end
	local segments, loopSegments, pathSegments, inputPaths = {}, {}, {}, {}
	local function segment(a, b, kind, group, ordinal)
		assert(a ~= b, "Constraint paths cannot contain zero-length segments")
		assert(#segments < maxSegments, "Planar constraint segment budget exceeded")
		table.insert(segments, {
			a = a,
			b = b,
			kind = kind,
			group = group,
			ordinal = ordinal,
			cuts = { { id = a, t = 0 }, {
				id = b,
				t = 1,
			} },
		})
		return #segments
	end
	for k, loop in initial.boundaryLoops do
		loopSegments[k] = {}
		for i, id in loop do
			local a, b = register(initial.points[id]), register(initial.points[loop[i % #loop + 1]])
			loopSegments[k][i] = segment(a, b, "boundary", k, i)
		end
	end
	for k, path in paths do
		assert(type(path) == "table" and #path >= 2, "Constraint paths need at least two points")
		pathSegments[k], inputPaths[k] = {}, {}
		for i, p in path do
			inputPaths[k][i] = register(p)
		end
		for i = 1, #path - 1 do
			pathSegments[k][i] = segment(inputPaths[k][i], inputPaths[k][i + 1], "path", k, i)
		end
	end
	local function parameter(p, a, b)
		local x, y = b.X - a.X, b.Y - a.Y
		return math.abs(x) >= math.abs(y) and (p.X - a.X) / x or (p.Y - a.Y) / y
	end
	local deviation = 0
	local function cut(s, id)
		-- All occurrences of one native point use the same represented parameter.
		-- Mixing exact intersection parameters with rounded on-segment parameters
		-- would spuriously reject ordinary crossings of an axis-aligned segment.
		local t = parameter(points[id], points[s.a], points[s.b])
		assert(
			U.finite(t) and t >= -1e-12 and t <= 1 + 1e-12,
			"Intersection parameter leaves its source segment"
		)
		t = math.clamp(t, 0, 1)
		for _, old in s.cuts do
			if old.id == id then
				return
			end
		end
		table.insert(s.cuts, { id = id, t = t })
		local p, a, b = points[id], points[s.a], points[s.b]
		local x, y = b.X - a.X, b.Y - a.Y
		local u = math.clamp(((p.X - a.X) * x + (p.Y - a.Y) * y) / (x * x + y * y), 0, 1)
		local dx, dy = p.X - a.X - x * u, p.Y - a.Y - y * u
		deviation = math.max(deviation, math.sqrt(dx * dx + dy * dy))
	end
	for i, a in segments do
		for j = i + 1, #segments do
			visit()
			local b = segments[j]
			local hit = P.intersectSegments2D(points[a.a], points[a.b], points[b.a], points[b.b])
			if hit.kind == "point" then
				local id = register(hit.point)
				if hit.proper then
					assert(
						id ~= a.a and id ~= a.b and id ~= b.a and id ~= b.b,
						"Proper intersection collapses onto an endpoint at native precision"
					)
				end
				cut(a, id)
				cut(b, id)
			elseif hit.kind == "overlap" then
				for _, p in hit.points do
					local id = register(p)
					cut(a, id)
					cut(b, id)
				end
			end
		end
	end
	-- Include represented intersection points lying exactly on any other source segment.
	for _, s in segments do
		for id, p in points do
			visit()
			if id ~= s.a and id ~= s.b and P.onSegment2D(p, points[s.a], points[s.b]) then
				cut(s, id)
			end
		end
		table.sort(s.cuts, function(a, b)
			return a.t < b.t or a.t == b.t and a.id < b.id
		end)
		for i = 2, #s.cuts do
			assert(s.cuts[i].t > s.cuts[i - 1].t, "Segment intersections have indistinguishable parameters")
		end
	end
	if options.maxConstructionError ~= nil then
		assert(
			type(options.maxConstructionError) == "number"
				and U.finite(options.maxConstructionError)
				and options.maxConstructionError >= 0,
			"Nonnegative construction error bound required"
		)
		assert(
			deviation <= options.maxConstructionError,
			"Native intersection construction exceeds requested error"
		)
	end
	local atomic, atomMap = {}, {}
	local function atom(a, b, s)
		local key = U.edge(a, b)
		local existing = atomMap[key]
		if not existing then
			assert(#atomic < maxSegments, "Atomic constraint segment budget exceeded")
			existing = { a = math.min(a, b), b = math.max(a, b), boundary = false, paths = {}, sources = {} }
			atomMap[key] = existing
			table.insert(atomic, existing)
		end
		if s.kind == "boundary" then
			existing.boundary = true
		else
			existing.paths[s.group] = true
		end
		table.insert(existing.sources, { kind = s.kind, group = s.group, segment = s.ordinal })
	end
	for _, s in segments do
		for i = 1, #s.cuts - 1 do
			atom(s.cuts[i].id, s.cuts[i + 1].id, s)
		end
	end
	-- Exact signs validate the represented atomic network after native rounding.
	for i, a in atomic do
		for j = i + 1, #atomic do
			visit()
			local b = atomic[j]
			local hit = P.intersectSegments2D(points[a.a], points[a.b], points[b.a], points[b.b])
			local shared = a.a == b.a or a.a == b.b or a.b == b.a or a.b == b.b
			assert(
				hit.kind == "none" or hit.kind == "point" and not hit.proper and shared,
				"Rounded constraint arrangement has an unresolved crossing or overlap"
			)
		end
	end
	local loops, loopIds = {}, {}
	for k, indices in loopSegments do
		loops[k], loopIds[k] = {}, {}
		for _, sid in indices do
			local s = segments[sid]
			for i = 1, #s.cuts - 1 do
				table.insert(loopIds[k], s.cuts[i].id)
				table.insert(loops[k], points[s.cuts[i].id])
			end
		end
	end
	local function inside(p)
		local location = P.pointInPolygon2D(p, loops[1])
		if location == "outside" then
			return false
		end
		for i = 2, #loops do
			if P.pointInPolygon2D(p, loops[i]) == "inside" then
				return false
			end
		end
		return true
	end
	for _, edge in atomic do
		if not edge.boundary then
			local a, b = points[edge.a], points[edge.b]
			assert(
				inside(a) and inside(b) and inside(Vector2.new((a.X + b.X) / 2, (a.Y + b.Y) / 2)),
				"Constraint leaves the polygon domain or enters a hole"
			)
		end
	end
	local holeLoops = {}
	for i = 2, #loops do
		table.insert(holeLoops, loops[i])
	end
	local seed = Planar.triangulate(loops[1], holeLoops, child)
	local triangles, edges, nextTriangle, triangleCount = {}, {}, 0, 0
	local function add(a, b, c)
		visit()
		local sign = P.orient2D(points[a], points[b], points[c])
		assert(sign ~= 0, "Constraint triangulation produced a zero-area triangle")
		if sign < 0 then
			b, c = c, b
		end
		assert(triangleCount < maxTriangles, "Planar constraint triangle budget exceeded")
		nextTriangle += 1
		triangleCount += 1
		local id = nextTriangle
		triangles[id] = { a, b, c }
		for i, v in triangles[id] do
			local w = triangles[id][i % 3 + 1]
			local key = U.edge(v, w)
			edges[key] = edges[key] or { a = math.min(v, w), b = math.max(v, w), faces = {}, count = 0 }
			edges[key].faces[id] = true
			edges[key].count += 1
		end
		return id
	end
	local function remove(id)
		visit()
		local tri = assert(triangles[id])
		triangles[id] = nil
		triangleCount -= 1
		for i, v in tri do
			local key = U.edge(v, tri[i % 3 + 1])
			local e = edges[key]
			e.faces[id] = nil
			e.count -= 1
			if e.count == 0 then
				edges[key] = nil
			end
		end
	end
	for _, tri in seed.triangles do
		add(register(seed.points[tri[1]]), register(seed.points[tri[2]]), register(seed.points[tri[3]]))
	end
	local boundaryVertices, boundaryEdges = {}, {}
	for _, loop in loopIds do
		for i, id in loop do
			boundaryVertices[id] = true
			boundaryEdges[U.edge(id, loop[i % #loop + 1])] = true
		end
	end
	for id, p in points do
		if boundaryVertices[id] then
			continue
		end
		assert(inside(p), "Constraint point is outside the domain")
		local found, edgeKey
		for _, tid in U.keys(triangles) do
			visit()
			local tri = triangles[tid]
			local a, b, c = points[tri[1]], points[tri[2]], points[tri[3]]
			if
				p.X < math.min(a.X, b.X, c.X)
				or p.X > math.max(a.X, b.X, c.X)
				or p.Y < math.min(a.Y, b.Y, c.Y)
				or p.Y > math.max(a.Y, b.Y, c.Y)
			then
				continue
			end
			local signs = {
				(P.orient2D(points[tri[1]], points[tri[2]], p)),
				(P.orient2D(points[tri[2]], points[tri[3]], p)),
				(P.orient2D(points[tri[3]], points[tri[1]], p)),
			}
			if signs[1] >= 0 and signs[2] >= 0 and signs[3] >= 0 then
				found = tid
				for i, s in signs do
					if s == 0 then
						edgeKey = U.edge(tri[i], tri[i % 3 + 1])
						break
					end
				end
				break
			end
		end
		assert(found, "Constraint point could not be located in the triangulation")
		if edgeKey then
			local edge = edges[edgeKey]
			assert(not boundaryEdges[edgeKey], "Unregistered boundary point after arrangement")
			for _, tid in U.keys(edge.faces) do
				local tri = triangles[tid]
				local other
				for _, v in tri do
					if v ~= edge.a and v ~= edge.b then
						other = v
					end
				end
				remove(tid)
				add(edge.a, id, other)
				add(id, edge.b, other)
			end
		else
			local tri = triangles[found]
			remove(found)
			add(tri[1], tri[2], id)
			add(tri[2], tri[3], id)
			add(tri[3], tri[1], id)
		end
	end
	local protected = table.clone(boundaryEdges)
	local recovered = 0
	local function crosses(a, b, x, y)
		local pa, pb, px, py = points[a], points[b], points[x], points[y]
		if
			math.max(pa.X, pb.X) < math.min(px.X, py.X)
			or math.max(px.X, py.X) < math.min(pa.X, pb.X)
			or math.max(pa.Y, pb.Y) < math.min(px.Y, py.Y)
			or math.max(px.Y, py.Y) < math.min(pa.Y, pb.Y)
		then
			return false
		end
		local sa = P.orient2D(points[a], points[b], points[x])
		local sb = P.orient2D(points[a], points[b], points[y])
		if sa * sb >= 0 then
			return false
		end
		return P.orient2D(points[x], points[y], points[a]) * P.orient2D(points[x], points[y], points[b]) < 0
	end
	local flips = 0
	for _, key in U.keys(atomMap) do
		local target = atomMap[key]
		if not edges[key] then
			-- Lawson constraint recovery. Convex crossed diagonals are exchanged;
			-- diagonals still crossing the constraint go to the tail of the queue.
			-- This also handles cavities with pinched boundaries and internal islands.
			local queue = {}
			for _, edgeKey in U.keys(edges) do
				visit()
				local edge = edges[edgeKey]
				if crosses(target.a, target.b, edge.a, edge.b) then
					table.insert(queue, edgeKey)
				end
			end
			local head, stalled = 1, 0
			while head <= #queue do
				visit()
				local edgeKey = queue[head]
				head += 1
				local edge = edges[edgeKey]
				if not edge or not crosses(target.a, target.b, edge.a, edge.b) then
					stalled = 0
					continue
				end
				assert(
					not protected[edgeKey] and edge.count == 2,
					"Constraint recovery would cross a protected boundary"
				)
				local adjacent = U.keys(edge.faces)
				local opposite = {}
				for i, tid in adjacent do
					for _, id in triangles[tid] do
						if id ~= edge.a and id ~= edge.b then
							opposite[i] = id
						end
					end
				end
				local x, y = opposite[1], opposite[2]
				if crosses(edge.a, edge.b, x, y) then
					assert(not edges[U.edge(x, y)], "Constraint edge exchange creates duplicate topology")
					remove(adjacent[1])
					remove(adjacent[2])
					add(x, y, edge.a)
					add(y, x, edge.b)
					flips += 1
					stalled = 0
					if crosses(target.a, target.b, x, y) then
						table.insert(queue, U.edge(x, y))
					end
				else
					table.insert(queue, edgeKey)
					stalled += 1
					assert(stalled < #queue - head + 1, "Constraint recovery has no flippable crossed edge")
				end
			end
			assert(edges[key], "Constraint recovery failed to create the requested edge")
			recovered += 1
		end
		protected[key] = true
	end
	local result, area = {}, 0
	local balance = {}
	for _, tid in U.keys(triangles) do
		visit()
		local tri = triangles[tid]
		local sign, det = P.orient2D(points[tri[1]], points[tri[2]], points[tri[3]])
		assert(sign > 0, "Constraint triangulation contains a reversed triangle")
		area += det / 2
		table.insert(result, tri)
		for i, a in tri do
			local b = tri[i % 3 + 1]
			local key = U.edge(a, b)
			balance[key] = (balance[key] or 0) + (a < b and 1 or -1)
		end
	end
	for key, edge in edges do
		assert(
			edge.count == (boundaryEdges[key] and 1 or 2),
			"Constrained triangulation has a crack or nonmanifold edge"
		)
		assert(
			boundaryEdges[key] or balance[key] == 0,
			"Constrained triangulation has inconsistent interior winding"
		)
	end
	for _, loop in loopIds do
		for i, a in loop do
			local b = loop[i % #loop + 1]
			local key = U.edge(a, b)
			assert(
				edges[key] and balance[key] == (a < b and 1 or -1),
				"Constrained triangulation lost a domain boundary"
			)
		end
	end
	for key in atomMap do
		assert(edges[key], "Constrained triangulation lost a path segment")
	end
	assert(
		math.abs(area - seed.area) <= math.max(math.abs(seed.area) * 1e-9, 1e-300),
		"Constrained triangulation area mismatch"
	)
	assert(
		#result == 2 * #points - U.count(boundaryVertices) + 2 * #holes - 2,
		"Constrained triangulation Euler count mismatch"
	)
	local expandedPaths = {}
	for k, indices in pathSegments do
		expandedPaths[k] = {}
		for j, sid in indices do
			local s = segments[sid]
			for i = 1, #s.cuts - (j == #indices and 0 or 1) do
				table.insert(expandedPaths[k], s.cuts[i].id)
			end
		end
	end
	return {
		points = points,
		triangles = result,
		boundaryLoops = loopIds,
		area = area,
		holes = #holes,
		paths = expandedPaths,
		inputPaths = inputPaths,
		constrainedEdges = atomMap,
		constructionError = deviation,
		work = work,
		recoveredEdges = recovered,
		edgeFlips = flips,
		complete = true,
	}
end
