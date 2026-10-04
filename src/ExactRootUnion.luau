-- Isolate a union without forming a high-degree product polynomial.
-- Algebraic identity uses a common root in the intersection of isolators.
return function(polynomials, low, high, R, P, settings, ctx)
	local one = R.number(1)
	local unique, all = {}, {}
	for _, source in polynomials do
		if #source <= 1 then
			continue
		end
		local p = P.scale(source, R.div(one, source[#source]))
		local duplicate = false
		for _, q in unique do
			if #p ~= #q then
				continue
			end
			local same = true
			for i, x in p do
				if not R.equal(x, q[i]) then
					same = false
					break
				end
			end
			if same then
				duplicate = true
				break
			end
		end
		if duplicate then
			continue
		end
		table.insert(unique, p)
		local result = P.isolate(p, low, high, settings)
		for _, root in result.roots do
			assert(#all < ctx.maxEvents, "Exact intersection event budget exceeded")
			root.analysis = result.analysis
			table.insert(all, root)
		end
	end
	local common = {}
	local function compare(a, b)
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
	table.sort(all, function(a, b)
		return compare(a, b) < 0
	end)
	local roots = {}
	for _, root in all do
		local previous = roots[#roots]
		if previous and compare(previous, root) == 0 then
			if root.exact then
				previous.low, previous.high, previous.exact = root.low, root.high, true
			else
				if R.compare(root.low, previous.low) > 0 then
					previous.low = root.low
				end
				if R.compare(root.high, previous.high) < 0 then
					previous.high = root.high
				end
			end
			previous.depth = math.max(previous.depth, root.depth)
		else
			table.insert(roots, root)
		end
	end
	if #roots == 0 or not (roots[1].exact and R.equal(roots[1].low, low)) then
		table.insert(roots, 1, { low = low, high = low, exact = true, depth = 0 })
	end
	if not (roots[#roots].exact and R.equal(roots[#roots].low, high)) then
		table.insert(roots, { low = high, high = high, exact = true, depth = 0 })
	end
	assert(#roots <= ctx.maxEvents, "Exact intersection event budget exceeded")
	require(script.Parent.ExactRootSeparation)(roots, R, P, settings)
	return roots
end
