-- Exact affine ruling equations in the two local profile parameters.
return function(a, b, R, P, T, ctx)
	local minus = R.number(-1)
	local function subtract(a, b)
		return P.add(a, P.scale(b, minus))
	end
	local function outer(a, b)
		if #a == 0 or #b == 0 then
			return {}
		end
		ctx.allocate(#b)
		local out = {}
		for i, x in b do
			out[i] = P.scale(a, x)
		end
		return T.trim(out)
	end
	local function difference(a, b)
		ctx.allocate(math.max(#a, #b))
		local out = {}
		for i = 1, math.max(#a, #b) do
			out[i] = subtract(a[i] or {}, b[i] or {})
		end
		return T.trim(out)
	end
	local endpointScales = {}
	local function normalized(h)
		assert(h[4][1].sign > 0, "Positive ruled endpoint weight required")
		local factor = R.div(R.number(1), h[4][1])
		table.insert(endpointScales, factor)
		local out = {}
		for i, p in h do
			out[i] = P.scale(p, factor)
		end
		return out
	end
	local a0, a1, b0, b1 =
		normalized(a.endpoints[1]),
		normalized(a.endpoints[2]),
		normalized(b.endpoints[1]),
		normalized(b.endpoints[2])
	local wa, wb = P.product(a0[4], a1[4]), P.product(b0[4], b1[4])
	local equations = {}
	for axis = 1, 3 do
		local deltaA = subtract(P.product(a1[axis], a0[4]), P.product(a0[axis], a1[4]))
		local deltaB = subtract(P.product(b1[axis], b0[4]), P.product(b0[axis], b1[4]))
		equations[axis] = {
			a = outer(deltaA, wb),
			b = outer(wa, P.scale(deltaB, minus)),
			c = difference(outer(P.product(a0[axis], a1[4]), wb), outer(wa, P.product(b0[axis], b1[4]))),
		}
	end
	-- A common divisor of a strictly positive endpoint-weight product never
	-- vanishes on the supported profile interval. Remove only those factors.
	local function transpose(p)
		local degree = 0
		for _, row in p do
			degree = math.max(degree, #row)
		end
		ctx.allocate(degree)
		local out = {}
		for i = 1, degree do
			local row = {}
			ctx.allocate(#p)
			for j = 1, #p do
				row[j] = p[j][i] or R.number(0)
			end
			out[i] = P.trim(row)
		end
		return T.trim(out)
	end
	local function cancel(e, weight)
		local g = weight
		for _, name in { "a", "b", "c" } do
			for _, row in e[name] do
				if #g <= 1 then
					break
				end
				g = P.gcd(g, row)
			end
		end
		if #g > 1 then
			for _, name in { "a", "b", "c" } do
				for i, row in e[name] do
					local quotient, remainder = P.divide(row, g)
					assert(#remainder == 0, "Positive weight factor division failed")
					e[name][i] = quotient
				end
			end
		end
		return #g > 1 and g or { R.number(1) }
	end
	for _, e in equations do
		local firstDivisor = cancel(e, wa)
		for _, name in { "a", "b", "c" } do
			e[name] = transpose(e[name])
		end
		local secondDivisor = cancel(e, wb)
		for _, name in { "a", "b", "c" } do
			e[name] = transpose(e[name])
		end
		local factor
		for _, name in { "a", "b", "c" } do
			local p = e[name]
			if #p > 0 then
				factor = R.div(R.number(1), p[#p][#p[#p]])
				break
			end
		end
		e.reduction = {
			endpointScales = endpointScales,
			profileDivisors = { firstDivisor, secondDivisor },
			positiveWeightProducts = { wa, wb },
			constantScale = factor or R.number(1),
		}
		if factor then
			for _, name in { "a", "b", "c" } do
				for i, row in e[name] do
					e[name][i] = P.scale(row, factor)
				end
			end
		end
	end
	return equations
end
