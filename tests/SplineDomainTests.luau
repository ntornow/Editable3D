return function(E)
	local N = E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, e)
		assert((a - b).Magnitude < (e or 0.0001), tostring(a) .. " != " .. tostring(b))
	end
	local function curve(degree)
		local points, weights = {}, {}
		for i = 1, degree + 5 do
			points[i] = Vector3.new(i - 1, math.sin(i) * 2, math.cos(i * 0.7))
			weights[i] = 0.4 + (i % 4) * 0.3
		end
		return N.curve(points, degree, { clamped = false, weights = weights })
	end
	local function same(a, b)
		for i = 0, 60 do
			local x, y = N.derivatives(a, i / 60), N.derivatives(b, i / 60)
			near(x.position, y.position)
			near(x.first, y.first, 0.001)
			near(x.second, y.second, 0.05)
		end
	end
	test("Unclamped quadratic endpoints use independent polynomial basis", function()
		local p = { Vector3.new(0, 0, 0), Vector3.new(2, 3, 0), Vector3.new(4, -1, 1), Vector3.new(6, 2, 2) }
		local c = N.curve(p, 2, { clamped = false })
		near(N.evaluate(c, 0), (p[1] + p[2]) * 0.5)
		near(N.evaluate(c, 1), (p[3] + p[4]) * 0.5)
		near(N.derivatives(c, 0).first, (p[2] - p[1]) * 2)
		near(N.derivatives(c, 1).first, (p[4] - p[3]) * 2)
		for i = 0, 20 do
			local t = i / 20
			local u = t * 2
			local span = math.min(math.floor(u) + 1, 2)
			local f = u - (span - 1)
			local expected = p[span] * ((1 - f) ^ 2 / 2)
				+ p[span + 1] * (0.5 + f - f * f)
				+ p[span + 2] * (f * f / 2)
			near(N.evaluate(c, t), expected)
		end
	end)
	test("Exact clamping retains rational positions and derivatives for degrees one through eight", function()
		for degree = 1, 8 do
			local c = curve(degree)
			local d = N.clamp(c)
			assert(d.clamped and not c.clamped)
			assert(d.knots[1] == c.knots[degree + 1] and d.knots[#d.knots] == c.knots[#c.points + 1])
			same(c, d)
		end
	end)
	test("Nonuniform asymmetric exterior knots clamp exactly", function()
		local c = N.curve(
			{ Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, Vector3.one },
			2,
			{ clamped = false, weights = { 1, 0.3, 2, 1.2, 0.6 }, knots = { -5, -1, 2, 2.4, 4.2, 7, 8, 12 } }
		)
		same(c, N.clamp(c))
		same(c, N.reverse(N.reverse(c)))
		local rev = N.reverse(c)
		for i = 0, 30 do
			near(N.evaluate(c, i / 30), N.evaluate(rev, 1 - i / 30))
		end
	end)
	test("Unclamped insertion removal and degree elevation retain active geometry", function()
		local c = curve(3)
		local inserted = N.insertKnot(c, 0.37, 2)
		same(c, inserted)
		local restored, r = N.removeKnot(inserted, 0.37, 2, { tolerance = 0.0001 })
		assert(r.complete and not restored.clamped)
		same(c, restored)
		same(c, N.elevateDegree(c, 2))
	end)
	test("Unclamped split retains outer endpoint behavior and normalized derivatives", function()
		local c = curve(4)
		local a, b = N.split(c, 0.37)
		for i = 0, 30 do
			local t = i / 30
			near(N.evaluate(a, t), N.evaluate(c, t * 0.37))
			near(N.evaluate(b, t), N.evaluate(c, 0.37 + t * 0.63))
			near(N.derivatives(a, t).first, N.derivatives(c, t * 0.37).first * 0.37, 0.001)
			near(N.derivatives(b, t).first, N.derivatives(c, 0.37 + t * 0.63).first * 0.63, 0.001)
		end
		same(a, N.clamp(a))
		same(b, N.clamp(b))
	end)
	test("Repeated active boundary knots select the correct one-sided basis", function()
		local c = N.curve(
			{ Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, Vector3.one },
			2,
			{ clamped = false, knots = { -1, 0, 0, 1, 2, 2, 2, 3 } }
		)
		same(c, N.clamp(c))
		near(N.evaluate(c, 1), c.points[4])
		local total = 0
		for _, w in N.basisWeights(c, 1) do
			total += w
		end
		assert(math.abs(total - 1) < 1e-12)
	end)
	test("Unclamped tensor-product directions preserve relative rational scales", function()
		local p, w = {}, {}
		for i = 1, 6 do
			p[i], w[i] = {}, {}
			for j = 1, 5 do
				p[i][j] = Vector3.new(i, j, math.sin(i * j))
				w[i][j] = 0.3 + (i * j % 7) * 0.2
			end
		end
		local s = N.surface(p, 3, 2, { weights = w, clampedU = false, clampedV = false })
		local clamped = N.clampSurface(N.clampSurface(s, "U"), "V")
		local elevated = N.elevateSurfaceDegree(s, "U", 1)
		local refined = N.insertSurfaceKnot(s, "V", 0.37)
		local iso = N.isoCurve(s, "U", 0.41)
		assert(clamped.clampedU and clamped.clampedV and not refined.clampedV)
		for i = 0, 10 do
			near(N.evaluate(iso, i / 10), N.evaluateSurface(s, i / 10, 0.41))
			for j = 0, 8 do
				local a = N.surfaceDerivatives(s, i / 10, j / 8)
				for _, other in { clamped, elevated, refined } do
					local b = N.surfaceDerivatives(other, i / 10, j / 8)
					near(a.position, b.position)
					near(a.du, b.du, 0.001)
					near(a.dv, b.dv, 0.001)
				end
			end
		end
	end)
	test("Clamped defaults still reject exterior knots and empty active domains", function()
		local p = { Vector3.zero, Vector3.xAxis, Vector3.yAxis }
		assert(not pcall(function()
			N.curve(p, 2, { knots = { -1, 0, 0, 1, 1, 2 } })
		end))
		assert(not pcall(function()
			N.curve(p, 2, { clamped = false, knots = { -1, 0, 1, 1, 2, 3 } })
		end))
		assert(N.curve(p, 2).clamped)
	end)
	report.success = report.failed == 0
	return report
end
