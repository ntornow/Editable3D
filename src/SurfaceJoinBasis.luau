-- Private homogeneous transverse jets in a common along-border Bernstein partition.
local U = require(script.Parent.Util)
local C = require(script.Parent.Cyclic)
local Core = require(script.Parent.SurfaceEditCore)
local B = {}
function B.new(surface, boundary, reverse, offset, ctx, O)
	local s = Core.prepare(surface, { maxControls = ctx.maxControls })
	local crossU, start = Core.boundary(s, boundary)
	local ordinary = s.kind == "cyclicSurface" and C.surfaceToNURBS(s) or s
	local cross, along = crossU and "U" or "V", crossU and "V" or "U"
	local n, p = crossU and #ordinary.control or #ordinary.control[1], ordinary["degree" .. cross]
	local k = ordinary["knots" .. cross]
	local t = start and k[p + 1] or k[n + 1]
	local scale = O.sub(O.value(k[n + 1]), O.value(k[p + 1]))
	local b, d, dd = {}, {}, {}
	for i = 1, n + p do
		b[i] = O.value(
			((not start and k[i] < t and k[i + 1] >= t) or (start and k[i] <= t and k[i + 1] > t)) and 1 or 0
		)
		d[i], dd[i] = O.value(0), O.value(0)
	end
	for degree = 1, p do
		local nb, nd, ndd = {}, {}, {}
		for i = 1, n + p - degree do
			local a, z = k[i + degree] - k[i], k[i + degree + 1] - k[i + 1]
			local function ratio(x, y)
				return y == 0 and O.value(0) or O.div(x, O.value(y, math.abs(y) * 8e-16))
			end
			local x = ratio(O.sub(O.value(t), O.value(k[i])), a)
			local y = ratio(O.sub(O.value(k[i + degree + 1]), O.value(t)), z)
			nb[i] = O.add(O.mul(x, b[i]), O.mul(y, b[i + 1]))
			nd[i] =
				O.add(O.add(O.mul(x, d[i]), O.mul(y, d[i + 1])), O.sub(ratio(b[i], a), ratio(b[i + 1], z)))
			ndd[i] = O.add(
				O.add(O.mul(x, dd[i]), O.mul(y, dd[i + 1])),
				O.mul(O.value(2), O.sub(ratio(d[i], a), ratio(d[i + 1], z)))
			)
		end
		b, d, dd = nb, nd, ndd
	end
	local jets, magnitude = { b, d, dd }, { 0, 0, 0 }
	for i = 1, n do
		d[i] = O.mul(d[i], O.mul(scale, O.value(start and -1 or 1)))
		dd[i] = O.mul(dd[i], O.mul(scale, scale))
		for order = 1, 3 do
			magnitude[order] += math.abs(jets[order][i][1]) + jets[order][i][2]
		end
	end
	local count, degree = crossU and #ordinary.control[1] or #ordinary.control, ordinary["degree" .. along]
	local raw, knots = ordinary["knots" .. along], {}
	local a, z = raw[degree + 1], raw[count + 1]
	local largest, gap = 0, math.huge
	for i, knot in raw do
		local q = O.div(O.sub(O.value(knot), O.value(a)), O.sub(O.value(z), O.value(a)))
		knots[i] = knot == a and 0 or knot == z and 1 or q[1]
		largest = math.max(largest, q[2])
		if i > 1 and knot > raw[i - 1] then
			assert(knots[i] > knots[i - 1], "Join knot normalization lost a distinct interval")
			gap = math.min(gap, knots[i] - knots[i - 1])
		end
	end
	if a == 0 and z == 1 then
		largest = 0
	end
	if reverse then
		local reversed = {}
		for i = 1, #knots do
			local knot = knots[#knots + 1 - i]
			local value = O.sub(O.value(1), O.value(knot))
			reversed[i] = value[1]
			if knot ~= 0 and knot ~= 1 then
				largest = math.max(largest, value[2])
			end
			if i > 1 and knot < knots[#knots + 2 - i] then
				assert(reversed[i] > reversed[i - 1], "Join reversal lost a distinct knot interval")
			end
		end
		knots = reversed
	end
	local maxWeight, minWeight = 0, math.huge
	for _, row in ordinary.weights do
		for _, w in row do
			maxWeight, minWeight = math.max(maxWeight, w), math.min(minWeight, w)
		end
	end
	local weights, ids = {}, {}
	for j = 1, count do
		weights[j], ids[j] = {}, {}
		local alongIndex = reverse and count + 1 - j or j
		for i = 1, n do
			local u, v = crossU and i or alongIndex, crossU and alongIndex or i
			local w = O.div(O.value(ordinary.weights[u][v]), O.value(maxWeight))
			assert(w[1] > 0, "Join normalized weight underflow")
			weights[j][i] = w
			ids[j][i] = offset + ((u - 1) % #s.control) * #s.control[1] + (v - 1) % #s.control[1] + 1
		end
	end
	ctx.visit(n * count)
	return {
		source = s,
		degree = degree,
		count = count,
		crossCount = n,
		knots = knots,
		weights = weights,
		ids = ids,
		jets = jets,
		magnitude = magnitude,
		knotError = largest,
		minGap = gap,
		weightRatio = maxWeight / minWeight,
		reverse = reverse,
	}
end
function B.breaks(a, b)
	local set = { [0] = true, [1] = true }
	for _, m in { a, b } do
		for _, k in m.knots do
			if k > 0 and k < 1 then
				set[k] = true
			end
		end
	end
	return U.keys(set)
end
function B.extract(m, breaks, ctx, O)
	local knots, p, rows = table.clone(m.knots), m.degree, {}
	ctx.allocate(m.count, m.count)
	for i = 1, m.count do
		rows[i] = {}
		for j = 1, m.count do
			rows[i][j] = O.value(i == j and 1 or 0)
		end
	end
	for _, t in breaks do
		local count = 0
		for _, knot in knots do
			if knot == t then
				count += 1
			end
		end
		for _ = count + 1, (t == 0 or t == 1) and p + 1 or p do
			local span
			for i = 1, #knots - 1 do
				if knots[i] <= t and t < knots[i + 1] then
					span = i
				end
			end
			assert(span, "Join knot extraction lost a span")
			ctx.allocate(#rows + 1, m.count)
			local out = {}
			for i = 1, span - p do
				out[i] = rows[i]
			end
			for i = span - count, #rows do
				out[i + 1] = rows[i]
			end
			for i = span - p + 1, span - count do
				local alpha = O.div(
					O.sub(O.value(t), O.value(knots[i])),
					O.sub(O.value(knots[i + p]), O.value(knots[i]))
				)
				out[i] = {}
				for j = 1, m.count do
					out[i][j] = O.mix(rows[i - 1][j], rows[i][j], alpha)
				end
			end
			rows = out
			table.insert(knots, span + 1, t)
			count += 1
		end
	end
	local first = 1
	while knots[first] < 0 do
		first += 1
	end
	local spans = {}
	ctx.allocate((#breaks - 1) * (p + 1), m.count)
	for span = 1, #breaks - 1 do
		spans[span] = {}
		for i = 1, p + 1 do
			spans[span][i] = rows[first + (span - 1) * p + i - 1]
		end
	end
	return spans
end
function B.fields(m, coefficients, order, total, ctx, O)
	ctx.allocate((m.degree + 1) * (order + 1), total + 1)
	local homogeneous, weights = {}, {}
	for d = 1, order + 1 do
		homogeneous[d], weights[d] = {}, {}
		for id = 1, total do
			homogeneous[d][id] = {}
		end
		for k, row in coefficients do
			local w = O.value(0)
			for id = 1, total do
				homogeneous[d][id][k] = O.value(0)
			end
			for j, along in row do
				for i = 1, m.crossCount do
					local c = O.mul(O.mul(along, m.jets[d][i]), m.weights[j][i])
					local id = m.ids[j][i]
					homogeneous[d][id][k] = O.add(homogeneous[d][id][k], c)
					w = O.add(w, c)
				end
			end
			weights[d][k] = w
		end
	end
	return homogeneous, weights
end
return B
