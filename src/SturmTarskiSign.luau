-- Exact sign at the unique root in an open isolating interval.
-- Sturm--Tarski: Var(SRemS(f,f'*g);low)-Var(...;high).
return function(R, P, root, g)
	if root.exact then
		return P.evaluate(g, root.low).sign
	end
	local f = root.analysis.squarefree
	assert(
		P.evaluate(f, root.low).sign ~= 0 and P.evaluate(f, root.high).sign ~= 0,
		"Tarski isolator endpoints must not be roots"
	)
	local function normalize(p)
		if #p == 0 then
			return {}
		end
		local leading = p[#p]
		if leading.sign < 0 then
			leading = R.neg(leading)
		end
		return P.scale(p, R.div(R.number(1), leading))
	end
	-- Q/f and (Q mod f)/f have identical pole indices. Horner reduction
	-- computes f'*g modulo f without exceeding f's degree at any step.
	local derivative = P.derivative(f)
	local product = {}
	for i = #g, 1, -1 do
		product = P.add(P.product(product, { R.number(0), R.number(1) }), P.scale(derivative, g[i]))
		local _, remainder = P.divide(product, f)
		product = remainder
	end
	local a, b = f, normalize(product)
	local sequence = { a }
	while #b > 0 do
		sequence[#sequence + 1] = b
		local _, remainder = P.divide(a, b)
		a, b = b, normalize(P.scale(remainder, R.number(-1)))
	end
	local function variation(x)
		local count, previous = 0, 0
		for _, p in sequence do
			local sign = P.evaluate(p, x).sign
			if sign ~= 0 then
				if previous ~= 0 and sign ~= previous then
					count += 1
				end
				previous = sign
			end
		end
		return count
	end
	local value = variation(root.low) - variation(root.high)
	assert(value >= -1 and value <= 1, "Tarski sign requires a unique isolated root")
	return value
end
