-- Exact divisibility plus a modular degree bound certifies the reconstructed gcd.
-- The normalized first polynomial must be monic integral after x -> x/scale.
return function(R, P, visit, options)
	local original = P.gcd
	local zero, one = R.number(0), R.number(1)
	local scale = R.number(options.normalRecurrenceScale or 4096)
	local function modulo(x, p)
		local n, d = 0, 0
		for i = #x.n, 1, -1 do
			n = (n * 16777216 + x.n[i]) % p
			visit(1)
		end
		for i = #x.d, 1, -1 do
			d = (d * 16777216 + x.d[i]) % p
			visit(1)
		end
		return n * x.sign, d
	end
	local function inverse(x, p)
		local out = 1
		local e = p - 2
		while e > 0 do
			visit(1)
			if e % 2 == 1 then
				out = (out * x) % p
			end
			e = math.floor(e / 2)
			if e > 0 then
				x = (x * x) % p
			end
		end
		return out
	end
	local function trim(p)
		while #p > 0 and p[#p] == 0 do
			table.remove(p)
		end
		return p
	end
	local function monic(p, prime)
		if #p == 0 then
			return p
		end
		local inv = inverse(p[#p], prime)
		for i, x in p do
			p[i] = (x * inv) % prime
		end
		return p
	end
	local function remainder(a, b, prime)
		a = table.clone(a)
		local inv = inverse(b[#b], prime)
		while #a >= #b do
			local k = #a - #b
			local factor = (a[#a] * inv) % prime
			for i, x in b do
				a[k + i] = (a[k + i] - factor * x) % prime
			end
			trim(a)
			visit(#b)
		end
		return a
	end
	local function convert(poly, prime)
		local out = {}
		for i, x in poly do
			local n, d = modulo(x, prime)
			if d == 0 then
				return nil
			end
			out[i] = (n * inverse(d, prime)) % prime
		end
		if #out > 0 and out[#out] == 0 then
			return nil
		end
		return out
	end
	return function(a, b)
		if #a == 0 or #b == 0 or math.min(#a, #b) <= 3 then
			return original(a, b)
		end
		if options.normalAllocate then
			options.normalAllocate(10 * (#a + #b))
		end
		local aa = {}
		local factor = one
		for i = #a, 1, -1 do
			aa[i] = R.mul(R.div(a[i], a[#a]), factor)
			factor = R.mul(factor, scale)
			if #aa[i].d ~= 1 or aa[i].d[1] ~= 1 then
				return original(a, b)
			end
		end
		-- Multiplying the second polynomial by a nonzero scalar does not change its gcd.
		local bb = {}
		factor = one
		for i = #b, 1, -1 do
			bb[i] = R.mul(b[i], factor)
			factor = R.mul(factor, scale)
		end
		local best = math.huge
		local residues = {}
		local modulus = one
		local accepted = 0
		local prime = 16777215
		for attempt = 1, (options.maxNormalPrimes or 128) do
			repeat
				prime -= 2
				assert(prime > 2, "Polynomial gcd prime budget exhausted")
				local good = true
				for d = 3, math.floor(math.sqrt(prime)), 2 do
					visit(1)
					if prime % d == 0 then
						good = false
						break
					end
				end
				if good then
					break
				end
			until false
			local u, v = convert(aa, prime), convert(bb, prime)
			if not u or not v then
				continue
			end
			while #v > 0 do
				u, v = v, remainder(u, v, prime)
			end
			local g = monic(u, prime)
			local d = #g - 1
			if d == 0 then
				return { one }
			end
			if d > best then
				continue
			end
			if d < best then
				best = d
				residues = table.create(d + 1, zero)
				modulus = one
				accepted = 0
			end
			local mm = modulo(modulus, prime)
			local multiplier = inverse(mm, prime)
			for i, x in g do
				local n = modulo(residues[i], prime)
				local delta = ((x - n) * multiplier) % prime
				residues[i] = R.add(residues[i], R.mul(modulus, R.number(delta)))
			end
			modulus = R.mul(modulus, R.number(prime))
			accepted += 1
			if accepted <= 2 or accepted % 4 == 0 or attempt == (options.maxNormalPrimes or 128) then
				local candidate = {}
				factor = one
				for i = #residues, 1, -1 do
					local x = residues[i]
					if R.compare(R.mul(x, R.number(2)), modulus) > 0 then
						x = R.sub(x, modulus)
					end
					candidate[i] = R.div(x, factor)
					factor = R.mul(factor, scale)
				end
				local _, ra = P.divide(a, candidate)
				if #ra == 0 then
					local _, rb = P.divide(b, candidate)
					if #rb == 0 then
						return candidate
					end
				end
			end
		end
		error("Polynomial gcd reconstruction budget exceeded")
	end
end
