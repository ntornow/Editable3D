-- Exact homogeneous clipping to the normalized rectangle, followed by correctly rounded binary32 points.
local E = require(script.Parent.ExpansionArithmetic)
local I = require(script.Parent.DirectedInterval)
local X = {}
local function sub(a, b)
	return E.subtract(a, b)
end
local function mul(a, b)
	return E.multiply(a, b)
end
local function same(a, b)
	return E.sign(sub(mul(a[1], b[3]), mul(b[1], a[3]))) == 0
		and E.sign(sub(mul(a[2], b[3]), mul(b[2], a[3]))) == 0
end
local function equalize(p)
	if E.sign(p[3]) < 0 then
		for i = 1, 3 do
			p[i] = E.negate(p[i])
		end
	end
	assert(E.sign(p[3]) > 0, "Invalid homogeneous trim denominator")
	local largest = 0
	for i = 1, 3 do
		for _, q in p[i] do
			largest = math.max(largest, math.abs(q))
		end
	end
	local _, exponent = math.frexp(largest)
	local factor = 2 ^ -exponent
	for i = 1, 3 do
		p[i] = mul(p[i], { factor })
	end
	return p
end
local planes = { { 1, 0, 1 }, { 1, 1, -1 }, { 2, 0, 1 }, { 2, 1, -1 } }
local function trim(points, source, planeIndex, visit)
	local plane = planes[planeIndex]
	local axis, bound, keepSign = plane[1], plane[2], plane[3]
	local out = {}
	local function add(p)
		if #out == 0 or not same(out[#out], p) then
			table.insert(out, p)
		else
			out[#out][4] = p[4]
		end
	end
	for i, a in points do
		visit()
		local b = points[i % #points + 1]
		local fa = sub(a[axis], mul({ bound }, a[3]))
		local fb = sub(b[axis], mul({ bound }, b[3]))
		local sa, sb = E.sign(fa) * keepSign, E.sign(fb) * keepSign
		if sa >= 0 then
			local copy = table.clone(a)
			if sa == 0 and sb < 0 then
				copy[4] = -planeIndex
			end
			add(copy)
		end
		if sa * sb < 0 then
			local owner = a[4]
			local p
			if owner > 0 then
				-- Recompute from the original edge. Chained rational intersections can
				-- grow expansion degree and underflow even when the final UV is ordinary.
				local first, last = source[owner], source[owner % #source + 1]
				local f = sub(first[axis], mul({ bound }, first[3]))
				local g = sub(last[axis], mul({ bound }, last[3]))
				p = {}
				for j = 1, 3 do
					p[j] = sub(mul(first[j], g), mul(last[j], f))
				end
				p[axis] = mul({ bound }, p[3])
				equalize(p)
			else
				local previous = planes[-owner]
				assert(previous[1] ~= axis, "Parallel clip boundaries cannot cross")
				p = { { 0 }, { 0 }, { 1 } }
				p[axis] = { bound }
				p[previous[1]] = { previous[2] }
			end
			p[4] = sb > 0 and owner or -planeIndex
			add(p)
		end
	end
	if #out > 1 and same(out[1], out[#out]) then
		out[1][4] = out[#out][4]
		table.remove(out)
	end
	return out
end
local scratch = buffer.create(4)
local function f32(bits)
	buffer.writeu32(scratch, 0, bits)
	return buffer.readf32(scratch, 0)
end
local function nearest(n, d, visit)
	assert(E.sign(n) >= 0 and E.sign(sub(n, d)) <= 0, "Clipped coordinate leaves the unit interval")
	if E.sign(n) == 0 then
		return 0
	end
	if E.sign(sub(n, d)) == 0 then
		return 1
	end
	local lo, hi = 0, 1065353216
	while hi - lo > 1 do
		visit()
		local mid = math.floor((lo + hi) / 2)
		if E.sign(sub(n, mul({ f32(mid) }, d))) >= 0 then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = f32(lo), f32(hi)
	local sign = E.sign(sub(mul({ 2 }, n), mul({ a + b }, d)))
	return sign < 0 and a or sign > 0 and b or lo % 2 == 0 and a or b
end
local function interval(e)
	local q = { 0, 0 }
	for _, v in e do
		q = I.add(q, { v, v })
	end
	return q
end
local function errorBound(p, v)
	local sum = { 0, 0 }
	for i, n in { v.X, v.Y } do
		local delta = sub(p[i], mul({ n }, p[3]))
		if E.sign(delta) ~= 0 then
			sum = I.add(sum, I.square(I.div(interval(delta), interval(p[3]))))
		end
	end
	return I.sqrt(sum)[2]
end
function X.clip(ring, x, y, visit)
	local points = {}
	for index, p in ring do
		table.insert(points, { E.add({ p.X }, { x }), E.add({ p.Y }, { y }), { 1 }, index })
	end
	local source = points
	for index in planes do
		points = trim(points, source, index, visit)
		if #points < 3 then
			return nil, 0
		end
	end
	-- A zero-area intersection of a simple filled polygon and the rectangle
	-- can only lie on one rectangle side (or corner). Test those exact planes;
	-- avoid multiplying high-degree rational orientation determinants.
	for _, plane in planes do
		local contained = true
		for _, p in points do
			if E.sign(sub(p[plane[1]], mul({ plane[2] }, p[3]))) ~= 0 then
				contained = false
				break
			end
		end
		if contained then
			return nil, 0
		end
	end
	local native, maximum = {}, 0
	for _, p in points do
		local q = Vector2.new(nearest(p[1], p[3], visit), nearest(p[2], p[3], visit))
		assert(#native == 0 or q ~= native[#native], "Clipped trim edge collapses at native precision")
		table.insert(native, q)
		maximum = math.max(maximum, errorBound(p, q))
	end
	assert(native[1] ~= native[#native], "Clipped closing trim edge collapses at native precision")
	return native, maximum
end
return X
