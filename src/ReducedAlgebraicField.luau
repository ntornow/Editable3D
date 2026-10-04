-- Internal localized number-field arithmetic with polynomial representatives.
-- A denominator's common factors with the defining modulus exclude the chosen
-- root (its sign was proved nonzero), so those factors can be removed safely.
return function(R, P, F, allocate)
	allocate = allocate or function() end
	local zero, one = R.number(0), R.number(1)
	local K = {}
	local function constant(x)
		allocate(x.sign == 0 and 1 or 2)
		return { n = x.sign == 0 and {} or { x }, d = { one }, sign = x.sign }
	end
	local function remainder(p, modulus)
		if #p < #modulus then
			return p
		end
		local _, rest = P.divide(p, modulus)
		return rest
	end
	local function productMod(a, b, modulus)
		local out = {}
		a = remainder(a, modulus)
		for i = #b, 1, -1 do
			out = P.add(P.product(out, { zero, one }), P.scale(a, b[i]))
			out = remainder(out, modulus)
		end
		return out
	end
	local function inverse(d, modulus)
		local a, b = modulus, d
		local u, v = {}, { one }
		while #b > 0 do
			local q, r = P.divide(a, b)
			local nextValue = P.add(u, P.scale(productMod(q, v, modulus), R.number(-1)))
			if #r > 0 then
				local scale = R.div(one, r[#r])
				r = P.scale(r, scale)
				nextValue = P.scale(nextValue, scale)
			end
			a, b, u, v = b, r, v, nextValue
		end
		assert(#a == 1, "Localized algebraic denominator must be invertible")
		return P.scale(u, R.div(one, a[1]))
	end
	local function make(n, d, knownSign)
		if #n <= 1 and #d == 1 then
			return constant(R.div(n[1] or zero, d[1]))
		end
		if F.root.exact then
			return constant(R.div(P.evaluate(n, F.root.low), P.evaluate(d, F.root.low)))
		end
		local modulus = F.root.analysis.squarefree
		n, d = remainder(n, modulus), remainder(d, modulus)
		local ds = F.sign(d)
		assert(ds ~= 0, "Algebraic field zero denominator")
		if #d == 1 then
			n = P.scale(n, R.div(one, d[1]))
		else
			local common = P.gcd(modulus, d)
			if #common > 1 then
				assert(F.sign(common) ~= 0, "Removed modulus factor must exclude the selected root")
				local previous = modulus
				modulus = P.quotient(modulus, common)
				F.root.modulusReductions = F.root.modulusReductions or {}
				F.root.modulusReductions[#F.root.modulusReductions + 1] =
					{ before = previous, discarded = common, after = modulus }
				F.root.analysis = P.analyze(modulus)
				n, d = remainder(n, modulus), remainder(d, modulus)
			end
			n = productMod(n, inverse(d, modulus), modulus)
		end
		local sign = knownSign or F.sign(n)
		if sign == 0 then
			return constant(zero)
		end
		if #n <= 1 then
			return constant(n[1] or zero)
		end
		allocate(#n + 1)
		return { n = n, d = { one }, sign = sign }
	end
	K.rational = constant
	function K.number(x)
		return constant(R.number(x))
	end
	function K.fromPolynomial(p)
		return make(p, { one })
	end
	K.fromFraction = make
	function K.neg(x)
		return { n = P.scale(x.n, R.number(-1)), d = { one }, sign = -x.sign }
	end
	function K.add(a, b)
		if a.sign == 0 then
			return b
		elseif b.sign == 0 then
			return a
		end
		return make(P.add(a.n, b.n), { one }, a.sign == b.sign and a.sign or nil)
	end
	function K.sub(a, b)
		return K.add(a, K.neg(b))
	end
	function K.mul(a, b)
		if a.sign == 0 then
			return a
		elseif b.sign == 0 then
			return b
		end
		return make(productMod(a.n, b.n, F.root.analysis.squarefree), { one }, a.sign * b.sign)
	end
	function K.div(a, b)
		assert(b.sign ~= 0, "Algebraic field division by zero")
		return make(a.n, b.n, a.sign * b.sign)
	end
	function K.compare(a, b)
		return K.sub(a, b).sign
	end
	function K.equal(a, b)
		return K.compare(a, b) == 0
	end
	function K.toRational(x)
		assert(#x.n <= 1, "Rational constant representation required")
		return x.n[1] or zero
	end
	return K
end
