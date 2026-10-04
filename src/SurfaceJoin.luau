-- Minimum weighted control displacement subject to full rational border identities.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local Core = require(script.Parent.SurfaceEditCore)
local Basis = require(script.Parent.SurfaceJoinBasis)
local Equations = require(script.Parent.SurfaceJoinEquations)
local Arithmetic = require(script.Parent.CoonsArithmetic)
local QR = require(script.Parent.EqualityQR)
local function scalar(value, default, positive)
	if value == nil then
		value = default
	end
	assert(
		type(value) == "number"
			and U.finite(value)
			and (positive and value > 0 or not positive and value >= 0),
		"Invalid finite join scalar"
	)
	return value
end
return function(surfaceA, boundaryA, surfaceB, boundaryB, options)
	options = U.copy(options or {})
	local order = U.integer(options.order == nil and 1 or options.order, 0)
	assert(order <= 2, "Join order must be 0, 1 or 2")
	for _, key in { "reverse", "fixedA", "fixedB", "requireComplete" } do
		assert(options[key] == nil or type(options[key]) == "boolean", "Join flags must be booleans")
	end
	local ratio = scalar(options.crossScale, 1, true)
	local tolerances = {
		scalar(options.tolerance, 1e-5),
		scalar(options.firstTolerance, 1e-5),
		scalar(options.secondTolerance, 1e-5),
	}
	local rankTolerance = scalar(options.rankTolerance, 1e-11, true)
	assert(rankTolerance < 1, "Join rank tolerance must be less than one")
	local limit = options.maxDisplacement == nil and math.huge or scalar(options.maxDisplacement, 0)
	local ctx = {
		work = 0,
		maxControls = U.integer(options.maxControls or 10000, 1),
		maxSpans = U.integer(options.maxSpans or 128, 1),
		maxConstraints = U.integer(options.maxConstraints or 2048, 1),
	}
	local maxWork = U.integer(options.maxWork or 50000000, 1)
	local maxEntries = U.integer(options.maxMatrixEntries or 1000000, 1)
	local maxVariables = U.integer(options.maxVariables or 1024, 1)
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Surface join cancelled")
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = ctx.work })
		end
	end
	ctx.visit = function(count)
		local previous = ctx.work
		ctx.work += count or 1
		assert(ctx.work <= maxWork, "Join work budget exceeded")
		if math.floor(previous / 256) ~= math.floor(ctx.work / 256) then
			ctx.check("work")
		end
	end
	ctx.allocate = function(rows, columns)
		assert(rows * columns <= maxEntries, "Join matrix allocation budget exceeded")
	end
	ctx.check("begin")
	local O = Arithmetic(ctx.visit)
	local a = Basis.new(surfaceA, boundaryA, false, 0, ctx, O)
	local countA = #a.source.control * #a.source.control[1]
	local b = Basis.new(surfaceB, boundaryB, options.reverse == true, countA, ctx, O)
	local total = countA + #b.source.control * #b.source.control[1]
	local points, original, variables, factors = {}, {}, {}, {}
	for index, model in { a, b } do
		local label, offset = index == 1 and "A" or "B", index == 1 and 0 or countA
		local s = model.source
		local pins = options["pins" .. label] or {}
		assert(type(pins) == "table", "Join pins must be control dictionaries")
		for key, value in pins do
			Core.index(key, #s.control, #s.control[1])
			assert(
				type(value) == "boolean" or U.vector(value),
				"Join pins must be booleans or finite Vector3 values"
			)
		end
		local stiffness = options["stiffness" .. label] or 1
		if type(stiffness) == "table" then
			for key, value in stiffness do
				Core.index(key, #s.control, #s.control[1])
				scalar(value, 1, true)
			end
		else
			scalar(stiffness, 1, true)
		end
		for i, row in s.control do
			for j, p in row do
				local id, key = offset + (i - 1) * #row + j, Core.key(i, j)
				local pin = pins[key]
				original[id], points[id] = p, typeof(pin) == "Vector3" and pin or p
				if options["fixed" .. label] then
					assert(points[id] == p, "Fixed patch conflicts with a moved pin")
				end
				if not options["fixed" .. label] and (pin == nil or pin == false) then
					table.insert(variables, id)
					local value = type(stiffness) == "table" and (stiffness[key] or 1) or stiffness
					factors[id] = 1 / math.sqrt(value)
				end
			end
		end
	end
	assert(#variables <= maxVariables, "Join variable budget exceeded")
	local equations, groups, spans = Equations(a, b, order, ratio, total, ctx, O)
	local origin = original[1]
	local function centered(values)
		local out = {}
		for id, p in values do
			out[id] = {}
			for k, axis in { "X", "Y", "Z" } do
				out[id][k] = O.sub(O.value(p[axis]), O.value(origin[axis]))
			end
		end
		return out
	end
	local relative = centered(points)
	local matrix, rhs = {}, {}
	ctx.allocate(#equations, #variables + 3)
	for rowIndex, row in equations do
		local residual = { 0, 0, 0 }
		for id, value in row do
			for k = 1, 3 do
				residual[k] -= value[1] * relative[id][k][1]
			end
		end
		matrix[rowIndex], rhs[rowIndex] = {}, residual
		for column, id in variables do
			matrix[rowIndex][column] = row[id][1] * factors[id]
		end
		ctx.visit(total * 3 + #variables)
	end
	local solver = { rank = 0, equations = #equations, variables = #variables, dependentResidual = 0 }
	if #variables > 0 then
		local solution
		solution, solver = QR(matrix, rhs, #variables, ctx, rankTolerance)
		for column, id in variables do
			local v, p, f = solution[column], points[id], factors[id]
			local x, y, z = p.X + v[1] * f, p.Y + v[2] * f, p.Z + v[3] * f
			assert(U.finite(x) and U.finite(y) and U.finite(z), "Join solution exceeds numeric range")
			points[id] = Vector3.new(x, y, z)
			assert(U.vector(points[id]), "Join native control exceeds numeric range")
		end
	end
	relative = centered(points)
	local radius, displacement, weighted = 0, 0, 0
	for id, p in points do
		local rr, delta = 0, 0
		for k, axis in { "X", "Y", "Z" } do
			rr += (math.abs(relative[id][k][1]) + relative[id][k][2]) ^ 2
			delta += (p[axis] - original[id][axis]) ^ 2
		end
		radius = math.max(radius, math.sqrt(rr))
		displacement = math.max(displacement, math.sqrt(delta))
		if factors[id] then
			weighted += delta / factors[id] ^ 2
		end
	end
	local normalization = { 0, 0, 0 }
	for _, model in { a, b } do
		if model.knotError > 0 then
			local epsilon = 32 * model.degree * (model.degree + 1) * model.knotError / model.minGap
			local first, second = model.magnitude[2], model.magnitude[3]
			local conditioningFactors = { 4, 16 * first, 64 * (second + first * first) }
			for d = 0, order do
				local allowance = epsilon * model.weightRatio >= 0.125 and math.huge
					or conditioningFactors[d + 1]
						* epsilon
						* radius
						* model.weightRatio ^ (d + 2)
						* (model == b and ratio ^ d or 1)
				normalization[d + 1] += allowance == allowance and allowance or math.huge
			end
		end
	end
	local bounds = { 0, 0, 0 }
	for _, group in groups do
		local maximum = 0
		for _, row in group.rows do
			local squared = 0
			for k = 1, 3 do
				local value = O.value(0)
				for id, coefficient in row do
					value = O.add(value, O.mul(coefficient, relative[id][k]))
				end
				squared += (math.abs(value[1]) + value[2]) ^ 2
			end
			maximum = math.max(maximum, math.sqrt(squared))
		end
		local bound = group.lower > 0 and maximum / group.lower or math.huge
		group.bound = bound + normalization[group.order + 1]
		bounds[group.order + 1] = math.max(bounds[group.order + 1], group.bound)
	end
	local complete = displacement <= limit
	for d = 0, order do
		complete = complete and bounds[d + 1] <= tolerances[d + 1]
	end
	local results = {}
	for index, model in { a, b } do
		local s, grid, offset = model.source, {}, index == 1 and 0 or countA
		for i, row in s.control do
			grid[i] = {}
			for j in row do
				grid[i][j] = points[offset + (i - 1) * #row + j]
			end
		end
		local config = table.clone(s)
		config.maxControls = ctx.maxControls
		results[index] = s.kind == "cyclicSurface" and C.surface(grid, s.degreeU, s.degreeV, config)
			or N.surface(grid, s.degreeU, s.degreeV, config)
	end
	ctx.check("finish")
	local report = {
		complete = complete,
		success = complete,
		reason = complete and "tolerance" or displacement > limit and "displacement" or "constraints",
		order = order,
		crossScale = ratio,
		reverse = options.reverse == true,
		positionErrorBound = bounds[1],
		firstDerivativeErrorBound = order >= 1 and bounds[2] or nil,
		secondDerivativeErrorBound = order >= 2 and bounds[3] or nil,
		knotNormalizationAllowances = normalization,
		maximumDisplacement = displacement,
		weightedSquaredDisplacement = weighted,
		spans = spans,
		controls = total,
		solver = solver,
		work = ctx.work,
		regularityChecked = false,
		intersectionsChecked = false,
		method = "Fixed-weight rational Bernstein constraints and pivoted row QR",
	}
	assert(
		complete or options.requireComplete == false,
		"Surface join did not meet its border constraints or displacement limit"
	)
	return results[1], results[2], report
end
