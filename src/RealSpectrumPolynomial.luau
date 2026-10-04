-- Root isolation specialized to a polynomial already proved to have only real roots.
-- Descartes variations of its Bernstein coefficients count roots exactly.
return function(R, P, visit, allocate)
	local zero, one, two = R.number(0), R.number(1), R.number(2)
	local baseAnalyze, baseCount = P.analyze, P.count
	local function variations(values)
		local last, count = 0, 0
		for _, x in values do
			if x.sign ~= 0 then
				if last ~= 0 and last ~= x.sign then
					count += 1
				end
				last = x.sign
			end
		end
		return count
	end
	local function intervalCoefficients(poly, a, b)
		if allocate then
			allocate(#poly * (#poly + 1))
		end
		-- Coefficients of (1+t)^d p((a+b*t)/(1+t)); positive binomial
		-- factors convert these to Bernstein coefficients without affecting signs.
		local out = { poly[#poly] }
		local binomial = { one }
		for i = #poly - 1, 1, -1 do
			local nextValues = table.create(#out + 1, zero)
			for j, x in out do
				nextValues[j] = R.add(nextValues[j], R.mul(a, x))
				nextValues[j + 1] = R.add(nextValues[j + 1], R.mul(b, x))
			end
			local nextBinomial = { one }
			for j = 2, #binomial do
				nextBinomial[j] = R.add(binomial[j - 1], binomial[j])
			end
			nextBinomial[#binomial + 1] = one
			binomial = nextBinomial
			for j, x in binomial do
				nextValues[j] = R.add(nextValues[j], R.mul(poly[i], x))
			end
			out = nextValues
			visit(#out)
		end
		return out
	end
	P.analyze = function(source)
		if not P.realSpectrum then
			return baseAnalyze(source)
		end
		local p = P.trim(table.clone(source))
		if #p <= 1 then
			return { realSpectrum = true, polynomial = p, squarefree = p, identity = #p == 0, factors = {} }
		end
		p = P.scale(p, R.div(one, p[#p]))
		local g = P.gcd(p, P.derivative(p))
		local w = P.quotient(p, g)
		local squarefree = w
		local factors = {}
		local multiplicity = 1
		while #w > 1 do
			assert(multiplicity <= #p, "Square-free decomposition did not terminate")
			local y = P.gcd(w, g)
			local f = P.quotient(w, y)
			if #f > 1 then
				factors[#factors + 1] = { polynomial = f, multiplicity = multiplicity }
			end
			w, g = y, P.quotient(g, y)
			multiplicity += 1
		end
		return {
			realSpectrum = true,
			polynomial = source,
			squarefree = squarefree,
			identity = false,
			factors = factors,
		}
	end
	P.count = function(analysis, a, b)
		if not analysis.realSpectrum then
			return baseCount(analysis, a, b)
		end
		if #analysis.squarefree <= 1 then
			return 0
		end
		local count = variations(intervalCoefficients(analysis.squarefree, a, b))
		return count + (P.evaluate(analysis.squarefree, b).sign == 0 and 1 or 0)
	end
	P.highestRealRoot = function(source, low, high, settings)
		local analysis = P.analyze(source)
		local p = analysis.squarefree
		local depth = 0
		local root
		while true do
			settings.nodes = (settings.nodes or 0) + 1
			assert(settings.nodes <= settings.maxNodes, "Polynomial root node budget exceeded")
			local atLow, atHigh = P.evaluate(p, low).sign, P.evaluate(p, high).sign
			if atHigh == 0 then
				root = { low = high, high = high, exact = true, depth = depth }
				break
			end
			local count = P.count(analysis, low, high)
			if count == 0 then
				if atLow == 0 then
					root = { low = low, high = low, exact = true, depth = depth }
				end
				break
			end
			if count == 1 and atLow ~= 0 and R.compare(R.sub(high, low), settings.tolerance) <= 0 then
				root = { low = low, high = high, exact = false, depth = depth }
				break
			end
			assert(depth < settings.maxDepth, "Polynomial root depth budget exceeded")
			local mid = R.div(R.add(low, high), two)
			if P.count(analysis, mid, high) > 0 then
				low = mid
			else
				high = mid
			end
			depth += 1
			visit(1)
		end
		if not root then
			return { roots = {}, analysis = analysis }
		end
		for _, f in analysis.factors do
			local matches = root.exact and P.evaluate(f.polynomial, root.low).sign == 0
				or not root.exact
					and P.count({ squarefree = f.polynomial, realSpectrum = true }, root.low, root.high) == 1
			if matches then
				assert(not root.multiplicity)
				root.multiplicity = f.multiplicity
			end
		end
		assert(root.multiplicity, "Highest root has no multiplicity")
		return { roots = { root }, analysis = analysis }
	end
	return P
end
