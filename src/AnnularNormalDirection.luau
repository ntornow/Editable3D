-- Prove a uniform oriented direction of an algebraic annular cross polynomial.
return function(R, P, F, coefficients, options, visit)
	assert(#coefficients == 324)
	local minus = R.number(-1)
	local reference
	for i = 1, #coefficients, 3 do
		if
			F.sign(coefficients[i]) ~= 0
			or F.sign(coefficients[i + 1]) ~= 0
			or F.sign(coefficients[i + 2]) ~= 0
		then
			reference = { coefficients[i], coefficients[i + 1], coefficients[i + 2] }
			break
		end
	end
	if not reference then
		return nil, { normalCertified = false, reason = "vanishingAnnularMode" }
	end
	local axis = 1
	while F.sign(reference[axis]) == 0 do
		axis += 1
	end
	if F.modulus then
		coefficients =
			require(script.Parent.NormalizeAlgebraicPolynomials)(R, P, F, coefficients, reference[axis])
		reference = nil
		for i = 1, #coefficients, 3 do
			if
				F.sign(coefficients[i]) ~= 0
				or F.sign(coefficients[i + 1]) ~= 0
				or F.sign(coefficients[i + 2]) ~= 0
			then
				reference = { coefficients[i], coefficients[i + 1], coefficients[i + 2] }
				break
			end
		end
		axis = 1
		while F.sign(reference[axis]) == 0 do
			axis += 1
		end
	end
	local scalar = {}
	for i = 1, #coefficients, 3 do
		if F.reduce then
			for component = 1, 3 do
				reference[component] = F.reduce(reference[component])
				coefficients[i + component - 1] = F.reduce(coefficients[i + component - 1])
			end
		end
		local a = coefficients[i + axis - 1]
		for component = 1, 3 do
			local determinant = P.add(
				P.product(coefficients[i + component - 1], reference[axis]),
				P.scale(P.product(a, reference[component]), minus)
			)
			if F.sign(determinant) ~= 0 then
				return nil,
					{ normalCertified = false, normalExists = false, reason = "varyingAnnularDirection" }
			end
		end
		scalar[#scalar + 1] = a
	end
	-- Choose orientation at an actual annular center, not from a control value.
	local choose = { 1, 5, 10, 10, 5, 1 }
	local sign
	for patch = 0, 2 do
		local center = {}
		for i = 1, 6 do
			for j = 1, 6 do
				center = P.add(
					center,
					P.scale(
						scalar[patch * 36 + (i - 1) * 6 + j],
						R.div(R.number(choose[i] * choose[j]), R.number(1024))
					)
				)
			end
		end
		local value = F.sign(center)
		if value ~= 0 then
			sign = value
			break
		end
	end
	if not sign then
		return nil, { normalCertified = false, reason = "zeroAnnularCenters" }
	end
	if sign < 0 then
		for i, p in scalar do
			scalar[i] = P.scale(p, minus)
		end
	end
	-- reference is scaled to agree with the now positive scalar direction.
	if F.sign(reference[axis]) ~= sign then
		for i, p in reference do
			reference[i] = P.scale(p, minus)
		end
	end
	local function split(grid, direction)
		local left, right = {}, {}
		for i = 1, 6 do
			left[i] = {}
			right[i] = {}
		end
		for line = 1, 6 do
			local values = {}
			for i = 1, 6 do
				values[i] = direction == 1 and grid[i][line] or grid[line][i]
			end
			local a, b = {}, {}
			a[1] = values[1]
			b[6] = values[6]
			for level = 1, 5 do
				for i = 1, 6 - level do
					values[i] = P.scale(P.add(values[i], values[i + 1]), R.number(0.5))
				end
				a[level + 1] = values[1]
				b[6 - level] = values[6 - level]
			end
			for i = 1, 6 do
				if direction == 1 then
					left[i][line] = a[i]
					right[i][line] = b[i]
				else
					left[line][i] = a[i]
					right[line][i] = b[i]
				end
			end
		end
		return left, right
	end
	local stack = {}
	for patch = 0, 2 do
		local grid = {}
		for i = 1, 6 do
			grid[i] = {}
			for j = 1, 6 do
				grid[i][j] = scalar[patch * 36 + (i - 1) * 6 + j]
			end
		end
		stack[#stack + 1] = { grid = grid, depth = 0, patch = patch + 1 }
	end
	local nodes = 0
	while #stack > 0 do
		local item = table.remove(stack)
		nodes += 1
		visit(1)
		assert(nodes <= (options.maxNormalCells or 10000), "Annular normal cell budget exceeded")
		if options.checkpoint then
			options.checkpoint({ stage = "annularNormal", cells = nodes, depth = item.depth })
		end
		local grid = item.grid
		local positive = true
		for i = 1, 6 do
			for j = 1, 6 do
				if F.sign(grid[i][j]) <= 0 then
					positive = false
				end
			end
		end
		if positive then
			continue
		end
		for _, ij in { { 1, 1 }, { 1, 6 }, { 6, 1 }, { 6, 6 } } do
			local corner = F.sign(grid[ij[1]][ij[2]])
			if corner < 0 then
				return nil,
					{
						normalCertified = false,
						normalExists = false,
						reason = "opposedAnnularDirections",
						cells = nodes,
					}
			end
			if corner == 0 then
				return nil,
					{ normalCertified = false, reason = "zeroAnnularBoundary", cells = nodes },
					reference
			end
		end
		if item.depth >= (options.maxNormalDepth or 16) then
			return nil, { normalCertified = false, reason = "annularSignDepth", cells = nodes }
		end
		local a, b = split(grid, item.depth % 2 + 1)
		stack[#stack + 1] = { grid = a, depth = item.depth + 1, patch = item.patch }
		stack[#stack + 1] = { grid = b, depth = item.depth + 1, patch = item.patch }
	end
	return reference, { normalCertified = true, normalExists = true, cells = nodes }
end
