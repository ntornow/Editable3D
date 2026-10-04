-- Internal ordered rational-function field K(e), 0<e<every positive K value.
return function(R, visit, allocate, maxDegree)
	allocate = allocate or function() end
	local P = require(script.Parent.ExactPolynomialRoots)(R, visit, maxDegree or 128, allocate)
	local zero, one = R.number(0), R.number(1)
	local K = {}
	local unit = { one }
	local function lowSign(p)
		for _, x in p do
			if x.sign ~= 0 then
				return x.sign
			end
		end
		return 0
	end
	local function make(n, d)
		assert(#d > 0, "Infinitesimal zero denominator")
		if #n == 0 then
			return { n = {}, d = unit, sign = 0 }
		end
		if d == unit then
			allocate(#n + 1)
			return { n = n, d = unit, sign = lowSign(n) }
		end
		if #d == 1 then
			local out = P.scale(n, R.div(one, d[1]))
			allocate(#out + 1)
			return { n = out, d = unit, sign = lowSign(out) }
		end
		local g = P.gcd(n, d)
		n, d = P.quotient(n, g), P.quotient(d, g)
		local scale = R.div(one, d[#d])
		n, d = P.scale(n, scale), P.scale(d, scale)
		allocate(#n + #d)
		return { n = n, d = d, sign = lowSign(n) * lowSign(d) }
	end
	function K.rational(x)
		allocate(2)
		return { n = x.sign == 0 and {} or { x }, d = unit, sign = x.sign }
	end
	function K.number(x)
		return K.rational(R.number(x))
	end
	function K.neg(x)
		return { n = P.scale(x.n, R.number(-1)), d = x.d, sign = -x.sign }
	end
	function K.add(a, b)
		if a.sign == 0 then
			return b
		elseif b.sign == 0 then
			return a
		end
		if a.d == unit and b.d == unit then
			return make(P.add(a.n, b.n), unit)
		end
		return make(P.add(P.product(a.n, b.d), P.product(b.n, a.d)), P.product(a.d, b.d))
	end
	function K.sub(a, b)
		return K.add(a, K.neg(b))
	end
	function K.mul(a, b)
		if a.sign == 0 or b.sign == 0 then
			return K.number(0)
		end
		return make(P.product(a.n, b.n), a.d == unit and b.d == unit and unit or P.product(a.d, b.d))
	end
	function K.div(a, b)
		assert(b.sign ~= 0)
		return make(P.product(a.n, b.d), P.product(a.d, b.n))
	end
	function K.compare(a, b)
		return K.sub(a, b).sign
	end
	function K.equal(a, b)
		return K.compare(a, b) == 0
	end
	K.fromFraction = make
	K.epsilon = make({ zero, one }, { one })
	return K
end
