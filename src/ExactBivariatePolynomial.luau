-- primitive Q[s][t] arithmetic without Q(s) fractions.
return function(R, P, ctx)
	local T = {}
	local one, minus = R.number(1), R.number(-1)
	local function storage(n)
		assert(n <= (ctx.maxDegree or 96) + 1, "Bivariate degree budget exceeded")
		ctx.allocate(n)
	end
	function T.trim(p)
		while #p > 0 and #p[#p] == 0 do
			table.remove(p)
		end
		return p
	end
	function T.primitive(p)
		if #p == 0 then
			return {}, {}
		end
		local content = {}
		for _, coefficient in p do
			ctx.visit(1)
			if #coefficient > 0 then
				content = P.gcd(content, coefficient)
				if #content == 1 then
					break
				end
			end
		end
		assert(#content > 0)
		storage(#p)
		local out = {}
		for i, coefficient in p do
			out[i] = P.quotient(coefficient, content)
		end
		local unit = out[#out][#out[#out]]
		local inverse = R.div(one, unit)
		for i, coefficient in out do
			out[i] = P.scale(coefficient, inverse)
		end
		return out, P.scale(content, unit)
	end
	function T.product(a, b)
		if #a == 0 or #b == 0 then
			return {}
		end
		storage(#a + #b - 1)
		local out = table.create(#a + #b - 1)
		for i = 1, #a + #b - 1 do
			out[i] = {}
		end
		for i, x in a do
			for j, y in b do
				ctx.visit(1)
				out[i + j - 1] = P.add(out[i + j - 1], P.product(x, y))
			end
		end
		return T.trim(out)
	end
	function T.derivative(p)
		storage(math.max(0, #p - 1))
		local out = {}
		for i = 2, #p do
			out[i - 1] = P.scale(p[i], R.number(i - 1))
		end
		return T.trim(out)
	end
	function T.quotient(a, b)
		assert(#b > 0, "Bivariate zero divisor")
		storage(#a)
		local rest = table.clone(a)
		storage(math.max(0, #a - #b + 1))
		local out = table.create(math.max(0, #a - #b + 1))
		for i = 1, #a - #b + 1 do
			out[i] = {}
		end
		while #rest >= #b do
			ctx.visit(1)
			local offset = #rest - #b
			local coefficient = P.quotient(rest[#rest], b[#b])
			out[offset + 1] = coefficient
			for j, value in b do
				rest[offset + j] = P.add(rest[offset + j], P.scale(P.product(coefficient, value), minus))
			end
			T.trim(rest)
		end
		assert(#rest == 0, "Inexact bivariate polynomial quotient")
		return T.trim(out)
	end
	function T.remainder(a, b)
		assert(#b > 0, "Bivariate zero divisor")
		local rest = a
		while #rest >= #b do
			ctx.visit(1)
			local offset = #rest - #b
			local leading = rest[#rest]
			storage(#rest)
			local nextValues = {}
			for i, coefficient in rest do
				local value = P.product(coefficient, b[#b])
				if i > offset then
					value = P.add(value, P.scale(P.product(leading, b[i - offset]), minus))
				end
				nextValues[i] = value
			end
			rest = T.primitive(T.trim(nextValues))
		end
		return rest
	end
	function T.gcd(a, b)
		a, b = T.primitive(a), T.primitive(b)
		while #b > 0 do
			ctx.visit(1)
			a, b = b, T.remainder(a, b)
		end
		return T.primitive(a)
	end
	function T.basis(polynomials)
		local basis, contents = {}, {}
		local function append(p)
			assert(#basis < (ctx.maxPolynomials or 64), "Bivariate basis allocation budget exceeded")
			table.insert(basis, p)
		end
		for i, p in polynomials do
			local primitive, content = T.primitive(p)
			contents[i] = content
			if #primitive <= 1 then
				continue
			end
			local current = T.primitive(T.quotient(primitive, T.gcd(primitive, T.derivative(primitive))))
			local count = #basis
			for j = 1, count do
				local common = T.gcd(current, basis[j])
				if #common > 1 then
					local remainder = T.primitive(T.quotient(basis[j], common))
					if #remainder > 1 then
						basis[j] = remainder
						append(common)
					else
						basis[j] = common
					end
					current = T.primitive(T.quotient(current, common))
					if #current <= 1 then
						break
					end
				end
			end
			if #current > 1 then
				append(current)
			end
		end
		return basis, contents
	end
	return T
end
