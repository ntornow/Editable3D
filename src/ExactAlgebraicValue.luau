-- Rational functions evaluated at one isolated real algebraic parameter.
-- No irreducibility assumption: vanishing is localized by exact common roots.
return function(R, P, B, root, settings)
	local zero, one = R.number(0), R.number(1)
	local F = { root = root }
	local common = {}
	function F.sign(source)
		if root.exact then
			return P.evaluate(source, root.low).sign
		end
		local p = source
		if #p >= #root.analysis.squarefree then
			local _, rest = P.divide(p, root.analysis.squarefree)
			p = rest
		end
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
				g = P.analyze(P.gcd(root.analysis.squarefree, p))
				common[source] = g
			end
			if P.count(g, root.low, root.high) == 1 then
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
