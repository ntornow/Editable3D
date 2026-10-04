-- Private bounded exact signed rationals over base-2^24 integer limbs.
-- No floating products exceed 2^49; float64 input is decoded from stored bits.
return function(visit, maxBits)
	maxBits = maxBits or 8192
	assert(
		type(maxBits) == "number" and maxBits % 1 == 0 and maxBits >= 1,
		"Positive exact arithmetic bit cap required"
	)
	assert(type(visit) == "function", "Exact arithmetic work callback required")
	local BASE = 2 ^ 24
	local function trim(a)
		while #a > 0 and a[#a] == 0 do
			table.remove(a)
		end
		return a
	end
	local function bits(a)
		if #a == 0 then
			return 0
		end
		local x, n = a[#a], 0
		while x > 0 do
			x = math.floor(x / 2)
			n += 1
		end
		return (#a - 1) * 24 + n
	end
	local function cap(n)
		assert(n <= maxBits, "Exact rational bit budget exceeded")
		visit(1)
	end
	local function cmp(a, b)
		visit(1)
		if #a ~= #b then
			return #a < #b and -1 or 1
		end
		for i = #a, 1, -1 do
			visit(1)
			if a[i] ~= b[i] then
				return a[i] < b[i] and -1 or 1
			end
		end
		return 0
	end
	local function add(a, b)
		cap(math.max(bits(a), bits(b)) + 1)
		local out, carry = {}, 0
		for i = 1, math.max(#a, #b) do
			visit(1)
			local sum = (a[i] or 0) + (b[i] or 0) + carry
			out[i], carry = sum % BASE, math.floor(sum / BASE)
		end
		if carry > 0 then
			table.insert(out, carry)
		end
		return out
	end
	local function sub(a, b)
		assert(cmp(a, b) >= 0, "Negative unsigned difference")
		local out, carry = {}, 0
		for i = 1, #a do
			visit(1)
			local delta = a[i] - (b[i] or 0) - carry
			carry = delta < 0 and 1 or 0
			out[i] = delta + carry * BASE
		end
		assert(carry == 0)
		return trim(out)
	end
	local function mul(a, b)
		if #a == 0 or #b == 0 then
			return {}
		end
		if #a == 1 and a[1] == 1 then
			visit(1)
			return b
		end
		if #b == 1 and b[1] == 1 then
			visit(1)
			return a
		end
		cap(bits(a) + bits(b))
		local out = table.create(#a + #b, 0)
		for i, x in a do
			local carry = 0
			for j, y in b do
				visit(1)
				local k = i + j - 1
				local product = x * y + out[k] + carry
				out[k], carry = product % BASE, math.floor(product / BASE)
			end
			out[i + #b] = carry
		end
		return trim(out)
	end
	local function shl(a, n)
		if #a == 0 then
			return {}
		end
		cap(bits(a) + n)
		local whole, part = math.floor(n / 24), n % 24
		local out = table.create(whole, 0)
		local carry, factor = 0, 2 ^ part
		for _, value in a do
			visit(1)
			local x = value * factor + carry
			table.insert(out, x % BASE)
			carry = math.floor(x / BASE)
		end
		if carry > 0 then
			table.insert(out, carry)
		end
		return out
	end
	local function shr(a, n)
		local whole, part = math.floor(n / 24), n % 24
		if whole >= #a then
			return {}
		end
		local out, carry = {}, 0
		local factor = 2 ^ part
		for i = #a, whole + 1, -1 do
			visit(1)
			local x = a[i] + carry * BASE
			out[i - whole] = math.floor(x / factor)
			carry = x % factor
		end
		return trim(out)
	end
	local function zeros(a)
		assert(#a > 0)
		local count = 0
		for _, x in a do
			visit(1)
			if x == 0 then
				count += 24
			else
				while x % 2 == 0 do
					x /= 2
					count += 1
				end
				return count
			end
		end
		error("Zero trailing count")
	end
	local function gcd(a, b)
		if #a == 0 then
			return b
		end
		if #b == 0 then
			return a
		end
		if #a == 1 and a[1] == 1 or #b == 1 and b[1] == 1 then
			visit(1)
			return { 1 }
		end
		local az, bz = zeros(a), zeros(b)
		local common = math.min(az, bz)
		a, b = shr(a, az), shr(b, bz)
		if #a == 1 and a[1] == 1 or #b == 1 and b[1] == 1 then
			visit(1)
			return shl({ 1 }, common)
		end
		while #b > 0 do
			if cmp(a, b) > 0 then
				a, b = b, a
			end
			b = sub(b, a)
			if #b > 0 then
				b = shr(b, zeros(b))
			end
		end
		return shl(a, common)
	end
	local function quotient(a, b)
		assert(#b > 0, "Exact rational zero divisor")
		if #b == 1 and b[1] == 1 then
			return a
		end
		if cmp(a, b) == 0 then
			return { 1 }
		end
		if #b == 1 then
			local out, remainder = table.create(#a, 0), 0
			for i = #a, 1, -1 do
				visit(1)
				-- The combined dividend is below BASE^2=2^48, exactly stored.
				-- A noninteger quotient stays at least 1/(BASE-1) from an
				-- integer, more than the binary64 rounding at this magnitude.
				local value = remainder * BASE + a[i]
				local digit = math.floor(value / b[1])
				out[i], remainder = digit, value - digit * b[1]
			end
			assert(remainder == 0, "Nonexact integer division")
			return trim(out)
		end
		local shift = zeros(b)
		if shift > 0 and bits(b) == shift + 1 then
			assert(#a == 0 or zeros(a) >= shift, "Nonexact integer division")
			return shr(a, shift)
		end
		local out = table.create(#a, 0)
		local rest = {}
		for i = bits(a) - 1, 0, -1 do
			visit(1)
			rest = shl(rest, 1)
			local bit = math.floor(a[math.floor(i / 24) + 1] / 2 ^ (i % 24)) % 2
			if bit == 1 then
				rest = add(rest, { 1 })
			end
			if cmp(rest, b) >= 0 then
				rest = sub(rest, b)
				local index = math.floor(i / 24) + 1
				out[index] += 2 ^ (i % 24)
			end
		end
		assert(#rest == 0, "Nonexact integer division")
		return trim(out)
	end
	local function small(n)
		local out = {}
		while n > 0 do
			table.insert(out, n % BASE)
			n = math.floor(n / BASE)
		end
		return out
	end
	local R = {}
	local zero = { sign = 0, n = {}, d = { 1 } }
	local function make(sign, n, d)
		if #n == 0 then
			return zero
		end
		local g = gcd(n, d)
		return { sign = sign, n = quotient(n, g), d = quotient(d, g) }
	end
	function R.number(x)
		assert(
			type(x) == "number" and x == x and math.abs(x) < math.huge,
			"Finite exact rational input required"
		)
		local bufferValue = buffer.create(8)
		buffer.writef64(bufferValue, 0, x)
		local lo, hi = buffer.readu32(bufferValue, 0), buffer.readu32(bufferValue, 4)
		local sign = hi >= 2 ^ 31 and -1 or 1
		local exponent = math.floor(hi / 2 ^ 20) % 2048
		local mantissa = (hi % 2 ^ 20) * 2 ^ 32 + lo
		if exponent > 0 then
			mantissa += 2 ^ 52
		end
		if mantissa == 0 then
			return zero
		end
		local shift = (exponent == 0 and -1022 or exponent - 1023) - 52
		local n, d = small(mantissa), { 1 }
		if shift < 0 then
			local remove = math.min(-shift, zeros(n))
			n = shr(n, remove)
			shift += remove
		end
		if shift >= 0 then
			n = shl(n, shift)
		else
			d = shl(d, -shift)
		end
		cap(math.max(bits(n), bits(d)))
		return { sign = sign, n = n, d = d }
	end
	function R.neg(a)
		return { sign = -a.sign, n = a.n, d = a.d }
	end
	function R.add(a, b)
		if a.sign == 0 then
			return b
		end
		if b.sign == 0 then
			return a
		end
		local g = gcd(a.d, b.d)
		local ad, bd = quotient(a.d, g), quotient(b.d, g)
		local an, bn = mul(a.n, bd), mul(b.n, ad)
		local n, sign
		if a.sign == b.sign then
			n, sign = add(an, bn), a.sign
		else
			local order = cmp(an, bn)
			if order == 0 then
				return zero
			end
			n, sign = order > 0 and sub(an, bn) or sub(bn, an), order > 0 and a.sign or b.sign
		end
		local common = gcd(n, g)
		return { sign = sign, n = quotient(n, common), d = mul(ad, quotient(b.d, common)) }
	end
	function R.sub(a, b)
		return R.add(a, R.neg(b))
	end
	function R.mul(a, b)
		if a.sign == 0 or b.sign == 0 then
			return zero
		end
		local g, h = gcd(a.n, b.d), gcd(b.n, a.d)
		return {
			sign = a.sign * b.sign,
			n = mul(quotient(a.n, g), quotient(b.n, h)),
			d = mul(quotient(a.d, h), quotient(b.d, g)),
		}
	end
	function R.div(a, b)
		assert(b.sign ~= 0, "Exact rational division by zero")
		return R.mul(a, { sign = b.sign, n = b.d, d = b.n })
	end
	function R.equal(a, b)
		return a.sign == b.sign and cmp(a.n, b.n) == 0 and cmp(a.d, b.d) == 0
	end
	function R.compare(a, b)
		if a.sign ~= b.sign then
			return a.sign < b.sign and -1 or 1
		end
		if a.sign == 0 then
			return 0
		end
		if cmp(a.d, b.d) == 0 then
			return a.sign * cmp(a.n, b.n)
		end
		return a.sign * cmp(mul(a.n, b.d), mul(b.n, a.d))
	end
	function R.fraction(sign, n, d)
		assert(sign == 1 or sign == -1 or sign == 0 and #n == 0, "Invalid rational sign")
		assert(#d > 0 and d[#d] > 0, "Positive rational denominator required")
		for _, value in { n, d } do
			for _, digit in value do
				visit(1)
				assert(
					type(digit) == "number" and digit % 1 == 0 and digit >= 0 and digit < BASE,
					"Invalid integer limb"
				)
			end
		end
		assert(#n == 0 or n[#n] > 0, "Unnormalized integer numerator")
		cap(math.max(bits(n), bits(d)))
		return make(sign, table.clone(n), table.clone(d))
	end
	function R.homogeneous(values)
		local denominator = { 1 }
		for _, x in values do
			local g = gcd(denominator, x.d)
			denominator = mul(quotient(denominator, g), x.d)
		end
		local out = {}
		for i, x in values do
			out[i] = x.sign == 0 and zero
				or { sign = x.sign, n = mul(x.n, quotient(denominator, x.d)), d = { 1 } }
		end
		return out, { sign = 1, n = denominator, d = { 1 } }
	end
	return R
end
