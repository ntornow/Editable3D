-- Private minimum-norm equality solve by pivoted, reorthogonalized row QR.
-- Fresh dense arrays are owned by the caller. No normal equations are formed.
return function(rows, rhs, columns, ctx, tolerance)
	local count, rank = #rows, 0
	local q, beta = {}, {}
	local function dot(a, b)
		local sum = 0
		for j = 1, columns do
			sum += a[j] * b[j]
		end
		ctx.visit(columns)
		return sum
	end
	-- Row scaling keeps degree, derivative units and equation gauges independent.
	for i, row in rows do
		local scale = 0
		for _, value in row do
			assert(value == value and math.abs(value) < math.huge, "Nonfinite join equation")
			scale = math.max(scale, math.abs(value))
		end
		if scale > 0 then
			for j = 1, columns do
				row[j] /= scale
			end
			for k = 1, 3 do
				rhs[i][k] /= scale
			end
		end
		local norm = math.sqrt(dot(row, row))
		if norm > 0 then
			for j = 1, columns do
				row[j] /= norm
			end
			for k = 1, 3 do
				rhs[i][k] /= norm
			end
		end
	end
	for step = 1, math.min(count, columns) do
		ctx.check("solve")
		local pivot, largest = step, 0
		for i = step, count do
			local norm2 = dot(rows[i], rows[i])
			if norm2 > largest then
				pivot, largest = i, norm2
			end
		end
		local norm = math.sqrt(largest)
		if norm <= tolerance then
			break
		end
		rows[step], rows[pivot] = rows[pivot], rows[step]
		rhs[step], rhs[pivot] = rhs[pivot], rhs[step]
		local basis, value = rows[step], rhs[step]
		for j = 1, columns do
			basis[j] /= norm
		end
		for k = 1, 3 do
			value[k] /= norm
		end
		q[step], beta[step], rank = basis, value, step
		for i = step + 1, count do
			-- Two passes keep nearly dependent border constraints orthogonal.
			for _ = 1, 2 do
				local projection = dot(rows[i], basis)
				for j = 1, columns do
					rows[i][j] -= projection * basis[j]
				end
				for k = 1, 3 do
					rhs[i][k] -= projection * value[k]
				end
				ctx.visit(columns + 3)
			end
		end
	end
	local solution = {}
	for j = 1, columns do
		local value = { 0, 0, 0 }
		for i = 1, rank do
			for k = 1, 3 do
				value[k] += q[i][j] * beta[i][k]
			end
		end
		ctx.visit(3 * rank)
		solution[j] = value
	end
	local residual = 0
	for i = rank + 1, count do
		for k = 1, 3 do
			residual = math.max(residual, math.abs(rhs[i][k]))
		end
	end
	return solution, { rank = rank, equations = count, variables = columns, dependentResidual = residual }
end
