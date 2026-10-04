-- Private union of explicit simple domains, optionally repeated by integer translations.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local D = require(script.Parent.Planar)
local Clip = require(script.Parent.TrimClip)
local function array(value, message)
	assert(type(value) == "table", message)
	local count = 0
	for key in value do
		count += 1
		assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #value, message)
	end
	assert(count == #value, message)
	return #value
end
return function(regions, options)
	options = table.clone(options or {})
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local maxVertices = U.integer(options.maxVertices or 20000, 4)
	local maxInputVertices = U.integer(options.maxInputVertices or 2000, 3)
	local maxCopies = U.integer(options.maxCopies or 256, 1)
	local maxRegions = U.integer(options.maxRegions or 256, 1)
	assert(array(regions, "Trim regions must be a dense array") <= maxRegions, "Trim region budget exceeded")
	local maxCoordinate = options.maxCoordinate or 1024
	assert(
		U.finite(maxCoordinate) and maxCoordinate >= 1 and maxCoordinate <= 2 ^ 20,
		"Invalid unwrapped coordinate limit"
	)
	for _, k in { "closedU", "closedV" } do
		assert(options[k] == nil or type(options[k]) == "boolean", "Periodic options must be boolean")
	end
	if options.maxClippingError ~= nil then
		assert(
			type(options.maxClippingError) == "number"
				and U.finite(options.maxClippingError)
				and options.maxClippingError >= 0,
			"Nonnegative clipping error limit required"
		)
	end
	local input, count = {}, 0
	for k, r in regions do
		assert(
			type(k) == "number" and k >= 1 and k % 1 == 0 and k <= #regions and type(r) == "table",
			"Trim regions must be an array"
		)
		array(r.outer, "Trim outer loop must be a dense array")
		array(r.holes or {}, "Trim holes must be a dense array")
		input[k] = { outer = table.clone(r.outer), holes = {} }
		for j, h in r.holes or {} do
			array(h, "Trim hole must be a dense array")
			input[k].holes[j] = table.clone(h)
		end
		for _, ring in { input[k].outer, table.unpack(input[k].holes) } do
			count += #ring
			assert(count <= maxInputVertices, "Trim input vertex budget exceeded")
			for _, p in ring do
				assert(
					typeof(p) == "Vector2" and U.finite(p.X) and U.finite(p.Y),
					"Finite native trim coordinates required"
				)
				assert(
					math.abs(p.X) <= maxCoordinate and math.abs(p.Y) <= maxCoordinate,
					"Unwrapped trim coordinate budget exceeded"
				)
				assert(options.closedU or p.X >= 0 and p.X <= 1, "Unwrapped U trim needs closedU")
				assert(options.closedV or p.Y >= 0 and p.Y <= 1, "Unwrapped V trim needs closedV")
			end
		end
	end
	local work = 0
	local function checkpoint(stage)
		assert(not options.cancelled or not options.cancelled(), "Trim decomposition cancelled")
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = work })
		end
		assert(not options.cancelled or not options.cancelled(), "Trim decomposition cancelled")
	end
	local function visit()
		work += 1
		assert(work <= maxWork, "Trim decomposition work budget exceeded")
		if work % 256 == 0 then
			checkpoint("decompose")
		end
	end
	checkpoint("begin")
	local paths, loopCount, copies = {}, 0, 0
	local clippedVertices = 0
	local minX, maxX, minY, maxY = 0, 1, 0, 1
	local clippingError = 0
	local child = { maxVertices = maxInputVertices, maxWork = maxWork, _visit = visit }
	for _, r in input do
		local domain = D.triangulate(r.outer, r.holes, child)
		local loX, hiX, loY, hiY = math.huge, -math.huge, math.huge, -math.huge
		for _, p in domain.points do
			loX = math.min(loX, p.X)
			hiX = math.max(hiX, p.X)
			loY = math.min(loY, p.Y)
			hiY = math.max(hiY, p.Y)
		end
		-- Equivalent strict integer bounds avoid losing sub-double-ULP seam crossings in 1-lo.
		local fromX, toX =
			options.closedU and 1 - math.ceil(hiX) or 0, options.closedU and -math.floor(loX) or 0
		local fromY, toY =
			options.closedV and 1 - math.ceil(hiY) or 0, options.closedV and -math.floor(loY) or 0
		copies += (toX - fromX + 1) * (toY - fromY + 1)
		assert(copies <= maxCopies, "Periodic trim copy budget exceeded")
		for x = fromX, toX do
			for y = fromY, toY do
				for _, ring in domain.boundaryLoops do
					local source = {}
					for _, id in ring do
						table.insert(source, domain.points[id])
					end
					local path, rounding = Clip.clip(source, x, y, visit)
					clippingError = math.max(clippingError, rounding)
					assert(
						options.maxClippingError == nil or clippingError <= options.maxClippingError,
						"Native clipping exceeds the requested error"
					)
					if path then
						clippedVertices += #path
						assert(clippedVertices <= maxVertices, "Clipped trim vertex budget exceeded")
						assert(
							P.polygonOrientation(path) == P.polygonOrientation(source),
							"Clipped trim orientation collapses at native precision"
						)
						table.insert(path, path[1])
						table.insert(paths, path)
						loopCount += 1
					end
				end
			end
		end
	end
	if loopCount == 0 then
		checkpoint("finish")
		return {}, {
			complete = true,
			regions = 0,
			copies = copies,
			work = work,
			area = 0,
			constructionError = 0,
			clippingError = clippingError,
		}
	end
	local V = Vector2.new
	table.insert(paths, { V(0, 0), V(1, 0), V(1, 1), V(0, 1), V(0, 0) })
	local arrangement = D.constrain(
		{ V(minX - 1, minY - 1), V(maxX + 1, minY - 1), V(maxX + 1, maxY + 1), V(minX - 1, maxY + 1) },
		{},
		paths,
		{
			maxVertices = maxVertices,
			maxSegments = options.maxSegments or 20000,
			maxTriangles = options.maxTriangles or 40000,
			maxWork = maxWork,
			maxConstructionError = options.maxConstructionError,
			_visit = visit,
		}
	)
	local barriers = {}
	for k = 1, loopCount do
		local path = arrangement.paths[k]
		for i = 1, #path - 1 do
			visit()
			local a, b = path[i], path[i + 1]
			local key = U.edge(a, b)
			barriers[key] = (barriers[key] or 0) + (a < b and 1 or -1)
		end
	end
	local edges, neighbors, labels, queue = {}, {}, {}, {}
	for tid, tri in arrangement.triangles do
		neighbors[tid] = {}
		for i, a in tri do
			visit()
			local b = tri[i % 3 + 1]
			local key = U.edge(a, b)
			edges[key] = edges[key] or {}
			table.insert(edges[key], { face = tid, a = a, b = b, direction = a < b and 1 or -1 })
		end
	end
	local function label(tid, value)
		if labels[tid] == nil then
			labels[tid] = value
			table.insert(queue, tid)
		else
			assert(labels[tid] == value, "Constructed trim winding is inconsistent")
		end
	end
	for key, sides in edges do
		visit()
		local delta = barriers[key] or 0
		if #sides == 1 then
			assert(delta == 0, "Trim reached enclosing construction boundary")
			label(sides[1].face, 0)
		else
			local a, b = sides[1], sides[2]
			assert(#sides == 2 and a.direction == -b.direction)
			table.insert(neighbors[a.face], { face = b.face, delta = -a.direction * delta })
			table.insert(neighbors[b.face], { face = a.face, delta = -b.direction * delta })
		end
	end
	local head = 1
	while head <= #queue do
		visit()
		local tid = queue[head]
		head += 1
		for _, other in neighbors[tid] do
			label(other.face, labels[tid] + other.delta)
		end
	end
	assert(#queue == #arrangement.triangles, "Trim winding left unclassified triangles")
	local selected, area, retained = {}, 0, 0
	for tid, tri in arrangement.triangles do
		visit()
		assert(labels[tid] >= 0, "Constructed trim has negative region winding")
		local inside = labels[tid] > 0
		for _, id in tri do
			local p = arrangement.points[id]
			inside = inside and p.X >= 0 and p.X <= 1 and p.Y >= 0 and p.Y <= 1
		end
		if inside then
			selected[tid] = true
			retained += 1
			local _, det =
				P.orient2D(arrangement.points[tri[1]], arrangement.points[tri[2]], arrangement.points[tri[3]])
			area += det / 2
		end
	end
	local outgoing, incoming = {}, {}
	for _, sides in edges do
		local a, b = sides[1], sides[2]
		local sa, sb = selected[a.face], b and selected[b.face]
		if not not sa ~= not not sb then
			visit()
			local edge = sa and a or b
			assert(
				not outgoing[edge.a] and not incoming[edge.b],
				"Trim union has a pinched or touching boundary"
			)
			outgoing[edge.a] = edge.b
			incoming[edge.b] = edge.a
		end
	end
	local loops, seen = {}, {}
	for _, start in U.keys(outgoing) do
		if seen[start] then
			continue
		end
		local path, current = {}, start
		repeat
			visit()
			assert(
				not seen[current] and outgoing[current] and incoming[current],
				"Trim union boundary does not form a simple loop"
			)
			seen[current] = true
			table.insert(path, arrangement.points[current])
			current = outgoing[current]
		until current == start
		table.insert(loops, path)
	end
	local result, holes = {}, {}
	for _, ring in loops do
		local orientation, det = P.polygonOrientation(ring)
		if orientation > 0 then
			assert(#result < maxRegions, "Decomposed trim region budget exceeded")
			table.insert(result, { outer = ring, holes = {}, _area = det })
		else
			assert(orientation < 0)
			table.insert(holes, ring)
		end
	end
	for _, hole in holes do
		local owner
		for k, r in result do
			visit()
			if
				P.pointInPolygon2D(hole[1], r.outer) == "inside"
				and (not owner or r._area < result[owner]._area)
			then
				owner = k
			end
		end
		assert(owner, "Trim hole has no enclosing region")
		table.insert(result[owner].holes, hole)
	end
	local measured = 0
	for _, r in result do
		local checked =
			D.triangulate(r.outer, r.holes, { maxVertices = maxVertices, maxWork = maxWork, _visit = visit })
		measured += checked.area
		r._area = nil
	end
	assert(math.abs(measured - area) <= math.max(area * 1e-9, 1e-300), "Decomposed trim area mismatch")
	checkpoint("finish")
	return result,
		{
			complete = true,
			regions = #result,
			copies = copies,
			work = work,
			area = area,
			constructionError = arrangement.constructionError,
			clippingError = clippingError,
			triangles = #arrangement.triangles,
			retainedTriangles = retained,
			loops = #loops,
		}
end
