-- Private trim-conforming adaptive rational surface tessellation.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local P = require(script.Parent.Predicates)
local D = require(script.Parent.Planar)
local Mesh = require(script.Parent.Mesh)
local Partition = require(script.Parent.SurfacePartition)
local Domain = require(script.Parent.TrimDomain)

local function derivativeBounds(s)
	local maximum, minimum, radius = 0, math.huge, 0
	local origin = s.control[1][1]
	for _, row in s.weights do
		for _, w in row do
			maximum = math.max(maximum, w)
		end
	end
	local h = {}
	for i, row in s.control do
		h[i] = {}
		for j, p in row do
			local w = s.weights[i][j] / maximum
			minimum = math.min(minimum, w)
			local x, y, z = p.X - origin.X, p.Y - origin.Y, p.Z - origin.Z
			radius = math.max(radius, math.sqrt(x * x + y * y + z * z))
			h[i][j] = { x * w, y * w, z * w, w }
		end
	end
	local result = {}
	for _, axis in { "U", "V" } do
		local degree, knots = axis == "U" and s.degreeU or s.degreeV, axis == "U" and s.knotsU or s.knotsV
		local n = axis == "U" and #h or #h[1]
		local scale = knots[n + 1] - knots[degree + 1]
		local xyz, weight = 0, 0
		for i = 1, #h - (axis == "U" and 1 or 0) do
			for j = 1, #h[1] - (axis == "V" and 1 or 0) do
				local index = axis == "U" and i or j
				local denominator = knots[index + degree + 1] - knots[index + 1]
				if denominator > 0 then
					local a, b = h[i][j], axis == "U" and h[i + 1][j] or h[i][j + 1]
					local factor = degree * scale / denominator
					local x, y, z = b[1] - a[1], b[2] - a[2], b[3] - a[3]
					xyz = math.max(xyz, math.sqrt(x * x + y * y + z * z) * factor)
					weight = math.max(weight, math.abs(b[4] - a[4]) * factor)
				end
			end
		end
		result[axis] = minimum > 0 and (xyz + radius * weight) / minimum or math.huge
	end
	return result
end

