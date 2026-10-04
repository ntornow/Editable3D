-- Fixed-weight linear fits and bounded nonlinear rational spline refinement.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local QR = require(script.Parent.DenseQR)
local F = {}

local function parameters(points, supplied, mode)
	local n, out = #points, {}
	assert(n >= 2, "At least two samples required")
	for _, p in points do
		assert(U.vector(p), "Finite Vector3 samples required")
	end
	if supplied then
		assert(#supplied == n, "Parameter count mismatch")
		for i, t in supplied do
			assert(
				U.finite(t) and t >= 0 and t <= 1 and (i == 1 or t > supplied[i - 1]),
				"Strictly increasing parameters in [0,1] required"
			)
			out[i] = t
		end
		assert(out[1] == 0 and out[n] == 1, "Fitting parameters must span [0,1]")
		return out
	end
	mode = mode or "chord"
	assert(mode == "chord" or mode == "centripetal" or mode == "uniform", "Unknown parameterization")
	out[1] = 0
	for i = 2, n do
		local delta = (points[i] - points[i - 1]).Magnitude
		out[i] = out[i - 1] + (mode == "uniform" and 1 or mode == "centripetal" and math.sqrt(delta) or delta)
	end
	local total = out[n]
	for i = 1, n do
		out[i] = total > 0 and out[i] / total or (i - 1) / (n - 1)
	end
	for i = 2, n do
		assert(out[i] > out[i - 1], "Repeated chord parameter; use uniform or provide distinct parameters")
	end
	return out
end

local function averagedKnots(params, degree)
	local n, knots = #params, {}
	for _ = 1, degree + 1 do
		table.insert(knots, 0)
	end
	for j = 1, n - degree - 1 do
		local sum = 0
		for i = j + 1, j + degree do
			sum += params[i]
		end
		table.insert(knots, sum / degree)
	end
	for _ = 1, degree + 1 do
		table.insert(knots, 1)
	end
	return knots
end

local function checkedBudget(samples, controls, options)
	U.integer(controls, 2)
	assert(controls <= (options.maxControls or 256), "Fitting control budget exceeded")
	assert(samples <= (options.maxSamples or 10000), "Fitting sample budget exceeded")
	assert(
		samples * controls <= (options.maxMatrixEntries or 1000000),
		"Fitting matrix allocation budget exceeded"
	)
	assert(
		samples * controls * (controls + 3) <= (options.maxWork or 50000000),
		"Fitting work budget exceeded"
	)
	if options.rankTolerance then
		assert(
			U.finite(options.rankTolerance) and options.rankTolerance > 0,
			"Positive rank tolerance required"
		)
	end
end

local function solve(rows, data, controlCount, pins, sampleWeights, options)
	local origin = data[1]
	local free, freeMap = {}, {}
	for index, point in pins do
		U.integer(index, 1)
		assert(index <= controlCount and U.vector(point), "Invalid fixed control")
	end
	for i = 1, controlCount do
		if not pins[i] then
			table.insert(free, i)
			freeMap[i] = #free
		end
	end
	assert(#data >= #free, "Underdetermined fit; reduce control count or supply pins")
	local maximumWeight = 1
	if sampleWeights then
		assert(#sampleWeights == #data, "Sample weight count mismatch")
		maximumWeight = 0
		for _, w in sampleWeights do
			assert(U.finite(w) and w > 0, "Positive finite sample weights required")
			maximumWeight = math.max(maximumWeight, w)
		end
	end
	local matrix, rhs = {}, {}
	for sample, row in rows do
		local scale = sampleWeights and math.sqrt(sampleWeights[sample] / maximumWeight) or 1
		local point = data[sample]
		local x, y, z = point.X - origin.X, point.Y - origin.Y, point.Z - origin.Z
		for index, p in pins do
			local w = row[index]
			x -= (p.X - origin.X) * w
			y -= (p.Y - origin.Y) * w
			z -= (p.Z - origin.Z) * w
		end
		matrix[sample], rhs[sample] = {}, { x * scale, y * scale, z * scale }
		for index, column in freeMap do
			matrix[sample][column] = row[index] * scale
		end
	end
	local solutions, diagnostics = {}, { rank = 0, rows = #data, columns = 0, method = "Fixed controls" }
	if #free > 0 then
		solutions, diagnostics = QR(matrix, rhs, #free, options)
		assert(solutions, "Fitting system is rank deficient or ill-conditioned")
	end
	local controls = {}
	for i = 1, controlCount do
		if pins[i] then
			controls[i] = pins[i]
		else
			local p = solutions[freeMap[i]]
			controls[i] = origin + Vector3.new(p[1], p[2], p[3])
			assert(U.vector(controls[i]), "Fitted control exceeds coordinate range")
		end
	end
	return controls, diagnostics
end

local function residuals(data, evaluate)
	local sum, maximum = 0, 0
	for i, p in data do
		local error = (evaluate(i) - p).Magnitude
		sum += error * error
		maximum = math.max(maximum, error)
	end
	return math.sqrt(sum / #data), maximum
end

function F.curve(points, degree, controlCount, options)
	options = options or {}
	checkedBudget(#points, controlCount, options)
	local params = parameters(points, options.parameters, options.parameterization)
	local knots = options.knots or (controlCount == #points and averagedKnots(params, degree) or nil)
	local basisCurve = N.curve(
		table.create(controlCount, Vector3.zero),
		degree,
		{ weights = options.weights, knots = knots }
	)
	local rows = {}
	for i, t in params do
		rows[i] = N.basisWeights(basisCurve, t)
	end
	local pins = table.clone(options.pins or {})
	if options.pinEndpoints ~= false then
		assert(not pins[1] or pins[1] == points[1], "Endpoint pin conflicts with sample")
		assert(
			not pins[controlCount] or pins[controlCount] == points[#points],
			"Endpoint pin conflicts with sample"
		)
		pins[1], pins[controlCount] = points[1], points[#points]
	end
	local controls, report = solve(rows, points, controlCount, pins, options.sampleWeights, options)
	local curve = N.curve(controls, degree, { weights = basisCurve.weights, knots = basisCurve.knots })
	report.rmsError, report.maximumError = residuals(points, function(i)
		return N.evaluate(curve, params[i])
	end)
	report.parameters, report.samples, report.controls = params, #points, controlCount
	report.success = true
	return curve, report
end

function F.interpolateCurve(points, degree, options)
	local curve, report = F.curve(points, degree, #points, options)
	local tolerance = (options or {}).tolerance or 1e-4
	assert(U.finite(tolerance) and tolerance >= 0, "Finite nonnegative interpolation tolerance required")
	assert(report.maximumError <= tolerance, "Curve interpolation exceeded requested tolerance")
	report.interpolated, report.tolerance = true, tolerance
	return curve, report
end

local function gridParameters(grid, axis, supplied, mode)
	local count = axis == "U" and #grid or #grid[1]
	local lines = axis == "U" and #grid[1] or #grid
	if supplied then
		local points = {}
		for i = 1, count do
			points[i] = axis == "U" and grid[i][1] or grid[1][i]
		end
		return parameters(points, supplied, mode)
	end
	local out = table.create(count, 0)
	for line = 1, lines do
		local points = {}
		for i = 1, count do
			points[i] = axis == "U" and grid[i][line] or grid[line][i]
		end
		local values = parameters(points, supplied, mode)
		for i, t in values do
			out[i] += t / lines
		end
	end
	out[1], out[count] = 0, 1
	return out
end

function F.surface(grid, degreeU, degreeV, controlsU, controlsV, options)
	options = options or {}
	U.integer(controlsU, 2)
	U.integer(controlsV, 2)
	local nu, nv = #grid, #grid > 0 and #grid[1] or 0
	assert(nu >= 2 and nv >= 2, "At least a 2x2 sample grid required")
	checkedBudget(nu * nv, controlsU * controlsV, options)
	for _, row in grid do
		assert(#row == nv, "Rectangular sample grid required")
		for _, p in row do
			assert(U.vector(p), "Finite Vector3 samples required")
		end
	end
	local pu = gridParameters(grid, "U", options.parametersU, options.parameterization)
	local pv = gridParameters(grid, "V", options.parametersV, options.parameterization)
	local cu = N.curve(
		table.create(controlsU, Vector3.zero),
		degreeU,
		{ knots = options.knotsU or (controlsU == nu and averagedKnots(pu, degreeU) or nil) }
	)
	local cv = N.curve(
		table.create(controlsV, Vector3.zero),
		degreeV,
		{ knots = options.knotsV or (controlsV == nv and averagedKnots(pv, degreeV) or nil) }
	)
	local weights, dummy, maximumWeight = {}, {}, 0
	if options.weights then
		assert(#options.weights == controlsU, "Surface weight rows mismatch")
	end
	for i = 1, controlsU do
		weights[i], dummy[i] = {}, table.create(controlsV, Vector3.zero)
		if options.weights then
			assert(#options.weights[i] == controlsV, "Surface weight columns mismatch")
		end
		for j = 1, controlsV do
			local w = options.weights and options.weights[i][j] or 1
			assert(U.finite(w) and w > 0, "Positive surface weights required")
			weights[i][j] = w
			maximumWeight = math.max(maximumWeight, w)
		end
	end
	local basisU, basisV = {}, {}
	for i, t in pu do
		basisU[i] = N.basisWeights(cu, t)
	end
	for j, t in pv do
		basisV[j] = N.basisWeights(cv, t)
	end
	local rows, samples, locations, sampleWeights = {}, {}, {}, options.sampleWeights and {} or nil
	if options.sampleWeights then
		assert(#options.sampleWeights == nu, "Sample weight rows mismatch")
	end
	for a = 1, nu do
		if options.sampleWeights then
			assert(#options.sampleWeights[a] == nv, "Sample weight columns mismatch")
		end
		for b = 1, nv do
			local row, denominator = {}, 0
			for i = 1, controlsU do
				for j = 1, controlsV do
					local value = basisU[a][i] * basisV[b][j] * (weights[i][j] / maximumWeight)
					row[(i - 1) * controlsV + j] = value
					denominator += value
				end
			end
			assert(denominator > 0, "Surface denominator is outside numeric range")
			for i, value in row do
				row[i] = value / denominator
			end
			table.insert(rows, row)
			table.insert(samples, grid[a][b])
			table.insert(locations, { pu[a], pv[b] })
			if sampleWeights then
				table.insert(sampleWeights, options.sampleWeights[a][b])
			end
		end
	end
	local pins = {}
	for i, row in options.pins or {} do
		U.integer(i, 1)
		assert(i <= controlsU, "Surface pin row outside control net")
		for j, p in row do
			U.integer(j, 1)
			assert(j <= controlsV, "Surface pin column outside control net")
			pins[(i - 1) * controlsV + j] = p
		end
	end
	local controls, report = solve(rows, samples, controlsU * controlsV, pins, sampleWeights, options)
	for i = 1, controlsU do
		for j = 1, controlsV do
			dummy[i][j] = controls[(i - 1) * controlsV + j]
		end
	end
	local surface =
		N.surface(dummy, degreeU, degreeV, { weights = weights, knotsU = cu.knots, knotsV = cv.knots })
	report.rmsError, report.maximumError = residuals(samples, function(i)
		return N.evaluateSurface(surface, locations[i][1], locations[i][2])
	end)
	report.parametersU, report.parametersV = pu, pv
	report.samples, report.controlsU, report.controlsV, report.success = #samples, controlsU, controlsV, true
	return surface, report
end

function F.interpolateSurface(grid, degreeU, degreeV, options)
	local surface, report = F.surface(grid, degreeU, degreeV, #grid, #grid > 0 and #grid[1] or 0, options)
	local tolerance = (options or {}).tolerance or 1e-4
	assert(U.finite(tolerance) and tolerance >= 0, "Finite nonnegative interpolation tolerance required")
	assert(report.maximumError <= tolerance, "Surface interpolation exceeded requested tolerance")
	report.interpolated, report.tolerance = true, tolerance
	return surface, report
end

function F.refineCurve(initial, points, options)
	return require(script.Parent.NonlinearFit).run(initial, points, false, options)
end

function F.refineSurface(initial, points, options)
	return require(script.Parent.NonlinearFit).run(initial, points, true, options)
end

return F
