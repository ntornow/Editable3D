-- Recover nonseparable rational weights, then tessellate the editable result.
return function(E)
	E = E or require(script.Parent.Parent)
	local controls = {}
	for i = 1, 3 do
		controls[i] = {}
		for j = 1, 3 do
			controls[i][j] = Vector3.new(i - 1, i == 2 and j == 2 and 1 or 0, j - 1)
		end
	end
	local target = E.NURBS.surface(
		controls,
		2,
		2,
		{ weights = { { 1, 0.8, 1.2 }, { 1.5, 0.55, 1.1 }, { 0.9, 1.3, 1 } } }
	)
	local samples, parameters = {}, {}
	local evaluate = E.NURBS.compileSurface(target)
	for i = 0, 4 do
		for j = 0, 4 do
			local uv = Vector2.new(i / 4, j / 4)
			parameters[#parameters + 1] = uv
			samples[#samples + 1] = evaluate.evaluate(uv.X, uv.Y)
		end
	end
	local initial = E.NURBS.surface(controls, 2, 2)
	local surface, fit = E.SplineFit.refineSurface(initial, samples, {
		parameters = parameters,
		optimizeControls = false,
		optimizeParameters = false,
		optimizeWeights = true,
		tolerance = 2e-6,
		maxIterations = 60,
		requireConverged = true,
	})
	assert(fit.toleranceSatisfied and fit.cost < fit.initialCost and initial.weights[2][2] == 1)
	local mesh = E.NURBS.tessellate(surface, 20, 20)
	assert(mesh:validate().valid)
	return { surface = surface, fit = fit, mesh = mesh, samples = samples, source = E.IO.encode(mesh) }
end
