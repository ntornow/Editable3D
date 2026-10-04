-- Exact source-specific convergence of the scaled stationary core recurrence.
local U = require(script.Parent.Util)
return function(p, edges, diagonals, kind, options, visit)
	assert(kind == "crease" or kind == "corner", "Stationary constrained sector required")
	local n = #diagonals
	assert(n >= 1)
	assert(#edges == n + 1)
	local count = 2 * n + 2
	local maximum = U.integer(options.maxExactCoefficients or 1000000, 1)
	local maxDegree = U.integer(options.maxKrylovDegree or 128, 1)
	assert(count <= maxDegree, "Constrained jet degree budget exceeded")
	local estimated = 12 * count * (count + 1) + 4 * (count + 1) ^ 2
	assert(estimated <= maximum, "Constrained jet coefficient budget exceeded")
	local points = { p }
	for _, v in edges do
		points[#points + 1] = v
	end
	for _, v in diagonals do
		points[#points + 1] = v
	end
	for _, v in points do
		if v[4] ~= 0 then
			return nil, { finiteCertified = false, reason = "uncertainControls" }
		end
	end
	local R = require(script.Parent.ExactRational)(visit, options.maxExactBits or 8192)
	local zero, one = R.number(0), R.number(1)
	local function weighted(values, weights)
		local out = zero
		for i, x in values do
			out = R.add(out, R.mul(x, R.number(weights[i])))
		end
		return out
	end
	local raw = {}
	for i, v in points do
		for axis = 1, 3 do
			raw[(i - 1) * 3 + axis] = R.number(v[axis])
		end
	end
	local function get(values, i, axis)
		return values[(i - 1) * 3 + axis]
	end
	local initial = {}
	for axis = 1, 3 do
		local center = kind == "corner" and get(raw, 1, axis)
			or R.div(
				weighted({ get(raw, 1, axis), get(raw, 2, axis), get(raw, n + 2, axis) }, { 4, 1, 1 }),
				R.number(6)
			)
		for i = 1, count do
			initial[(i - 1) * 3 + axis] = R.sub(get(raw, i, axis), center)
		end
	end
	local function advance(v)
		local out = {}
		for axis = 1, 3 do
			local center = get(v, 1, axis)
			out[axis] = kind == "corner" and R.mul(R.number(2), center)
				or R.div(weighted({ center, get(v, 2, axis), get(v, n + 2, axis) }, { 6, 1, 1 }), R.number(4))
			out[3 + axis] = R.add(center, get(v, 2, axis))
			out[(n + 1) * 3 + axis] = R.add(center, get(v, n + 2, axis))
			for j = 1, n - 1 do
				out[(j + 1) * 3 + axis] = R.div(
					weighted({
						center,
						get(v, j + 2, axis),
						get(v, j + 1, axis),
						get(v, j + 3, axis),
						get(v, n + j + 2, axis),
						get(v, n + j + 3, axis),
					}, { 6, 6, 1, 1, 1, 1 }),
					R.number(8)
				)
			end
			for j = 0, n - 1 do
				out[(n + j + 2) * 3 + axis] = R.div(
					weighted(
						{ center, get(v, j + 2, axis), get(v, j + 3, axis), get(v, n + j + 3, axis) },
						{ 1, 1, 1, 1 }
					),
					R.number(2)
				)
			end
		end
		assert(#out == #initial)
		return out
	end
	local basis, powers = {}, {}
	local current = initial
	local polynomial
	for degree = 0, count do
		if options.checkpoint then
			options.checkpoint({ stage = "constrainedJet", degree = degree, coreSize = count })
		end
		visit(count)
		powers[degree + 1] = current
		local value = table.clone(current)
		local representation = table.create(degree + 1, zero)
		representation[degree + 1] = one
		for _, b in basis do
			local factor = value[b.pivot]
			if factor.sign ~= 0 then
				for i, x in value do
					value[i] = R.sub(x, R.mul(factor, b.value[i]))
				end
				for i, x in b.polynomial do
					representation[i] = R.sub(representation[i], R.mul(factor, x))
				end
			end
		end
		local pivot
		for i, x in value do
			if x.sign ~= 0 then
				pivot = i
				break
			end
		end
		if not pivot then
			polynomial = representation
			break
		end
		local factor = value[pivot]
		for i, x in value do
			value[i] = R.div(x, factor)
		end
		for i, x in representation do
			representation[i] = R.div(x, factor)
		end
		basis[#basis + 1] = { pivot = pivot, value = value, polynomial = representation }
		current = advance(current)
	end
	assert(polynomial, "Constrained core did not close its Krylov recurrence")
	-- Verify the relation again against original powers before using it as evidence.
	for i in initial do
		local value = zero
		for j, x in polynomial do
			value = R.add(value, R.mul(x, powers[j][i]))
		end
		assert(value.sign == 0, "Invalid exact Krylov relation")
	end
	local function atOne(poly)
		local value = zero
		for _, x in poly do
			value = R.add(value, x)
		end
		return value
	end
	local function encode(x)
		return { sign = x.sign, numerator = table.clone(x.n), denominator = table.clone(x.d) }
	end
	local function encodePoly(poly)
		local out = {}
		for i, x in poly do
			out[i] = encode(x)
		end
		return out
	end
	local certificate = {
		method = "exactKrylovSchur",
		coreSize = count,
		degree = #polynomial - 1,
		polynomial = encodePoly(polynomial),
		base = 2 ^ 24,
		finiteCertified = false,
		coefficientPreflight = estimated,
	}
	local stablePolynomial = polynomial
	local hasUnit = atOne(polynomial).sign == 0
	if hasUnit then
		stablePolynomial = table.create(#polynomial - 1, zero)
		stablePolynomial[#stablePolynomial] = polynomial[#polynomial]
		for i = #stablePolynomial - 1, 1, -1 do
			stablePolynomial[i] = R.add(polynomial[i + 1], stablePolynomial[i + 1])
		end
		assert(R.add(polynomial[1], stablePolynomial[1]).sign == 0)
		if atOne(stablePolynomial).sign == 0 then
			certificate.reason = "unitJordanMode"
			return nil, certificate
		end
	end
	local stable, reflections, failedDegree =
		require(script.Parent.ExactSchurStability)(R, stablePolynomial, visit)
	certificate.stablePolynomial = encodePoly(stablePolynomial)
	certificate.reflections = encodePoly(reflections)
	if not stable then
		certificate.reason = "noncontractingModes"
		certificate.failedDegree = failedDegree
		return nil, certificate
	end
	local limit = table.create(#initial, zero)
	if hasUnit then
		local denominator = atOne(stablePolynomial)
		for j, coefficient in stablePolynomial do
			for i, x in powers[j] do
				limit[i] = R.add(limit[i], R.mul(coefficient, x))
			end
		end
		for i, x in limit do
			limit[i] = R.div(x, denominator)
		end
	end
	local advanced = advance(limit)
	for i, x in limit do
		assert(R.equal(advanced[i], x), "Scaled limit is not stationary")
	end
	for axis = 1, 3 do
		assert(get(limit, 1, axis).sign == 0, "Constrained jet center is nonzero")
		if kind == "crease" then
			assert(R.add(get(limit, 2, axis), get(limit, n + 2, axis)).sign == 0)
		end
		for j = 1, n - 1 do
			assert(
				R.add(get(limit, j + 1, axis), get(limit, j + 3, axis)).sign == 0,
				"Nonaffine characteristic edge pattern"
			)
		end
		for j = 0, n - 1 do
			assert(
				R.equal(get(limit, n + j + 3, axis), R.add(get(limit, j + 2, axis), get(limit, j + 3, axis))),
				"Nonaffine characteristic diagonal"
			)
		end
	end
	certificate.finiteCertified = true
	certificate.unitMode = hasUnit
	certificate.scaledLimit = encodePoly(limit)
	local enclose = require(script.Parent.ExactRationalBounds)(R, visit)
	local I = require(script.Parent.DirectedInterval)
	local native = {}
	for i = 1, n + 1 do
		local v = {}
		local error = { 0, 0 }
		for axis = 1, 3 do
			local b = enclose(get(limit, i + 1, axis))
			if not U.finite(b[1]) or not U.finite(b[2]) then
				certificate.reason = "nativeRange"
				return nil, certificate
			end
			local midpoint = b[1] / 2 + b[2] / 2
			if not U.finite(midpoint) then
				certificate.reason = "nativeRange"
				return nil, certificate
			end
			v[axis] = midpoint
			local radius = math.max(
				I.sub({ midpoint, midpoint }, { b[1], b[1] })[2],
				I.sub({ b[2], b[2] }, { midpoint, midpoint })[2]
			)
			error = I.add(error, { radius, radius })
		end
		v[4] = error[2]
		native[i] = v
	end
	return native, certificate
end
