-- Complete one-sided polynomial normal decision at an exact parameter point.
return function(R, controls, u, v, orientation, options, visit)
	local allocated = 0
	local function allocate(n)
		allocated += n
		assert(
			allocated <= (options.maxExactCoefficients or 20000000),
			"Polynomial normal coefficient budget exceeded"
		)
		if options.normalAllocate then
			options.normalAllocate(n)
		end
	end
	local ctx = { visit = visit, allocate = allocate, maxDegree = options.maxNormalPolynomialDegree or 128 }
	local M = require(script.Parent.ExactSparsePolynomial)(R, 2, ctx)
	local zero, one = R.number(0), R.number(1)
	local integerBasis = { { 1, -3, 3, -1 }, { 4, 0, -6, 3 }, { 1, 3, 3, -3 }, { 0, 0, 0, 1 } }
	local surface = {}
	for axis = 1, 3 do
		local terms = {}
		for i = 0, 3 do
			for j = 0, 3 do
				for a = 0, 3 do
					for b = 0, 3 do
						local coefficient = integerBasis[i + 1][a + 1] * integerBasis[j + 1][b + 1]
						if coefficient ~= 0 then
							terms[#terms + 1] = {
								powers = { a, b },
								value = R.mul(
									controls[i .. ":" .. j][axis],
									R.div(R.number(coefficient), R.number(36))
								),
							}
						end
					end
				end
			end
		end
		surface[axis] = M.make(terms)
	end
	local du, dv = {}, {}
	for i, p in surface do
		du[i], dv[i] = M.derivative(p, 1), M.derivative(p, 2)
	end
	local jacobian = {}
	for i, pair in { { 2, 3 }, { 3, 1 }, { 1, 2 } } do
		jacobian[i] = M.scale(
			M.sub(M.product(du[pair[1]], dv[pair[2]]), M.product(du[pair[2]], dv[pair[1]])),
			R.number(orientation)
		)
	end
	local T = require(script.Parent.InfinitesimalField)(R, visit, allocate, ctx.maxDegree)
	local D = require(script.Parent.InfinitesimalField)(T, visit, allocate, ctx.maxDegree)
	local MD = require(script.Parent.ExactSparsePolynomial)(D, 2, ctx)
	local choose = {
		{ 1 },
		{ 1, 1 },
		{ 1, 2, 1 },
		{ 1, 3, 3, 1 },
		{ 1, 4, 6, 4, 1 },
		{ 1, 5, 10, 10, 5, 1 },
		{
			1,
			6,
			15,
			20,
			15,
			6,
			1,
		},
	}
	local function powers(value, n)
		local out = { one }
		for i = 1, n do
			out[i + 1] = R.mul(out[i], value)
		end
		return out
	end
	local up, vp = powers(R.number(u), 6), powers(R.number(v), 6)
	local deltaPowers = { D.number(1) }
	for i = 1, 12 do
		deltaPowers[i + 1] = D.mul(deltaPowers[i], D.epsilon)
	end
	local function sides(x)
		if x == 0 then
			return { 1 }
		elseif x == 1 then
			return { -1 }
		else
			return { -1, 1 }
		end
	end
	local patches = {}
	for _, su in sides(u) do
		for _, sv in sides(v) do
			local patch = {}
			for axis, p in jacobian do
				local terms = {}
				for _, term in p do
					local a, b = term.powers[1], term.powers[2]
					for i = 0, a do
						for j = 0, b do
							local factor = R.mul(
								R.mul(up[a - i + 1], vp[b - j + 1]),
								R.number(choose[a + 1][i + 1] * choose[b + 1][j + 1] * su ^ i * sv ^ j)
							)
							local coefficient = R.mul(term.value, factor)
							if coefficient.sign ~= 0 then
								terms[#terms + 1] = {
									powers = { i, j },
									value = D.mul(
										D.rational(T.rational(coefficient)),
										deltaPowers[i + j + 1]
									),
								}
							end
						end
					end
				end
				patch[axis] = MD.make(terms)
			end
			patches[#patches + 1] = patch
		end
	end
	local degree
	local function leading(value)
		for i, c in value.n do
			if c.sign ~= 0 then
				return i - 1, c
			end
		end
		return nil
	end
	for _, patch in patches do
		for _, p in patch do
			for _, term in p do
				local order = leading(term.value)
				if order and (not degree or order < degree) then
					degree = order
				end
			end
		end
	end
	if not degree then
		return nil,
			{
				normalCertified = false,
				normalExists = false,
				decisionCertified = true,
				reason = "noRegularPoints",
				method = "exactPolynomialNormal",
			}
	end
	local candidate
	for _, patch in patches do
		local byPower = {}
		for axis, p in patch do
			for _, term in p do
				local order, c = leading(term.value)
				if order == degree then
					assert(#c.n <= 1 and #c.d == 1)
					local coefficient = R.div(c.n[1] or zero, c.d[1])
					local key = table.concat(term.powers, ",")
					byPower[key] = byPower[key] or { zero, zero, zero }
					byPower[key][axis] = coefficient
				end
			end
		end
		for _, direction in byPower do
			if not candidate then
				candidate = direction
			end
			for _, pair in { { 1, 2 }, { 1, 3 }, { 2, 3 } } do
				if
					not R.equal(
						R.mul(candidate[pair[1]], direction[pair[2]]),
						R.mul(candidate[pair[2]], direction[pair[1]])
					)
				then
					return nil,
						{
							normalCertified = false,
							normalExists = false,
							decisionCertified = true,
							reason = "varyingPolynomialDirection",
							method = "exactPolynomialNormal",
						}
				end
			end
		end
	end
	assert(candidate)
	local axis = 1
	while candidate[axis].sign == 0 do
		axis += 1
	end
	local cells = 0
	for _, sign in { 1, -1 } do
		local N = {}
		for i, c in candidate do
			N[i] = sign == 1 and c or R.neg(c)
		end
		local valid = true
		for _, patch in patches do
			for component = 1, 3 do
				if component ~= axis then
					local a = D.rational(T.rational(N[axis]))
					local b = D.rational(T.rational(N[component]))
					local longitudinal = MD.scale(patch[axis], a)
					local difference = MD.sub(MD.scale(patch[component], a), MD.scale(patch[axis], b))
					for _, side in { -1, 1 } do
						local cone = MD.add(
							MD.scale(longitudinal, D.rational(T.epsilon)),
							MD.scale(difference, D.number(side))
						)
						local nonnegative = true
						for _, term in cone do
							if term.value.sign < 0 then
								nonnegative = false
								break
							end
						end
						if not nonnegative then
							local result = require(script.Parent.ThomCAD)({ cone }, 2, D, ctx, {
								quantifiers = { "forall", "forall" },
								maxTarskiQueries = options.maxNormalTarskiQueries or 100000,
								maxCells = options.maxNormalCells or 10000,
								maxProjectionPolynomials = options.maxNormalProjectionPolynomials or 256,
							}, function(signs)
								if signs[1] ~= nil then
									return signs[1] >= 0
								end
								return nil
							end)
							cells += result.cells
							if not result.result then
								valid = false
								break
							end
						end
					end
				end
				if not valid then
					break
				end
			end
			if not valid then
				break
			end
		end
		if valid then
			local normal, error, reason = require(script.Parent.GenericNormalBounds)(R, R, N, function(x)
				return { x, x }
			end, function()
				return false
			end, options.normalTolerance or 1e-5, visit)
			return normal,
				{
					normalCertified = true,
					normalExists = true,
					decisionCertified = true,
					method = "exactPolynomialNormal",
					normalErrorBound = error,
					nativeAvailable = normal ~= nil,
					reason = reason,
					cells = cells,
					order = degree,
					quadrants = #patches,
					allocatedCoefficients = allocated,
				}
		end
	end
	return nil,
		{
			normalCertified = false,
			normalExists = false,
			decisionCertified = true,
			reason = "nonuniformPolynomialNormal",
			method = "exactPolynomialNormal",
			cells = cells,
			order = degree,
			quadrants = #patches,
			allocatedCoefficients = allocated,
		}
end
