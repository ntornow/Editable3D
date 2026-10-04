-- Internal exact field of exponential-polynomial germs, with formal GCD reduction.
return function(K, bases, ctx, options)
	options = options or {}
	local count = #bases
	local dimension = count + 1
	for _, base in bases do
		assert(base.sign > 0, "Exponential generators must be positive")
	end
	local T = require(script.Parent.InfinitesimalField)(K, ctx.visit, ctx.allocate, ctx.maxDegree or 128)
	local M = require(script.Parent.ExactSparsePolynomial)(T, dimension, ctx)
	local algebra = require(script.Parent.MultivariateBasis)(M, T, dimension, ctx, options)
	local G = { coefficientField = T }
	local one = M.constant(T.number(1))
	local baseCache = {}
	local actualBases = {}
	local comparisonCache = {}
	local function actualBase(powers)
		local exponents = {}
		for i = 1, count do
			exponents[i] = powers[i]
		end
		local key = table.concat(exponents, ",")
		if baseCache[key] then
			return baseCache[key]
		end
		local value = K.number(1)
		for i, n in exponents do
			for _ = 1, n do
				ctx.visit(1)
				value = K.mul(value, bases[i])
			end
		end
		local id
		for i, b in actualBases do
			if K.equal(b, value) then
				id = i
				break
			end
		end
		if not id then
			id = #actualBases + 1
			actualBases[id] = value
			ctx.allocate(1)
		end
		ctx.allocate(dimension)
		baseCache[key] = id
		return id
	end
	local function groupsFor(poly)
		local groups = {}
		for _, term in poly do
			local base = actualBase(term.powers)
			local power = term.powers[dimension]
			local found = false
			for _, group in groups do
				ctx.visit(1)
				if power == group.power and base == group.base then
					group.coefficient = T.add(group.coefficient, term.value)
					found = true
					break
				end
			end
			if not found then
				groups[#groups + 1] = { base = base, power = power, coefficient = term.value }
			end
		end
		return groups
	end
	local function compareBases(a, b)
		if a == b then
			return 0
		end
		local key = a .. "," .. b
		if comparisonCache[key] == nil then
			comparisonCache[key] = K.compare(actualBases[a], actualBases[b])
			ctx.allocate(1)
		end
		return comparisonCache[key]
	end
	local function sign(poly)
		local top
		for _, group in groupsFor(poly) do
			if group.coefficient.sign ~= 0 then
				if not top then
					top = group
				else
					local c = compareBases(group.base, top.base)
					if c > 0 or c == 0 and group.power > top.power then
						top = group
					end
				end
			end
		end
		return top and top.coefficient.sign or 0
	end
	local function make(n, d)
		local ds = d == one and 1 or sign(d)
		assert(ds ~= 0, "Zero germ denominator")
		local ns = sign(n)
		if ns == 0 then
			return { n = {}, d = one, sign = 0 }
		end
		if d == one then
			return { n = n, d = one, sign = ns }
		end
		if #d == 1 then
			local constant = true
			for _, power in d[1].powers do
				if power ~= 0 then
					constant = false
					break
				end
			end
			if constant then
				return { n = M.scale(n, T.div(T.number(1), d[1].value)), d = one, sign = ns * ds }
			end
		end
		local common = algebra.gcd(n, d)
		n, d = M.quotient(n, common), M.quotient(d, common)
		local scalar = T.div(T.number(1), d[1].value)
		n, d = M.scale(n, scalar), M.scale(d, scalar)
		return { n = n, d = d, sign = ns * ds }
	end
	function G.constant(x)
		return { n = M.constant(x), d = one, sign = x.sign }
	end
	function G.rational(x)
		return G.constant(T.rational(x))
	end
	function G.number(x)
		return G.rational(K.number(x))
	end
	function G.fromTerms(terms)
		local out = {}
		for _, term in terms do
			local powers = table.create(dimension, 0)
			powers[dimension] = term.power
			assert(term.power >= 0 and term.power % 1 == 0)
			if not K.equal(term.base, K.number(1)) then
				local index
				for i, b in bases do
					if K.equal(b, term.base) then
						index = i
						break
					end
				end
				assert(index, "Unknown positive exponential generator")
				powers[index] = 1
			end
			out[#out + 1] = { powers = powers, value = term.coefficient }
		end
		return make(M.make(out), one)
	end
	function G.neg(a)
		return { n = M.neg(a.n), d = a.d, sign = -a.sign }
	end
	function G.add(a, b)
		if a.sign == 0 then
			return b
		elseif b.sign == 0 then
			return a
		end
		if a.d == one and b.d == one then
			return make(M.add(a.n, b.n), one)
		end
		return make(M.add(M.product(a.n, b.d), M.product(b.n, a.d)), M.product(a.d, b.d))
	end
	function G.sub(a, b)
		return G.add(a, G.neg(b))
	end
	function G.mul(a, b)
		if a.sign == 0 or b.sign == 0 then
			return G.number(0)
		end
		return make(M.product(a.n, b.n), a.d == one and b.d == one and one or M.product(a.d, b.d))
	end
	function G.div(a, b)
		assert(b.sign ~= 0)
		return make(M.product(a.n, b.d), M.product(a.d, b.n))
	end
	function G.compare(a, b)
		return G.sub(a, b).sign
	end
	function G.equal(a, b)
		return G.compare(a, b) == 0
	end
	function G.key(value)
		return "[" .. M.key(value.n) .. "]/[" .. M.key(value.d) .. "]"
	end
	local function denominator(value)
		assert(#value.d == 1)
		for _, power in value.d[1].powers do
			assert(power == 0)
		end
		return value.d[1].value
	end
	function G.leading(value)
		local groups = groupsFor(value.n)
		local top
		for _, group in groups do
			if group.coefficient.sign ~= 0 then
				if not top then
					top = group
				else
					local c = compareBases(group.base, top.base)
					if c > 0 or c == 0 and group.power > top.power then
						top = group
					end
				end
			end
		end
		return top and { base = actualBases[top.base], power = top.power, coefficient = top.coefficient }
			or nil
	end
	function G.coefficient(value, base, power)
		for _, group in groupsFor(value.n) do
			if group.power == power and K.equal(actualBases[group.base], base) then
				local coefficient = T.div(group.coefficient, denominator(value))
				assert(#coefficient.n <= 1 and #coefficient.d == 1, "Source mode depends on tolerance")
				return K.div(coefficient.n[1] or K.number(0), coefficient.d[1])
			end
		end
		return K.number(0)
	end
	G.tolerance = G.constant(T.epsilon)
	return G
end
