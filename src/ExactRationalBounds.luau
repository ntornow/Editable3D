-- Enclose an exact rational without converting large integers to float64.
local I = require(script.Parent.DirectedInterval)
return function(R, visit)
	local base = 2 ^ 24
	local function leading(a)
		local result, approximate, factor = { 0, 0 }, 0, 1
		for i = #a, math.max(1, #a - 3), -1 do
			local term = a[i] * factor -- exact dyadic, at most 24 significant bits
			result = I.add(result, { term, term })
			approximate += term
			factor /= base
			visit(1)
		end
		if #a > 4 then
			-- The omitted positive base digits sum to strictly less than base^-3.
			result = I.add(result, { 0, base ^ -3 })
		end
		return result, approximate
	end
	return function(a)
		if a.sign == 0 then
			return { 0, 0 }
		end
		local numerator, approximateN = leading(a.n)
		local denominator, approximateD = leading(a.d)
		local result = I.div(numerator, denominator)
		local approximate = approximateN / approximateD
		local exponent = (#a.n - #a.d) * 24
		while exponent ~= 0 do
			local amount = math.clamp(exponent, -512, 512)
			local scale = 2 ^ amount
			result = I.mul(result, { scale, scale })
			approximate *= scale
			exponent -= amount
			visit(1)
		end
		result[1] = math.max(0, result[1])
		if a.sign < 0 then
			result, approximate = I.neg(result), -approximate
		end
		-- Exact representable values avoid needless widths; this numerical guess
		-- is used only after an exact stored-bit equality decision.
		if approximate == approximate and math.abs(approximate) < math.huge and I.isNormal(approximate) then
			for _, value in { approximate, I.down(approximate), I.up(approximate) } do
				if I.isNormal(value) and R.equal(R.number(value), a) then
					return { value, value }
				end
			end
		end
		return result
	end
end
