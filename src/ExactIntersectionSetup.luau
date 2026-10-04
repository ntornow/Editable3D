-- Bounded snapshots and shared exact-arithmetic resources for surface contacts.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
return function(sources, settings)
	assert(type(settings) == "table", "Exact intersection settings required")
	local entries, active = 0, {}
	local maximum = U.integer(settings.maxSnapshotEntries or 4000000, 1)
	local function copy(value, depth)
		if type(value) ~= "table" then
			return value
		end
		assert(depth <= 64 and not active[value], "Spline snapshot has cyclic or excessively nested data")
		active[value] = true
		local out = {}
		for key, item in value do
			entries += 1
			assert(entries <= maximum, "Spline snapshot entry budget exceeded")
			out[key] = copy(item, depth + 1)
		end
		active[value] = nil
		return out
	end
	local options = copy(settings, 1)
	sources = copy(sources, 1)
	local function positive(value, default)
		value = value == nil and default or value
		assert(
			type(value) == "number" and U.finite(value) and value > 0,
			"Positive finite intersection tolerance required"
		)
		return value
	end
	local limits = {
		tolerance = positive(options.tolerance, 1e-4),
		parameterTolerance = positive(options.parameterTolerance, 1e-7),
		iterations = U.integer(options.maxIterations or 24, 0),
		maxControls = U.integer(options.maxControls or 10000, 1),
		maxCells = U.integer(options.maxCells or 8192, 1),
		maxVertices = U.integer(options.maxVertices or 8192, 1),
	}
	local isolation = {
		maxDepth = U.integer(options.maxDepth or 256, 0),
		maxNodes = U.integer(options.maxNodes or 20000, 1),
		nodes = 0,
	}
	assert(
		isolation.maxDepth <= 512 and limits.iterations <= 128,
		"Exact intersection refinement limit exceeded"
	)
	local maxWork = U.integer(options.maxWork or 100000000, 1)
	local maxCoefficients = U.integer(options.maxCoefficients or 2000000, 1)
	local maxDegree = U.integer(options.maxPolynomialDegree or 96, 1)
	assert(maxDegree <= 256, "Exact polynomial degree limit exceeds 256")
	for _, flag in
		{
			"requireComplete",
			"requireComponents",
			"orderComponents",
			"requireOrdered",
			"identifyPeriodicSeams",
			"requireQuotient",
		}
	do
		assert(options[flag] == nil or type(options[flag]) == "boolean", "Intersection flag must be boolean")
	end
	assert(
		not (options.orderComponents or options.requireOrdered),
		"Exact intersection cells do not provide regular-arc ordering"
	)
	for _, name in { "cancelled", "checkpoint" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Intersection callback must be a function"
		)
	end
	local initial = options.parameterBox or { { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }
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
			"Nonempty normalized intersection range required"
		)
		assert(
			I.isNormal(range[1]) and I.isNormal(range[2]),
			"Subnormal intersection parameter endpoints are unsupported"
		)
	end
	local report = {
		algorithm = "exactRuled",
		method = "Exact cylindrical decomposition of linear-fiber polynomial inequalities",
		cells = {},
		vertices = {},
		components = {},
		connections = {},
		unresolved = {},
		work = 0,
		visited = 0,
		covered = 0,
		excluded = 0,
		coefficientsAllocated = 0,
		parameterBox = initial,
		coverageCertified = true,
		rootCoverageComplete = true,
		cellTopologyCertified = true,
		cellDimensionsCertified = true,
		parameterComponentsCertified = true,
		parameterTopologyCertified = false,
		componentTopologyCertified = false,
		ordering = { requested = false },
		periodicQuotient = { requested = false, nodes = 0, pairs = 0 },
		boundaryOwnership = "Open profile slabs with closed event fibers; shared original knots have one owner",
		componentSpace = "Closed four-dimensional parameter domain; no spatial or periodic identification",
		representation = "Exact algebraic event fibers and rational graph/band cells; native vertices are anchors, not a polygonal approximation",
	}
	local ctx = {
		maxPieces = U.integer(options.maxPieces or 2048, 1),
		maxEvents = U.integer(options.maxEvents or 2048, 1),
	}
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Surface intersection query cancelled")
		if options.checkpoint then
			options.checkpoint({
				stage = stage,
				work = report.work,
				visited = isolation.nodes,
				cells = #report.cells,
				vertices = #report.vertices,
				seamNodes = report.periodicQuotient.nodes,
				seamPairs = report.periodicQuotient.pairs,
			})
		end
	end
	ctx.visit = function(n)
		local before = report.work
		report.work += n or 1
		assert(report.work <= maxWork, "Exact intersection work budget exceeded")
		if math.floor(before / 256) ~= math.floor(report.work / 256) then
			ctx.check("work")
		end
	end
	ctx.allocate = function(n)
		report.coefficientsAllocated += n
		assert(
			report.coefficientsAllocated <= maxCoefficients,
			"Exact intersection cumulative coefficient budget exceeded"
		)
	end
	ctx.check("begin")
	local R = require(script.Parent.ExactRational)(ctx.visit, U.integer(options.maxExactBits or 8192, 1))
	local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, maxDegree, ctx.allocate)
	local B = require(script.Parent.ExactPolynomialBounds)(R, P, ctx.visit)
	isolation.tolerance = R.number(limits.parameterTolerance)
	local bounds = {}
	for i, range in initial do
		bounds[i] = { R.number(range[1]), R.number(range[2]) }
	end
	return {
		sources = sources,
		options = options,
		limits = limits,
		isolation = isolation,
		ctx = ctx,
		R = R,
		P = P,
		B = B,
		report = report,
		bounds = bounds,
	}
end
