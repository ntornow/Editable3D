-- Source-vector recurrence asymptotics over one isolated dominant positive root.
return function(R, P, polynomial, options, visit)
	local zero, one = R.number(0), R.number(1)
	local analysis = P.analyze(polynomial)
	if #analysis.squarefree <= 1 then
		return nil, "zeroSequence"
	end
	local count = P.count(analysis, zero, one) + (P.evaluate(analysis.squarefree, zero).sign == 0 and 1 or 0)
	if count ~= #analysis.squarefree - 1 or P.evaluate(analysis.squarefree, one).sign == 0 then
		return nil, "unsupportedSpectrum"
	end
	local settings = {
		tolerance = R.number(1 / 1024),
		maxDepth = options.maxRootDepth or 128,
		maxNodes = options.maxRootNodes or 100000,
	}
	local isolated = (P.realSpectrum and P.highestRealRoot or P.isolate)(polynomial, zero, one, settings)
	local root = isolated.roots[#isolated.roots]
	if root.exact and root.low.sign == 0 then
		return nil, "nilpotentSequence"
	end
	root.analysis = isolated.analysis
	local B = require(script.Parent.ExactPolynomialBounds)(R, P, visit)
	local F = require(script.Parent.AnnularAlgebraicValue)(R, P, B, root, settings)
	local derivative = polynomial
	for _ = 1, root.multiplicity do
		derivative = P.derivative(derivative)
	end
	assert(F.sign(derivative) > 0, "Dominant pole orientation is not positive")
	-- f(z)=p(z)/(z-rho)=(z-rho)^(m-1)q(z). Applying f(M) to the
	-- initial vector gives its leading Jordan direction with a positive scale.
	-- Each coefficient is retained as a rational polynomial in rho.
	local degree = #polynomial - 1
	local coefficients = {}
	for i = 1, degree do
		local coefficient = {}
		for j = i + 1, #polynomial do
			coefficient[#coefficient + 1] = polynomial[j]
		end
		coefficients[i] = coefficient
	end
	local function leading(powers)
		assert(#powers >= degree)
		local out = {}
		for axis in powers[1] do
			local p = {}
			for i, f in coefficients do
				if powers[i][axis].sign ~= 0 then
					p = P.add(p, P.scale(f, powers[i][axis]))
				end
			end
			if #p >= #analysis.squarefree then
				local _, rest = P.divide(p, analysis.squarefree)
				p = rest
			end
			out[axis] = p
		end
		return out
	end
	return {
		root = root,
		value = F,
		leading = leading,
		coefficients = coefficients,
		multiplicity = root.multiplicity,
	}
end
