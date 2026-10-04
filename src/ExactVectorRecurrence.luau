-- Exact minimal vector recurrence for a caller-supplied linear evolution.
return function(R, initial, advance, dimension, options, visit)
	local limit = math.min(dimension, options.maxNormalKrylovDegree or 128)
	local estimated = 2 * #initial * (limit + 1) + 4 * (limit + 1) ^ 2 + 20 * #initial
	assert(
		estimated <= (options.maxExactCoefficients or 1000000),
		"Normal recurrence coefficient budget exceeded"
	)
	if options.normalAllocate then
		options.normalAllocate(estimated)
	end
	local zero, one = R.number(0), R.number(1)
	local basis, powers = {}, {}
	local current = initial
	for degree = 0, limit do
		if options.checkpoint then
			options.checkpoint({
				stage = "normalRecurrence",
				degree = degree,
				dimension = dimension,
				coordinates = #initial,
			})
		end
		visit(#initial)
		powers[degree + 1] = current
		local value = table.clone(current)
		local representation = table.create(degree + 1, zero)
		representation[degree + 1] = one
		for _, row in basis do
			local factor = value[row.pivot]
			if factor.sign ~= 0 then
				for i, x in value do
					value[i] = R.sub(x, R.mul(factor, row.value[i]))
				end
				for i, x in row.polynomial do
					representation[i] = R.sub(representation[i], R.mul(factor, x))
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
		if not pivot then
			for i in initial do
				local sum = zero
				for j, x in representation do
					sum = R.add(sum, R.mul(x, powers[j][i]))
				end
				assert(sum.sign == 0, "Normal recurrence relation did not verify")
			end
			return representation, powers, estimated
		end
		local factor = value[pivot]
		for i, x in value do
			value[i] = R.div(x, factor)
		end
		for i, x in representation do
			representation[i] = R.div(x, factor)
		end
		basis[#basis + 1] = { pivot = pivot, value = value, polynomial = representation }
		current = advance(current)
		assert(#current == #initial, "Normal recurrence state changed dimension")
	end
	error("Normal recurrence degree budget exceeded")
end
