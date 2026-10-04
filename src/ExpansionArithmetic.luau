-- Private error-free floating-point expansion operations for native-coordinate predicates.
local splitter = 134217729 -- 2^27+1 for binary64 product splitting

local function twoSum(a, b)
	local x = a + b
	local bv = x - a
	local av = x - bv
	return (a - av) + (b - bv), x
end
local function twoProduct(a, b)
	local x = a * b
	local c = splitter * a
	local ah = c - (c - a)
	local al = a - ah
	c = splitter * b
	local bh = c - (c - b)
	local bl = b - bh
	local error = al * bl - (((x - ah * bh) - al * bh) - ah * bl)
	return error, x
end
local function grow(e, b)
	local out = {}
	local q = b
	for _, a in e do
		local small, large = twoSum(q, a)
		if small ~= 0 then
			table.insert(out, small)
		end
		q = large
	end
	if q ~= 0 or #out == 0 then
		table.insert(out, q)
	end
	return out
end
local function add(a, b)
	local out = a
	for _, value in b do
		out = grow(out, value)
	end
	return out
end
local function negate(a)
	local out = {}
	for i, value in a do
		out[i] = -value
	end
	return out
end
local function subtract(a, b)
	return add(a, negate(b))
end
local function multiply(a, b)
	local out = { 0 }
	for _, x in a do
		for _, y in b do
			local small, large = twoProduct(x, y)
			out = grow(out, small)
			out = grow(out, large)
		end
	end
	return out
end
local function difference(a, b)
	local tail, head = twoSum(a, -b)
	return tail ~= 0 and { tail, head } or { head }
end
local function estimate(e)
	local sum = 0
	for _, x in e do
		sum += x
	end
	return sum
end
local function sign(x)
	return x > 0 and 1 or x < 0 and -1 or 0
end

return {
	add = add,
	subtract = subtract,
	multiply = multiply,
	difference = difference,
	negate = negate,
	estimate = estimate,
	sign = function(e)
		return sign(e[#e])
	end,
}
