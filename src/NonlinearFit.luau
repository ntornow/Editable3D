-- Private bounded damped Gauss-Newton fitting with native-coordinate acceptance.
local U = require(script.Parent.Util)
local Model = require(script.Parent.NonlinearFitModel)
local QR = require(script.Parent.DenseQR)
local F = {}

local function positive(value, fallback, zero)
	value = value == nil and fallback or value
	assert(
		type(value) == "number" and U.finite(value) and (zero and value >= 0 or value > 0),
		"Finite valid nonlinear fitting tolerance required"
	)
	return value
end

function F.run(initial, samples, surface, options)
	options = options or {}
	for _, name in { "optimizeControls", "optimizeWeights", "optimizeParameters", "requireConverged" } do
		assert(
			options[name] == nil or type(options[name]) == "boolean",
			"Fitting optimization flags must be boolean"
		)
	end
	local ctx = {
		maxControls = U.integer(options.maxControls or 64, 1),
		maxExpandedControls = U.integer(options.maxExpandedControls or 10000, 1),
		maxSamples = U.integer(options.maxSamples or 1000, 1),
		maxVariables = U.integer(options.maxVariables or 256, 1),
		maxMatrixEntries = U.integer(options.maxMatrixEntries or 1000000, 1),
		maxWork = U.integer(options.maxWork or 200000000, 1),
		maxLogWeightChange = positive(options.maxLogWeightChange, 20),
		work = 0,
		evaluations = 0,
		iterations = 0,
	}
	assert(ctx.maxLogWeightChange <= 100, "Log weight range must be at most 100")
	local iterations = U.integer(options.maxIterations or 30, 0)
	local attempts = U.integer(options.maxAttempts or 8, 1)
	assert(iterations <= 1000 and attempts <= 64, "Nonlinear fitting iteration or attempt limit exceeded")
	local residualTolerance = positive(options.tolerance, 1e-5, true)
	local gradientTolerance = positive(options.gradientTolerance, 1e-8, true)
	local damping = positive(options.damping, 1e-3)
	local rankTolerance = positive(options.rankTolerance, 1e-12)
	assert(
		damping >= 1e-12 and damping <= 1e16 and rankTolerance < 1,
		"Invalid nonlinear fitting damping or rank tolerance"
	)
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Nonlinear fitting cancelled")
		if options.checkpoint then
			options.checkpoint({
				stage = stage,
				work = ctx.work,
				iterations = ctx.iterations,
				evaluations = ctx.evaluations,
			})
		end
	end
	ctx.charge = function(work)
		assert(ctx.work + work <= ctx.maxWork, "Nonlinear fitting work budget exceeded")
		ctx.work += work
	end
	ctx.check("begin")
	local model, state = Model.new(initial, samples, surface, options, ctx)
	local columns = #model.variables
	local rows = 3 * #samples
	assert(
		(rows + columns) * columns <= ctx.maxMatrixEntries,
		"Nonlinear fitting matrix allocation budget exceeded"
	)
	local current = Model.evaluate(model, state, false)
	local initialCost = current.cost
	local history = { current.cost }
	local accepted, rejected, gradient = 0, 0, math.huge
	local converged, reason = false, "iterations"
	local function linearization()
		ctx.charge(rows * columns)
		local value = Model.evaluate(model, state, true)
		local diagonal, g = {}, {}
		for column = 1, columns do
			local sum, dot = 0, 0
			for row = 1, rows do
				local a = value.matrix[row][column]
				assert(U.finite(a), "Fitting derivative outside numerical range")
				sum += a * a
				dot += a * value.residual[row]
			end
			diagonal[column] = math.clamp(math.sqrt(sum), 1e-6, 1e6)
			g[column] = dot
		end
		gradient = 0
		local active = {}
		for column, variable in model.variables do
			local x = Model.value(model, state, variable)
			local slack = variable.kind == "weight" and 1e-12 or 0
			local blocked = (variable.lower and x <= variable.lower + slack and g[column] >= 0)
				or (variable.upper and x >= variable.upper - slack and g[column] <= 0)
			active[column] = not blocked
			if not blocked then
				gradient = math.max(gradient, math.abs(g[column]) / diagonal[column])
			end
		end
		assert(U.finite(gradient), "Fitting gradient outside numerical range")
		return value, diagonal, active
	end
	if columns == 0 then
		converged, reason, gradient = true, "fixed", 0
	elseif current.maximumError <= residualTolerance then
		converged, reason = true, "residual"
	else
		for iteration = 1, iterations do
			ctx.iterations = iteration
			ctx.check("iteration")
			local value, diagonal, active = linearization()
			if gradient <= gradientTolerance then
				converged, reason = true, "gradient"
				break
			end
			local improved = false
			for _ = 1, attempts do
				local cost = (rows + columns) * columns * (columns + 1)
				ctx.charge(cost)
				local matrix, rhs = {}, {}
				for row = 1, rows do
					matrix[row] = table.clone(value.matrix[row])
					for column = 1, columns do
						if not active[column] then
							matrix[row][column] = 0
						end
					end
					rhs[row] = { -value.residual[row] }
				end
				for column = 1, columns do
					local row = table.create(columns, 0)
					row[column] = math.sqrt(damping) * diagonal[column]
					matrix[rows + column], rhs[rows + column] = row, { 0 }
				end
				local delta = QR(matrix, rhs, columns, {
					maxWork = cost,
					maxMatrixEntries = ctx.maxMatrixEntries,
					rankTolerance = rankTolerance,
					checkpoint = function()
						ctx.check("solve")
					end,
				})
				local trial = delta and Model.step(model, state, delta)
				local evaluation = trial and Model.evaluate(model, trial, false)
				if evaluation and evaluation.cost < current.cost then
					state, current = trial, evaluation
					accepted += 1
					table.insert(history, current.cost)
					damping = math.max(1e-12, damping * 0.3)
					improved = true
					break
				end
				rejected += 1
				damping = math.min(1e16, damping * 10)
			end
			if current.maximumError <= residualTolerance then
				converged, reason = true, "residual"
				break
			end
			if not improved then
				reason = "stalled"
				break
			end
		end
		if not converged then
			linearization()
			if gradient <= gradientTolerance then
				converged, reason = true, "gradient"
			end
		end
	end
	local report = {
		complete = converged,
		success = converged,
		converged = converged,
		termination = reason,
		method = "Bounded damped Gauss-Newton / Givens QR",
		regularityChecked = false,
		iterations = ctx.iterations,
		acceptedSteps = accepted,
		rejectedSteps = rejected,
		evaluations = ctx.evaluations,
		work = ctx.work,
		variables = columns,
		samples = #samples,
		controls = model.count,
		initialCost = initialCost,
		cost = current.cost,
		costHistory = history,
		coordinateScale = model.scale,
		rmsError = math.sqrt(current.sumError / #samples),
		maximumError = current.maximumError,
		weightedRmsError = math.sqrt(current.cost / model.totalConfidence) * model.scale,
		tolerance = residualTolerance,
		toleranceSatisfied = current.maximumError <= residualTolerance,
		projectedGradient = reason ~= "residual" and gradient < math.huge and gradient or nil,
		gradientTolerance = gradientTolerance,
		parameters = Model.parameters(model, state),
		weightGaugeControl = model.gaugeControl,
		optimizedControls = options.optimizeControls ~= false,
		optimizedWeights = options.optimizeWeights == true,
		optimizedParameters = options.optimizeParameters ~= false,
	}
	ctx.check("finish")
	assert(not options.requireConverged or converged, "Nonlinear fitting did not converge: " .. reason)
	return current.descriptor, report
end
return F
