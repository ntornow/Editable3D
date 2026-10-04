-- Bounded sparse polynomials over an ordered coefficient field, descending lex order xn first.
return function(R, dimension, ctx)
	local M = { dimension = dimension }
	local zero, one = R.number(0), R.number(1)
	local function key(powers)
		return table.concat(powers, ",")
	end
	local function larger(a, b)
		ctx.visit(1)
		for i = dimension, 1, -1 do
			if a[i] ~= b[i] then
				return a[i] > b[i]
			end
		end
		return false
	end
	local function canonical(terms)
		local map, out = {}, {}
		for _, term in terms do
			ctx.visit(1)
			assert(#term.powers == dimension, "Polynomial variable count mismatch")
			for _, n in term.powers do
				assert(
					n >= 0 and n % 1 == 0 and n <= (ctx.maxDegree or 96),
					"Multivariate degree budget exceeded"
				)
			end
			local k = key(term.powers)
			local old = map[k]
			if old then
				old.value = R.add(old.value, term.value)
			else
				ctx.allocate(1)
				map[k] = { powers = table.clone(term.powers), value = term.value }
			end
		end
		for _, term in map do
			if term.value.sign ~= 0 then
				table.insert(out, term)
			end
		end
		-- A pure Luau merge sort permits work checkpoints to yield while
		-- ordering coefficients. table.sort's C comparator cannot yield.
		local count, width = #out, 1
		local scratch = table.create(count)
		while width < count do
			for first = 1, count, 2 * width do
				local middle = math.min(first + width, count + 1)
				local finish = math.min(first + 2 * width, count + 1)
				local left, right = first, middle
				for slot = first, finish - 1 do
					if right >= finish or (left < middle and larger(out[left].powers, out[right].powers)) then
						scratch[slot] = out[left]
						left += 1
					else
						scratch[slot] = out[right]
						right += 1
					end
				end
			end
			out, scratch = scratch, out
			width *= 2
		end
		return out
	end
	M.make = canonical
	function M.constant(value)
		if value.sign == 0 then
			return {}
		end
		ctx.allocate(1)
		return { { powers = table.create(dimension, 0), value = value } }
	end
	function M.variable(axis)
		local powers = table.create(dimension, 0)
		powers[axis] = 1
		return canonical({ { powers = powers, value = one } })
	end
	function M.add(a, b)
		local terms = table.clone(a)
		for _, t in b do
			table.insert(terms, t)
		end
		return canonical(terms)
	end
	function M.scale(a, value)
		if value.sign == 0 then
			return {}
		end
		local out = {}
		for _, t in a do
			ctx.visit(1)
			table.insert(out, { powers = t.powers, value = R.mul(t.value, value) })
		end
		return canonical(out)
	end
	function M.neg(a)
		return M.scale(a, R.number(-1))
	end
	function M.sub(a, b)
		return M.add(a, M.neg(b))
	end
	function M.product(a, b)
		local terms = {}
		for _, x in a do
			for _, y in b do
				ctx.visit(1)
				ctx.allocate(1)
				local powers = {}
				for i = 1, dimension do
					powers[i] = x.powers[i] + y.powers[i]
				end
				table.insert(terms, { powers = powers, value = R.mul(x.value, y.value) })
			end
		end
		return canonical(terms)
	end
	function M.equal(a, b)
		if #a ~= #b then
			return false
		end
		for i, x in a do
			if key(x.powers) ~= key(b[i].powers) or not R.equal(x.value, b[i].value) then
				return false
			end
		end
		return true
	end
	function M.quotient(a, b)
		assert(#b > 0, "Multivariate zero divisor")
		if #b == 1 then
			local terms = {}
			for _, t in a do
				local powers = {}
				for i = 1, dimension do
					powers[i] = t.powers[i] - b[1].powers[i]
					assert(powers[i] >= 0, "Inexact multivariate monomial quotient")
				end
				table.insert(terms, { powers = powers, value = R.div(t.value, b[1].value) })
			end
			return canonical(terms)
		end
		local remainder, out = a, {}
		while #remainder > 0 do
			ctx.visit(1)
			local powers = {}
			for i = 1, dimension do
				powers[i] = remainder[1].powers[i] - b[1].powers[i]
				assert(powers[i] >= 0, "Inexact multivariate polynomial quotient")
			end
			local term = { powers = powers, value = R.div(remainder[1].value, b[1].value) }
			table.insert(out, term)
			remainder = M.sub(remainder, M.product({ term }, b))
		end
		return canonical(out)
	end
	function M.leadingRemainder(a, b)
		assert(#b > 0)
		local remainder, count = a, 0
		while #remainder > 0 do
			ctx.visit(1)
			local powers = {}
			for i = 1, dimension do
				powers[i] = remainder[1].powers[i] - b[1].powers[i]
				if powers[i] < 0 then
					return remainder, count
				end
			end
			local term = { powers = powers, value = R.div(remainder[1].value, b[1].value) }
			remainder = M.sub(remainder, M.product({ term }, b))
			count += 1
		end
		return remainder, count
	end
	function M.degree(p, axis)
		local n = -1
		for _, t in p do
			n = math.max(n, t.powers[axis])
		end
		return n
	end
	function M.coefficient(p, axis, degree)
		local out = {}
		for _, t in p do
			if t.powers[axis] == degree then
				local powers = table.clone(t.powers)
				powers[axis] = 0
				table.insert(out, { powers = powers, value = t.value })
			end
		end
		return canonical(out)
	end
	function M.truncate(p, axis, degree)
		local out = {}
		for _, t in p do
			if t.powers[axis] <= degree then
				table.insert(out, t)
			end
		end
		return canonical(out)
	end
	function M.derivative(p, axis)
		local out = {}
		for _, t in p do
			if t.powers[axis] > 0 then
				local powers = table.clone(t.powers)
				powers[axis] -= 1
				table.insert(out, { powers = powers, value = R.mul(t.value, R.number(t.powers[axis])) })
			end
		end
		return canonical(out)
	end
	function M.normalize(p)
		if #p == 0 then
			return {}, zero
		end
		return M.scale(p, R.div(one, p[1].value)), p[1].value
	end
	local function scalarKey(value)
		if R.key then
			return R.key(value)
		end
		if type(value) == "number" then
			return tostring(value)
		end
		local a, b = {}, {}
		for _, x in value.n do
			a[#a + 1] = scalarKey(x)
		end
		for _, x in value.d do
			b[#b + 1] = scalarKey(x)
		end
		return value.sign .. ":[" .. table.concat(a, ",") .. "]/[" .. table.concat(b, ",") .. "]"
	end
	function M.key(p)
		local parts = {}
		for _, t in p do
			local r = t.value
			table.insert(parts, key(t.powers) .. "=" .. scalarKey(r))
		end
		return table.concat(parts, ";")
	end
	function M.evaluate(p, values, K, embed)
		K, embed = K or R, embed or function(x)
			return x
		end
		local out = K.number(0)
		for _, term in p do
			local v = embed(term.value)
			for axis, power in term.powers do
				local x = values[axis]
				for _ = 1, power do
					v = K.mul(v, x)
				end
			end
			out = K.add(out, v)
		end
		return out
	end
	function M.specialize(p, axis, values, K, embed)
		local out = table.create(M.degree(p, axis) + 1, K.number(0))
		for _, term in p do
			local v = embed(term.value)
			for i, power in term.powers do
				if i == axis then
					continue
				end
				assert(i < axis or power == 0, "Unbound projected polynomial variable")
				for _ = 1, power do
					v = K.mul(v, values[i])
				end
			end
			local index = term.powers[axis] + 1
			out[index] = K.add(out[index], v)
		end
		while #out > 0 and out[#out].sign == 0 do
			table.remove(out)
		end
		return out
	end
	return M
end
