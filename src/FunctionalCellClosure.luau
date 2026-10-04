-- Eliminate coordinates expressed by rational graphs near the fixed target.
-- Every chosen denominator is nonzero at that target. Removing its zero set
-- leaves the same local closure, and projection is a local homeomorphism.
return function(polynomials, signs, origins, M, R, point, offset, ctx)
	local eliminated, steps = {}, {}
	local function constant(p)
		if #p ~= 1 then
			return false
		end
		for _, n in p[1].powers do
			if n ~= 0 then
				return false
			end
		end
		return true
	end
	local function substitute(p, axis, numerator, denominator)
		local degree = M.degree(p, axis)
		if degree < 0 then
			return {}
		end
		local polynomial = constant(denominator)
		if polynomial then
			numerator = M.scale(numerator, R.div(R.number(1), denominator[1].value))
		end
		local even = polynomial and degree or 2 * math.ceil(degree / 2)
		local np, dp = { M.constant(R.number(1)) }, { M.constant(R.number(1)) }
		for i = 1, even do
			np[i + 1] = M.product(np[i], numerator)
			if not polynomial then
				dp[i + 1] = M.product(dp[i], denominator)
			end
		end
		local out = {}
		for i = 0, degree do
			local term = M.product(M.coefficient(p, axis, i), np[i + 1])
			if not polynomial then
				term = M.product(term, dp[even - i + 1])
			end
			out = M.add(out, term)
		end
		return out
	end
	while true do
		local selected, axis, denominator, targetDenominator
		for candidate = M.dimension, offset + 1, -1 do
			if eliminated[candidate] then
				continue
			end
			for _, index in origins do
				local p = polynomials[index]
				if signs[index] ~= 0 or M.degree(p, candidate) ~= 1 then
					continue
				end
				local coefficient = M.coefficient(p, candidate, 1)
				local value = M.evaluate(coefficient, point)
				if value.sign ~= 0 then
					selected, axis, denominator, targetDenominator = index, candidate, coefficient, value
					break
				end
			end
			if selected then
				break
			end
		end
		if not selected then
			break
		end
		ctx.visit(1)
		local equation = polynomials[selected]
		local numerator = M.neg(M.coefficient(equation, axis, 0))
		if not R.equal(M.evaluate(numerator, point), R.mul(point[axis], targetDenominator)) then
			return nil, { method = "closedRationalGraphExclusion", equation = equation }
		end
		for i, p in polynomials do
			polynomials[i] = substitute(p, axis, numerator, denominator)
		end
		steps[#steps + 1] =
			{ axis = axis, equation = equation, numerator = numerator, denominator = denominator }
		eliminated[axis] = true
		-- The denominator guard restricts only points outside a target neighborhood.
		-- Multiplication by an even denominator power preserves all source signs.
		for _, condition in
			{
				{ M.product(denominator, denominator), 1 },
				{ M.product(numerator, denominator), 2 },
				{ M.product(M.sub(denominator, numerator), denominator), 2 },
			}
		do
			polynomials[#polynomials + 1] = condition[1]
			signs[#polynomials] = condition[2]
			origins[#origins + 1] = #polynomials
		end
	end
	return eliminated, { method = "localContinuousRationalGraph", steps = steps }
end
