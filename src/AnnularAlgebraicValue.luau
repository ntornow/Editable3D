-- Rational functions evaluated at one isolated real algebraic parameter.
-- No irreducibility assumption: vanishing is localized by exact common roots.
return function(R, P, B, root, settings)
	local zero, one = R.number(0), R.number(1)
	local F = { root = root }
	local common = {}
	local modulus = root.analysis.squarefree
	function F.reduce(source)
		if #source < #modulus then
			return source
		end
		local _, rest = P.divide(source, modulus)
		return rest
	end
	function F.modulus()
		return modulus
	end
	function F.localize(source)
		if root.exact then
			return 0
		end
		local g = P.gcd(modulus, source)
		if #g > 1 and #g < #modulus then
			local left, right = P.evaluate(g, root.low).sign, P.evaluate(g, root.high).sign
			assert(left ~= 0 and right ~= 0)
			modulus = left ~= right and g or P.quotient(modulus, g)
		end
		return #modulus - 1
	end
	function F.sign(source)
		if root.exact then
			return P.evaluate(source, root.low).sign
		end
		local p = F.reduce(source)
		if #p == 0 then
			return 0
		end
		while true do
			if root.exact then
				return P.evaluate(p, root.low).sign
			end
			local box = B.evaluate(p, { root.low, root.high })
			if box[1].sign > 0 then
				return 1
			end
			if box[2].sign < 0 then
				return -1
			end
			local g = common[source]
			if not g then
				g = P.gcd(modulus, p)
				common[source] = g
			end
			-- g divides a square-free modulus whose interval contains at most
			-- one root. Opposite endpoint signs exactly detect that simple root;
			-- computing a fresh Sturm chain for g is unnecessary.
			local left, right = P.evaluate(g, root.low).sign, P.evaluate(g, root.high).sign
			assert(left ~= 0 and right ~= 0, "Nonexact algebraic interval endpoint is a root")
			if left ~= right then
				if #g < #modulus then
					modulus = g
				end
				return 0
			end
			P.refine(root.analysis, root, settings)
		end
	end
	function F.constant(value)
		return { n = { value }, d = { one } }
	end
	function F.compare(a, b)
		local sa, sb = F.sign(a.d), F.sign(b.d)
		assert(sa ~= 0 and sb ~= 0, "Algebraic rational denominator vanishes")
		local difference = P.add(P.product(a.n, b.d), P.scale(P.product(b.n, a.d), R.number(-1)))
		return F.sign(difference) * sa * sb
	end
	function F.exact(value)
		assert(root.exact, "Exact parameter required")
		return R.div(P.evaluate(value.n, root.low), P.evaluate(value.d, root.low))
	end
	function F.bound(value, fallback)
		if root.exact then
			local x = F.exact(value)
			return { x, x }
		end
		local numerator = B.evaluate(value.n, { root.low, root.high })
		local denominator = B.evaluate(value.d, { root.low, root.high })
		if denominator[1].sign <= 0 and denominator[2].sign >= 0 then
			return fallback
		end
		if denominator[2].sign < 0 then
			numerator = B.neg(numerator)
			denominator = B.neg(denominator)
		end
		return B.intersect(B.divide(numerator, denominator), fallback)
	end
	function F.refine()
		if root.exact or root.depth >= settings.maxDepth then
			return false
		end
		P.refine(root.analysis, root, settings)
		return true
	end
	F.zero, F.one = F.constant(zero), F.constant(one)
	return F
end
