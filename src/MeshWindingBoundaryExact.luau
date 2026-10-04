-- Exact source-plane samples; output geometry still requires the native audits.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
local makeR = require(script.Parent.ExactRational)
local prepare = require(script.Parent.RationalWinding)
return function(data, options, regions, maxBits, maxCoefficients)
	assert(
		data.validation.closed or #data.triangles == 0,
		"Winding repair requires closed oriented source sheets"
	)
	local rule = options.windingRule or "nonzero"
	assert(
		rule == "nonzero" or rule == "positive" or rule == "odd",
		"Winding rule must be nonzero, positive or odd"
	)
	local attempts = U.integer(options.maxRayDirections or 12, 2)
	assert(attempts <= 12, "Too many winding ray directions")
	local requestedOffset = options.classificationOffset or data.extent * 1e-4
	assert(
		U.finite(requestedOffset) and (requestedOffset > 0 or #data.triangles == 0),
		"Positive finite classification offset required"
	)
	assert(#data.triangles * 96 + 128 <= maxCoefficients, "Exact winding coefficient budget exceeded")
	local report = {
		windingRule = rule,
		sampleMethod = "exactRational",
		exactSamples = true,
		rayTests = 0,
		ambiguousRays = 0,
		classified = 0,
		discarded = 0,
		duplicateFragments = 0,
		reversed = 0,
		minOffset = math.huge,
		maxOffset = 0,
		exactWork = 0,
		exactFragments = 0,
		exactRays = 0,
	}
	assert(not options.cancelled or not options.cancelled(), "Winding classification cancelled")
	if options.checkpoint then
		options.checkpoint({ stage = "classifyExact", work = data.getWork() })
	end
	local function visit(n)
		n = n or 1
		report.exactWork += n
		data.visit("classifyExact", n)
	end
	local R = makeR(visit, maxBits)
	local enclose = require(script.Parent.ExactRationalBounds)(R, visit)
	local triangles, groups = {}, {}
	for i, context in data.triangles do
		triangles[i], groups[i] = context.points, regions and regions.groups[context.face] or 1
	end
	local C = #triangles > 0
		and prepare(triangles, R, visit, groups, regions and regions.count or 1, attempts)
	local function inside(numbers)
		if regions then
			return regions.contains(numbers)
		end
		if rule == "positive" then
			return numbers[1] > 0
		end
		if rule == "odd" then
			return math.abs(numbers[1]) % 2 == 1
		end
		return numbers[1] ~= 0
	end
	local selection = {}
	for fi, fragment in data.fragments do
		local context = data.triangles[fragment.triangle]
		local weights = { R.number(0), R.number(0), R.number(0) }
		for _, record in fragment.records do
			for j, w in record.weights do
				weights[j] = R.add(weights[j], R.number(w))
			end
		end
		local center = C.center(context.index, weights)
		local owner = true
		for other in context.coplanar do
			visit(1)
			if other < context.index and C.contains(other, center) then
				owner = false
				break
			end
		end
		if not owner then
			report.duplicateFragments += 1
			continue
		end
		local minus, plus, delta = C.samples(context.index, weights, requestedOffset)
		local wm, wp = C.winding(minus), C.winding(plus)
		local normalSquare = R.number(0)
		for _, x in C.contexts[context.index].normal do
			normalSquare = R.add(normalSquare, R.mul(x, x))
		end
		local length = enclose(normalSquare)
		length[1] = math.max(0, length[1])
		local offset = I.mul(enclose(delta), I.sqrt(length))
		report.minOffset, report.maxOffset =
			math.min(report.minOffset, math.max(0, offset[1])), math.max(report.maxOffset, offset[2])
		report.classified += 1
		if inside(wm) == inside(wp) then
			report.discarded += 1
			continue
		end
		selection[fi] = inside(wm) and 1 or -1
		if selection[fi] < 0 then
			report.reversed += 1
		end
	end
	if C then
		report.rayTests, report.ambiguousRays, report.exactRays =
			C.report.triangleTests, C.report.ambiguous, C.report.rays
	end
	if report.minOffset == math.huge then
		report.minOffset = 0
	end
	report.exactFragments = report.classified
	report.offsetRangeCertified = true
	assert(not options.cancelled or not options.cancelled(), "Winding classification cancelled")
	return selection, report
end
