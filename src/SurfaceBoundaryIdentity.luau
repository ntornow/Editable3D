-- Private exact rational boundary-curve identity for a tensor B-spline surface.
-- Curve coefficients are computed in each span's normalized power coordinate.
local makeRational = require(script.Parent.ExactRational)
return function(source, direction, ctx)
	local visit = ctx.visit
	local R = makeRational(visit, ctx.maxExactBits)
	local zero, one = R.number(0), R.number(1)
	local function polyAdd(a, b)
		local out = {}
		for i = 1, math.max(#a, #b) do
			visit(1)
			out[i] = R.add(a[i] or zero, b[i] or zero)
		end
		return out
	end
	local function linear(a, x, y)
		local out = table.create(#a + 1, zero)
		for i, value in a do
			visit(1)
			out[i] = R.add(out[i], R.mul(value, x))
			out[i + 1] = R.add(out[i + 1], R.mul(value, y))
		end
		return out
	end
	local function product(a, b)
		local out = table.create(#a + #b - 1, zero)
		for i, x in a do
			for j, y in b do
				visit(1)
				out[i + j - 1] = R.add(out[i + j - 1], R.mul(x, y))
			end
		end
		return out
	end
	local function knotValues(knots)
		local out = {}
		for i, k in knots do
			visit(1)
			out[i] = R.number(k)
		end
		return out
	end
	local function basis(knots, degree, span)
		local lo, width = knots[span], R.sub(knots[span + 1], knots[span])
		assert(width.sign > 0, "Positive exact spline span required")
		local previous = { [span] = { one } }
		for d = 1, degree do
			local nextValues = {}
			for i = span - d, span do
				local p = { zero }
				local a, b = previous[i], previous[i + 1]
				if a then
					local den = R.sub(knots[i + d], knots[i])
					if den.sign ~= 0 then
						p = linear(a, R.div(R.sub(lo, knots[i]), den), R.div(width, den))
					end
				end
				if b then
					local den = R.sub(knots[i + d + 1], knots[i + 1])
					if den.sign ~= 0 then
						p = polyAdd(
							p,
							linear(b, R.div(R.sub(knots[i + d + 1], lo), den), R.neg(R.div(width, den)))
						)
					end
				end
				nextValues[i] = p
			end
			previous = nextValues
		end
		return previous
	end
	local alongU = direction == 1
	local degree = alongU and source.degreeU or source.degreeV
	local otherDegree = alongU and source.degreeV or source.degreeU
	local count = alongU and #source.control or #source.control[1]
	local other = alongU and #source.control[1] or #source.control
	ctx.allocate(
		4 * (count + other + degree + otherDegree + 2)
			+ 8 * other * (degree + 1)
			+ 8 * (math.max(degree, otherDegree) + 1) ^ 2
	)
	local rawKnots = alongU and source.knotsU or source.knotsV
	local knots = knotValues(rawKnots)
	local first, last
	for i = degree + 1, count do
		if rawKnots[i] < rawKnots[i + 1] then
			first = first or i
			last = i
		end
	end
	assert(first and last, "Missing exact spline domain")
	local boundaries = {}
	for side, span in { first, last } do
		local polynomials = basis(knots, degree, span)
		local weights = {}
		for i, p in polynomials do
			visit(1)
			local value = p[1]
			if side == 2 then
				value = zero
				for _, x in p do
					value = R.add(value, x)
				end
			end
			assert(value.sign >= 0, "Negative boundary basis")
			weights[i] = value
		end
		local values = {}
		for j = 1, other do
			local h = { zero, zero, zero, zero }
			for i, b in weights do
				local u, v = alongU and i or j, alongU and j or i
				local p = source.control[u][v]
				local w = R.mul(b, R.number(source.weights[u][v]))
				for axis, value in { p.X, p.Y, p.Z } do
					h[axis] = R.add(h[axis], R.mul(w, R.number(value)))
				end
				h[4] = R.add(h[4], w)
			end
			assert(h[4].sign > 0, "Nonpositive homogeneous boundary weight")
			values[j] = h
		end
		boundaries[side] = values
	end
	local otherRaw = alongU and source.knotsV or source.knotsU
	local otherKnots = knotValues(otherRaw)
	local checked = 0
	for span = otherDegree + 1, other do
		if otherRaw[span] >= otherRaw[span + 1] then
			continue
		end
		local polynomials = basis(otherKnots, otherDegree, span)
		local sides = {}
		for side, controls in boundaries do
			local coefficients = {}
			for axis = 1, 4 do
				coefficients[axis] = table.create(otherDegree + 1, zero)
				for i, p in polynomials do
					for j, x in p do
						visit(1)
						coefficients[axis][j] = R.add(coefficients[axis][j], R.mul(controls[i][axis], x))
					end
				end
			end
			sides[side] = coefficients
		end
		for axis = 1, 3 do
			local a, b = product(sides[1][axis], sides[2][4]), product(sides[2][axis], sides[1][4])
			for i, x in a do
				if not R.equal(x, b[i]) then
					return false,
						{
							certified = true,
							equal = false,
							reason = "differentBoundaryCurves",
							span = span,
							axis = axis,
							coefficient = i,
							checkedSpans = checked,
						}
				end
			end
		end
		checked += 1
	end
	return true,
		{ certified = true, equal = true, reason = "exactBoundaryCurveIdentity", checkedSpans = checked }
end
