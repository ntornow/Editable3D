-- exact projection of three affine equations on a compact unit square.
-- Coefficients are Q[s,t] polynomials; the two fiber unknowns are alpha,beta.
return function(equations, R, P, T, ctx, options)
	options = options or {}
	local zero, one, minus = {}, { { R.number(1) } }, R.number(-1)
	local function add(a, b)
		ctx.allocate(math.max(#a, #b))
		local out = {}
		for i = 1, math.max(#a, #b) do
			out[i] = P.add(a[i] or {}, b[i] or {})
		end
		return T.trim(out)
	end
	local function scale(p, k)
		ctx.allocate(#p)
		local out = {}
		for i, c in p do
			out[i] = P.scale(c, k)
		end
		return T.trim(out)
	end
	local function sub(a, b)
		return add(a, scale(b, minus))
	end
	local function rationalKey(value)
		return value.sign .. ":" .. table.concat(value.n, ",") .. "/" .. table.concat(value.d, ",")
	end
	local sources, keys = {}, {}
	local function reference(p)
		if #p == 0 then
			return { constant = 0 }
		end
		if #p == 1 and #p[1] == 1 then
			return { constant = p[1][1].sign }
		end
		local leading = p[#p][#p[#p]]
		local normalized = scale(p, R.div(R.number(1), leading))
		local parts = {}
		for _, row in normalized do
			local coefficients = {}
			for _, value in row do
				ctx.visit(1)
				table.insert(coefficients, rationalKey(value))
			end
			table.insert(parts, table.concat(coefficients, ";"))
		end
		local key = table.concat(parts, "|")
		local index = keys[key]
		if not index then
			assert(
				#sources < (options.maxFiberPolynomials or 1024),
				"Fiber projection polynomial budget exceeded"
			)
			index = #sources + 1
			keys[key] = index
			table.insert(sources, { p = normalized, relation = "measure" })
		end
		return { index = index, orientation = leading.sign }
	end
	assert(#equations == 3, "Three world-coordinate equations required")
	local constraints = {}
	for i, e in equations do
		constraints[i] = { a = e.a, b = e.b, c = e.c, relation = "eq" }
	end
	local firstBound = #constraints + 1
	table.insert(constraints, { a = one, b = zero, c = zero, relation = "ge" })
	table.insert(constraints, { a = scale(one, minus), b = zero, c = one, relation = "ge" })
	table.insert(constraints, { a = zero, b = one, c = zero, relation = "ge" })
	table.insert(constraints, { a = zero, b = scale(one, minus), c = one, relation = "ge" })
	local normals = {}
	for _, equation in equations do
		table.insert(normals, reference(equation.a))
		table.insert(normals, reference(equation.b))
	end
	local cases, rankTwo = {}, {}
	local worldDeterminant
	for i, first in constraints do
		for j = 1, i - 1 do
			ctx.visit(1)
			local second = constraints[j]
			local determinant = sub(T.product(first.a, second.b), T.product(second.a, first.b))
			if #determinant == 0 then
				continue
			end
			local alpha = sub(T.product(first.b, second.c), T.product(first.c, second.b))
			local beta = sub(T.product(first.c, second.a), T.product(first.a, second.c))
			local condition = {
				determinant = determinant,
				alpha = alpha,
				beta = beta,
				determinantSign = reference(determinant),
				residuals = {},
				active = { i, j },
			}
			if i < firstBound and j < firstBound then
				table.insert(rankTwo, condition.determinantSign)
			end
			for k, constraint in constraints do
				if k == i or k == j then
					condition.residuals[k] = { constant = 0 }
					continue
				end
				local world = i < firstBound and j < firstBound and k < firstBound
				local orientation = (i - j) * (i - k) * (j - k) > 0 and 1 or -1
				if world and worldDeterminant then
					local ref = worldDeterminant
					condition.residuals[k] = ref.index
							and { index = ref.index, orientation = ref.orientation * orientation }
						or { constant = ref.constant * orientation }
				else
					local residual = add(
						add(T.product(constraint.a, alpha), T.product(constraint.b, beta)),
						T.product(constraint.c, determinant)
					)
					local ref = reference(residual)
					condition.residuals[k] = ref
					if world then
						worldDeterminant = ref.index
								and { index = ref.index, orientation = ref.orientation * orientation }
							or { constant = ref.constant * orientation }
					end
				end
			end
			table.insert(cases, condition)
		end
	end
	local function sign(ref, signs)
		return ref.index and signs[ref.index] * ref.orientation or ref.constant
	end
	local function feasible(case, signs)
		local d = sign(case.determinantSign, signs)
		if d == 0 then
			return false
		end
		for i, residual in case.residuals do
			local value = sign(residual, signs)
			if i < firstBound and value ~= 0 or i >= firstBound and value * d < 0 then
				return false
			end
		end
		return true
	end
	local function truth(signs)
		for _, case in cases do
			if feasible(case, signs) then
				return true
			end
		end
		return false
	end
	local function dimension(signs)
		for _, ref in rankTwo do
			if sign(ref, signs) ~= 0 then
				return 0
			end
		end
		local rank = 0
		for _, ref in normals do
			if sign(ref, signs) ~= 0 then
				rank = 1
				break
			end
		end
		if rank == 0 then
			return 2
		end
		local pattern
		for _, case in cases do
			if feasible(case, signs) then
				local mask = 0
				for i = firstBound, #constraints do
					if sign(case.residuals[i], signs) == 0 then
						mask += 2 ^ (i - firstBound)
					end
				end
				if pattern and mask ~= pattern then
					return 1
				end
				pattern = mask
			end
		end
		assert(pattern ~= nil, "Fiber dimension requested outside the feasible set")
		return 0
	end
	local function pattern(caseIndex, signs)
		local case = cases[caseIndex]
		local mask = 0
		for i = firstBound, #constraints do
			if sign(case.residuals[i], signs) == 0 then
				mask += 2 ^ (i - firstBound)
			end
		end
		return mask
	end
	local function vertices(signs)
		local found, patterns = {}, {}
		local rankTwoHere = false
		for _, ref in rankTwo do
			if sign(ref, signs) ~= 0 then
				rankTwoHere = true
				break
			end
		end
		for index, case in cases do
			if feasible(case, signs) then
				if rankTwoHere then
					return { index }
				end
				local mask = pattern(index, signs)
				if not patterns[mask] then
					patterns[mask] = true
					table.insert(found, index)
				end
			end
		end
		assert(#found > 0 and #found <= 4, "Invalid compact convex fiber vertex count")
		return found
	end
	return {
		sources = sources,
		cases = cases,
		truth = truth,
		dimension = dimension,
		vertices = vertices,
		pattern = pattern,
		constraints = constraints,
		normalReferences = normals,
		rankTwoReferences = rankTwo,
	}
end
