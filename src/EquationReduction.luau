-- Bounded exact elementary ideal-preserving equation rewrites, with witnesses.
return function(source, M, R, ctx, options)
	options = options or {}
	local equations = table.clone(source)
	local steps = {}
	local function divisible(a, b)
		for i, power in a do
			if power < b[i] then
				return false
			end
		end
		return true
	end
	local function reduce(p, skip)
		local remainder, quotients = {}, {}
		for j = 1, #equations do
			quotients[j] = {}
		end
		while #p > 0 do
			ctx.visit(1)
			local divisor
			for j, q in equations do
				if j ~= skip and #q > 0 and divisible(p[1].powers, q[1].powers) then
					divisor = j
					break
				end
			end
			if divisor then
				local q = equations[divisor]
				local powers = {}
				for axis, n in p[1].powers do
					powers[axis] = n - q[1].powers[axis]
				end
				local term = M.make({ { powers = powers, value = R.div(p[1].value, q[1].value) } })
				quotients[divisor] = M.add(quotients[divisor], term)
				p = M.sub(p, M.product(term, q))
			else
				remainder[#remainder + 1] = p[1]
				p = table.clone(p)
				table.remove(p, 1)
			end
		end
		return M.make(remainder), quotients
	end
	local pass = 0
	while true do
		pass += 1
		assert(pass <= (options.maxEquationPasses or 64), "Equation reduction pass budget exceeded")
		local changed = false
		for i, p in equations do
			if #p == 0 then
				continue
			end
			local remainder, quotients = reduce(p, i)
			local normalized, scale = M.normalize(remainder)
			if not M.equal(p, normalized) then
				assert(
					#steps < (options.maxEquationRewrites or 1024),
					"Equation reduction witness budget exceeded"
				)
				steps[#steps + 1] =
					{ index = i, before = p, after = normalized, scale = scale, quotients = quotients }
				equations[i] = normalized
				changed = true
			end
		end
		if not changed then
			break
		end
	end
	local out = {}
	for _, p in equations do
		if #p > 0 then
			out[#out + 1] = p
		end
	end
	return out,
		{ source = source, equations = equations, steps = steps, passes = pass },
		function(p)
			return reduce(p, nil)
		end
end
