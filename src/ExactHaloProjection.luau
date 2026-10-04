-- Preserve every nonhalo mode exactly by a rational Bezout projector.
return function(R, P, polynomial, powers, visit)
	local one, zero = R.number(1), R.number(0)
	local high, low = polynomial, { one }
	for _, h in { 0.125, 0.0625, 0.03125, 0.015625 } do
		local factor = { R.number(-h), one }
		while #high > 1 do
			local q, rest = P.divide(high, factor)
			if #rest > 0 then
				break
			end
			high = q
			low = P.product(low, factor)
		end
	end
	local a, b = high, low
	local u, v = { one }, {}
	local s, t = {}, { one }
	while #b > 0 do
		local q, rest = P.divide(a, b)
		a, b = b, rest
		u, s = s, P.add(u, P.scale(P.product(q, s), R.number(-1)))
		v, t = t, P.add(v, P.scale(P.product(q, t), R.number(-1)))
	end
	assert(#a == 1 and a[1].sign ~= 0, "Halo projector factors are not coprime")
	local inverse = P.scale(v, R.div(one, a[1]))
	local projector = P.product(inverse, low)
	local residual = P.add(P.product(P.scale(u, R.div(one, a[1])), high), projector)
	assert(#residual == 1 and R.equal(residual[1], one), "Halo Bezout relation failed")
	local values = table.create(#powers[1], zero)
	for j, c in projector do
		assert(powers[j], "Halo projector exceeds retained recurrence powers")
		for i, x in powers[j] do
			visit(1)
			values[i] = R.add(values[i], R.mul(c, x))
		end
	end
	return values, { high = high, low = low, projector = projector }
end
