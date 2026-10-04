return function(E)
	local N, F = E.NURBS, E.SplineFit
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function vec(a, b, tolerance)
		assert((a - b).Magnitude < (tolerance or 2e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function polynomial(t)
		return Vector3.new(1 + 2 * t, t * t - 0.3 * t, t * t * t - t)
	end
	local function samples(count, fn)
		local points, params = {}, {}
		for i = 0, count - 1 do
			local t = i / (count - 1)
			points[i + 1], params[i + 1] = fn(t), t
		end
		return points, params
	end
	local function analyticSurface(u, v)
		return Vector3.new(u * 2, v * 3, 0.2 * u * u + 0.7 * u * v - 0.4 * v * v)
	end
	local function grid(nu, nv, fn)
		local points, pu, pv = {}, {}, {}
		for i = 1, nu do
			points[i] = {}
			pu[i] = (i - 1) / (nu - 1)
			for j = 1, nv do
				pv[j] = (j - 1) / (nv - 1)
				points[i][j] = fn(pu[i], pv[j])
			end
		end
		return points, pu, pv
	end
	test("Rational basis weights form a positive partition and reconstruct geometry", function()
		local c = N.curve({ Vector3.xAxis, Vector3.one, Vector3.yAxis }, 2, { weights = { 1, 0.4, 2 } })
		for i = 0, 20 do
			local t = i / 20
			local values = N.basisWeights(c, t)
			local sum, p = 0, Vector3.zero
			for j, v in values do
				assert(v >= 0)
				sum += v
				p += c.points[j] * v
			end
			assert(math.abs(sum - 1) < 1e-12)
			vec(p, N.evaluate(c, t))
		end
	end)
	test("Cubic interpolation reproduces an independent polynomial between samples", function()
		local points, params = samples(8, polynomial)
		local c, r = F.interpolateCurve(points, 3, { parameters = params })
		assert(r.interpolated and r.maximumError < 2e-6 and #c.points == 8)
		for i = 0, 80 do
			vec(N.evaluate(c, i / 80), polynomial(i / 80))
		end
	end)
	test("Least squares recovers a cubic using fewer controls than samples", function()
		local points, params = samples(31, polynomial)
		local c, r = F.curve(points, 3, 4, { parameters = params })
		assert(r.success and r.maximumError < 2e-6 and #c.points == 4)
		vec(c.points[1], points[1])
		vec(c.points[4], points[#points])
		for i = 0, 50 do
			vec(N.evaluate(c, i / 50), polynomial(i / 50))
		end
	end)
	test("Fixed rational weights recover an exact circle from sampled positions", function()
		local arc = N.curve(
			{ Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis },
			2,
			{ weights = { 1, math.sqrt(0.5), 1 } }
		)
		local points, params = samples(17, function(t)
			return N.evaluate(arc, t)
		end)
		local c, r = F.curve(points, 2, 3, { parameters = params, weights = arc.weights })
		assert(r.maximumError < 2e-6)
		for i = 0, 40 do
			assert(math.abs(N.evaluate(c, i / 40).Magnitude - 1) < 2e-6)
		end
	end)
	test("Sample confidence reduces outlier influence and is scale invariant", function()
		local points, params = samples(9, function(t)
			return Vector3.new(t, 2 * t, 0)
		end)
		points[5] += Vector3.yAxis * 3
		local weights = table.create(9, 1)
		weights[5] = 0.001
		local weighted =
			F.curve(points, 1, 2, { parameters = params, pinEndpoints = false, sampleWeights = weights })
		local unweighted = F.curve(points, 1, 2, { parameters = params, pinEndpoints = false })
		assert(math.abs(N.evaluate(weighted, 0.5).Y - 1) < math.abs(N.evaluate(unweighted, 0.5).Y - 1) * 0.01)
		for i, w in weights do
			weights[i] = w * 1e100
		end
		local scaled =
			F.curve(points, 1, 2, { parameters = params, pinEndpoints = false, sampleWeights = weights })
		for i = 0, 10 do
			vec(N.evaluate(weighted, i / 10), N.evaluate(scaled, i / 10))
		end
	end)
	test("Curve fitting honors exact control pins and source immutability", function()
		local points, params = samples(11, polynomial)
		local saved = points[1]
		local pin = Vector3.new(1.6, 0.1, -0.2)
		local c, r = F.curve(points, 3, 4, { parameters = params, pins = { [2] = pin } })
		assert(c.points[2] == pin and r.rank == 1 and points[1] == saved)
		c.points[1] = Vector3.one * 99
		assert(points[1] == saved)
	end)
	test(
		"Uniform interpolation permits repeated positions and chord mode rejects repeated parameters",
		function()
			local points = { Vector3.zero, Vector3.zero, Vector3.xAxis, Vector3.one }
			assert(not pcall(F.interpolateCurve, points, 2))
			local c, r = F.interpolateCurve(points, 2, { parameterization = "uniform" })
			assert(r.interpolated)
			for i, p in points do
				vec(N.evaluate(c, (i - 1) / 3), p)
			end
		end
	)
	test("Fitting preserves translated coordinates and custom knot domains", function()
		local shift = Vector3.new(17, 160, -23)
		local points, params = samples(21, function(t)
			return polynomial(t) + shift
		end)
		local c, r = F.curve(points, 3, 4, { parameters = params, knots = { 2, 2, 2, 2, 7, 7, 7, 7 } })
		assert(r.maximumError < 4e-5 and c.knots[1] == 2)
		for i = 0, 40 do
			vec(N.evaluate(c, i / 40), polynomial(i / 40) + shift, 4e-5)
		end
	end)
	test("Tensor-product interpolation reproduces a quadratic patch between samples", function()
		local points, pu, pv = grid(5, 4, analyticSurface)
		local s, r = F.interpolateSurface(points, 2, 2, { parametersU = pu, parametersV = pv })
		assert(r.interpolated and r.maximumError < 3e-6)
		for i = 0, 16 do
			for j = 0, 12 do
				vec(N.evaluateSurface(s, i / 16, j / 12), analyticSurface(i / 16, j / 12))
			end
		end
	end)
	test("Surface fitting recovers lower control count and exact requested pins", function()
		local points, pu, pv = grid(9, 8, analyticSurface)
		local pins = { [1] = { [1] = Vector3.zero }, [3] = { [3] = analyticSurface(1, 1) } }
		local s, r = F.surface(points, 2, 2, 3, 3, { parametersU = pu, parametersV = pv, pins = pins })
		assert(r.maximumError < 3e-6 and s.control[1][1] == Vector3.zero and s.control[3][3] == pins[3][3])
		for i = 0, 12 do
			for j = 0, 12 do
				vec(N.evaluateSurface(s, i / 12, j / 12), analyticSurface(i / 12, j / 12))
			end
		end
	end)
	test("Nonseparable rational surface weights are fitted as one coupled system", function()
		local control, weights = {}, {}
		for i = 1, 3 do
			control[i], weights[i] = {}, {}
			for j = 1, 3 do
				control[i][j] = Vector3.new(i - 1, j - 1, 0.2 * i * j)
				weights[i][j] = 0.5 + ((i * 5 + j * 2) % 7) * 0.3
			end
		end
		local source = N.surface(control, 2, 2, { weights = weights })
		local points, pu, pv = grid(7, 6, function(u, v)
			return N.evaluateSurface(source, u, v)
		end)
		local fitted, r =
			F.surface(points, 2, 2, 3, 3, { parametersU = pu, parametersV = pv, weights = weights })
		assert(r.maximumError < 4e-6)
		for i = 0, 12 do
			for j = 0, 12 do
				vec(N.evaluateSurface(source, i / 12, j / 12), N.evaluateSurface(fitted, i / 12, j / 12))
			end
		end
	end)
	test("Interpolation refuses incompatible pins rather than claiming success", function()
		local points, params = samples(4, polynomial)
		assert(
			not pcall(
				F.interpolateCurve,
				points,
				3,
				{ parameters = params, pins = { [2] = Vector3.one * 99 }, tolerance = 1e-5 }
			)
		)
		local points2, pu, pv = grid(3, 3, analyticSurface)
		assert(
			not pcall(
				F.interpolateSurface,
				points2,
				2,
				2,
				{ parametersU = pu, parametersV = pv, pins = { [2] = { [2] = Vector3.one * 99 } }, tolerance = 1e-5 }
			)
		)
	end)
	test("Fitting validates ranks samples weights budgets and cancellation", function()
		local points, params = samples(5, polynomial)
		assert(not pcall(F.curve, points, 2, 9))
		assert(not pcall(F.curve, points, 2, 3, { sampleWeights = { 1, -1, 1, 1, 1 } }))
		assert(not pcall(F.curve, points, 2, 3, { parameters = { 0, 0.5, 0.5, 0.9, 1 } }))
		assert(not pcall(F.curve, points, 2, 3, { maxWork = 1 }))
		assert(not pcall(F.curve, points, 2, 3, { maxMatrixEntries = 2 }))
		assert(not pcall(F.surface, { { Vector3.zero, Vector3.one }, { Vector3.zero } }, 1, 1, 2, 2))
		local n = 0
		assert(not pcall(F.curve, points, 2, 3, {
			parameters = params,
			checkpoint = function()
				n += 1
				error("cancel")
			end,
		}))
		assert(n == 1)
	end)
	report.success = report.failed == 0
	return report
end
