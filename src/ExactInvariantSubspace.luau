-- Exact scalar invariant basis shared by the three coordinate columns.
return function(R, initial, advance, options, visit)
	local zero = R.number(0)
	local size = #initial / 3
	if options.normalAllocate then
		options.normalAllocate(10 * size * size)
	end
	local basis, columns = {}, {}
	local function express(source)
		local value = table.clone(source)
		local coefficients = {}
		for i, row in basis do
			local factor = value[row.pivot]
			coefficients[i] = factor
			if factor.sign ~= 0 then
				for j, x in value do
					value[j] = R.sub(x, R.mul(factor, row.value[j]))
				end
			end
		end
		local pivot
		for i, x in value do
			if x.sign ~= 0 then
				pivot = i
				break
			end
		end
		if pivot then
			assert(
				#basis < (options.maxNormalSubspaceDimension or 128),
				"Normal invariant subspace budget exceeded"
			)
			local factor = value[pivot]
			for i, x in value do
				value[i] = R.div(x, factor)
			end
			basis[#basis + 1] = { pivot = pivot, value = value }
			coefficients[#basis] = factor
		end
		visit(size)
		return coefficients
	end
	local initialColumns = {}
	for axis = 1, 3 do
		local column = {}
		for i = 1, size do
			column[i] = initial[(i - 1) * 3 + axis]
		end
		initialColumns[axis] = express(column)
	end
	local cursor = 1
	while cursor <= #basis do
		if options.checkpoint then
			options.checkpoint({ stage = "normalInvariantSubspace", dimension = #basis, column = cursor })
		end
		columns[cursor] = express(advance(basis[cursor].value))
		cursor += 1
	end
	local dimension = #basis
	local coordinate = {}
	for i = 1, dimension do
		for axis = 1, 3 do
			coordinate[(i - 1) * 3 + axis] = initialColumns[axis][i] or zero
		end
	end
	local function restore(v)
		local out = table.create(size * 3, zero)
		for i, row in basis do
			for j, x in row.value do
				for axis = 1, 3 do
					local k = (j - 1) * 3 + axis
					out[k] = R.add(out[k], R.mul(x, v[(i - 1) * 3 + axis]))
				end
			end
		end
		return out
	end
	local recovered = restore(coordinate)
	for i, x in initial do
		assert(R.equal(recovered[i], x), "Invariant source representation failed")
	end
	for i, row in basis do
		local expected = advance(row.value)
		for j, x in expected do
			local sum = zero
			for k, b in basis do
				sum = R.add(sum, R.mul(b.value[j], columns[i][k] or zero))
			end
			assert(R.equal(sum, x), "Invariant operator representation failed")
		end
	end
	local function step(v)
		local out = table.create(dimension * 3, zero)
		for j, column in columns do
			for i, x in column do
				if x.sign ~= 0 then
					for axis = 1, 3 do
						local k = (i - 1) * 3 + axis
						out[k] = R.add(out[k], R.mul(x, v[(j - 1) * 3 + axis]))
					end
				end
			end
		end
		return out
	end
	return { dimension = dimension, basis = basis, initial = coordinate, advance = step, restore = restore }
end
