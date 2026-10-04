-- Exact ordering of isolated roots in a common ordered coefficient field.
return function(R, P, settings)
	local common = {}
	return function(a, b)
		if a == b then
			return 0
		end
		while true do
			if a.exact and b.exact then
				return R.compare(a.low, b.low)
			end
			if R.compare(a.high, b.low) <= 0 then
				return -1
			end
			if R.compare(b.high, a.low) <= 0 then
				return 1
			end
			local lo = R.compare(a.low, b.low) > 0 and a.low or b.low
			local hi = R.compare(a.high, b.high) < 0 and a.high or b.high
			if a.exact then
				if P.evaluate(b.analysis.squarefree, a.low).sign == 0 then
					return 0
				end
			elseif b.exact then
				if P.evaluate(a.analysis.squarefree, b.low).sign == 0 then
					return 0
				end
			else
				common[a.analysis] = common[a.analysis] or {}
				local g = common[a.analysis][b.analysis]
				if not g then
					g = P.analyze(P.gcd(a.analysis.squarefree, b.analysis.squarefree))
					common[a.analysis][b.analysis] = g
				end
				if
					#g.squarefree > 1 and (P.count(g, lo, hi) > 0 or P.evaluate(g.squarefree, lo).sign == 0)
				then
					return 0
				end
			end
			if a.exact then
				P.refine(b.analysis, b, settings)
			elseif b.exact then
				P.refine(a.analysis, a, settings)
			elseif R.compare(R.sub(a.high, a.low), R.sub(b.high, b.low)) >= 0 then
				P.refine(a.analysis, a, settings)
			else
				P.refine(b.analysis, b, settings)
			end
		end
	end
end