return function(trimmed, options)
	trimmed, options = Domain.snapshot(trimmed, options)
	local tolerance = options.tolerance or 0.01
	assert(U.finite(tolerance) and tolerance > 0, "Positive trim tessellation tolerance required")
	local seamTolerance = options.seamTolerance or 1e-6
	assert(U.finite(seamTolerance) and seamTolerance >= 0, "Nonnegative seam tolerance required")
	local maxVertices = U.integer(options.maxVertices or 100000, 3)
	local maxTriangles = U.integer(options.maxTriangles or 200000, 1)
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local work = 0
	local function visit()
		assert(not options.cancelled or not options.cancelled(), "Adaptive trim cancelled")
		work += 1
		assert(work <= maxWork, "Adaptive trim work budget exceeded")
		if options.checkpoint and work % 256 == 0 then
			options.checkpoint({ stage = "trim", work = work, maxWork = maxWork })
		end
	end
	assert(not options.cancelled or not options.cancelled(), "Adaptive trim cancelled")
	if options.checkpoint then
		options.checkpoint({ stage = "begin", work = 0 })
	end
	assert(not options.cancelled or not options.cancelled(), "Adaptive trim cancelled")
	local surface = trimmed.surface
	local prepared = N.compileSurface(surface)
	local data = Domain.prepare(trimmed.regions, options, visit)
	if #data.regions == 0 then
		return Mesh.new(),
			{
				converged = true,
				geometricErrorBound = true,
				errorBound = 0,
				faceErrorBounds = {},
				parameterRoundingBound = 0,
				trimBoundaryErrorBound = 0,
				stitchingError = 0,
				constructionError = 0,
				parameterArea = 0,
				originalParameterArea = 0,
				trimLoops = {},
				poles = {},
				triangles = 0,
				vertices = 0,
				boundaryEdges = 0,
				parameterTriangles = 0,
				retainedParameterTriangles = 0,
				collapsedPoleTriangles = 0,
				leaves = 0,
				partitionLeaves = 0,
				discardedLeaves = 0,
				refinements = 0,
				work = work,
				regions = 0,
				method = "Adaptive Bernstein patches with constrained trim triangulation",
			}
	end
	local paths, boxes, trimCount = {}, {}, #data.boundaryLoops
	for k, loop in data.boundaryLoops do
		paths[k] = {}
		for i, id in loop do
			local a, b = data.points[id], data.points[loop[i % #loop + 1]]
			table.insert(paths[k], a)
			table.insert(
				boxes,
				{ math.min(a.X, b.X), math.max(a.X, b.X), math.min(a.Y, b.Y), math.max(a.Y, b.Y) }
			)
		end
		table.insert(paths[k], paths[k][1])
	end
	local function active(node)
		-- A conservative boundary box overlap keeps doubtful cells for refinement.
		-- Native UV rounding cannot prune a thin region beside a partition boundary.
		local padding = 2 ^ -23
		for _, box in boxes do
			visit()
			if
				box[1] <= node.u1 + padding
				and box[2] >= node.u0 - padding
				and box[3] <= node.v1 + padding
				and box[4] >= node.v0 - padding
			then
				return true
			end
		end
		local center = Vector2.new((node.u0 + node.u1) / 2, (node.v0 + node.v1) / 2)
		for _, loop in data.loops do
			for _ in loop do
				visit()
			end
		end
		return Domain.classify(data.regions, center) ~= "outside"
	end
	local config = table.clone(options)
	config.tolerance = tolerance * 0.9
	config.checkpoint = function(progress)
		visit()
		if options.checkpoint then
			options.checkpoint(progress)
		end
		assert(not options.cancelled or not options.cancelled(), "Adaptive trim cancelled")
	end
	local leaves, refinement = Partition(surface, config, active)
	local lines, seamU, seamV = { U = {}, V = {} }, { [0] = true, [1] = true }, { [0] = true, [1] = true }
	local function line(axis, fixed, lo, hi)
		lines[axis][fixed] = lines[axis][fixed] or {}
		table.insert(lines[axis][fixed], { lo, hi })
	end
	local derivatives = derivativeBounds(surface)
	for _, node in leaves do
		visit()
		local low, high = Vector2.new(node.u0, node.v0), Vector2.new(node.u1, node.v1)
		assert(low.X < high.X and low.Y < high.Y, "Adaptive cell collapses at native UV precision")
		node.low, node.high = low, high
		local du = math.max(math.abs(low.X - node.u0), math.abs(high.X - node.u1))
		local dv = math.max(math.abs(low.Y - node.v0), math.abs(high.Y - node.v1))
		node.parameterError = 2
			* ((du == 0 and 0 or derivatives.U * du) + (dv == 0 and 0 or derivatives.V * dv))
		for _, x in { low.X, high.X } do
			line("U", x, low.Y, high.Y)
			if x == 0 or x == 1 then
				seamU[low.Y], seamU[high.Y] = true, true
			end
		end
		for _, y in { low.Y, high.Y } do
			line("V", y, low.X, high.X)
			if y == 0 or y == 1 then
				seamV[low.X], seamV[high.X] = true, true
			end
		end
	end
	for _, uv in data.points do
		if uv.X == 0 or uv.X == 1 then
			seamU[uv.Y] = true
		end
		if uv.Y == 0 or uv.Y == 1 then
			seamV[uv.X] = true
		end
	end
	for _, axis in { "U", "V" } do
		for _, fixed in U.keys(lines[axis]) do
			local intervals = lines[axis][fixed]
			table.sort(intervals, function(a, b)
				return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
			end)
			local lo, hi
			local function emit()
				if lo then
					table.insert(
						paths,
						axis == "U" and { Vector2.new(fixed, lo), Vector2.new(fixed, hi) }
							or { Vector2.new(lo, fixed), Vector2.new(hi, fixed) }
					)
				end
			end
			for _, interval in intervals do
				visit()
				if lo and interval[1] <= hi then
					hi = math.max(hi, interval[2])
				else
					emit()
					lo, hi = interval[1], interval[2]
				end
			end
			emit()
		end
	end
	for _, entry in { { "U", options.closedU, seamU }, { "V", options.closedV, seamV } } do
		if entry[2] then
			for _, side in { 0, 1 } do
				local path = {}
				for _, value in U.keys(entry[3]) do
					table.insert(
						path,
						entry[1] == "U" and Vector2.new(side, value) or Vector2.new(value, side)
					)
				end
				table.insert(paths, path)
			end
		end
	end
	local arrangement = D.constrain({ Vector2.zero, Vector2.xAxis, Vector2.one, Vector2.yAxis }, {}, paths, {
		maxVertices = options.maxParameterVertices or maxVertices,
		maxSegments = options.maxSegments or 20000,
		maxTriangles = options.maxParameterTriangles or maxTriangles,
		maxWork = maxWork,
		maxConstructionError = options.maxConstructionError,
		_visit = visit,
	})
	local barriers, boundaryVertices, trimLoops = {}, {}, {}
	for k = 1, trimCount do
		local path, polygon = arrangement.paths[k], {}
		for i = 1, #path - 1 do
			local a, b = path[i], path[i + 1]
			assert(
				not boundaryVertices[a],
				"Trim boundary contacts itself after native intersection construction"
			)
			boundaryVertices[a] = true
			table.insert(polygon, arrangement.points[a])
			barriers[U.edge(a, b)] = a < b and 1 or -1
		end
		assert(
			P.polygonOrientation(polygon) == data.orientations[k],
			"Rounded trim boundary changed orientation"
		)
		trimLoops[k] = polygon
	end
	-- Region labels propagate across unconstrained edges. This avoids rounding
	-- triangle centroids onto a boundary when triangles are extremely narrow.
	local edges, neighbors, labels, queue = {}, {}, {}, {}
	for tid, tri in arrangement.triangles do
		neighbors[tid] = {}
		for i, a in tri do
			local b = tri[i % 3 + 1]
			local key = U.edge(a, b)
			edges[key] = edges[key] or {}
			table.insert(edges[key], { face = tid, direction = a < b and 1 or -1 })
		end
	end
	local function label(tid, value)
		if labels[tid] == nil then
			labels[tid] = value
			table.insert(queue, tid)
		else
			assert(labels[tid] == value, "Trim regions have inconsistent winding after construction")
		end
	end
	for key, incident in edges do
		visit()
		if barriers[key] then
			for _, side in incident do
				label(side.face, side.direction == barriers[key])
			end
		elseif #incident == 2 then
			table.insert(neighbors[incident[1].face], incident[2].face)
			table.insert(neighbors[incident[2].face], incident[1].face)
		end
	end
	local head = 1
	while head <= #queue do
		visit()
		local tid = queue[head]
		head += 1
		for _, other in neighbors[tid] do
			label(other, labels[tid])
		end
	end
	assert(#queue == #arrangement.triangles, "Trim region classification left unlabeled triangles")
	local binCount = math.min(64, math.max(1, math.ceil(math.sqrt(#leaves))))
	local bins = {}
	local function bin(value)
		return math.clamp(math.floor(value * binCount), 0, binCount - 1)
	end
	for index, node in leaves do
		for x = bin(node.low.X), bin(node.high.X) do
			for y = bin(node.low.Y), bin(node.high.Y) do
				local key = x * binCount + y
				bins[key] = bins[key] or {}
				table.insert(bins[key], index)
			end
		end
	end
	local poles = {}
	if options.collapsePoles then
		for _, edge in { { "U0", "V", 0 }, { "U1", "V", 1 }, { "V0", "U", 0 }, { "V1", "U", 1 } } do
			local curve = N.isoCurve(surface, edge[2], edge[3])
			local collapse = true
			for _, p in curve.points do
				if (p - curve.points[1]).Magnitude > seamTolerance then
					collapse = false
					break
				end
			end
			poles[edge[1]] = collapse
		end
	end
	local mesh, aliases, corners, map = Mesh.new(), {}, {}, {}
	local stitchError, maximum, parameterError, parameterArea, collapsed = 0, 0, 0, 0, {}
	local retained, faceBounds = 0, {}
	local function corner(index)
		if map[index] then
			return map[index], corners[index]
		end
		local uv = arrangement.points[index]
		local u, v = uv.X, uv.Y
		local d = prepared.derivatives(u, v)
		if options.closedU and (u == 0 or u == 1) then
			assert(
				(d.position - prepared.evaluate(1 - u, v)).Magnitude <= seamTolerance,
				"Closed trim U boundary does not coincide"
			)
		end
		if options.closedV and (v == 0 or v == 1) then
			assert(
				(d.position - prepared.evaluate(u, 1 - v)).Magnitude <= seamTolerance,
				"Closed trim V boundary does not coincide"
			)
		end
		local pole = u == 0 and poles.U0 and "U0"
			or u == 1 and poles.U1 and "U1"
			or v == 0 and poles.V0 and "V0"
			or v == 1 and poles.V1 and "V1"
			or nil
		local normal = d.normal
		if not d.regular then
			assert(pole, "Trim sample is singular without a declared boundary pole")
			local pu, pv = u, v
			if pole == "U0" then
				pu = 1e-5
			elseif pole == "U1" then
				pu = 1 - 1e-5
			elseif pole == "V0" then
				pv = 1e-5
			else
				pv = 1 - 1e-5
			end
			local limit = prepared.derivatives(pu, pv)
			assert(limit.regular, "Trim pole has no regular interior normal limit")
			normal = limit.normal
		end
		local cu, cv = options.closedU and u == 1 and 0 or u, options.closedV and v == 1 and 0 or v
		local key = pole or string.format("%.17g:%.17g", cu, cv)
		local id = aliases[key]
		if id then
			local distance = (mesh.vertices[id] - d.position).Magnitude
			assert(distance <= seamTolerance, "Shared trim samples do not coincide within seam tolerance")
			stitchError = math.max(stitchError, distance)
		else
			assert(mesh.nextVertex <= maxVertices, "Adaptive trim mesh vertex budget exceeded")
			id = mesh:addVertex(d.position)
			aliases[key] = id
		end
		map[index], corners[index] = id, { uv = uv, normal = normal }
		return id, corners[index]
	end
	for tid, tri in arrangement.triangles do
		if not labels[tid] then
			continue
		end
		visit()
		retained += 1
		local a, b, c = arrangement.points[tri[1]], arrangement.points[tri[2]], arrangement.points[tri[3]]
		local lowX, highX = math.min(a.X, b.X, c.X), math.max(a.X, b.X, c.X)
		local lowY, highY = math.min(a.Y, b.Y, c.Y), math.max(a.Y, b.Y, c.Y)
		local candidates = bins[bin((a.X + b.X + c.X) / 3) * binCount + bin((a.Y + b.Y + c.Y) / 3)]
		local containing
		for _, index in candidates or {} do
			visit()
			local node = leaves[index]
			if
				lowX >= node.low.X
				and highX <= node.high.X
				and lowY >= node.low.Y
				and highY <= node.high.Y
			then
				containing = node
				break
			end
		end
		assert(containing and containing.active, "Trim triangle escaped its bounded adaptive patch")
		local bound = containing.errorBound + containing.parameterError
		maximum = math.max(maximum, bound)
		parameterError = math.max(parameterError, containing.parameterError)
		local _, det = P.orient2D(a, b, c)
		parameterArea += det / 2
		local ids, cr = {}, {}
		for i, index in tri do
			ids[i], cr[i] = corner(index)
		end
		if ids[1] == ids[2] or ids[2] == ids[3] or ids[3] == ids[1] then
			table.insert(collapsed, ids)
		else
			assert(mesh.nextFace <= maxTriangles, "Adaptive trim triangle budget exceeded")
			local fid = mesh:addFace(ids, cr, options.material)
			faceBounds[fid] = bound
		end
	end
	assert(retained > 0, "Adaptive trim has no retained parameter triangles")
	local topology = mesh:topology()
	local used = {}
	for _, face in mesh.faces do
		for _, id in face.vertices do
			used[id] = true
		end
	end
	for _, ids in collapsed do
		for i, a in ids do
			assert(used[a], "Collapsed trim triangle has an isolated image point")
			local b = ids[i % 3 + 1]
			assert(
				a == b or topology.edges[U.edge(a, b)],
				"Collapsed trim triangle has an uncovered image edge"
			)
		end
	end
	for _, face in mesh.faces do
		for _ in face.vertices do
			visit()
		end
	end
	local connectivity = require(script.Parent.Connectivity).analyze(mesh)
	assert(connectivity.valid, "Adaptive trim quotient has invalid edge or vertex topology")
	local validation = mesh:validate()
	assert(validation.valid, "Adaptive trim produced degenerate or invalid mesh topology")
	local construction = arrangement.constructionError
	local boundaryError = construction == 0 and 0
		or math.sqrt(derivatives.U * derivatives.U + derivatives.V * derivatives.V) * construction
	local errorBound = maximum + stitchError + boundaryError
	for fid in faceBounds do
		faceBounds[fid] += stitchError + boundaryError
	end
	assert(not options.cancelled or not options.cancelled(), "Adaptive trim cancelled")
	return mesh,
		{
			converged = errorBound <= tolerance,
			geometricErrorBound = true,
			errorBound = errorBound,
			faceErrorBounds = faceBounds,
			parameterRoundingBound = parameterError,
			trimBoundaryErrorBound = boundaryError,
			stitchingError = stitchError,
			constructionError = arrangement.constructionError,
			parameterArea = parameterArea,
			originalParameterArea = data.area,
			trimLoops = trimLoops,
			poles = poles,
			triangles = U.count(mesh.faces),
			vertices = U.count(mesh.vertices),
			boundaryEdges = validation.boundaryEdges,
			parameterTriangles = #arrangement.triangles,
			retainedParameterTriangles = retained,
			collapsedPoleTriangles = #collapsed,
			leaves = refinement.leaves,
			partitionLeaves = refinement.partitionLeaves,
			discardedLeaves = refinement.discardedLeaves,
			refinements = refinement.refinements,
			work = work,
			regions = #data.regions,
			reason = errorBound > tolerance
					and "Subdivision limits or native seam/parameter precision exceeded tolerance"
				or nil,
			method = "Adaptive Bernstein patches with constrained trim triangulation",
		}
end
