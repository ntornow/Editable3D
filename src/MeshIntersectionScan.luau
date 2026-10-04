-- Private bounded BVH pair traversal over robustly triangulated source faces.
local U = require(script.Parent.Util)
local Core = require(script.Parent.TriangleIntersectionCore)
return function(a, b, options)
	options = options or {}
	local selfQuery = b == nil
	b = b or a
	local maxTriangles = U.integer(options.maxTriangles or 500000, 1)
	local maxTests = U.integer(options.maxTests or 1000000, 1)
	local maxHits = U.integer(options.maxIntersections or 10000, 1)
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local work, triangleCount = 0, 0
	local function checkpoint(stage)
		if options.checkpoint and work % 256 == 0 then
			options.checkpoint({ stage = stage, work = work, triangles = triangleCount })
		end
	end
	if options.checkpoint then
		options.checkpoint({ stage = "begin", work = 0, triangles = 0 })
	end
	local function prepare(mesh)
		local items = {}
		for _, fid in U.keys(mesh.faces) do
			local f = mesh.faces[fid]
			for _, corner in
				mesh:faceTriangles(fid, {
					validateSimple = true,
					maxVertices = options.maxFaceVertices or 2000,
					maxWork = options.maxFaceWork or maxWork,
				})
			do
				triangleCount += 1
				assert(triangleCount <= maxTriangles, "Intersection triangle allocation budget exceeded")
				work += 1
				assert(work <= maxWork, "Intersection preparation work budget exceeded")
				local ids, points = {}, {}
				for i, k in corner do
					ids[i], points[i] = f.vertices[k], mesh.vertices[f.vertices[k]]
				end
				local pr = Core.prepare(points)
				local lo, hi = points[1], points[1]
				for i = 2, 3 do
					lo, hi = lo:Min(points[i]), hi:Max(points[i])
				end
				local center = Vector3.new(
					(points[1].X + points[2].X + points[3].X) / 3,
					(points[1].Y + points[2].Y + points[3].Y) / 3,
					(points[1].Z + points[2].Z + points[3].Z) / 3
				)
				table.insert(items, {
					index = #items + 1,
					face = fid,
					corners = corner,
					vertices = ids,
					points = points,
					projection = pr,
					lo = lo,
					hi = hi,
					center = center,
				})
				checkpoint("prepare")
			end
		end
		local function build(list)
			if #list == 0 then
				return nil
			end
			local lo, hi = list[1].lo, list[1].hi
			for _, item in list do
				work += 1
				assert(work <= maxWork, "Intersection index work budget exceeded")
				lo, hi = lo:Min(item.lo), hi:Max(item.hi)
				checkpoint("index")
			end
			local node = { lo = lo, hi = hi, count = #list }
			if #list <= 8 then
				node.items = list
				return node
			end
			local x, y, z = hi.X - lo.X, hi.Y - lo.Y, hi.Z - lo.Z
			local axis = x >= y and x >= z and "X" or y >= z and "Y" or "Z"
			table.sort(list, function(a, b)
				return a.center[axis] < b.center[axis]
					or a.center[axis] == b.center[axis] and a.index < b.index
			end)
			local left, right = {}, {}
			for i, item in list do
				table.insert(i <= math.floor(#list / 2) and left or right, item)
			end
			node.left, node.right = build(left), build(right)
			return node
		end
		return { items = items, root = build(table.clone(items)) }
	end
	local first = prepare(a)
	local second = selfQuery and first or prepare(b)
	local hits = {}
	local report = {
		complete = true,
		trianglesA = #first.items,
		trianglesB = #second.items,
		tests = 0,
		nodePairs = 0,
		ordinaryAdjacencies = 0,
		crossings = 0,
		overlaps = 0,
		contacts = 0,
		constructionFailures = 0,
		maxRoundingError = 0,
		selfQuery = selfQuery,
	}
	local stopped = false
	local function stop(reason)
		stopped, report.complete, report.reason = true, false, reason
	end
	local function overlap(a, b)
		return a.lo.X <= b.hi.X
			and b.lo.X <= a.hi.X
			and a.lo.Y <= b.hi.Y
			and b.lo.Y <= a.hi.Y
			and a.lo.Z <= b.hi.Z
			and b.lo.Z <= a.hi.Z
	end
	local function test(x, y)
		if stopped or not overlap(x, y) then
			return
		end
		if selfQuery then
			if x.index == y.index then
				return
			end
			if x.index > y.index then
				x, y = y, x
			end
		end
		if report.tests >= maxTests then
			stop("Triangle test budget reached")
			return
		end
		work += 1
		if work > maxWork then
			stop("Intersection work budget reached")
			return
		end
		report.tests += 1
		checkpoint("intersections")
		local hit = Core.triangles(x.points, y.points, x.projection, y.projection)
		if hit.kind == "none" then
			return
		end
		local shared = 0
		if selfQuery then
			for _, id in x.vertices do
				if table.find(y.vertices, id) then
					shared += 1
				end
			end
		end
		local ordinary = hit.dimension == 0 and shared == 1 or hit.dimension == 1 and shared == 2
		if ordinary then
			report.ordinaryAdjacencies += 1
			if not options.includeAdjacent then
				return
			end
		end
		if not ordinary then
			local key = hit.classification == "crossing" and "crossings"
				or hit.classification == "overlap" and "overlaps"
				or "contacts"
			report[key] += 1
		end
		report.maxRoundingError = math.max(report.maxRoundingError, hit.maxRoundingError or 0)
		if not hit.constructionComplete then
			report.constructionFailures += 1
		end
		if hit.classification == "contact" and options.includeContacts == false and not ordinary then
			return
		end
		hit.faceA, hit.faceB = x.face, y.face
		hit.triangleA, hit.triangleB = x.index, y.index
		hit.verticesA, hit.verticesB = table.clone(x.vertices), table.clone(y.vertices)
		hit.cornersA, hit.cornersB = table.clone(x.corners), table.clone(y.corners)
		hit.ordinaryAdjacency = ordinary
		table.insert(hits, hit)
		if #hits >= maxHits then
			stop("Intersection report budget reached")
		end
	end
	local function traverse(x, y)
		if stopped or not x or not y or not overlap(x, y) then
			return
		end
		work += 1
		if work > maxWork then
			stop("Intersection work budget reached")
			return
		end
		report.nodePairs += 1
		checkpoint("intersections")
		if x.items and y.items then
			for _, p in x.items do
				for _, q in y.items do
					if x ~= y or p.index < q.index then
						test(p, q)
					end
					if stopped then
						return
					end
				end
			end
		elseif x == y then
			traverse(x.left, x.left)
			traverse(x.left, x.right)
			traverse(x.right, x.right)
		elseif not x.items and (y.items or x.count >= y.count) then
			traverse(x.left, y)
			traverse(x.right, y)
		else
			traverse(x, y.left)
			traverse(x, y.right)
		end
	end
	traverse(first.root, second.root)
	report.work, report.reported = work, #hits
	report.intersectionFree = report.complete
		and report.crossings == 0
		and report.overlaps == 0
		and report.contacts == 0
	report.surfaceCrossing = report.crossings > 0 or report.overlaps > 0
	return hits, report
end
