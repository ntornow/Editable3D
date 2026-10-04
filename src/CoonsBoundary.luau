-- Double homogeneous extraction; native Vector3 rounding happens only at output.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local B = {}
function B.new(curve, origin, ctx, O)
	assert(
		type(curve) == "table" and curve.kind == "curve",
		"Coons boundaries require ordinary rational curves"
	)
	assert(#curve.points <= ctx.maxControls, "Coons input control budget exceeded")
	assert(#curve.points <= ctx.maxIntermediateControls, "Coons intermediate control budget exceeded")
	local config = table.clone(curve)
	config.maxControls = ctx.maxControls
	local c = N.curve(curve.points, curve.degree, config)
	local n, p = #c.points, c.degree
	local a, b = c.knots[p + 1], c.knots[n + 1]
	local maximum, minimum, extent = 0, math.huge, 0
	for _, w in c.weights do
		maximum = math.max(maximum, w)
		minimum = math.min(minimum, w)
	end
	local out = { degree = p, points = {}, knots = {}, constant = true, normalizationAllowance = 0 }
	local largestError, minGap = 0, math.huge
	for i, k in c.knots do
		local q = O.div(O.sub(O.value(k), O.value(a)), O.sub(O.value(b), O.value(a)))
		out.knots[i] = q[1]
		if k == a then
			out.knots[i] = 0
		elseif k == b then
			out.knots[i] = 1
		end
		largestError = math.max(largestError, q[2])
		if i > 1 and k > c.knots[i - 1] then
			assert(out.knots[i] > out.knots[i - 1], "Coons knot normalization lost a distinct interval")
			minGap = math.min(minGap, out.knots[i] - out.knots[i - 1])
		end
	end
	for i, point in c.points do
		local w = c.weights[i] == maximum and O.value(1) or O.div(O.value(c.weights[i]), O.value(maximum))
		assert(w[1] > 0, "Coons normalized weight underflow")
		out.constant = out.constant and c.weights[i] == maximum
		local h, relative = {}, {}
		for k, axis in { "X", "Y", "Z" } do
			local d = O.sub(O.value(point[axis]), O.value(origin[axis]))
			relative[k] = d
			h[k] = O.mul(d, w)
			extent = math.max(extent, math.abs(d[1]))
		end
		h[4] = w
		out.points[i] = h
		if c.clamped and i == 1 then
			out.startPoint, out.startNative = relative, point
		end
		if c.clamped and i == n then
			out.endPoint, out.endNative = relative, point
		end
	end
	-- Knot arithmetic affects the boundary's parameterization as well as controls.
	-- A deliberately conservative degree/gap/weight condition allowance is kept
	-- separate from homogeneous coefficient and native-control reconstruction error.
	local ratio = maximum / minimum
	if a == 0 and b == 1 then
		largestError = 0
	end
	out.normalizationAllowance = largestError == 0 and 0
		or math.sqrt(3) * extent * 32 * p * (p + 1) * largestError / minGap * ratio * ratio
	assert(U.finite(out.normalizationAllowance), "Coons boundary conditioning exceeds numeric range")
	return out
end
local function insert(c, u, boundary, ctx, O)
	local n, p, k, s = #c.points, c.degree, nil, 0
	for i, v in c.knots do
		ctx.visit()
		if v == u then
			s += 1
		end
		if i < #c.knots and v <= u and u < c.knots[i + 1] then
			k = i
		end
	end
	assert(k and s < (boundary and p + 1 or p), "Coons knot extraction failed")
	assert(n + 1 <= ctx.maxIntermediateControls, "Coons intermediate control budget exceeded")
	local points = {}
	for i = 1, k - p do
		ctx.visit()
		points[i] = c.points[i]
	end
	for i = k - s, n do
		ctx.visit()
		points[i + 1] = c.points[i]
	end
	for i = k - p + 1, k - s do
		local t =
			O.div(O.sub(O.value(u), O.value(c.knots[i])), O.sub(O.value(c.knots[i + p]), O.value(c.knots[i])))
		assert(U.finite(t[1]) and t[1] >= 0 and t[1] <= 1, "Coons knot insertion is outside its span")
		local h = {}
		for channel = 1, 4 do
			h[channel] = O.mix(c.points[i - 1][channel], c.points[i][channel], t)
		end
		points[i] = h
	end
	c.points = points
	table.insert(c.knots, k + 1, u)
end
local function multiplicity(c, t, ctx)
	local count = 0
	for _, k in c.knots do
		ctx.visit()
		if k == t then
			count += 1
		end
	end
	return count
end
function B.clamp(c, ctx, O)
	for _, t in { 0, 1 } do
		for _ = multiplicity(c, t, ctx) + 1, c.degree + 1 do
			insert(c, t, true, ctx, O)
		end
	end
	local first, last = 1, #c.knots
	while c.knots[first] < 0 do
		first += 1
	end
	while c.knots[last] > 1 do
		last -= 1
	end
	local knots, points = {}, {}
	for i = first, last do
		ctx.visit()
		table.insert(knots, c.knots[i])
	end
	for i = first, last - c.degree - 1 do
		ctx.visit()
		table.insert(points, c.points[i])
	end
	c.knots, c.points = knots, points
end
function B.breaks(a, b)
	local seen = { [0] = true, [1] = true }
	for _, c in { a, b } do
		for _, k in c.knots do
			if k > 0 and k < 1 then
				seen[k] = true
			end
		end
	end
	return U.keys(seen)
end
function B.extract(c, breaks, ctx, O)
	local expected = (#breaks - 1) * c.degree + 1
	assert(expected <= ctx.maxIntermediateControls, "Coons intermediate control budget exceeded")
	for _, t in breaks do
		if t > 0 and t < 1 then
			for _ = multiplicity(c, t, ctx) + 1, c.degree do
				insert(c, t, false, ctx, O)
			end
		end
	end
	local segments = {}
	for i = 1, #breaks - 1 do
		local data = {}
		for j = 1, c.degree + 1 do
			data[j] = c.points[(i - 1) * c.degree + j]
		end
		segments[i] = data
	end
	return segments
end
return B
