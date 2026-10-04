-- Private bounded least-squares kernel. Mutates fresh matrix/RHS work arrays.
-- Original Givens QR; callers own argument validation and coordinate centering.
local U = require(script.Parent.Util)
return function(matrix, rhs, columns, options)
	options = options or {}
	local rows, channels = #matrix, #rhs[1]
	assert(rows >= columns and #rhs == rows and columns > 0, "Overdetermined or square QR system required")
	assert(
		rows * columns <= (options.maxMatrixEntries or 1000000),
		"Fitting matrix allocation budget exceeded"
	)
	assert(
		rows * columns * (columns + channels) <= (options.maxWork or 50000000),
		"Fitting work budget exceeded"
	)
	local largest, smallest = 0, math.huge
	for column = 1, columns do
		if options.checkpoint then
			options.checkpoint((column - 1) / columns)
		end
		for row = rows, column + 1, -1 do
			local a, b = matrix[row - 1][column], matrix[row][column]
			if b ~= 0 then
				local scale = math.max(math.abs(a), math.abs(b))
				local radius = scale * math.sqrt((a / scale) ^ 2 + (b / scale) ^ 2)
				local c, s = a / radius, b / radius
				for j = column, columns do
					local x, y = matrix[row - 1][j], matrix[row][j]
					matrix[row - 1][j], matrix[row][j] = c * x + s * y, -s * x + c * y
				end
				for j = 1, channels do
					local x, y = rhs[row - 1][j], rhs[row][j]
					rhs[row - 1][j], rhs[row][j] = c * x + s * y, -s * x + c * y
				end
			end
		end
		local pivot = math.abs(matrix[column][column])
		largest, smallest = math.max(largest, pivot), math.min(smallest, pivot)
		if not U.finite(pivot) or pivot <= math.max(largest, 1) * (options.rankTolerance or 1e-12) then
			return nil,
				{
					rank = column - 1,
					columns = columns,
					reason = "Fitting system is rank deficient or ill-conditioned",
				}
		end
	end
	local result = {}
	for i = columns, 1, -1 do
		result[i] = {}
		for channel = 1, channels do
			local value = rhs[i][channel]
			for j = i + 1, columns do
				value -= matrix[i][j] * result[j][channel]
			end
			result[i][channel] = value / matrix[i][i]
			assert(U.finite(result[i][channel]), "Fitting solution exceeds numeric range")
		end
	end
	return result,
		{
			rank = columns,
			rows = rows,
			columns = columns,
			diagonalRatio = smallest / largest,
			method = "Givens QR",
		}
end
