-- Private independent spline states, periodic correspondence and analytic Jacobians.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local basis = require(script.Parent.SplineBasis)
local M = {}

local function scalar(value, message)
	assert(type(value) == "number" and U.finite(value), message or "Finite fitting scalar required")
	return value
end
local function controlKey(key, surface, nu, nv)
	if not surface then
		U.integer(key, 1)
		assert(key <= nu, "Fitting control index outside curve")
		return key
	end
	assert(type(key) == "string", "Surface fitting control keys must be i:j strings")
	local a, b = key:match("^(%d+):(%d+)$")
	a, b = tonumber(a), tonumber(b)
	assert(
		a and b and a >= 1 and a <= nu and b >= 1 and b <= nv and key == a .. ":" .. b,
		"Surface fitting control index is missing or noncanonical"
	)
	return (a - 1) * nv + b
end
local function pinMap(values, surface, nu, nv, weight)
	local pins = {}
	for key, value in values or {} do
		local id = controlKey(key, surface, nu, nv)
		if weight then
			assert(scalar(value) > 0, "Positive rational weight pins required")
		else
			assert(U.vector(value), "Finite pinned control required")
		end
		pins[id] = value
	end
	return pins
end

function M.new(initial, samples, surface, options, ctx)
	assert(type(initial) == "table" and type(samples) == "table", "Initial spline and samples required")
	local expected = surface and "surface" or "curve"
	local periodicKind = surface and "cyclicSurface" or "cyclicCurve"
	assert(initial.kind == expected or initial.kind == periodicKind, "Initial spline kind mismatch")
	local grid = surface and initial.control or initial.points
	assert(type(grid) == "table" and #grid >= 2, "Spline control array required")
	local nu, nv = #grid, surface and #grid[1] or 1
	assert(nu * nv <= ctx.maxControls, "Nonlinear fitting control budget exceeded")
	assert(#samples >= 1 and #samples <= ctx.maxSamples, "Nonlinear fitting sample budget exceeded")
	local config = table.clone(initial)
	config.maxControls = ctx.maxExpandedControls
	local source
	if surface then
		source = initial.kind == periodicKind and C.surface(grid, initial.degreeU, initial.degreeV, config)
			or N.surface(grid, initial.degreeU, initial.degreeV, config)
	else
		source = initial.kind == periodicKind and C.curve(grid, initial.degree, config)
			or N.curve(grid, initial.degree, config)
	end
	local model = {
		surface = surface,
		source = source,
		nu = nu,
		nv = nv,
		count = nu * nv,
		periodicU = surface and source.cyclicU == true or not surface and source.kind == periodicKind,
		periodicV = surface and source.cyclicV == true,
		data = {},
		confidence = {},
		variables = {},
		ctx = ctx,
	}
	local state = { points = {}, weights = {}, parameters = {} }
	for i = 1, nu do
		for j = 1, nv do
			local id = (i - 1) * nv + j
			state.points[id] = surface and source.control[i][j] or source.points[i]
			state.weights[id] = surface and source.weights[i][j] or source.weights[i]
		end
	end
	local pins = pinMap(options.pins, surface, nu, nv, false)
	local weightPins = pinMap(options.weightPins, surface, nu, nv, true)
	for id, point in pins do
		state.points[id] = point
	end
	for id, weight in weightPins do
		state.weights[id] = weight
	end
	if options.optimizeWeights and not next(weightPins) then
		weightPins[1] = state.weights[1]
		model.gaugeControl = surface and "1:1" or 1
	end
	model.baseWeights = table.clone(state.weights)
	local maximumConfidence, totalConfidence = 0, 0
	if options.sampleWeights then
		assert(#options.sampleWeights == #samples, "Sample confidence count mismatch")
	end
	for i, point in samples do
		assert(U.vector(point), "Finite fitting samples required")
		model.data[i] = point
		local confidence = options.sampleWeights and options.sampleWeights[i] or 1
		assert(scalar(confidence) > 0, "Positive finite sample confidence required")
		model.confidence[i] = confidence
		maximumConfidence = math.max(maximumConfidence, confidence)
	end
	for i, confidence in model.confidence do
		model.confidence[i] = confidence / maximumConfidence
		assert(model.confidence[i] > 0, "Sample confidence ratio outside numerical range")
		totalConfidence += model.confidence[i]
	end
	model.totalConfidence = totalConfidence
	local origin, scale = model.data[1], 0
	for _, list in { model.data, state.points } do
		for _, point in list do
			scale = math.max(
				scale,
				math.abs(point.X - origin.X),
				math.abs(point.Y - origin.Y),
				math.abs(point.Z - origin.Z)
			)
		end
	end
	model.scale = scale > 0 and scale or 1
	if surface then
		assert(options.parameters, "Surface refinement requires one initial Vector2 parameter per sample")
	end
	if options.parameters then
		assert(#options.parameters == #samples, "Initial parameter count mismatch")
	end
	local parameterPins = {}
	for i = 1, #samples do
		local value = options.parameters and options.parameters[i]
		if surface then
			assert(typeof(value) == "Vector2", "Surface fitting parameters must be Vector2 values")
			state.parameters[i] = { scalar(value.X), scalar(value.Y) }
		else
			value = value == nil
					and (#samples == 1 and 0 or (i - 1) / (#samples - (model.periodicU and 0 or 1)))
				or value
			state.parameters[i] = { scalar(value) }
		end
		parameterPins[i] = {}
	end
	for i, value in options.parameterPins or {} do
		U.integer(i, 1)
		assert(i <= #samples, "Parameter pin outside samples")
		if surface then
			assert(typeof(value) == "Vector2", "Surface parameter pins must be Vector2 values")
			state.parameters[i] = { scalar(value.X), scalar(value.Y) }
			parameterPins[i] = { true, true }
		else
			state.parameters[i][1], parameterPins[i][1] = scalar(value), true
		end
	end
	for d, name in { "parameterPinsU", "parameterPinsV" } do
		assert(surface or options[name] == nil, "Axis-specific parameter pins require a surface")
		for i, value in options[name] or {} do
			U.integer(i, 1)
			assert(i <= #samples, "Parameter pin outside samples")
			state.parameters[i][d], parameterPins[i][d] = scalar(value), true
		end
	end
	for _, params in state.parameters do
		for _, value in params do
			assert(value >= 0 and value <= 1, "Initial parameters and pins must lie in [0,1]")
		end
		if surface then
			local p = Vector2.new(params[1], params[2])
			params[1], params[2] = p.X, p.Y
		end
	end
	local function variable(kind, id, axis, lo, hi)
		model.variables[#model.variables + 1] = { kind = kind, id = id, axis = axis, lower = lo, upper = hi }
		assert(#model.variables <= ctx.maxVariables, "Nonlinear fitting variable budget exceeded")
	end
	for id = 1, model.count do
		if options.optimizeControls ~= false and not pins[id] then
			for axis = 1, 3 do
				variable("point", id, axis)
			end
		end
		if options.optimizeWeights and not weightPins[id] then
			variable("weight", id, nil, -ctx.maxLogWeightChange, ctx.maxLogWeightChange)
		end
	end
	if options.optimizeParameters ~= false then
		for i = 1, #samples do
			for axis = 1, surface and 2 or 1 do
				if not parameterPins[i][axis] then
					local periodic = axis == 1 and model.periodicU or axis == 2 and model.periodicV
					variable("parameter", i, axis, not periodic and 0 or nil, not periodic and 1 or nil)
				end
			end
		end
	end
	model.parameterPins = parameterPins
	return model, state
end

function M.descriptor(model, state)
	local config = table.clone(model.source)
	config.maxControls = model.ctx.maxExpandedControls
	if not model.surface then
		config.weights = state.weights
		return model.periodicU and C.curve(state.points, config.degree, config)
			or N.curve(state.points, config.degree, config)
	end
	local points, weights = {}, {}
	for i = 1, model.nu do
		points[i], weights[i] = {}, {}
		for j = 1, model.nv do
			local id = (i - 1) * model.nv + j
			points[i][j], weights[i][j] = state.points[id], state.weights[id]
		end
	end
	config.weights = weights
	return (model.periodicU or model.periodicV) and C.surface(points, config.degreeU, config.degreeV, config)
		or N.surface(points, config.degreeU, config.degreeV, config)
end

function M.evaluate(model, state, jacobian)
	local descriptor = M.descriptor(model, state)
	local expanded = descriptor.kind == "cyclicCurve" and C.toNURBS(descriptor)
		or descriptor.kind == "cyclicSurface" and C.surfaceToNURBS(descriptor)
		or descriptor
	local evaluator = model.surface and N.compileSurface(expanded) or N.compileCurve(expanded)
	local eu, ev =
		model.surface and #expanded.control or #expanded.points, model.surface and #expanded.control[1] or 1
	local degreeU, degreeV =
		model.surface and expanded.degreeU or expanded.degree, model.surface and expanded.degreeV or 0
	model.ctx.charge(#model.data * eu * ev * (degreeU + degreeV + 1))
	local result =
		{ cost = 0, sumError = 0, maximumError = 0, residual = {}, matrix = {}, descriptor = descriptor }
	local maxWeight = 0
	for _, weight in state.weights do
		maxWeight = math.max(maxWeight, weight)
	end
	for sample, target in model.data do
		model.ctx.check("evaluate")
		local params = state.parameters[sample]
		local info = model.surface and evaluator.derivatives(params[1], params[2])
			or evaluator.derivatives(params[1])
		local point = info.position
		local residual = { point.X - target.X, point.Y - target.Y, point.Z - target.Z }
		local squared = residual[1] ^ 2 + residual[2] ^ 2 + residual[3] ^ 2
		result.sumError += squared
		result.maximumError = math.max(result.maximumError, math.sqrt(squared))
		local scale = math.sqrt(model.confidence[sample]) / model.scale
		for axis = 1, 3 do
			local r = residual[axis] * scale
			result.residual[#result.residual + 1] = r
			result.cost += r * r
		end
		if jacobian then
			local a = basis(eu, degreeU, model.surface and expanded.knotsU or expanded.knots, params[1])
			local b = model.surface and basis(ev, degreeV, expanded.knotsV, params[2]) or { 1 }
			local coefficients, denominator = table.create(model.count, 0), 0
			for i = 1, eu do
				for j = 1, ev do
					local id = ((i - 1) % model.nu) * model.nv + (j - 1) % model.nv + 1
					local value = a[i] * b[j] * (state.weights[id] / maxWeight)
					coefficients[id] += value
					denominator += value
				end
			end
			assert(denominator > 0 and U.finite(denominator), "Fitting denominator outside numerical range")
			local rows = { {}, {}, {} }
			for column, variable in model.variables do
				local x, y, z = 0, 0, 0
				if variable.kind == "point" then
					local value = coefficients[variable.id] / denominator * model.scale
					if variable.axis == 1 then
						x = value
					elseif variable.axis == 2 then
						y = value
					else
						z = value
					end
				elseif variable.kind == "weight" then
					local p = state.points[variable.id]
					local r = coefficients[variable.id] / denominator
					x, y, z = (p.X - point.X) * r, (p.Y - point.Y) * r, (p.Z - point.Z) * r
				elseif variable.id == sample then
					local tangent = not model.surface and info.first
						or variable.axis == 1 and info.du
						or info.dv
					x, y, z = tangent.X, tangent.Y, tangent.Z
				end
				rows[1][column], rows[2][column], rows[3][column] = x * scale, y * scale, z * scale
			end
			for _, row in rows do
				result.matrix[#result.matrix + 1] = row
			end
		end
	end
	assert(U.finite(result.cost), "Fitting residual outside numerical range")
	model.ctx.evaluations += 1
	return result
end

function M.value(model, state, variable)
	if variable.kind == "weight" then
		return math.log(state.weights[variable.id] / model.baseWeights[variable.id])
	elseif variable.kind == "parameter" then
		return state.parameters[variable.id][variable.axis]
	end
	return 0
end

function M.step(model, state, delta)
	local nextState =
		{ points = table.clone(state.points), weights = table.clone(state.weights), parameters = {} }
	for i, params in state.parameters do
		nextState.parameters[i] = table.clone(params)
	end
	local coordinates = {}
	local factor = 1
	for i, variable in model.variables do
		local limit = variable.kind == "parameter" and 0.25 or variable.kind == "weight" and 1 or 1
		if math.abs(delta[i][1]) > limit then
			factor = math.min(factor, limit / math.abs(delta[i][1]))
		end
	end
	for i, variable in model.variables do
		local change = delta[i][1] * factor
		local id = variable.id
		if variable.kind == "point" then
			if not coordinates[id] then
				local p = state.points[id]
				coordinates[id] = { p.X, p.Y, p.Z }
			end
			coordinates[id][variable.axis] += change * model.scale
		else
			local value = M.value(model, state, variable) + change
			if variable.lower then
				value = math.max(variable.lower, value)
			end
			if variable.upper then
				value = math.min(variable.upper, value)
			end
			if variable.kind == "weight" then
				value = model.baseWeights[id] * math.exp(value)
				if not U.finite(value) or value <= 0 then
					return nil
				end
				nextState.weights[id] = value
			else
				if not variable.lower then
					value %= 1
				end
				nextState.parameters[id][variable.axis] = value
			end
		end
	end
	for id, p in coordinates do
		local value = Vector3.new(p[1], p[2], p[3])
		if not U.vector(value) then
			return nil
		end
		nextState.points[id] = value
	end
	if model.surface then
		for i, params in nextState.parameters do
			local p = Vector2.new(params[1], params[2])
			-- Reports return native Vector2 parameters, so accept against that same precision.
			params[1], params[2] = p.X, p.Y
		end
	end
	return nextState
end

function M.parameters(model, state)
	local out = {}
	for i, p in state.parameters do
		out[i] = model.surface and Vector2.new(p[1], p[2]) or p[1]
	end
	return out
end
return M
