-- Private sequential equality-constrained quadratic steps in positive angle space.
local U = require(script.Parent.Util)
local System = require(script.Parent.AngleConstraintSystem)
local Linear = require(script.Parent.UVLinearSolver)
local O = {}
local function norms(values)
	local maximum, total = 0, 0
	for _, value in values do
		maximum = math.max(maximum, math.abs(value))
		total += math.abs(value)
	end
	return maximum, total
end
function O.solve(target, fans, options, visit, checkpoint)
	local minimum = options.minimumAngle
	local inverse, weight, alpha = {}, {}, {}
	for i, beta in target do
		visit(1)
		weight[i] = math.max(beta, minimum)
		inverse[i] = weight[i] ^ 2 / 2
		alpha[i] = math.clamp(beta, minimum * 1.01, math.pi - minimum * 1.01)
	end
	local function energy(angles)
		local value = 0
		for i, a in angles do
			visit(1)
			value += ((a - target[i]) / weight[i]) ^ 2
		end
		return value
	end
	local report =
		{ converged = false, iterations = 0, history = {}, linearIterations = 0, lineSearchSteps = 0 }
	for iteration = 0, options.iterations do
		local values, rows = System.evaluate(alpha, fans, visit, true)
		local constraint, l1 = norms(values)
		local objective = energy(alpha)
		local gradient, scaled = {}, {}
		for i, a in alpha do
			visit(1)
			gradient[i] = (a - target[i]) / inverse[i]
			scaled[i] = a - target[i]
		end
		local rhs = System.multiply(rows, scaled, visit)
		local diagonal = {}
		for i, row in rows do
			rhs[i] = values[i] - rhs[i]
			local sum = 0
			for k, index in row.indices do
				visit(1)
				sum += row.values[k] ^ 2 * inverse[index]
			end
			diagonal[i] = sum
		end
		local function multiply(x)
			local transposed = System.transpose(rows, x, #alpha, visit)
			for i in transposed do
				visit(1)
				transposed[i] *= inverse[i]
			end
			return System.multiply(rows, transposed, visit)
		end
		local lambda, linear = Linear.solve(rhs, diagonal, multiply, options.linear, visit)
		report.linearIterations += linear.iterations
		local jt = System.transpose(rows, lambda, #alpha, visit)
		local direction, relative, slope = {}, 0, 0
		for i in alpha do
			visit(1)
			direction[i] = -inverse[i] * (gradient[i] + jt[i])
			relative = math.max(relative, math.abs(direction[i]) / weight[i])
			slope += gradient[i] * direction[i]
		end
		report.energy, report.constraintResidual, report.relativeStep, report.linear =
			objective, constraint, relative, linear
		table.insert(report.history, {
			energy = objective,
			constraintResidual = constraint,
			relativeStep = relative,
			linearResidual = linear.residual,
		})
		checkpoint("angleIteration")
		if not linear.converged then
			report.reason = "linearSolve"
			break
		end
		if constraint <= options.constraintTolerance and relative <= options.stationarityTolerance then
			report.converged = true
			break
		end
		if iteration == options.iterations then
			report.reason = "iterationLimit"
			break
		end
		local multiplier = norms(lambda)
		local penalty = math.max(1, 2 * multiplier)
		slope -= penalty * l1
		if not U.finite(slope) or slope >= 0 then
			report.reason = "nonDescent"
			break
		end
		local step = 1
		for i, a in alpha do
			visit(1)
			local d = direction[i]
			if d < 0 then
				step = math.min(step, 0.99 * (a - minimum) / -d)
			elseif d > 0 then
				step = math.min(step, 0.99 * (math.pi - minimum - a) / d)
			end
		end
		local accepted = false
		local merit = objective + penalty * l1
		for _ = 1, options.lineSearchSteps do
			report.lineSearchSteps += 1
			local candidate = {}
			local valid = true
			for i, a in alpha do
				visit(1)
				candidate[i] = a + step * direction[i]
				valid = valid and candidate[i] > minimum and candidate[i] < math.pi - minimum
			end
			if valid then
				local nextValues = System.evaluate(candidate, fans, visit, false)
				local _, nextL1 = norms(nextValues)
				if energy(candidate) + penalty * nextL1 <= merit + 1e-4 * step * slope then
					alpha = candidate
					accepted = true
					break
				end
			end
			step *= 0.5
		end
		if not accepted then
			report.reason = "lineSearch"
			break
		end
		report.iterations = iteration + 1
	end
	return alpha, report
end
return O
