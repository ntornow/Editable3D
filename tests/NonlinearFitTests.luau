return function(E)
	local F, N, C = E.SplineFit, E.NURBS, E.Cyclic
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tol)
		assert(math.abs(a - b) < (tol or 1e-4), tostring(a) .. " ~= " .. tostring(b))
	end
	local function vec(a, b, tol)
		assert((a - b).Magnitude < (tol or 1e-4), tostring(a) .. " ~= " .. tostring(b))
	end
	local function monotone(r)
		for i = 2, #r.costHistory do
			assert(r.costHistory[i] < r.costHistory[i - 1])
		end
		assert(r.cost <= r.initialCost and r.work > 0)
	end
	local function arc(weight)
		return N.curve(
			{ Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis },
			2,
			{ weights = { 1, weight or 1, 1 } }
		)
	end
	local function curveSamples(curve, count)
		local p, t = {}, {}
		local evaluator = N.compileCurve(curve.kind == "cyclicCurve" and C.toNURBS(curve) or curve)
		for i = 0, count - 1 do
			t[i + 1] = i / (count - 1)
			p[i + 1] = evaluator.evaluate(t[i + 1])
		end
		return p, t
	end
	local function patch()
		return N.surface({
			{ Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, 2, 0) },
			{ Vector3.new(1, 0, 0), Vector3.new(1, 1, 1), Vector3.new(1, 2, 0) },
			{ Vector3.new(2, 0, 0), Vector3.new(2, 1, 0), Vector3.new(2, 2, 0) },
		}, 2, 2)
	end
	local function surfaceSamples(surface, count)
		local p, t = {}, {}
		local evaluator =
			N.compileSurface(surface.kind == "cyclicSurface" and C.surfaceToNURBS(surface) or surface)
		for i = 0, count - 1 do
			for j = 0, count - 1 do
				local uv = Vector2.new(i / (count - 1), j / (count - 1))
				t[#t + 1] = uv
				p[#p + 1] = evaluator.evaluate(uv.X, uv.Y)
			end
		end
		return p, t
	end
	test("Fixed-control log weight fitting recovers independent circular geometry", function()
		local target = arc(math.sqrt(0.5))
		local data, t = curveSamples(target, 11)
		local source = arc(1.4)
		local fitted, r = F.refineCurve(source, data, {
			parameters = t,
			optimizeControls = false,
			optimizeParameters = false,
			optimizeWeights = true,
			weightPins = { [1] = 1, [3] = 1 },
			tolerance = 1e-6,
		})
		assert(r.converged and r.toleranceSatisfied)
		near(fitted.weights[2], math.sqrt(0.5), 1e-5)
		for i = 0, 20 do
			near(N.evaluate(fitted, i / 20).Magnitude, 1, 2e-6)
		end
		assert(source.weights[2] == 1.4)
		monotone(r)
	end)
	test("Weight gauge and confidence scaling preserve rational fitting", function()
		local data, t = curveSamples(arc(math.sqrt(0.5)), 9)
		local a = arc(1.2)
		local b = arc(1.2)
		for i = 1, 3 do
			b.weights[i] *= 1e80
		end
		local x, r = F.refineCurve(
			a,
			data,
			{ parameters = t, optimizeControls = false, optimizeParameters = false, optimizeWeights = true }
		)
		local y, s = F.refineCurve(b, data, {
			parameters = t,
			optimizeControls = false,
			optimizeParameters = false,
			optimizeWeights = true,
			sampleWeights = table.create(#data, 1e90),
		})
		assert(r.converged and s.converged and r.weightGaugeControl == 1)
		near(y.weights[2] / y.weights[1], x.weights[2] / x.weights[1], 1e-5)
		for i = 0, 10 do
			vec(N.evaluate(x, i / 10), N.evaluate(y, i / 10), 1e-5)
		end
		monotone(r)
		monotone(s)
	end)
	test("Curve correspondence refinement recovers nonuniform parameters", function()
		local source = arc(math.sqrt(0.5))
		local parameters = { 0, 0.02, 0.1, 0.25, 0.55, 0.88, 1 }
		local data = {}
		for i, t in parameters do
			data[i] = N.evaluate(source, t)
		end
		local fitted, r = F.refineCurve(source, data, { optimizeControls = false, tolerance = 1e-6 })
		assert(r.converged and r.toleranceSatisfied and fitted.weights[2] == source.weights[2])
		for i, t in parameters do
			near(r.parameters[i], t, 2e-6)
		end
		monotone(r)
	end)
	test("Open parameter bounds reach closest endpoints with nonzero residual", function()
		local source = N.curve({ Vector3.zero, Vector3.xAxis }, 1)
		local data = { Vector3.new(-2, 1, 0), Vector3.new(0.3, 1, 0), Vector3.new(4, 1, 0) }
		local _, r = F.refineCurve(source, data, { parameters = { 0.3, 0.8, 0.7 }, optimizeControls = false })
		assert(r.converged and r.termination == "gradient" and not r.toleranceSatisfied)
		near(r.parameters[1], 0)
		near(r.parameters[2], 0.3)
		near(r.parameters[3], 1)
		near(r.maximumError, math.sqrt(10), 1e-6)
		monotone(r)
	end)
	test("Native control steps recover independent polynomial coefficients and exact pins", function()
		local source = N.curve({ Vector3.zero, Vector3.new(0.5, -1, 0), Vector3.xAxis }, 2)
		local data, t = {}, {}
		for i = 0, 10 do
			local u = i / 10
			t[i + 1] = u
			data[i + 1] = Vector3.new(u, 2 * u * (1 - u), 0)
		end
		local result, r = F.refineCurve(source, data, {
			parameters = t,
			optimizeParameters = false,
			pins = { [1] = Vector3.zero, [3] = Vector3.xAxis },
			tolerance = 1e-6,
		})
		assert(r.converged and result.points[1] == Vector3.zero and result.points[3] == Vector3.xAxis)
		vec(result.points[2], Vector3.new(0.5, 1, 0), 2e-6)
		assert(source.points[2].Y == -1)
		monotone(r)
	end)
	test("Joint curve controls and correspondences improve a displaced rational arc", function()
		local data, t = curveSamples(arc(math.sqrt(0.5)), 9)
		local source = arc(1)
		source.points[2] += Vector3.new(0.08, -0.05, 0.1)
		local result, r = F.refineCurve(source, data, {
			parameters = t,
			optimizeWeights = true,
			pins = { [1] = Vector3.xAxis, [3] = Vector3.yAxis },
			parameterPins = { [1] = 0, [9] = 1 },
			maxIterations = 60,
			tolerance = 2e-5,
		})
		assert(r.converged and r.maximumError < 2e-5)
		assert(result.points[1] == Vector3.xAxis and result.points[3] == Vector3.yAxis)
		monotone(r)
	end)
	test("Periodic curve correspondence crosses the seam without duplicate controls", function()
		local source = C.curve({ Vector3.xAxis, Vector3.yAxis, -Vector3.xAxis, -Vector3.yAxis }, 2)
		local truth = { 0.01, 0.2, 0.55, 0.99 }
		local data = {}
		for i, t in truth do
			data[i] = C.evaluate(source, t)
		end
		local result, r = F.refineCurve(
			source,
			data,
			{ parameters = { 0.96, 0.24, 0.5, 0.03 }, optimizeControls = false, tolerance = 1e-6 }
		)
		assert(r.converged and result.kind == "cyclicCurve" and #result.points == 4)
		for i, t in truth do
			near(r.parameters[i], t, 2e-6)
		end
		vec(C.derivatives(result, 0).first, C.derivatives(result, 1).first)
		monotone(r)
	end)
	test("Nonseparable surface weights are optimized as one rational control grid", function()
		local target = patch()
		target.weights = { { 1, 0.8, 1.2 }, { 1.5, 0.55, 1.1 }, { 0.9, 1.3, 1 } }
		local data, params = surfaceSamples(target, 5)
		local source = patch()
		local result, r = F.refineSurface(source, data, {
			parameters = params,
			optimizeControls = false,
			optimizeParameters = false,
			optimizeWeights = true,
			tolerance = 2e-6,
			maxIterations = 60,
		})
		assert(r.converged and r.weightGaugeControl == "1:1")
		for i = 1, 3 do
			for j = 1, 3 do
				near(result.weights[i][j], target.weights[i][j], 5e-4)
			end
		end
		for i = 0, 7 do
			for j = 0, 7 do
				vec(N.evaluateSurface(result, i / 7, j / 7), N.evaluateSurface(target, i / 7, j / 7), 1e-5)
			end
		end
		monotone(r)
	end)
	test("Unstructured surface correspondences refine with independent boundary pins", function()
		local source = patch()
		local truth =
			{ Vector2.new(0, 0.2), Vector2.new(0.3, 0.7), Vector2.new(0.9, 1), Vector2.new(0.8, 0.15) }
		local data = {}
		for i, p in truth do
			data[i] = N.evaluateSurface(source, p.X, p.Y)
		end
		local result, r = F.refineSurface(source, data, {
			parameters = {
				Vector2.new(0, 0.4),
				Vector2.new(0.5, 0.5),
				Vector2.new(0.6, 1),
				Vector2.new(0.7, 0.3),
			},
			parameterPinsU = { [1] = 0 },
			parameterPinsV = { [3] = 1 },
			optimizeControls = false,
			tolerance = 2e-6,
		})
		assert(r.converged and r.parameters[1].X == 0 and r.parameters[3].Y == 1)
		for i, p in truth do
			assert((r.parameters[i] - p).Magnitude < 3e-6)
		end
		assert(result.control[2][2] == source.control[2][2])
		monotone(r)
	end)
	test("Surface controls preserve pinned borders and exact sample parameter pins", function()
		local target = patch()
		local data, params = surfaceSamples(target, 5)
		local source = patch()
		source.control[2][2] = Vector3.new(1.2, 0.8, -1)
		local pins = {}
		for i = 1, 3 do
			for j = 1, 3 do
				if i ~= 2 or j ~= 2 then
					pins[i .. ":" .. j] = target.control[i][j]
				end
			end
		end
		local fitted, r = F.refineSurface(
			source,
			data,
			{ parameters = params, optimizeParameters = false, pins = pins, tolerance = 2e-6 }
		)
		assert(r.converged)
		vec(fitted.control[2][2], target.control[2][2], 5e-6)
		for key, point in pins do
			local a, b = key:match("(%d+):(%d+)")
			assert(fitted.control[tonumber(a)][tonumber(b)] == point)
		end
		monotone(r)
	end)
	test("Periodic surface fitting retains unique seam controls and UV directions", function()
		local p = {}
		for i = 1, 4 do
			p[i] = {}
			for j = 1, 3 do
				local a = (i - 1) * math.pi / 2
				p[i][j] = Vector3.new(math.cos(a), j - 1, math.sin(a))
			end
		end
		local source = C.surface(p, 2, 2, { cyclicU = true, cyclicV = false })
		local truth = { Vector2.new(0.01, 0.2), Vector2.new(0.5, 0.7), Vector2.new(0.99, 0.4) }
		local data = {}
		for i, t in truth do
			data[i] = C.evaluateSurface(source, t.X, t.Y)
		end
		local fitted, r = F.refineSurface(source, data, {
			parameters = { Vector2.new(0.96, 0.3), Vector2.new(0.45, 0.6), Vector2.new(0.04, 0.6) },
			optimizeControls = false,
			tolerance = 2e-6,
		})
		assert(r.converged and fitted.cyclicU and not fitted.cyclicV and #fitted.control == 4)
		for i, t in truth do
			assert((r.parameters[i] - t).Magnitude < 5e-6)
		end
		vec(C.evaluateSurface(fitted, 0, 0.3), C.evaluateSurface(fitted, 1, 0.3))
		monotone(r)
	end)
	test("Analytic control weight and correspondence Jacobians match centered differences", function()
		local Model = require(script.Parent.NonlinearFitModel)
		for _, surface in { false, true } do
			local ctx = {
				maxControls = 64,
				maxExpandedControls = 10000,
				maxSamples = 100,
				maxVariables = 256,
				maxLogWeightChange = 20,
				evaluations = 0,
				charge = function() end,
				check = function() end,
			}
			local initial = surface and patch() or arc(0.8)
			if surface then
				initial.weights[2][2] = 0.7
			end
			local parameters = surface and { Vector2.new(0.23, 0.61), Vector2.new(0.73, 0.37) }
				or { 0.23, 0.73 }
			local model, state = Model.new(
				initial,
				{ Vector3.new(0.1, 0.2, 0.3), Vector3.new(0.5, 0.7, 0.1) },
				surface,
				{ parameters = parameters, optimizeWeights = true },
				ctx
			)
			local exact = Model.evaluate(model, state, true)
			for column = 1, #model.variables do
				local plus, minus = {}, {}
				for i = 1, #model.variables do
					plus[i] = { i == column and 0.001 or 0 }
					minus[i] = { i == column and -0.001 or 0 }
				end
				local a = Model.evaluate(model, Model.step(model, state, plus), false)
				local b = Model.evaluate(model, Model.step(model, state, minus), false)
				for row = 1, #exact.residual do
					near((a.residual[row] - b.residual[row]) / 0.002, exact.matrix[row][column], 0.0002)
				end
			end
		end
	end)
	test("Confidence weights recover an independent constrained weighted mean", function()
		local source = N.curve({ Vector3.zero, Vector3.zero }, 1)
		local data = { Vector3.new(1, 0, 0), Vector3.new(3, 2, 0), Vector3.new(5, -2, 0) }
		local fitted, r = F.refineCurve(source, data, {
			parameters = { 0.5, 0.5, 0.5 },
			pins = { [1] = Vector3.zero },
			sampleWeights = { 1, 3, 2 },
			optimizeParameters = false,
			gradientTolerance = 1e-7,
		})
		assert(r.converged and not r.toleranceSatisfied)
		vec(fitted.points[2], 2 * (data[1] + 3 * data[2] + 2 * data[3]) / 6, 2e-6)
		local weighted = 0
		for i, w in { 1, 3, 2 } do
			weighted += w * (N.evaluate(fitted, 0.5) - data[i]).Magnitude ^ 2
		end
		near(r.weightedRmsError, math.sqrt(weighted / 6), 1e-6)
		monotone(r)
	end)
	test("Weight recovery is covariant under moderate world transforms and scale", function()
		local target = arc(math.sqrt(0.5))
		local source = arc(1.3)
		local frame = CFrame.new(1024, -512, 256) * CFrame.Angles(0.2, -0.4, 0.7)
		for _, curve in { target, source } do
			for i, p in curve.points do
				curve.points[i] = frame:PointToWorldSpace(p * 7.5)
			end
		end
		local data, t = curveSamples(target, 11)
		local fitted, r = F.refineCurve(source, data, {
			parameters = t,
			optimizeControls = false,
			optimizeParameters = false,
			optimizeWeights = true,
			weightPins = { [1] = 1, [3] = 1 },
			tolerance = 0.0002,
		})
		assert(r.converged)
		near(fitted.weights[2], math.sqrt(0.5), 0.0002)
		monotone(r)
	end)
	test("Log weight bounds remain positive and report constrained stationarity", function()
		local data, t = curveSamples(arc(10), 9)
		local fitted, r = F.refineCurve(arc(), data, {
			parameters = t,
			optimizeControls = false,
			optimizeParameters = false,
			optimizeWeights = true,
			weightPins = { [1] = 1, [3] = 1 },
			maxLogWeightChange = 0.1,
		})
		assert(r.converged and r.termination == "gradient" and not r.toleranceSatisfied)
		near(fitted.weights[2], math.exp(0.1), 1e-12)
		assert(fitted.weights[2] > 0)
		monotone(r)
	end)
	test("Native coordinate plateaus report stalled fitting without false convergence", function()
		local origin = Vector3.new(1e8, 0, 0)
		local source = N.curve({ origin, origin }, 1)
		local fitted, r = F.refineCurve(source, { origin, origin + Vector3.new(8, 0, 0) }, {
			parameters = { 0.5, 0.5 },
			pins = { [1] = origin },
			optimizeParameters = false,
			tolerance = 0.1,
			gradientTolerance = 1e-12,
			maxAttempts = 4,
		})
		assert(not r.converged and r.termination == "stalled" and r.acceptedSteps == 0)
		assert(fitted.points[2] == origin and source.points[1] == origin)
		near(r.maximumError, 8)
	end)
	test("Unclamped nonuniform knots remain unchanged during control fitting", function()
		local source = N.curve({
			Vector3.new(-1, 0, 0),
			Vector3.zero,
			Vector3.new(1, 1, 0),
			Vector3.new(2, 0, 0),
			Vector3.new(3, 0, 0),
		}, 2, { clamped = false, knots = { -2, -1, 0, 0.3, 0.8, 1, 2, 4 }, weights = { 1, 2, 0.8, 1.2, 1 } })
		local target = N.curve(source.points, 2, source)
		for i, p in target.points do
			target.points[i] = p + Vector3.new(0, 0, 0.5)
		end
		local data, t = curveSamples(target, 13)
		local fitted, r =
			F.refineCurve(source, data, { parameters = t, optimizeParameters = false, tolerance = 2e-6 })
		assert(r.converged and fitted.clamped == false)
		for i, knot in source.knots do
			assert(fitted.knots[i] == knot)
		end
		for i = 0, 17 do
			vec(N.evaluate(fitted, i / 17), N.evaluate(target, i / 17), 1e-5)
		end
		assert(source.points[1].Z == 0)
		monotone(r)
	end)
	test("Cancellation inside a QR solve leaves source samples and pins unchanged", function()
		local source = arc(1.4)
		local data, t = curveSamples(arc(math.sqrt(0.5)), 9)
		local pins = { [1] = Vector3.xAxis, [3] = Vector3.yAxis }
		local visited = false
		local ok = pcall(function()
			F.refineCurve(source, data, {
				parameters = t,
				pins = pins,
				optimizeWeights = true,
				checkpoint = function(progress)
					if progress.stage == "solve" then
						visited = true
						error("cancel solve")
					end
				end,
			})
		end)
		assert(
			not ok
				and visited
				and source.weights[2] == 1.4
				and data[1] == Vector3.xAxis
				and pins[3] == Vector3.yAxis
		)
	end)
	test("Joint surface fitting decreases residuals with exact corners and retained weights", function()
		local target = patch()
		target.control[2][2] += Vector3.new(0.2, -0.1, 0.2)
		local data, params = surfaceSamples(target, 4)
		local source = patch()
		local pins = {}
		for _, i in { 1, 3 } do
			for _, j in { 1, 3 } do
				pins[i .. ":" .. j] = source.control[i][j]
			end
		end
		local fitted, r = F.refineSurface(
			source,
			data,
			{ parameters = params, pins = pins, maxIterations = 60, tolerance = 1e-5 }
		)
		assert(r.converged and r.cost < r.initialCost and r.maximumError < 1e-5)
		for i, row in fitted.weights do
			for j, w in row do
				assert(w == source.weights[i][j])
			end
		end
		for _, i in { 1, 3 } do
			for _, j in { 1, 3 } do
				assert(fitted.control[i][j] == source.control[i][j])
			end
		end
		monotone(r)
	end)
	test("Fitted rational surfaces retain native geometry normals and UV borders", function()
		local target = patch()
		target.weights[2][2] = 0.6
		local data, params = surfaceSamples(target, 5)
		local fitted, r = F.refineSurface(patch(), data, {
			parameters = params,
			optimizeControls = false,
			optimizeParameters = false,
			optimizeWeights = true,
			tolerance = 2e-6,
		})
		assert(r.converged)
		local mesh = N.tessellate(fitted, 12, 10)
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			local function area(m)
				local sum = 0
				for _, t in m:triangles() do
					local a, b, c = m.vertices[t[1]], m.vertices[t[2]], m.vertices[t[3]]
					sum += (b - a):Cross(c - a).Magnitude / 2
				end
				return sum
			end
			near(area(restored), area(mesh), 1e-5)
			local first, last = false, false
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-4)
					first = first or corner.uv.X == 0
					last = last or corner.uv.X == 1
				end
			end
			assert(first and last)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Fixed models report stationarity separately from requested accuracy", function()
		local source = arc()
		local result, r = F.refineCurve(
			source,
			{ Vector3.new(3, 0, 0) },
			{ parameters = { 0 }, optimizeControls = false, optimizeParameters = false }
		)
		assert(r.converged and r.termination == "fixed" and not r.toleranceSatisfied and r.variables == 0)
		near(r.maximumError, 2)
		result.points[1] = Vector3.zero
		assert(source.points[1] == Vector3.xAxis)
	end)
	test("Iteration exhaustion returns explicit partial progress and strict mode rejects", function()
		local source = arc(2)
		local data, t = curveSamples(arc(math.sqrt(0.5)), 9)
		local opts = {
			parameters = t,
			optimizeControls = false,
			optimizeParameters = false,
			optimizeWeights = true,
			maxIterations = 0,
		}
		local fitted, r = F.refineCurve(source, data, opts)
		assert(not r.converged and not r.complete and not r.success and r.termination == "iterations")
		assert(fitted.weights[2] == 2 and r.acceptedSteps == 0)
		opts.requireConverged = true
		assert(not pcall(function()
			F.refineCurve(source, data, opts)
		end))
	end)
	test("Invalid inputs allocation budgets and cancellation preserve inputs", function()
		local source = arc()
		local data, t = curveSamples(arc(math.sqrt(0.5)), 7)
		local invalid = {
			{ maxControls = 1 },
			{ maxVariables = 1 },
			{ maxSamples = 2 },
			{ maxMatrixEntries = 1 },
			{ maxWork = 1 },
			{ pins = { [99] = Vector3.zero } },
			{ weightPins = { [2] = 0 } },
			{ parameters = { 0, 1 } },
			{ sampleWeights = { 1, 1, 1, 0, 1, 1, 1 } },
			{ parameterPins = { [8] = 0 } },
			{ parameterPins = { [1] = -1 } },
			{ maxLogWeightChange = 101 },
			{ optimizeWeights = 1 },
			{
				cancelled = function()
					return true
				end,
			},
			{
				checkpoint = function()
					error("cancel")
				end,
			},
		}
		for _, opts in invalid do
			assert(not pcall(function()
				F.refineCurve(source, data, opts)
			end))
		end
		assert(source.weights[2] == 1 and source.points[2] == Vector3.new(1, 1, 0) and t[1] == 0)
		assert(not pcall(function()
			F.refineSurface(patch(), { Vector3.zero }, {})
		end))
	end)
	report.success = report.failed == 0
	return report
end
