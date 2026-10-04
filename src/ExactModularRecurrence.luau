-- Modular candidates become evidence only after an exact full-state identity.
return function(R, initial, advance, dimension, options, visit)
	local cap = math.min(dimension, options.maxNormalKrylovDegree or 128)
	assert(
		3 * #initial * (cap + 2) + 8 * (cap + 1) ^ 2 <= (options.maxExactCoefficients or 1000000),
		"Modular recurrence coefficient budget exceeded"
	)
	if options.normalAllocate then
		options.normalAllocate(3 * #initial * (cap + 2) + 8 * (cap + 1) ^ 2)
	end
	local zero, one = R.number(0), R.number(1)
	local powers = { initial }
	local function power(k)
		while #powers < k do
			powers[#powers + 1] = advance(powers[#powers])
			assert(#powers[#powers] == #initial)
		end
		return powers[k]
	end
	local prime = 16777215
	local function nextPrime()
		while true do
			prime -= 2
			assert(prime > 2, "Normal recurrence prime budget exhausted")
			local good = true
			for d = 3, math.floor(math.sqrt(prime)), 2 do
				visit(1)
				if prime % d == 0 then
					good = false
					break
				end
			end
			if good then
				return prime
			end
		end
	end
	local function modulo(limbs, p)
		local value = 0
		for i = #limbs, 1, -1 do
			visit(1)
			value = (value * 16777216 + limbs[i]) % p
		end
		return value
	end
	local function inverse(x, p)
		assert(x ~= 0)
		local exponent = p - 2
		local out = 1
		while exponent > 0 do
			visit(1)
			if exponent % 2 == 1 then
				out = (out * x) % p
			end
			exponent = math.floor(exponent / 2)
			if exponent > 0 then
				x = (x * x) % p
			end
		end
		return out
	end
	local function modular(p)
		local cache = {}
		local basis = {}
		local scalar = 1
		for degree = 0, cap do
			local vector = power(degree + 1)
			local value = {}
			for i, x in vector do
				if x.sign == 0 then
					value[i] = 0
				else
					local denominator = modulo(x.d, p)
					if denominator == 0 then
						return nil
					end
					local inv = cache[denominator]
					if not inv then
						inv = inverse(denominator, p)
						cache[denominator] = inv
					end
					value[i] = (((modulo(x.n, p) * inv) % p) * scalar * x.sign) % p
				end
			end
			local representation = table.create(degree + 1, 0)
			representation[degree + 1] = 1
			for _, row in basis do
				local factor = value[row.pivot]
				if factor ~= 0 then
					for i, x in value do
						value[i] = (x - factor * row.value[i]) % p
					end
					for i, x in row.polynomial do
						representation[i] = (representation[i] - factor * x) % p
					end
					visit(#value + #row.polynomial)
				end
			end
			local pivot
			for i, x in value do
				if x ~= 0 then
					pivot = i
					break
				end
			end
			if not pivot then
				return representation
			end
			local inv = inverse(value[pivot], p)
			for i, x in value do
				value[i] = (x * inv) % p
			end
			for i, x in representation do
				representation[i] = (x * inv) % p
			end
			visit(#value + #representation)
			basis[#basis + 1] = { pivot = pivot, value = value, polynomial = representation }
			scalar = (scalar * (options.normalRecurrenceScale or 4096)) % p
		end
		error("Modular normal recurrence degree budget exceeded")
	end
	local modulus = one
	local residues = {}
	local degree = -1
	local accepted = 0
	local function candidate()
		local out = {}
		local denominator = one
		for i = degree + 1, 1, -1 do
			local x = residues[i]
			if R.compare(R.mul(x, R.number(2)), modulus) > 0 then
				x = R.sub(x, modulus)
			end
			out[i] = R.div(x, denominator)
			denominator = R.mul(denominator, R.number(options.normalRecurrenceScale or 4096))
		end
		return out
	end
	local function verify(polynomial)
		for axis in initial do
			local sum = zero
			for i, x in polynomial do
				if x.sign ~= 0 then
					sum = R.add(sum, R.mul(x, powers[i][axis]))
				end
			end
			if sum.sign ~= 0 then
				return false
			end
		end
		return true
	end
	for attempt = 1, (options.maxNormalPrimes or 128) do
		local p = nextPrime()
		local polynomial = modular(p)
		if options.checkpoint then
			options.checkpoint({
				stage = "modularNormalRecurrence",
				prime = attempt,
				degree = polynomial and #polynomial - 1,
			})
		end
		if not polynomial or #polynomial - 1 < degree then
			continue
		end
		if #polynomial - 1 > degree then
			degree = #polynomial - 1
			modulus = one
			residues = table.create(degree + 1, zero)
			accepted = 0
		end
		local multiplier = inverse(modulo(modulus.n, p), p)
		for i, x in polynomial do
			local delta = ((x - modulo(residues[i].n, p)) * multiplier) % p
			residues[i] = R.add(residues[i], R.mul(modulus, R.number(delta)))
		end
		modulus = R.mul(modulus, R.number(p))
		accepted += 1
		if accepted <= 2 or accepted % 4 == 0 or attempt == (options.maxNormalPrimes or 128) then
			local result = candidate()
			if verify(result) then
				return result, powers, { primes = attempt, accepted = accepted, degree = degree }
			end
		end
	end
	error("Normal recurrence reconstruction budget exceeded")
end
