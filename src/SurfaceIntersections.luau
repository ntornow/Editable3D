-- Exhaustive interval cover of rational surface intersections by local graphs.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
local B = require(script.Parent.IntervalSpline)
local G = require(script.Parent.SurfaceIntersectionGraph)
local function subset(a, b)
	for axis = 1, 4 do
		if a[axis][1] < b[axis][1] or a[axis][2] > b[axis][2] then
			return false
		end
	end
	return true
end
local function size(box)
	local n = 0
	for _, range in box do
		n = math.max(n, I.width(range))
	end
	return n
end
local function positive(x, default)
	x = x == nil and default or x
	assert(
		type(x) == "number" and U.finite(x) and x > 0,
		"Positive finite surface intersection tolerance required"
	)
	return x
end
return function(surfaceA, surfaceB, options)
	if options and options.method == "exactTensorPair" then
		return require(script.Parent.GeneralTensorIntersections)(surfaceA, surfaceB, options)
	end
	if options and options.method == "exactGraphPair" then
		return require(script.Parent.GraphPairIntersections)(surfaceA, surfaceB, options)
	end
	if options and options.method == "exactRuledPair" then
		return require(script.Parent.RuledPairIntersections)(surfaceA, surfaceB, options)
	end
	if options and options.method == "exactTensorPlane" then
		return require(script.Parent.TensorPlaneIntersections)(surfaceA, surfaceB, options)
	end
	if options and options.method == "exactRuled" then
		return require(script.Parent.RuledPlaneIntersections)(surfaceA, surfaceB, options)
	end
	options = U.copy(options or {})
	assert(
		options.method == nil or options.method == "interval" or options.method == "exactAffine",
		"Surface intersection method must be interval or exactAffine"
	)
	if options.method == "exactAffine" then
		assert(
			not (
					options.orderComponents
					or options.requireOrdered
					or options.identifyPeriodicSeams
					or options.requireQuotient
				),
			"Exact affine cells provide convex boundaries, not interval arc ordering or periodic quotients"
		)
	end
	local limits = {
		tolerance = positive(options.tolerance, 1e-4),
		parameterTolerance = positive(options.parameterTolerance, 1e-7),
		maxNodes = U.integer(options.maxNodes or 20000, 1),
		maxDepth = U.integer(options.maxDepth or 48, 0),
		maxCurves = U.integer(options.maxCurves or 1024, 1),
		maxSegments = U.integer(options.maxSegments or 8192, 1),
		maxIterations = U.integer(options.maxIterations or 20, 1),
		maxOrderNodes = U.integer(options.maxOrderNodes == nil and 10000 or options.maxOrderNodes, 0),
		maxOrderSteps = U.integer(options.maxOrderSteps == nil and 1024 or options.maxOrderSteps, 0),
		maxOrderDepth = U.integer(options.maxOrderDepth == nil and 24 or options.maxOrderDepth, 0),
		maxSeamNodes = U.integer(options.maxSeamNodes == nil and 10000 or options.maxSeamNodes, 0),
		maxSeamPairs = U.integer(options.maxSeamPairs == nil and 100000 or options.maxSeamPairs, 0),
		maxSeamDepth = U.integer(options.maxSeamDepth == nil and 24 or options.maxSeamDepth, 0),
		maxOrderedSegments = U.integer(
			options.maxOrderedSegments == nil and 8192 or options.maxOrderedSegments,
			0
		),
		maxConnectionPairs = U.integer(
			options.maxConnectionPairs == nil and 100000 or options.maxConnectionPairs,
			0
		),
		maxConnectionNodes = U.integer(
			options.maxConnectionNodes == nil and 10000 or options.maxConnectionNodes,
			0
		),
		maxConnectionDepth = U.integer(
			options.maxConnectionDepth == nil and 24 or options.maxConnectionDepth,
			0
		),
	}
	assert(
		limits.maxDepth <= 128
			and limits.maxIterations <= 128
			and limits.maxConnectionDepth <= 128
			and limits.maxOrderDepth <= 128
			and limits.maxSeamDepth <= 128,
		"Surface intersection refinement limit exceeds 128"
	)
	assert(
		options.requireComplete == nil or type(options.requireComplete) == "boolean",
		"Surface intersection completion flag must be boolean"
	)
	assert(
		options.requireComponents == nil or type(options.requireComponents) == "boolean",
		"Surface intersection component flag must be boolean"
	)
	for _, flag in { "orderComponents", "requireOrdered", "identifyPeriodicSeams", "requireQuotient" } do
		assert(
			options[flag] == nil or type(options[flag]) == "boolean",
			"Surface intersection ordering flag must be boolean"
		)
	end
	local initial = U.copy(options.parameterBox or { { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 } })
	assert(
		type(initial) == "table" and #initial == 4,
		"Surface intersection parameterBox requires uA/vA/uB/vB ranges"
	)
	for _, range in initial do
		assert(
			type(range) == "table"
				and #range == 2
				and type(range[1]) == "number"
				and type(range[2]) == "number"
				and U.finite(range[1])
				and U.finite(range[2])
				and range[1] >= 0
				and range[2] <= 1
				and range[1] < range[2],
			"Nonempty normalized surface intersection range required"
		)
		assert(
			I.isNormal(range[1]) and I.isNormal(range[2]),
			"Subnormal surface intersection parameter endpoints are unsupported"
		)
	end
	local report: { [string]: any } = {
		curves = {},
		unresolved = {},
		visited = 0,
		excluded = 0,
		covered = 0,
		nonlinearSplits = 0,
		coveredCuts = 0,
		work = 0,
		complete = false,
		coverageCertified = true,
		componentTopologyCertified = false,
		method = "Outward-rounded homogeneous bounds and parametric Krawczyk graphs",
		boundaryOwnership = "Closed parameter ranges; chart overlap and periodic seam duplication are retained",
	}
	local ctx = {
		maxControls = U.integer(options.maxControls or 10000, 1),
		maxPieces = U.integer(options.maxPieces or 2048, 1),
		maxExactBits = U.integer(options.maxExactBits == nil and 8192 or options.maxExactBits, 1),
		segments = 0,
	}
	local maxWork, maxCoefficients =
		U.integer(options.maxWork or 100000000, 1), U.integer(options.maxCoefficients or 1000000, 1)
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Surface intersection query cancelled")
		if options.checkpoint then
			options.checkpoint({
				stage = stage,
				work = report.work,
				visited = report.visited,
				curves = #report.curves,
				orderNodes = report.ordering and report.ordering.visited,
				orderSteps = report.ordering and report.ordering.steps,
				orderedSegments = report.ordering and report.ordering.segments,
				seamNodes = report.periodicQuotient and report.periodicQuotient.nodes,
				seamPairs = report.periodicQuotient and report.periodicQuotient.pairs,
			})
		end
	end
	ctx.visit = function(n)
		local before = report.work
		report.work += n or 1
		assert(report.work <= maxWork, "Surface intersection work budget exceeded")
		if math.floor(before / 256) ~= math.floor(report.work / 256) then
			ctx.check("work")
		end
	end
	ctx.allocate = function(n)
		assert(n <= maxCoefficients, "Surface intersection coefficient budget exceeded")
	end
	surfaceA, surfaceB = U.copy(surfaceA), U.copy(surfaceB)
	ctx.check("begin")
	assert(
		type(surfaceA) == "table"
			and type(surfaceA.control) == "table"
			and type(surfaceA.control[1]) == "table"
			and U.vector(surfaceA.control[1][1]),
		"Surface intersection control grid required"
	)
	local origin = surfaceA.control[1][1]
	local a, b = B.prepare(surfaceA, true, origin, ctx), B.prepare(surfaceB, true, origin, ctx)
	report.piecesA, report.piecesB = #a.pieces, #b.pieces
	if options.method == "exactAffine" then
		return require(script.Parent.AffineSurfaceCells)(
			a.source,
			b.source,
			initial,
			options,
			limits,
			ctx,
			report
		)
	end
	local affine = require(script.Parent.AffineSurfaceProjection)(a, b, initial, ctx)
	report.affinePartner = affine
	local fixed = {}
	if affine then
		for _, axis in affine.fixedAxes do
			fixed[axis] = true
		end
	end
	local function searchSize(box)
		if not affine then
			return size(box)
		end
		return math.max(I.width(box[affine.searchAxes[1]]), I.width(box[affine.searchAxes[2]]))
	end
	local function evaluate(box)
		local x, y = B.evaluate(a, { box[1], box[2] }, ctx), B.evaluate(b, { box[3], box[4] }, ctx)
		local f, j = {}, {}
		for k = 1, 3 do
			f[k] = I.sub(I.mul(x.value[k], y.value[4]), I.mul(y.value[k], x.value[4]))
			j[k] = {}
			for d = 1, 2 do
				j[k][d] =
					I.sub(I.mul(x.derivatives[d][k], y.value[4]), I.mul(y.value[k], x.derivatives[d][4]))
				j[k][d + 2] =
					I.sub(I.mul(x.value[k], y.derivatives[d][4]), I.mul(y.derivatives[d][k], x.value[4]))
			end
		end
		ctx.visit(90)
		return { f = f, j = j, a = x, b = y }
	end
	local graphs = {}
	local function expand(graph, domain)
		-- Enlarge an already proved graph before covering neighboring search boxes.
		-- Every accepted enlargement gets a fresh existence/uniqueness proof.
		for _ = 1, 4 do
			local changed = false
			for axis = 1, 4 do
				local r = domain[axis]
				local amount = math.max((r[2] - r[1]) * 0.5, (initial[axis][2] - initial[axis][1]) / 64)
				local candidate = table.clone(domain)
				candidate[axis] =
					{ math.max(initial[axis][1], r[1] - amount), math.min(initial[axis][2], r[2] + amount) }
				if candidate[axis][1] == r[1] and candidate[axis][2] == r[2] then
					continue
				end
				local step = G.step(candidate, graph.free, evaluate(candidate), evaluate, ctx)
				if step.unique then
					graph, domain, changed = step, candidate, true
				end
			end
			if not changed then
				break
			end
		end
		graph.domain = domain
		return graph
	end
	local function known(box)
		for _, graph in graphs do
			ctx.visit(4)
			if subset(box, graph.domain) then
				return true
			end
		end
		return false
	end
	local function unresolved(box, depth, reason)
		table.insert(
			report.unresolved,
			{ parameterBox = box, depth = depth, reason = reason, certified = false }
		)
	end
	local function uncoveredParts(box)
		-- A certified graph owns every root in its isolating domain. Remove a
		-- substantial covered rectangle and retain closed slabs around it.
		-- Shared slab boundaries may duplicate work, but cannot lose roots.
		local best, bestFraction
		for _, graph in graphs do
			ctx.visit(4)
			local overlap, fraction = {}, 1
			for axis = 1, 4 do
				local domain = graph.domain[axis]
				local margin = (domain[2] - domain[1]) / 16
				local interior = {
					domain[1] == initial[axis][1] and domain[1] or domain[1] + margin,
					domain[2] == initial[axis][2] and domain[2] or domain[2] - margin,
				}
				-- Keep cut boundaries inside the proved domain, so roundoff around
				-- an already covered root cannot generate endless exterior slivers.
				if
					(domain[1] > initial[axis][1] and interior[1] <= domain[1])
					or (domain[2] < initial[axis][2] and interior[2] >= domain[2])
				then
					fraction = 0
					break
				end
				local range = I.intersect(box[axis], interior)
				if not range then
					fraction = 0
					break
				end
				overlap[axis] = range
				local width = box[axis][2] - box[axis][1]
				if width > 0 then
					fraction *= (range[2] - range[1]) / width
				end
			end
			if fraction >= 0.25 and (not bestFraction or fraction > bestFraction) then
				best, bestFraction = overlap, fraction
			end
		end
		if not best then
			return nil
		end
		local core, parts = U.copy(box), {}
		for axis = 1, 4 do
			if core[axis][1] < best[axis][1] then
				local part = U.copy(core)
				part[axis][2] = best[axis][1]
				table.insert(parts, part)
				core[axis][1] = best[axis][1]
			end
			if core[axis][2] > best[axis][2] then
				local part = U.copy(core)
				part[axis][1] = best[axis][2]
				table.insert(parts, part)
				core[axis][2] = best[axis][2]
			end
		end
		return parts
	end
	-- Discover broad arcs before spending the budget on thin uncovered slivers.
	-- Priority changes only visit order; every queued box keeps its full cover.
	local stack, serial = {}, 0
	local function before(a, b)
		return a.priority > b.priority or (a.priority == b.priority and a.serial < b.serial)
	end
	local function push(node)
		if not affine then
			table.insert(stack, node)
			return
		end
		-- Affine injectivity plus the strict whole-hull projection certificate
		-- permits keeping partner parameters at their full requested ranges.
		for _, axis in affine.fixedAxes do
			node.box[axis] = initial[axis]
		end
		serial += 1
		local priority = 1
		for axis = 1, 4 do
			local span = initial[axis][2] - initial[axis][1]
			priority *= span > 0 and (node.box[axis][2] - node.box[axis][1]) / span or 0
		end
		node.priority, node.serial = priority, serial
		local index = #stack + 1
		while index > 1 do
			local parent = math.floor(index / 2)
			if before(stack[parent], node) then
				break
			end
			stack[index], index = stack[parent], parent
		end
		stack[index] = node
	end
	local function pop()
		if not affine then
			return table.remove(stack)
		end
		local result = stack[1]
		local tail = table.remove(stack)
		if #stack > 0 then
			local index = 1
			while index * 2 <= #stack do
				local child = index * 2
				if child < #stack and before(stack[child + 1], stack[child]) then
					child += 1
				end
				if before(tail, stack[child]) then
					break
				end
				stack[index], index = stack[child], child
			end
			stack[index] = tail
		end
		return result
	end
	push({ box = initial, depth = 0 })
	while #stack > 0 do
		ctx.check("search")
		if report.visited >= limits.maxNodes then
			for _, node in stack do
				unresolved(node.box, node.depth, "nodes")
			end
			break
		end
		local node = pop()
		report.visited += 1
		if known(node.box) then
			report.covered += 1
			continue
		end
		if node.depth < limits.maxDepth then
			local parts = uncoveredParts(node.box)
			if parts and #stack + #parts <= limits.maxNodes then
				report.coveredCuts += 1
				for _, part in parts do
					push({ box = part, depth = node.depth + 1 })
				end
				continue
			end
		end
		local data, empty = evaluate(node.box), false
		for k = 1, 3 do
			if not I.zero(data.f[k]) or not I.intersect(data.a.box[k], data.b.box[k]) then
				empty = true
				break
			end
		end
		if empty then
			report.excluded += 1
			continue
		end
		local chosen, box = nil, table.clone(node.box)
		for free = 1, 4 do
			if fixed[free] then
				continue
			end
			local step = G.step(node.box, free, data, evaluate, ctx)
			if step.excluded then
				empty = true
				break
			end
			if step.unique then
				step.domain = node.box
				chosen = step
				break
			end
			if step.norm and step.norm < 1 then
				-- Contraction can leave root coordinates on numerical box edges.
				-- Validate existence again in a padded dependent domain, contained
				-- in the requested parameter ranges. No unproved padding is returned.
				local padded = table.clone(node.box)
				for axis = 1, 4 do
					if axis ~= free then
						local r = I.hull(node.box[axis], step.image[axis])
						local delta =
							math.max((r[2] - r[1]) * 0.25, (initial[axis][2] - initial[axis][1]) * 1e-10)
						padded[axis] = {
							math.max(initial[axis][1], r[1] - delta),
							math.min(initial[axis][2], r[2] + delta),
						}
					end
				end
				local inflated = G.step(padded, free, evaluate(padded), evaluate, ctx)
				if inflated.unique then
					inflated.domain = padded
					chosen = inflated
					break
				end
			end
			if step.box then
				for axis = 1, 4 do
					box[axis] = I.intersect(box[axis], step.box[axis])
					if not box[axis] then
						empty = true
						break
					end
				end
			end
			if empty then
				break
			end
		end
		if empty then
			report.excluded += 1
			continue
		end
		if chosen then
			if #graphs >= limits.maxCurves then
				unresolved(node.box, node.depth, "curves")
			else
				table.insert(graphs, expand(chosen, chosen.domain))
			end
			continue
		end
		if known(box) then
			report.covered += 1
			continue
		end
		if node.depth >= limits.maxDepth then
			unresolved(box, node.depth, "depth")
			continue
		end
		if searchSize(box) < searchSize(node.box) * 0.65 then
			push({ box = box, depth = node.depth + 1 })
			continue
		end
		if searchSize(box) <= limits.parameterTolerance then
			unresolved(box, node.depth, "singular-boundary-or-precision")
			continue
		end
		local axis = affine and affine.searchAxes[1] or 1
		for i = 1, 4 do
			if
				not fixed[i]
				and (box[i][2] - box[i][1]) / (initial[i][2] - initial[i][1])
					> (box[axis][2] - box[axis][1]) / (initial[axis][2] - initial[axis][1])
			then
				axis = i
			end
		end
		-- Prefer nonlinear parameter directions. Splitting an affine partner's
		-- coordinates can duplicate the same difficult curve many times in 4D.
		-- This is only a search ordering heuristic; all proofs use interval bounds.
		local rowScales = {}
		for row = 1, 3 do
			local scale = 0
			for column = 1, 4 do
				scale = math.max(scale, math.abs(data.j[row][column][1]), math.abs(data.j[row][column][2]))
			end
			rowScales[row] = scale
		end
		local best = 1e-8
		local nonlinearAxis
		for candidate = 1, 4 do
			if fixed[candidate] then
				continue
			end
			local score = 0
			for row = 1, 3 do
				if rowScales[row] > 0 and rowScales[row] < math.huge then
					score += I.width(data.j[row][candidate]) / rowScales[row]
				end
			end
			score *= (box[candidate][2] - box[candidate][1]) / (initial[candidate][2] - initial[candidate][1])
			if score > best and score < math.huge then
				nonlinearAxis, best = candidate, score
			end
		end
		if nonlinearAxis then
			axis = nonlinearAxis
			report.nonlinearSplits += 1
		end
		local lo, hi = box[axis][1], box[axis][2]
		local middle = I.mid(box[axis])
		if middle <= lo or middle >= hi then
			unresolved(box, node.depth, "precision")
			continue
		end
		local left, right = U.copy(box), U.copy(box)
		-- Closed midpoint children cover the parent exactly. Validated domain
		-- padding handles shared boundaries without exponentially duplicated boxes.
		left[axis][2], right[axis][1] = middle, middle
		if #stack + 2 > limits.maxNodes then
			unresolved(box, node.depth, "nodes")
			continue
		end
		push({ box = right, depth = node.depth + 1 })
		push({ box = left, depth = node.depth + 1 })
	end
	local retained = {}
	for _, region in report.unresolved do
		if known(region.parameterBox) then
			report.covered += 1
		else
			table.insert(retained, region)
		end
	end
	report.unresolved = retained
	report.rootCoverageComplete = #retained == 0
	report.complete = #retained == 0
	for _, graph in graphs do
		local curve
		if ctx.segments >= limits.maxSegments then
			curve = { certified = true, accurate = false, reason = "segments", samples = {}, segments = {} }
		else
			curve = G.sample(graph, evaluate, origin, ctx, limits)
		end
		curve.parameterAxis, curve.parameterRange = graph.free, graph.box[graph.free]
		curve.parameterBox, curve.isolatingBox = graph.box, graph.domain
		curve.contractionNorm, curve.uniqueGraph = graph.norm, true
		table.insert(report.curves, curve)
		report.complete = report.complete and curve.accurate
	end
	local components = require(script.Parent.SurfaceIntersectionComponents)(
		graphs,
		report.curves,
		evaluate,
		ctx,
		limits,
		report.rootCoverageComplete
	)
	for name, value in components do
		report[name] = value
	end
	if
		options.orderComponents
		or options.requireOrdered
		or options.identifyPeriodicSeams
		or options.requireQuotient
	then
		require(script.Parent.SurfaceIntersectionOrdering)(
			graphs,
			report,
			evaluate,
			origin,
			initial,
			ctx,
			limits
		)
	else
		report.ordering = { requested = false }
		report.parameterTopologyCertified = false
		report.orderedComplete = false
	end
	if options.identifyPeriodicSeams or options.requireQuotient then
		require(script.Parent.SurfacePeriodicQuotient)(
			report,
			{ surfaceA, surfaceB },
			{ a, b },
			evaluate,
			initial,
			ctx,
			limits
		)
	else
		report.periodicQuotient = { requested = false }
		report.quotientTopologyCertified, report.quotientComplete = false, false
	end
	report.segmentCount, report.parameterBox = ctx.segments, initial
	report.success, report.converged = report.complete, report.complete
	report.reason = report.complete and "complete" or #retained > 0 and "unresolved" or "approximation"
	ctx.check("finish")
	assert(
		report.complete or not options.requireComplete,
		"Surface intersection query has unresolved or inaccurate results"
	)
	assert(
		report.parameterComponentsCertified or not options.requireComponents,
		"Surface intersection parameter components remain unresolved"
	)
	assert(
		report.orderedComplete or not options.requireOrdered,
		"Surface intersection ordering remains unresolved or inaccurate"
	)
	assert(
		report.quotientComplete or not options.requireQuotient,
		"Surface intersection periodic quotient remains unresolved or inaccurate"
	)
	return report
end
