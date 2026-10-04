-- Divide several root-polynomial values by one positive algebraic value.
return function(R, P, F, values, denominator)
	local one, minus = R.number(1), R.number(-1)
	local sign = F.sign(denominator)
	assert(sign ~= 0)
	if sign < 0 then
		denominator = P.scale(denominator, minus)
	end
	if F.root.exact then
		local d = P.evaluate(denominator, F.root.low)
		local out = {}
		for i, p in values do
			local x = R.div(P.evaluate(p, F.root.low), d)
			out[i] = x.sign == 0 and {} or { x }
		end
		return out
	end
	F.localize(denominator)
	local modulus = F.modulus()
	local function reduce(p)
		if #p < #modulus then
			return p
		end
		local _, r = P.divide(p, modulus)
		return r
	end
	local a, b = modulus, reduce(denominator)
	local u, v = {}, { one }
	while #b > 0 do
		local q, r = P.divide(a, b)
		local nextValue = reduce(P.add(u, P.scale(P.product(q, v), minus)))
		if #r > 0 then
			local scale = R.div(one, r[#r])
			r = P.scale(r, scale)
			nextValue = P.scale(nextValue, scale)
		end
		a, b, u, v = b, r, v, nextValue
	end
	assert(#a == 1 and a[1].sign ~= 0, "Algebraic normalization denominator not invertible")
	local inverse = P.scale(u, R.div(one, a[1]))
	local out = {}
	for i, p in values do
		out[i] = reduce(P.product(reduce(p), inverse))
	end
	return out
end
