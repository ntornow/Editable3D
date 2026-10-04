-- Private bounded L-BFGS with descent checks on the rounded candidate coordinates.
local U = require(script.Parent.Util)
local O = {}
local function dot(a, b, visit)
	local value = 0
	for i, x in a do
		visit(1)
		value += x * b[i]
	end
	return value
end
local function maximum(values)
	local result = 0
	for _, value in values do
		if not U.finite(value) then
			return math.huge
		end
		result = math.max(result, math.abs(value))
	end
	return result
end
function O.solve(initial, movable, evaluate, native, options, visit, checkpoint)
	local x = table.clone(initial)
	local indices = {}
	for _, id in movable do
		table.insert(indices, 2 * id - 1)
		table.insert(indices, 2 * id)
	end
	local function evaluateFree(coordinates)
		local value, full = evaluate(coordinates)
		local gradient = {}
		for i, j in indices do
			visit(1)
			gradient[i] = full[j]
		end
		return value, gradient
	end
	local energy, gradient = evaluateFree(x)
	local report = {
		initialEnergy = energy,
		energy = energy,
		iterations = 0,
		history = {},
		converged = false,
		lineSearchSteps = 0,
	}
	local history = {}
	local resultNative
	for iteration = 0, options.iterations do
		report.energy, report.gradientNorm = energy, maximum(gradient)
		table.insert(report.history, { energy = energy, gradientNorm = report.gradientNorm })
		checkpoint("relaxIteration")
		if not U.finite(energy) or not U.finite(report.gradientNorm) then
			report.reason = "nonfiniteEnergy"
			break
		end
		if report.gradientNorm <= options.gradientTolerance then
			report.converged = true
			break
		end
		if iteration == options.iterations then
			report.reason = "iterationLimit"
			break
		end
		local q, alphas = table.clone(gradient), {}
		for i = #history, 1, -1 do
			local item = history[i]
			local alpha = item.rho * dot(item.s, q, visit)
			alphas[i] = alpha
			for j in q do
				visit(1)
				q[j] -= alpha * item.y[j]
			end
		end
		local gamma = 1
		if #history > 0 then
			local last = history[#history]
			gamma = dot(last.s, last.y, visit) / dot(last.y, last.y, visit)
		end
		local direction = {}
		for i, value in q do
			visit(1)
			direction[i] = gamma * value
		end
		for i, item in history do
			local beta = item.rho * dot(item.y, direction, visit)
			for j in direction do
				visit(1)
				direction[j] += item.s[j] * (alphas[i] - beta)
			end
		end
		for i in direction do
			direction[i] = -direction[i]
		end
		local slope = dot(direction, gradient, visit)
		if not U.finite(slope) or slope >= 0 then
			table.clear(history)
			for i, value in gradient do
				direction[i] = -value
			end
		end
		local step = math.min(1, 0.25 / maximum(direction))
		local accepted = false
		for _ = 1, options.lineSearchSteps do
			report.lineSearchSteps += 1
			local candidate = table.clone(x)
			for i, j in indices do
				visit(1)
				candidate[j] += step * direction[i]
			end
			local payload
			candidate, payload = native(candidate)
			if candidate then
				local nextEnergy, nextGradient = evaluateFree(candidate)
				local delta = {}
				for i, j in indices do
					visit(1)
					delta[i] = candidate[j] - x[j]
				end
				local actualSlope = dot(delta, gradient, visit)
				if actualSlope < 0 and nextEnergy < energy and nextEnergy <= energy + 1e-4 * actualSlope then
					local difference = {}
					for i, value in nextGradient do
						visit(1)
						difference[i] = value - gradient[i]
					end
					local curvature = dot(delta, difference, visit)
					local lengthProduct =
						math.sqrt(dot(delta, delta, visit) * dot(difference, difference, visit))
					if
						U.finite(curvature)
						and U.finite(lengthProduct)
						and curvature > 1e-12 * lengthProduct
					then
						table.insert(history, { s = delta, y = difference, rho = 1 / curvature })
						if #history > options.historySize then
							table.remove(history, 1)
						end
					end
					x, energy, gradient = candidate, nextEnergy, nextGradient
					resultNative = payload
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
	return x, report, resultNative
end
return O
