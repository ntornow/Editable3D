-- Classical rational Coons blending in a positive common Bernstein denominator.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local Boundary = require(script.Parent.CoonsBoundary)
local Arithmetic = require(script.Parent.CoonsArithmetic)
local EPS = 2.220446049250313e-16
local function choose(n, k)
	local value = 1
	for i = 1, math.min(k, n - k) do
		value = value * (n - i + 1) / i
	end
	return value
end
return function(bottom, top, left, right, options)
	options = table.clone(options or {})
	local tolerance = options.tolerance == nil and 1e-5 or options.tolerance
	local maxError = options.maxError == nil and 1e-5 or options.maxError
	assert(
		type(tolerance) == "number" and U.finite(tolerance) and tolerance >= 0,
		"Nonnegative finite Coons corner tolerance required"
	)
	assert(
		type(maxError) == "number" and U.finite(maxError) and maxError >= 0,
		"Nonnegative finite Coons construction error required"
	)
	assert(
		options.requireComplete ~= false or options.returnReport == true,
		"Incomplete Coons output requires returnReport=true"
	)
	local ctx = {
		maxControls = U.integer(options.maxControls or 10000, 1),
		maxIntermediateControls = U.integer(options.maxIntermediateControls or 20000, 1),
	}
	local maxWork = U.integer(options.maxWork or 20000000, 1)
	local maxPatches = U.integer(options.maxPatches or 4096, 1)
	local maxDegree = U.integer(options.maxDegree or 17, 1)
	assert(maxDegree <= 17, "Coons output degree budget exceeds supported degree 17")
	local report = {
		complete = false,
		success = false,
		work = 0,
		patches = 0,
		constructionErrorBound = 0,
		nativeRoundingBound = 0,
		arithmeticErrorBound = 0,
		stitchAdjustments = 0,
		regularityChecked = false,
		intersectionsChecked = false,
	}
	local function pulse(stage)
		assert(not options.cancelled or not options.cancelled(), "Coons construction cancelled")
		if options.constructionCheckpoint then
			options.constructionCheckpoint({ stage = stage, work = report.work, patches = report.patches })
		end
	end
	ctx.visit = function()
		report.work += 1
		assert(report.work <= maxWork, "Coons construction work budget exceeded")
		if report.work % 256 == 0 then
			pulse("construct")
		end
	end
	local O = Arithmetic(ctx.visit)
	pulse("begin")
	if options.checkpoint then
		options.checkpoint(0)
	end
	assert(
		type(bottom) == "table" and type(bottom.points) == "table" and U.vector(bottom.points[1]),
		"Coons bottom boundary required"
	)
	local origin = bottom.points[1]
	local curves = {}
	for i, c in { bottom, top, left, right } do
		curves[i] = Boundary.new(c, origin, ctx, O)
		Boundary.clamp(curves[i], ctx, O)
	end
	local function degree(a, b)
		local p, q = a.constant and 0 or a.degree, b.constant and 0 or b.degree
		return math.max(a.degree + q, b.degree + p, p + q + 1)
	end
	local du, dv = degree(curves[1], curves[2]), degree(curves[3], curves[4])
	assert(du <= maxDegree and dv <= maxDegree, "Coons output degree budget exceeded")
	local breaksU, breaksV = Boundary.breaks(curves[1], curves[2]), Boundary.breaks(curves[3], curves[4])
	local nu, nv = (#breaksU - 1) * du + 1, (#breaksV - 1) * dv + 1
	assert(nu * nv <= ctx.maxControls, "Coons output control budget exceeded")
	assert((#breaksU - 1) * (#breaksV - 1) <= maxPatches, "Coons patch budget exceeded")
	report.degreeU, report.degreeV, report.controlsU, report.controlsV = du, dv, nu, nv
	local function endpoint(c, last)
		local exact = last and c.endPoint or c.startPoint
		if exact then
			return exact
		end
		local h = c.points[last and #c.points or 1]
		local p = {}
		for k = 1, 3 do
			p[k] = O.div(h[k], h[4])
		end
		return p
	end
	local corners = {
		endpoint(curves[1], false),
		endpoint(curves[1], true),
		endpoint(curves[2], false),
		endpoint(curves[2], true),
	}
	local other = {
		endpoint(curves[3], false),
		endpoint(curves[4], false),
		endpoint(curves[3], true),
		endpoint(curves[4], true),
	}
	local mismatch = 0
	local nativeCorners =
		{ curves[1].startNative, curves[1].endNative, curves[2].startNative, curves[2].endNative }
	local nativeOther =
		{ curves[3].startNative, curves[4].startNative, curves[3].endNative, curves[4].endNative }
	for i, p in corners do
		local sum = 0
		for k = 1, 3 do
			if nativeCorners[i] and nativeOther[i] then
				local axis = ({ "X", "Y", "Z" })[k]
				sum += (nativeCorners[i][axis] - nativeOther[i][axis]) ^ 2
			else
				sum += (p[k][1] - other[i][k][1]) ^ 2
			end
		end
		mismatch = math.max(mismatch, math.sqrt(sum))
	end
	assert(mismatch <= tolerance, "Coons boundary corners do not meet")
	report.cornerMismatch = mismatch
	local function multiply(a, b)
		local p, q = #a - 1, #b - 1
		local out = {}
		for k = 0, p + q do
			local sum = O.value(0)
			for i = math.max(0, k - q), math.min(p, k) do
				local j = k - i
				local factor = choose(p, i) * choose(q, j) / choose(p + q, k)
				local f = O.value(factor, math.abs(factor) * 16 * (p + q + 1) * EPS)
				sum = O.add(sum, O.mul(O.mul(a[i + 1], b[j + 1]), f))
			end
			out[k + 1] = sum
		end
		return out
	end
	local function elevate(a, d)
		for p = #a - 1, d - 1 do
			local out = { a[1] }
			for i = 1, p do
				local t = O.div(O.value(i), O.value(p + 1))
				out[i + 1] = O.mix(a[i + 1], a[i], t)
			end
			out[p + 2] = a[p + 1]
			a = out
		end
		return a
	end
	local function field(segment, k)
		local out = {}
		for i, h in segment do
			out[i] = h[k]
		end
		return out
	end
	local function axis(a, b, breaks, d)
		local sa, sb = Boundary.extract(a, breaks, ctx, O), Boundary.extract(b, breaks, ctx, O)
		local out, maximum = {}, 0
		for i, part in sa do
			local wa = a.constant and { O.value(1) } or field(part, 4)
			local wb = b.constant and { O.value(1) } or field(sb[i], 4)
			local w = multiply(wa, wb)
			local record = { first = {}, last = {}, weight = elevate(w, d) }
			record.zero = elevate(
				multiply(
					w,
					{ O.sub(O.value(1), O.value(breaks[i])), O.sub(O.value(1), O.value(breaks[i + 1])) }
				),
				d
			)
			record.one = elevate(multiply(w, { O.value(breaks[i]), O.value(breaks[i + 1]) }), d)
			for k = 1, 3 do
				record.first[k] = elevate(multiply(field(part, k), wb), d)
				record.last[k] = elevate(multiply(field(sb[i], k), wa), d)
			end
			for _, v in record.weight do
				maximum = math.max(maximum, v[1])
			end
			out[i] = record
		end
		assert(maximum > 0 and U.finite(maximum), "Coons product weights underflowed")
		for _, r in out do
			local lists = { r.weight, r.zero, r.one }
			for k = 1, 3 do
				table.insert(lists, r.first[k])
				table.insert(lists, r.last[k])
			end
			for _, list in lists do
				for i, v in list do
					list[i] = O.div(v, O.value(maximum))
				end
			end
		end
		return out
	end
	local uAxis = axis(curves[1], curves[2], breaksU, du)
	if options.checkpoint then
		options.checkpoint(0.25)
	end
	local vAxis = axis(curves[3], curves[4], breaksV, dv)
	if options.checkpoint then
		options.checkpoint(0.5)
	end
	local control, weights = {}, {}
	for i = 1, nu do
		control[i], weights[i] = {}, {}
	end
	for iu, u in uAxis do
		for iv, v in vAxis do
			local minimum, maxNumeratorError, maxWeightError, radius, arithmetic = math.huge, 0, 0, 0, 0
			for i = 1, du + 1 do
				for j = 1, dv + 1 do
					local x, y = (iu - 1) * du + i, (iv - 1) * dv + j
					local w = O.mul(u.weight[i], v.weight[j])
					assert(
						w[1] > 0 and U.finite(w[1]),
						"Coons tensor weight is outside positive numeric range"
					)
					local q, position = {}, {}
					local cornerFactors = {
						O.mul(u.zero[i], v.zero[j]),
						O.mul(u.one[i], v.zero[j]),
						O.mul(u.zero[i], v.one[j]),
						O.mul(u.one[i], v.one[j]),
					}
					for k = 1, 3 do
						local a = O.add(O.mul(u.first[k][i], v.zero[j]), O.mul(u.last[k][i], v.one[j]))
						local b = O.add(O.mul(u.zero[i], v.first[k][j]), O.mul(u.one[i], v.last[k][j]))
						q[k] = O.add(a, b)
						for c = 1, 4 do
							q[k] = O.sub(q[k], O.mul(corners[c][k], cornerFactors[c]))
						end
						position[k] = q[k][1] / w[1]
					end
					local p =
						Vector3.new(origin.X + position[1], origin.Y + position[2], origin.Z + position[3])
					assert(U.vector(p), "Coons native control overflow")
					if control[x][y] then
						if control[x][y] ~= p or weights[x][y] ~= w[1] then
							report.stitchAdjustments += 1
						end
					else
						control[x][y], weights[x][y] = p, w[1]
					end
					p = control[x][y]
					local numeratorError, roundingError, radial, arithmeticError = 0, 0, 0, 0
					for k, name in { "X", "Y", "Z" } do
						local relative = O.sub(O.value(p[name]), O.value(origin[name]))
						local stored = O.mul(relative, O.value(weights[x][y]))
						local residual = O.sub(q[k], stored)
						numeratorError += (math.abs(residual[1]) + residual[2]) ^ 2
						arithmeticError += residual[2] ^ 2
						roundingError += (p[name] - (origin[name] + position[k])) ^ 2
						radial += (math.abs(relative[1]) + relative[2]) ^ 2
					end
					minimum = math.min(minimum, w[1] - w[2])
					maxNumeratorError = math.max(maxNumeratorError, math.sqrt(numeratorError))
					maxWeightError = math.max(maxWeightError, math.abs(w[1] - weights[x][y]) + w[2])
					radius = math.max(radius, math.sqrt(radial))
					arithmetic = math.max(arithmetic, math.sqrt(arithmeticError))
					report.nativeRoundingBound =
						math.max(report.nativeRoundingBound, math.sqrt(roundingError))
				end
			end
			local bound = minimum > 0 and (maxNumeratorError + radius * maxWeightError) / minimum or math.huge
			report.constructionErrorBound = math.max(report.constructionErrorBound, bound)
			report.arithmeticErrorBound = math.max(
				report.arithmeticErrorBound,
				minimum > 0 and (arithmetic + radius * maxWeightError) / minimum or math.huge
			)
			report.patches += 1
			pulse("patch")
			if options.checkpoint then
				options.checkpoint(0.5 + 0.5 * report.patches / (#uAxis * #vAxis))
			end
		end
	end
	local knotAllowance = 0
	for _, c in curves do
		knotAllowance += 2 * c.normalizationAllowance
	end
	report.knotNormalizationAllowance = knotAllowance
	report.constructionErrorBound += knotAllowance
	report.boundaryErrorBound = report.constructionErrorBound + mismatch
	report.complete = U.finite(report.constructionErrorBound) and report.constructionErrorBound <= maxError
	report.success = report.complete
	report.reason = report.complete and "tolerance" or "precision"
	report.maxError = maxError
	local function knots(breaks, d)
		local out = {}
		for i, k in breaks do
			for _ = 1, (i == 1 or i == #breaks) and d + 1 or d do
				table.insert(out, k)
			end
		end
		return out
	end
	local surface = N.surface(control, du, dv, {
		weights = weights,
		knotsU = knots(breaksU, du),
		knotsV = knots(breaksV, dv),
		maxControls = ctx.maxControls,
	})
	pulse("finish")
	assert(
		options.requireComplete == false or report.complete,
		"Coons construction did not meet maxError at native precision"
	)
	return surface, report
end
