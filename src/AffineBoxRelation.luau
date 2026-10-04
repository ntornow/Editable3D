-- Exact affine solution set intersected with a closed coordinate box.
-- All vertices of the bounded polytope are enumerated by independent active
-- bounds in the nullspace of the equality system. Rationals are immutable.
return function(rows, bounds, R, visit)
	local n = #bounds
	assert(n > 0 and n <= 4)
	local zero, one = R.number(0), R.number(1)
	local function rref(input, columns)
		local matrix = {}
		for i, row in input do
			assert(#row == columns + 1)
			matrix[i] = table.clone(row)
			visit(columns + 1)
		end
		local pivots, at = {}, 1
		for column = 1, columns do
			local pivot
			for i = at, #matrix do
				visit(1)
				if matrix[i][column].sign ~= 0 then
					pivot = i
					break
				end
			end
			if not pivot then
				continue
			end
			matrix[at], matrix[pivot] = matrix[pivot], matrix[at]
			local divisor = matrix[at][column]
			for j = column, columns + 1 do
				matrix[at][j] = R.div(matrix[at][j], divisor)
			end
			for i, row in matrix do
				if i == at or row[column].sign == 0 then
					continue
				end
				local factor = row[column]
				for j = column, columns + 1 do
					row[j] = R.sub(row[j], R.mul(factor, matrix[at][j]))
				end
			end
			pivots[at], at = column, at + 1
		end
		for i = at, #matrix do
			if matrix[i][columns + 1].sign ~= 0 then
				return nil, pivots
			end
		end
		return matrix, pivots
	end
	local matrix, pivots = rref(rows, n)
	if not matrix then
		return { vertices = {}, equalityRank = #pivots, inconsistent = true }
	end
	local pivotSet, free, origin, basis = {}, {}, table.create(n, zero), {}
	for i, column in pivots do
		pivotSet[column] = true
		origin[column] = matrix[i][n + 1]
	end
	for column = 1, n do
		if not pivotSet[column] then
			table.insert(free, column)
		end
	end
	for j, column in free do
		local vector = table.create(n, zero)
		vector[column] = one
		for i, pivot in pivots do
			vector[pivot] = R.neg(matrix[i][column])
		end
		basis[j] = vector
	end
	local vertices, active, chosen, candidates = {}, {}, {}, 0
	local function add(parameters)
		local point, constraints = {}, {}
		for axis = 1, n do
			local x = origin[axis]
			for j, t in parameters do
				x = R.add(x, R.mul(basis[j][axis], t))
			end
			local lo, hi = R.compare(x, bounds[axis][1]), R.compare(x, bounds[axis][2])
			if lo < 0 or hi > 0 then
				return
			end
			if lo == 0 then
				table.insert(constraints, { axis = axis, side = 1 })
			end
			if hi == 0 then
				table.insert(constraints, { axis = axis, side = 2 })
			end
			point[axis] = x
		end
		for _, previous in vertices do
			local equal = true
			for axis = 1, n do
				if not R.equal(point[axis], previous[axis]) then
					equal = false
					break
				end
			end
			if equal then
				return
			end
		end
		table.insert(vertices, point)
		table.insert(active, constraints)
	end
	local function sides(index, equations)
		if index > #free then
			candidates += 1
			local solved, columns = rref(equations, #free)
			if not solved or #columns ~= #free then
				return
			end
			local parameters = {}
			for i, column in columns do
				parameters[column] = solved[i][#free + 1]
			end
			add(parameters)
			return
		end
		local axis = chosen[index]
		for side = 1, 2 do
			local row = {}
			for j, vector in basis do
				row[j] = vector[axis]
			end
			row[#free + 1] = R.sub(bounds[axis][side], origin[axis])
			equations[index] = row
			sides(index + 1, equations)
		end
	end
	local function combinations(index, first)
		if index > #free then
			sides(1, {})
			return
		end
		for axis = first, n - (#free - index) do
			chosen[index] = axis
			combinations(index + 1, axis + 1)
		end
	end
	if #free == 0 then
		add({})
	else
		combinations(1, 1)
	end
	local dimension = -1
	if #vertices > 0 then
		local differences = {}
		for i = 2, #vertices do
			local row = {}
			for j = 1, n do
				row[j] = R.sub(vertices[i][j], vertices[1][j])
			end
			row[n + 1] = zero
			table.insert(differences, row)
		end
		local _, columns = rref(differences, n)
		dimension = #columns
	end
	return {
		vertices = vertices,
		active = active,
		dimension = dimension,
		equalityRank = #pivots,
		freeAxes = free,
		origin = origin,
		basis = basis,
		candidates = candidates,
		rref = rref,
	}
end
