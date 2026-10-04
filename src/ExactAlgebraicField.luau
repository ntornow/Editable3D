-- ordered algebraic coefficient field at one isolated root.
return function(R, P, F, allocate)
	allocate = allocate or function() end
	local zero, one, minus = R.number(0), R.number(1), R.number(-1)
	local function constant(x)
		allocate(x.sign == 0 and 1 or 2)
		return { n = x.sign == 0 and {} or { x }, d = { one }, sign = x.sign }
	end
	local K = {}
	local function make(n, d)
		if #n <= 1 and #d == 1 then
			return constant(R.div(n[1] or zero, d[1]))
		end
		if F.root.exact then
			return constant(R.div(P.evaluate(n, F.root.low), P.evaluate(d, F.root.low)))
		end
		local modulus = F.root.analysis.squarefree
		if #n >= #modulus then
			local _, rest = P.divide(n, modulus)
			n = rest
		end
		if #d >= #modulus then
			local _, rest = P.divide(d, modulus)
			d = rest
		end
		if #n <= 1 and #d == 1 then
			return constant(R.div(n[1] or zero, d[1]))
		end
		local ds = F.sign(d)
		assert(ds ~= 0, "Algebraic field zero denominator")
		local ns = F.sign(n)
		if ns == 0 then
			return constant(zero)
		end
		local g = P.gcd(n, d)
		n, d = P.quotient(n, g), P.quotient(d, g)
		local scalar = R.div(one, d[#d])
		n, d = P.scale(n, scalar), P.scale(d, scalar)
		return { n = n, d = d, sign = ns * ds }
	end
	function K.rational(x)
		return constant(x)
	end
	function K.number(x)
		return constant(R.number(x))
	end
	function K.fromPolynomial(p)
		allocate(1)
		return make(p, { one })
	end
	function K.fromFraction(n, d)
		return make(n, d)
	end
	function K.neg(x)
		return { n = P.scale(x.n, minus), d = x.d, sign = -x.sign }
	end
	function K.add(a, b)
		return make(P.add(P.product(a.n, b.d), P.product(b.n, a.d)), P.product(a.d, b.d))
	end
	function K.sub(a, b)
		return K.add(a, K.neg(b))
	end
	function K.mul(a, b)
		return make(P.product(a.n, b.n), P.product(a.d, b.d))
	end
	function K.div(a, b)
		assert(b.sign ~= 0, "Algebraic field division by zero")
		return make(P.product(a.n, b.d), P.product(a.d, b.n))
	end
	function K.compare(a, b)
		if #a.n <= 1 and #a.d == 1 and #b.n <= 1 and #b.d == 1 then
			return R.compare(R.div(a.n[1] or zero, a.d[1]), R.div(b.n[1] or zero, b.d[1]))
		end
		return F.compare(a, b)
	end
	function K.equal(a, b)
		return K.compare(a, b) == 0
	end
	function K.toRational(value)
		assert(#value.n <= 1 and #value.d == 1, "Rational constant representation required")
		return R.div(value.n[1] or zero, value.d[1])
	end
	return K
end
