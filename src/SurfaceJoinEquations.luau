-- Private full-border rational C0/C1/C2 equations with fixed positive weights.
local Basis = require(script.Parent.SurfaceJoinBasis)
local EPS = 2.220446049250313e-16
local function choose(n, k)
	local x = 1
	for i = 1, math.min(k, n - k) do
		x = x * (n - i + 1) / i
	end
	return x
end
return function(a, b, order, ratio, total, ctx, O)
	local function multiply(x, y)
		local p, q, out = #x - 1, #y - 1, {}
		for k = 0, p + q do
			local sum = O.value(0)
			for i = math.max(0, k - q), math.min(p, k) do
				local factor = choose(p, i) * choose(q, k - i) / choose(p + q, k)
				sum = O.add(
					sum,
					O.mul(O.mul(x[i + 1], y[k - i + 1]), O.value(factor, factor * 16 * (p + q + 1) * EPS))
				)
			end
			out[k + 1] = sum
		end
		return out
	end
	local function combine(x, y, factor)
		assert(#x == #y)
		local out = {}
		for i = 1, #x do
			out[i] = O.add(x[i], O.mul(y[i], O.value(factor)))
		end
		return out
	end
	local function numerator(h, w, d)
		if d == 0 then
			return h[1]
		end
		if d == 1 then
			return combine(multiply(h[2], w[1]), multiply(h[1], w[2]), -1)
		end
		local result = combine(multiply(h[3], multiply(w[1], w[1])), multiply(h[2], multiply(w[1], w[2])), -2)
		result = combine(result, multiply(h[1], multiply(w[1], w[3])), -1)
		return combine(result, multiply(h[1], multiply(w[2], w[2])), 2)
	end
	local breaks = Basis.breaks(a, b)
	assert(#breaks - 1 <= ctx.maxSpans, "Join span budget exceeded")
	local aa, bb = Basis.extract(a, breaks, ctx, O), Basis.extract(b, breaks, ctx, O)
	local equations, groups = {}, {}
	for span = 1, #breaks - 1 do
		ctx.check("equations")
		local ha, wa = Basis.fields(a, aa[span], order, total, ctx, O)
		local hb, wb = Basis.fields(b, bb[span], order, total, ctx, O)
		local da, db = { O.value(1) }, { O.value(1) }
		for d = 0, order do
			da, db = multiply(da, wa[1]), multiply(db, wb[1])
			local denominator = multiply(da, db)
			local lower = math.huge
			for _, w in denominator do
				lower = math.min(lower, w[1] - w[2])
			end
			local group = { order = d, span = span, lower = lower, rows = {} }
			ctx.allocate(#equations + #denominator, total)
			assert(#equations + #denominator <= ctx.maxConstraints, "Join constraint budget exceeded")
			for k = 1, #denominator do
				group.rows[k] = {}
			end
			for id = 1, total do
				local ah, bh = {}, {}
				for derivative = 1, order + 1 do
					ah[derivative], bh[derivative] = ha[derivative][id], hb[derivative][id]
				end
				local left, right = multiply(numerator(ah, wa, d), db), multiply(numerator(bh, wb, d), da)
				local row = combine(left, right, (d == 1 and 1 or -1) * ratio ^ d)
				for k, value in row do
					group.rows[k][id] = value
				end
			end
			for _, row in group.rows do
				table.insert(equations, row)
			end
			table.insert(groups, group)
		end
	end
	return equations, groups, #breaks - 1
end
