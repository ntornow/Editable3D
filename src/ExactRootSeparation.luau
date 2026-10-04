-- Strict rational gaps leave an interior sample between every exact event.
-- Nonexact roots must carry their defining square-free analysis.
return function(roots, R, P, settings)
	-- A rational slab sample must be strictly between the actual events, even
	-- when an isolator initially shares an endpoint with an exact domain bound.
	for i = 1, #roots - 1 do
		local a, b = roots[i], roots[i + 1]
		while R.compare(a.high, b.low) >= 0 do
			assert(not (a.exact and b.exact), "Distinct exact events are not ordered")
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
