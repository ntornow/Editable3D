-- Whole-domain root coverage with interval exclusion and validated isolated roots.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
local B = require(script.Parent.IntervalSpline)
local K = require(script.Parent.IntervalNewton3)
local function positive(value, default)
	value = value == nil and default or value
	assert(
		type(value) == "number" and U.finite(value) and value > 0,
		"Positive finite intersection tolerance required"
	)
	return value
end
local function subset(a, b)
	for i = 1, 3 do
		if a[i][1] < b[i][1] or a[i][2] > b[i][2] then
			return false
		end
	end
	return true
end
local function size(box)
	local largest = 0
	for i = 1, 3 do
		largest = math.max(largest, I.width(box[i]))
	end
	return largest
end
return function(curve, surface, options)
	if options and options.method == "exactPlane" then
		return require(script.Parent.CurvePlaneIntersections)(curve, surface, options)
	end
	assert(
		not options or options.method == nil or options.method == "interval",
		"Unknown curve/surface intersection method"
	)
	options = U.copy(options or {})
	local tolerance = positive(options.tolerance, 1e-5)
	local parameterTolerance = positive(options.parameterTolerance, 1e-7)
	local maxNodes = U.integer(options.maxNodes or 10000, 1)
	local maxDepth = U.integer(options.maxDepth or 48, 0)
	local maxRoots = U.integer(options.maxRoots or 1024, 1)
	local iterations = U.integer(options.maxIterations or 20, 1)
	assert(maxDepth <= 128 and iterations <= 128, "Intersection refinement limit exceeds 128")
	assert(
		options.requireComplete == nil or type(options.requireComplete) == "boolean",
		"Intersection completion flag must be boolean"
	)
	local initial = U.copy(options.parameterBox or { { 0, 1 }, { 0, 1 }, { 0, 1 } })
	assert(type(initial) == "table" and #initial == 3, "Intersection parameterBox requires t/u/v ranges")
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
				and range[2] > range[1],
			"Nonempty normalized intersection range required"
		)
		assert(
			I.isNormal(range[1]) and I.isNormal(range[2]),
			"Subnormal intersection parameter endpoints are unsupported"
		)
	end
	local report = {
		complete = false,
		roots = {},
		unresolved = {},
		visited = 0,
		excluded = 0,
		covered = 0,
		work = 0,
		method = "Outward-rounded homogeneous spline bounds and interval Krawczyk contraction",
		coverageCertified = true,
		boundaryOwnership = "Closed parameter ranges; unresolved boundary contacts are retained",
	}
	local ctx = {
		maxControls = U.integer(options.maxControls or 10000, 1),
		maxPieces = U.integer(options.maxPieces or 2048, 1),
	}
	local maxCoefficients = U.integer(options.maxCoefficients or 1000000, 1)
	local maxWork = U.integer(options.maxWork or 50000000, 1)
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Spline intersection query cancelled")
		if options.checkpoint then
			options.checkpoint({
				stage = stage,
				work = report.work,
				visited = report.visited,
				roots = #report.roots,
			})
		end
	end
	ctx.visit = function(n)
		local previous = report.work
		report.work += n or 1
		assert(report.work <= maxWork, "Spline intersection work budget exceeded")
		if math.floor(previous / 256) ~= math.floor(report.work / 256) then
			ctx.check("work")
		end
	end
	ctx.allocate = function(n)
		assert(n <= maxCoefficients, "Spline intersection coefficient budget exceeded")
	end
	curve, surface = U.copy(curve), U.copy(surface)
	ctx.check("begin")
	assert(
		type(curve) == "table" and type(curve.points) == "table" and U.vector(curve.points[1]),
		"Intersection curve controls required"
	)
	local origin = curve.points[1]
	local a, b = B.prepare(curve, false, origin, ctx), B.prepare(surface, true, origin, ctx)
	report.curvePieces, report.surfacePieces = #a.pieces, #b.pieces
	local function evaluate(box)
		local x = B.evaluate(a, { box[1] }, ctx)
		local y = B.evaluate(b, { box[2], box[3] }, ctx)
		local f, j = {}, {}
		for axis = 1, 3 do
			f[axis] = I.sub(I.mul(x.value[axis], y.value[4]), I.mul(y.value[axis], x.value[4]))
			j[axis] = {
				I.sub(I.mul(x.derivatives[1][axis], y.value[4]), I.mul(y.value[axis], x.derivatives[1][4])),
			}
			for d = 1, 2 do
				j[axis][d + 1] = I.sub(
					I.mul(x.value[axis], y.derivatives[d][4]),
					I.mul(y.derivatives[d][axis], x.value[4])
				)
			end
		end
		ctx.visit(60)
		return { f = f, j = j, a = x.box, b = y.box }
	end
	local function excluded(data)
		for i = 1, 3 do
			if not I.zero(data.f[i]) or not I.intersect(data.a[i], data.b[i]) then
				return true
			end
		end
		return false
	end
	local function rootData(box, domain, norm)
		local data = evaluate(box)
		local positionBox, coordinates = {}, {}
		for i, axis in { "X", "Y", "Z" } do
			local intersection = I.intersect(data.a[i], data.b[i])
			assert(intersection, "A certified intersection lost its geometric enclosure")
			positionBox[i] = I.add(intersection, { origin[axis], origin[axis] })
			if math.abs(positionBox[i][1]) == math.huge or math.abs(positionBox[i][2]) == math.huge then
				return nil
			end
			coordinates[i] = I.mid(positionBox[i])
		end
		local p = Vector3.new(table.unpack(coordinates))
		assert(U.vector(p), "Intersection position exceeds native range")
		local squared = { 0, 0 }
		for i, axis in { "X", "Y", "Z" } do
			squared = I.add(squared, I.square(I.sub(positionBox[i], { p[axis], p[axis] })))
		end
		local errorBound = I.sqrt({ math.max(0, squared[1]), squared[2] })[2]
		local parameters = { I.mid(box[1]), I.mid(box[2]), I.mid(box[3]) }
		local parameterError = 0
		for i = 1, 3 do
			local delta = I.sub(box[i], { parameters[i], parameters[i] })
			parameterError = math.max(parameterError, math.abs(delta[1]), math.abs(delta[2]))
		end
		return {
			position = p,
			curveParameter = parameters[1],
			u = parameters[2],
			v = parameters[3],
			parameterBox = box,
			positionBox = positionBox,
			errorBound = errorBound,
			parameterErrorBound = parameterError,
			certified = true,
			unique = true,
			accurate = errorBound <= tolerance and size(box) <= parameterTolerance,
			classification = "isolated",
			nonsingularEnclosure = true,
			contractionNorm = norm,
			isolatingBoxes = { domain },
		}
	end
	local function resolve(box, domain, norm)
		local current = box
		for _ = 1, iterations do
			local root = rootData(current, domain, norm)
			if root and root.accurate then
				return root
			end
			local step = K(current, evaluate(current).j, evaluate, ctx)
			assert(not step.excluded, "A certified intersection was excluded during refinement")
			if not step.box or size(step.box) >= size(current) * 0.99 then
				return root
			end
			current = step.box
		end
		return rootData(current, domain, norm)
	end
	local stack = { { box = initial, depth = 0 } }
	local function known(box)
		for _, root in report.roots do
			for _, domain in root.isolatingBoxes do
				ctx.visit(3)
				if subset(box, domain) then
					return true
				end
			end
		end
		return false
	end
	local function unresolved(node, reason)
		table.insert(
			report.unresolved,
			{ parameterBox = node.box, reason = reason, depth = node.depth, certified = false }
		)
	end
	while #stack > 0 do
		ctx.check("search")
		if report.visited >= maxNodes then
			for _, node in stack do
				unresolved(node, "nodes")
			end
			break
		end
		local node = table.remove(stack)
		report.visited += 1
		if known(node.box) then
			report.covered += 1
			continue
		end
		local data = evaluate(node.box)
		if excluded(data) then
			report.excluded += 1
			continue
		end
		local step = K(node.box, data.j, evaluate, ctx)
		if step.excluded then
			report.excluded += 1
			continue
		end
		local isolatingDomain = node.box
		if not step.unique and step.norm and step.norm < 1 then
			-- A contraction can reach the rounding floor before proving inclusion.
			-- Enlarge around its full Newton image and validate a fresh root domain.
			local padded = {}
			for axis = 1, 3 do
				local range = I.hull(node.box[axis], step.image[axis])
				local delta =
					math.max((range[2] - range[1]) * 0.25, (initial[axis][2] - initial[axis][1]) * 1e-10)
				padded[axis] = {
					math.max(initial[axis][1], range[1] - delta),
					math.min(initial[axis][2], range[2] + delta),
				}
			end
			local inflated = K(padded, evaluate(padded).j, evaluate, ctx)
			if inflated.unique then
				step, isolatingDomain = inflated, padded
			end
		end
		if step.unique then
			local root = resolve(step.box, isolatingDomain, step.norm)
			if not root then
				unresolved(node, "precision")
				continue
			end
			local match
			for _, existing in report.roots do
				ctx.visit(3)
				if subset(existing.parameterBox, isolatingDomain) then
					match = existing
					break
				end
				for _, domain in existing.isolatingBoxes do
					ctx.visit(3)
					if subset(root.parameterBox, domain) then
						match = existing
						break
					end
				end
				if match then
					break
				end
			end
			if match then
				table.insert(match.isolatingBoxes, isolatingDomain)
				if
					root.errorBound < match.errorBound
					and root.parameterErrorBound <= match.parameterErrorBound
				then
					local domains = match.isolatingBoxes
					for key, value in root do
						match[key] = value
					end
					match.isolatingBoxes = domains
				end
			elseif #report.roots >= maxRoots then
				unresolved(node, "roots")
			else
				table.insert(report.roots, root)
			end
			continue
		end
		local box = step.box or node.box
		if known(box) then
			report.covered += 1
			continue
		end
		if node.depth >= maxDepth then
			unresolved({ box = box, depth = node.depth }, "depth")
			continue
		end
		-- Re-evaluate a substantially contracted box before applying the precision
		-- stop: its fresh Jacobian can certify a root that the parent could not.
		if size(box) < size(node.box) * 0.65 then
			table.insert(stack, { box = box, depth = node.depth + 1 })
			continue
		end
		if size(box) <= parameterTolerance then
			local boundary = false
			for i = 1, 3 do
				boundary = boundary or box[i][1] == initial[i][1] or box[i][2] == initial[i][2]
			end
			unresolved(
				{ box = box, depth = node.depth },
				boundary and "boundary" or step.singular and "singular" or "precision"
			)
			continue
		end
		local axis = 1
		for i = 2, 3 do
			if
				(box[i][2] - box[i][1]) / (initial[i][2] - initial[i][1])
				> (box[axis][2] - box[axis][1]) / (initial[axis][2] - initial[axis][1])
			then
				axis = i
			end
		end
		local lo, hi = box[axis][1], box[axis][2]
		local first, last = lo + (hi - lo) * 0.375, lo + (hi - lo) * 0.625
		if first <= lo or last >= hi or first >= last then
			unresolved({ box = box, depth = node.depth }, "precision")
			continue
		end
		local left, right = U.copy(box), U.copy(box)
		left[axis][2], right[axis][1] = last, first
		table.insert(stack, { box = right, depth = node.depth + 1 })
		table.insert(stack, { box = left, depth = node.depth + 1 })
	end
	table.sort(report.roots, function(x, y)
		if x.curveParameter ~= y.curveParameter then
			return x.curveParameter < y.curveParameter
		end
		if x.u ~= y.u then
			return x.u < y.u
		end
		return x.v < y.v
	end)
	local retained = {}
	for _, region in report.unresolved do
		if known(region.parameterBox) then
			report.covered += 1
		else
			table.insert(retained, region)
		end
	end
	report.unresolved = retained
	for i, root in report.roots do
		for j = i + 1, #report.roots do
			ctx.visit(3)
			local overlap, region = true, {}
			for axis = 1, 3 do
				local other = report.roots[j].parameterBox[axis]
				overlap = overlap and I.intersect(root.parameterBox[axis], other) ~= nil
				region[axis] = I.hull(root.parameterBox[axis], other)
			end
			if overlap then
				unresolved({ box = region, depth = 0 }, "identity")
			end
		end
	end
	report.complete = #report.unresolved == 0
	for _, root in report.roots do
		report.complete = report.complete and root.accurate
	end
	report.success, report.converged = report.complete, report.complete
	report.reason = report.complete and "complete" or #report.unresolved > 0 and "unresolved" or "precision"
	report.parameterBox = initial
	ctx.check("finish")
	assert(
		report.complete or not options.requireComplete,
		"Spline intersection query has unresolved or inaccurate results"
	)
	return report
end
