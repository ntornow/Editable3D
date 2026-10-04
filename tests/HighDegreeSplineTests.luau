return function(E)
	local N = E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, t)
		assert((a - b).Magnitude < (t or 5e-6), tostring(a) .. " ~= " .. tostring(b))
	end
	local function curve(degree)
		local p, w = {}, {}
		for i = 0, degree do
			p[i + 1] = Vector3.new(i / degree, 0.3 * math.sin(i), 0.2 * math.cos(i * 0.7))
			w[i + 1] = 0.5 + (i % 5) * 0.17
		end
		return N.curve(p, degree, { weights = w })
	end
	local function independent(c, t)
		local h = {}
		for i, p in c.points do
			local w = c.weights[i]
			h[i] = { p.X * w, p.Y * w, p.Z * w, w }
		end
		local function casteljau(data)
			for count = #data - 1, 1, -1 do
				local nextValues = {}
				for i = 1, count do
					local row = {}
					for k = 1, 4 do
						row[k] = (1 - t) * data[i][k] + t * data[i + 1][k]
					end
					nextValues[i] = row
				end
				data = nextValues
			end
			return data[1]
		end
		local d, dd = {}, {}
		for i = 1, c.degree do
			d[i] = {}
			for k = 1, 4 do
				d[i][k] = c.degree * (h[i + 1][k] - h[i][k])
			end
		end
		for i = 1, c.degree - 1 do
			dd[i] = {}
			for k = 1, 4 do
				dd[i][k] = (c.degree - 1) * (d[i + 1][k] - d[i][k])
			end
		end
		h, d, dd = casteljau(h), casteljau(d), casteljau(dd)
		local p, a, b = {}, {}, {}
		for k = 1, 3 do
			p[k] = h[k] / h[4]
			a[k] = (d[k] - p[k] * d[4]) / h[4]
			b[k] = (dd[k] - 2 * a[k] * d[4] - p[k] * dd[4]) / h[4]
		end
		return Vector3.new(table.unpack(p)), Vector3.new(table.unpack(a)), Vector3.new(table.unpack(b))
	end
	test("Degrees nine through seventeen match independent homogeneous de Casteljau derivatives", function()
		for degree = 9, 17 do
			local c = curve(degree)
			local compiled = N.compileCurve(c)
			for _, t in { 0, 0.03, 0.27, 0.51, 0.83, 0.99, 1 } do
				local p, a, b = independent(c, t)
				local d = compiled.derivatives(t)
				near(d.position, p)
				near(d.first, a, 2e-5)
				near(d.second, b, 0.0002)
			end
		end
	end)
	test("High-degree rational circle elevation preserves radius derivatives and curvature", function()
		local c = E.Surfaces.arc(CFrame.identity, 2, 0, math.pi / 2)
		for _, degree in { 9, 13, 17 } do
			local d = N.elevateDegree(c, degree - 2)
			assert(d.degree == degree)
			for i = 0, 20 do
				local t = i / 20
				local a, b = N.derivatives(c, t), N.derivatives(d, t)
				near(a.position, b.position)
				near(a.first, b.first, 2e-5)
				near(a.second, b.second, 0.0002)
				assert(math.abs(b.curvature - 0.5) < 0.00005)
			end
		end
	end)
	test("Degree seventeen insertion splitting reversal and extraction preserve parameterization", function()
		local c = curve(17)
		local refined = N.insertKnot(c, 0.37, 17)
		local a, b = N.split(refined, 0.37)
		local reverse = N.reverse(refined)
		local pieces = N.bezierSegments(refined)
		assert(#pieces == 2)
		for i = 0, 20 do
			local t = i / 20
			near(N.evaluate(c, t), N.evaluate(refined, t))
			near(N.evaluate(reverse, 1 - t), N.evaluate(c, t))
			near(N.evaluate(a, t), N.evaluate(c, t * 0.37))
			near(N.evaluate(b, t), N.evaluate(c, 0.37 + 0.63 * t))
		end
	end)
	test("High-degree surface edits isocurves and Bezier extraction preserve an analytic plane", function()
		local s = E.Surfaces.plane(CFrame.identity, Vector2.new(3, 2))
		s = N.elevateSurfaceDegree(N.elevateSurfaceDegree(s, "U", 16), "V", 12)
		s = N.insertSurfaceKnot(N.insertSurfaceKnot(s, "U", 0.37, 2), "V", 0.61, 1)
		local pieces = N.bezierPatches(s)
		assert(#pieces == 4)
		local a, b = N.splitSurface(s, "U", 0.37)
		local transposed = E.SurfaceEdit.transpose(s)
		for i = 0, 8 do
			for j = 0, 8 do
				local u, v = i / 8, j / 8
				local expected = Vector3.new(3 * (u - 0.5), 2 * (v - 0.5), 0)
				near(N.evaluateSurface(s, u, v), expected)
				near(N.evaluateSurface(transposed, v, u), expected)
				near(N.evaluate(N.isoCurve(s, "U", v), u), expected)
				near(N.evaluateSurface(a, u, v), N.evaluateSurface(s, u * 0.37, v))
				near(N.evaluateSurface(b, u, v), N.evaluateSurface(s, 0.37 + 0.63 * u, v))
			end
		end
	end)
	test("High-degree knot removal accepts a redundant inserted knot with a verified bound", function()
		local c = curve(12)
		local refined = N.insertKnot(c, 0.4)
		local removed, r = N.removeKnot(refined, 0.4, 1, { tolerance = 1e-4 })
		assert(r.removed == 1)
		for i = 0, 30 do
			near(N.evaluate(removed, i / 30), N.evaluate(c, i / 30), 1e-5)
		end
	end)
	test("Ordinary and periodic degree limits remain explicit and independent", function()
		assert(not pcall(function()
			N.curve(table.create(19, Vector3.zero), 18)
		end))
		assert(not pcall(function()
			N.elevateDegree(curve(17), 1)
		end))
		assert(not pcall(function()
			E.Cyclic.curve(table.create(10, Vector3.zero), 9)
		end))
	end)
	test("High-degree unclamped extraction and nonuniform spans retain independent domains", function()
		local points, weights = {}, {}
		for i = 1, 21 do
			points[i] = Vector3.new(i * 0.1, 0.3 * math.cos(i), 0.1 * math.sin(i))
			weights[i] = 0.7 + (i % 4) * 0.2
		end
		local c = N.curve(points, 17, { clamped = false, weights = weights })
		local clamped = N.clamp(c)
		local pieces = N.bezierSegments(c)
		assert(#pieces == 4 and clamped.degree == 17)
		for i = 0, 20 do
			local t = i / 20
			near(N.evaluate(c, t), N.evaluate(clamped, t))
			near(N.derivatives(c, t).first, N.derivatives(clamped, t).first, 3e-5)
		end
		for _, part in pieces do
			for i = 0, 8 do
				local t = i / 8
				near(N.evaluate(part.curve, t), N.evaluate(c, part.first + t * (part.last - part.first)))
			end
		end
	end)
	test("High-degree tensor evaluation and differentiation retain nonseparable rational weights", function()
		local p, w = {}, {}
		for i = 1, 18 do
			p[i], w[i] = {}, {}
			for j = 1, 11 do
				p[i][j] = Vector3.new((i - 1) / 17, (j - 1) / 10, 0.1 * math.sin(i + j))
				w[i][j] = 0.8 + ((i * 3 + j * 7) % 11) * 0.05
			end
		end
		local s = N.surface(p, 17, 10, { weights = w })
		local compiled = N.compileSurface(s)
		for _, uv in { { 0.2, 0.7 }, { 0.61, 0.38 }, { 0.93, 0.14 } } do
			local u, v = uv[1], uv[2]
			local d = compiled.derivatives(u, v)
			local h = 0.001
			near(d.du, (compiled.evaluate(u + h, v) - compiled.evaluate(u - h, v)) / (2 * h), 0.0002)
			near(d.dv, (compiled.evaluate(u, v + h) - compiled.evaluate(u, v - h)) / (2 * h), 0.0002)
			near(compiled.evaluate(u, v), N.evaluate(N.isoCurve(s, "U", v), u))
		end
	end)
	report.success = report.failed == 0
	return report
end
