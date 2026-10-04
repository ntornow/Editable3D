-- Bounded primitive pseudo-remainder GCD and a coprime squarefree basis.
return function(M, R, dimension, ctx, options)
	options = options or {}
	local one = M.constant(R.number(1))
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
	local cache, cacheCount = {}, 0
	local modularCoprime = require(script.Parent.ModularCoprime)(M, ctx)
	local algebraicCoefficients = type(R.number(1).d[1]) == "table"
	local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, ctx.maxDegree or 96, ctx.allocate)
	local function coprime(a, b, axis)
		if not algebraicCoefficients then
			return modularCoprime(a, b, axis)
		end
		if axis <= 1 then
			return false
		end
		for trial = 1, 2 do
			local values = {}
			for i = 1, axis - 1 do
				values[i] = R.number(i + trial)
			end
			local x = M.specialize(a, axis, values, R, function(q)
				return q
			end)
			local y = M.specialize(b, axis, values, R, function(q)
				return q
			end)
			if #x == M.degree(a, axis) + 1 and #y == M.degree(b, axis) + 1 and #P.gcd(x, y) == 1 then
				return true
			end
		end
		return false
	end
	local gcd, primitive
	local function content(p, axis)
		local g = {}
		for j = 0, M.degree(p, axis) do
			local coefficient = M.coefficient(p, axis, j)
			if #coefficient > 0 then
				g = gcd(g, coefficient, axis - 1)
				if constant(g) then
					break
				end
			end
		end
		return g
	end
	primitive = function(p, axis)
		if #p == 0 then
			return {}
		end
		if axis <= 0 then
			return one
		end
		return M.normalize(M.quotient(p, content(p, axis)))
	end
	gcd = function(a, b, axis)
		ctx.visit(1)
		if #a == 0 then
			return M.normalize(b)
		end
		if #b == 0 then
			return M.normalize(a)
		end
		if axis <= 0 or constant(a) or constant(b) then
			return one
		end
		while axis > 0 and M.degree(a, axis) == 0 and M.degree(b, axis) == 0 do
			axis -= 1
		end
		if axis <= 0 then
			return one
		end
		a, b = M.normalize(a), M.normalize(b)
		local ka, kb = M.key(a), M.key(b)
		local key = axis .. ":" .. (ka < kb and ka .. "|" .. kb or kb .. "|" .. ka)
		if cache[key] then
			return cache[key]
		end
		if axis == 1 then
			local x = M.specialize(a, 1, {}, R, function(q)
				return q
			end)
			local y = M.specialize(b, 1, {}, R, function(q)
				return q
			end)
			local coefficients = P.gcd(x, y)
			local terms = {}
			for i, value in coefficients do
				local powers = table.create(dimension, 0)
				powers[1] = i - 1
				terms[#terms + 1] = { powers = powers, value = value }
			end
			local result = M.make(terms)
			if cacheCount < (options.maxGcdCache or 10000) then
				ctx.allocate(1)
				cacheCount += 1
				cache[key] = result
			end
			return result
		end
		local ca, cb = content(a, axis), content(b, axis)
		local common = gcd(ca, cb, axis - 1)
		a, b = M.normalize(M.quotient(a, ca)), M.normalize(M.quotient(b, cb))
		if coprime(a, b, axis) then
			a, b = one, {}
		end
		while #b > 0 do
			if M.degree(b, axis) == 0 then
				a = one
				break
			end
			local reduced, count = M.leadingRemainder(a, b)
			if count > 0 and M.degree(reduced, axis) < M.degree(b, axis) then
				a, b = b, primitive(reduced, axis)
				continue
			end
			local remainder = a
			local degree = M.degree(b, axis)
			local leading = M.coefficient(b, axis, degree)
			while #remainder > 0 and M.degree(remainder, axis) >= degree do
				ctx.visit(1)
				local offset = M.degree(remainder, axis) - degree
				local factor = M.coefficient(remainder, axis, M.degree(remainder, axis))
				local powers = table.create(dimension, 0)
				powers[axis] = offset
				local monomial = M.make({ { powers = powers, value = R.number(1) } })
				remainder = M.sub(M.product(leading, remainder), M.product(M.product(factor, monomial), b))
				-- B is primitive: removing coefficient content preserves the primitive GCD.
				remainder = primitive(remainder, axis)
			end
			a, b = b, primitive(remainder, axis)
		end
		local result = M.normalize(M.product(common, primitive(a, axis)))
		if cacheCount < (options.maxGcdCache or 10000) then
			ctx.allocate(1)
			cacheCount += 1
			cache[key] = result
		end
		return result
	end
	local function squarefree(p)
		local common = p
		for axis = 1, dimension do
			common = gcd(common, M.derivative(p, axis), dimension)
			if constant(common) then
				break
			end
		end
		return M.normalize(M.quotient(p, common))
	end
	local function basis(polynomials)
		local out = {}
		local function append(p)
			if #p == 0 or constant(p) then
				return
			end
			assert(
				#out < (options.maxProjectionPolynomials or 256),
				"CAD squarefree basis allocation budget exceeded"
			)
			table.insert(out, (M.normalize(p)))
		end
		for _, source in polynomials do
			if #source == 0 or constant(source) then
				continue
			end
			local p = squarefree(source)
			local count = #out
			for i = 1, count do
				local common = gcd(p, out[i], dimension)
				if not constant(common) then
					local rest = M.quotient(out[i], common)
					if not constant(rest) then
						out[i] = M.normalize(rest)
						append(common)
					else
						out[i] = common
					end
					p = M.quotient(p, common)
					if constant(p) then
						break
					end
				end
			end
			append(p)
		end
		return out
	end
	return {
		gcd = function(a, b)
			return gcd(a, b, dimension)
		end,
		basis = basis,
		squarefree = squarefree,
		split = function(p, axis)
			return primitive(p, axis), content(p, axis)
		end,
	}
end
