-- Bounded exact truncated Sylvester minors over a polynomial domain.
return function(a, b, axis, M, R, ctx, maximumEntries)
	local m, n = M.degree(a, axis), M.degree(b, axis)
	assert(m >= 0 and n >= 0)
	local one = M.constant(R.number(1))
	local function determinant(matrix)
		local size = #matrix
		if size == 0 then
			return one
		end
		local previous, sign = one, 1
		for k = 1, size - 1 do
			local row = k
			while row <= size and #matrix[row][k] == 0 do
				row += 1
				ctx.visit(1)
			end
			if row > size then
				return {}
			end
			if row ~= k then
				matrix[k], matrix[row] = matrix[row], matrix[k]
				sign = -sign
			end
			local pivot = matrix[k][k]
			for i = k + 1, size do
				for j = k + 1, size do
					ctx.visit(1)
					local numerator =
						M.sub(M.product(matrix[i][j], pivot), M.product(matrix[i][k], matrix[k][j]))
					matrix[i][j] = k == 1 and numerator or M.quotient(numerator, previous)
				end
				matrix[i][k] = {}
			end
			previous = pivot
		end
		return M.scale(matrix[size][size], R.number(sign))
	end
	local result = {}
	for j = 0, math.min(m, n) do
		local size = m + n - 2 * j
		assert(
			size * size <= (maximumEntries or 4096),
			"Principal subresultant matrix allocation budget exceeded"
		)
		ctx.allocate(size * size)
		local matrix = {}
		for row = 1, size do
			matrix[row] = {}
			local first = row <= n - j
			local poly = first and a or b
			local degree = first and m or n
			local shift = first and row - 1 or row - (n - j) - 1
			for column = 1, size do
				matrix[row][column] = M.coefficient(poly, axis, degree - (column - shift - 1))
			end
		end
		result[j + 1] = determinant(matrix)
	end
	return result
end
