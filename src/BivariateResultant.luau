-- fraction-free Sylvester determinant in Q[s].
return function(a, b, R, P, visit, maximumEntries, allocate)
	if #a == 0 or #b == 0 then
		return {}
	end
	local m, n = #a - 1, #b - 1
	local size = m + n
	assert(size * size <= maximumEntries, "Resultant matrix allocation budget exceeded")
	visit(size * size)
	if allocate then
		allocate(size * size)
	end
	local one = { R.number(1) }
	if size == 0 then
		return one
	end
	local matrix = {}
	for row = 1, size do
		matrix[row] = table.create(size)
		for column = 1, size do
			matrix[row][column] = {}
		end
		local polynomial, shift = row <= n and a or b, row <= n and row - 1 or row - n - 1
		for j = 1, #polynomial do
			matrix[row][shift + j] = polynomial[#polynomial - j + 1]
		end
	end
	local previous = one
	local sign = 1
	for k = 1, size - 1 do
		local row = k
		while row <= size and #matrix[row][k] == 0 do
			row += 1
			visit(1)
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
				visit(1)
				local numerator = P.add(
					P.product(matrix[i][j], pivot),
					P.scale(P.product(matrix[i][k], matrix[k][j]), R.number(-1))
				)
				matrix[i][j] = k == 1 and numerator or P.quotient(numerator, previous)
			end
			matrix[i][k] = {}
		end
		previous = pivot
	end
	return P.scale(matrix[size][size], R.number(sign))
end
