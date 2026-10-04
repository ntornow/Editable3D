-- A nonzero resultant after a degree-preserving finite-field specialization
-- certifies coprimality over Q(x1,...,x[k-1])[xk]. Failure is inconclusive.
return function(M, ctx)
	local prime = 65521
	local function power(a, n)
		local value = 1
		while n > 0 do
			ctx.visit(1)
			if n % 2 == 1 then
				value = value * a % prime
			end
			a = a * a % prime
			n = math.floor(n / 2)
		end
		return value
	end
	local function integer(limbs)
		local n = 0
		for i = #limbs, 1, -1 do
			ctx.visit(1)
			n = (n * 16777216 + limbs[i]) % prime
		end
		return n
	end
	local residues = {}
	local function rational(q)
		if residues[q] ~= nil then
			return residues[q]
		end
		local denominator = integer(q.d)
		if denominator == 0 then
			return nil
		end
		local n = q.sign * integer(q.n) * power(denominator, prime - 2) % prime
		ctx.allocate(1)
		residues[q] = n
		return n
	end
	local function trim(p)
		while #p > 0 and p[#p] == 0 do
			table.remove(p)
		end
		return p
	end
	local function specialize(p, axis, trial)
		local out = table.create(M.degree(p, axis) + 1, 0)
		ctx.allocate(#out)
		for _, term in p do
			local v = rational(term.value)
			if v == nil then
				return nil
			end
			for i = 1, axis - 1 do
				v = v * power(i + trial, term.powers[i]) % prime
			end
			local j = term.powers[axis] + 1
			out[j] = (out[j] + v) % prime
		end
		return trim(out)
	end
	return function(a, b, axis)
		if type(a[1].value.d[1]) ~= "number" or type(b[1].value.d[1]) ~= "number" then
			return false
		end
		for trial = 1, 3 do
			local x, y = specialize(a, axis, trial), specialize(b, axis, trial)
			if not x or not y then
				return false
			end
			if #x ~= M.degree(a, axis) + 1 or #y ~= M.degree(b, axis) + 1 then
				continue
			end
			while #y > 0 do
				local inverse = power(y[#y], prime - 2)
				while #x >= #y do
					local shift = #x - #y
					local factor = x[#x] * inverse % prime
					for i = 1, #y do
						ctx.visit(1)
						x[i + shift] = (x[i + shift] - factor * y[i]) % prime
					end
					trim(x)
				end
				x, y = y, x
			end
			if #x == 1 then
				return true
			end
		end
		return false
	end
end
