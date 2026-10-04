-- Private outward intervals, including runtimes that flush subnormal arithmetic.
-- Adjacent-double helpers operate on stored bits. Arithmetic endpoints widen tiny
-- values to normal bounds before and after each operation, preventing FTZ loss.
local I = {}
local scratch = buffer.create(8)
buffer.writeu32(scratch, 4, 1048576)
local NORMAL = buffer.readf64(scratch, 0)
local function bits(x)
	buffer.writef64(scratch, 0, x)
	return buffer.readu32(scratch, 0), buffer.readu32(scratch, 4)
end
local function fromBits(low, high)
	buffer.writeu32(scratch, 0, low)
	buffer.writeu32(scratch, 4, high)
	return buffer.readf64(scratch, 0)
end
local function step(x, up)
	local low, high = bits(x)
	local negative = high >= 2147483648
	local magnitude = high % 2147483648
	assert(magnitude < 2146435072 or (magnitude == 2146435072 and low == 0), "NaN interval scalar")
	if magnitude == 0 and low == 0 then
		return fromBits(1, up and 0 or 2147483648)
	end
	if magnitude == 2146435072 and low == 0 and up ~= negative then
		return x
	end
	if up ~= negative then
		if low == 4294967295 then
			low, high = 0, high + 1
		else
			low += 1
		end
	else
		if low == 0 then
			low, high = 4294967295, high - 1
		else
			low -= 1
		end
	end
	return fromBits(low, high)
end
function I.up(x)
	return step(x, true)
end
function I.down(x)
	return step(x, false)
end
function I.isNormal(x)
	local low, high = bits(x)
	local magnitude = high % 2147483648
	return (magnitude == 0 and low == 0) or (magnitude >= 1048576 and magnitude < 2146435072)
end
local function normalBound(x, upper)
	if x >= NORMAL or x <= -NORMAL then
		return x
	end
	local low, high = bits(x)
	local magnitude = high % 2147483648
	assert(magnitude < 2146435072, "NaN interval scalar")
	if magnitude == 0 and low == 0 then
		return 0
	end
	if high >= 2147483648 then
		return upper and 0 or -NORMAL
	end
	return upper and NORMAL or 0
end
local function outward(x, upper)
	-- An arithmetic zero may be a flushed nonzero result. Enclose the entire
	-- subnormal range without relying on floating comparisons of its members.
	if x < NORMAL and x > -NORMAL then
		return upper and NORMAL or -NORMAL
	end
	return normalBound(step(x, upper), upper)
end
function I.leq(a, b)
	local al, ah = bits(a)
	local bl, bh = bits(b)
	if ah % 2147483648 == 0 and al == 0 then
		ah = 0
	end
	if bh % 2147483648 == 0 and bl == 0 then
		bh = 0
	end
	local an, bn = ah >= 2147483648, bh >= 2147483648
	if an ~= bn then
		return an
	end
	if ah == bh then
		return an and al >= bl or not an and al <= bl
	end
	return an and ah > bh or not an and ah < bh
end
function I.new(lo, hi)
	hi = hi == nil and lo or hi
	assert(lo == lo and hi == hi and I.leq(lo, hi), "Ordered non-NaN interval required")
	return { normalBound(lo, false), normalBound(hi, true) }
end
function I.whole()
	return { -math.huge, math.huge }
end
function I.add(a, b)
	local al, ah, bl, bh =
		normalBound(a[1], false), normalBound(a[2], true), normalBound(b[1], false), normalBound(b[2], true)
	-- Exact identities need no arithmetic rounding, after FTZ-safe normalization.
	if al == 0 and ah == 0 then
		return { bl, bh }
	end
	if bl == 0 and bh == 0 then
		return { al, ah }
	end
	if al == ah and bl == bh and al == -bl and math.abs(al) < math.huge then
		return { 0, 0 }
	end
	local lo, hi = al + bl, ah + bh
	if lo ~= lo or hi ~= hi then
		return I.whole()
	end
	return { outward(lo, false), outward(hi, true) }
end
function I.neg(a)
	return { -normalBound(a[2], true), -normalBound(a[1], false) }
end
function I.sub(a, b)
	return I.add(a, I.neg(b))
end
local function product(a, b)
	if a == 0 or b == 0 then
		return 0
	end
	return a * b
end
function I.mul(a, b)
	local al, ah, bl, bh =
		normalBound(a[1], false), normalBound(a[2], true), normalBound(b[1], false), normalBound(b[2], true)
	if (al == 0 and ah == 0) or (bl == 0 and bh == 0) then
		return { 0, 0 }
	end
	if al == 1 and ah == 1 then
		return { bl, bh }
	end
	if bl == 1 and bh == 1 then
		return { al, ah }
	end
	if al == -1 and ah == -1 then
		return { -bh, -bl }
	end
	if bl == -1 and bh == -1 then
		return { -ah, -al }
	end
	local x, y, z, w = product(al, bl), product(al, bh), product(ah, bl), product(ah, bh)
	return { outward(math.min(x, y, z, w), false), outward(math.max(x, y, z, w), true) }
end
function I.div(a, b)
	local lo, hi = normalBound(b[1], false), normalBound(b[2], true)
	if lo <= 0 and hi >= 0 then
		return I.whole()
	end
	if lo == 1 and hi == 1 then
		return I.new(a[1], a[2])
	end
	if lo == -1 and hi == -1 then
		return I.neg(a)
	end
	if lo == hi and math.abs(lo) < math.huge and a[1] == lo and a[2] == hi then
		return { 1, 1 }
	end
	return I.mul(a, { outward(1 / hi, false), outward(1 / lo, true) })
end
function I.square(a)
	local lo, hi = normalBound(a[1], false), normalBound(a[2], true)
	if lo == 0 and hi == 0 then
		return { 0, 0 }
	end
	local x, y = lo * lo, hi * hi
	local lower = lo <= 0 and hi >= 0 and 0 or math.max(0, outward(math.min(x, y), false))
	return { lower, outward(math.max(x, y), true) }
end
function I.sqrt(a)
	local lo, hi = normalBound(a[1], false), normalBound(a[2], true)
	assert(lo >= 0, "Square root interval must be nonnegative")
	if lo == 0 and hi == 0 then
		return { 0, 0 }
	end
	return { math.max(0, outward(math.sqrt(lo), false)), outward(math.sqrt(hi), true) }
end
function I.intersect(a, b)
	local lo, hi =
		math.max(normalBound(a[1], false), normalBound(b[1], false)),
		math.min(normalBound(a[2], true), normalBound(b[2], true))
	return lo <= hi and { lo, hi } or nil
end
function I.hull(a, b)
	return {
		math.min(normalBound(a[1], false), normalBound(b[1], false)),
		math.max(normalBound(a[2], true), normalBound(b[2], true)),
	}
end
function I.contains(a, x)
	return I.leq(a[1], x) and I.leq(x, a[2])
end
function I.zero(a)
	return normalBound(a[1], false) <= 0 and normalBound(a[2], true) >= 0
end
function I.mid(a)
	assert(math.abs(a[1]) < math.huge and math.abs(a[2]) < math.huge, "Finite midpoint interval required")
	return math.clamp(a[1] * 0.5 + a[2] * 0.5, a[1], a[2])
end
function I.width(a)
	return outward(normalBound(a[2], true) - normalBound(a[1], false), true)
end
return I
