return function(E)
	local N = E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function vec(a, b, tolerance)
		assert((a - b).Magnitude < (tolerance or 2e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function arc(scale)
		scale = scale or 1
		return N.curve(
			{ Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis },
			2,
			{ weights = { scale, math.sqrt(0.5) * scale, scale } }
		)
	end
	local function surface()
		local points, weights = {}, {}
		for i = 1, 4 do
			points[i], weights[i] = {}, {}
			for j = 1, 3 do
				points[i][j] = Vector3.new(i - 1, j - 1, 0.15 * (i - 1) * (j - 1))
				weights[i][j] = 0.4 + ((i * 7 + j * 3) % 11) * 0.25
			end
		end
		return N.surface(points, 2, 2, { weights = weights, knotsU = { 2, 2, 2, 3.1, 7, 7, 7 } })
	end
	local function sameCurve(a, b, tolerance)
		for i = 0, 80 do
			vec(N.evaluate(a, i / 80), N.evaluate(b, i / 80), tolerance)
		end
	end
	test("Bezier decomposition retains nonuniform domains and one-sided segment derivatives", function()
		local c = N.insertKnot(N.insertKnot(arc(), 0.17), 0.73)
		local parts = N.bezierSegments(c)
		assert(#parts == 3)
		for _, part in parts do
			for i = 0, 12 do
				local t = i / 12
				vec(N.evaluate(part.curve, t), N.evaluate(c, part.first + (part.last - part.first) * t))
			end
			vec(
				N.derivatives(part.curve, 0.37).first,
				N.derivatives(c, part.first + (part.last - part.first) * 0.37).first
					* (part.last - part.first)
			)
		end
	end)
	test("Degree elevation keeps an exact circle radius curvature and endpoints", function()
		local c = N.elevateDegree(arc(), 4)
		assert(c.degree == 6 and #c.points == 7)
		for i = 0, 40 do
			local d = N.derivatives(c, i / 40)
			assert(math.abs(d.position.Magnitude - 1) < 1e-6)
			assert(math.abs(d.curvature - 1) < 5e-5)
			assert(math.abs(d.position:Dot(d.first)) < 2e-6)
		end
		vec(N.evaluate(c, 0), Vector3.xAxis)
		vec(N.evaluate(c, 1), Vector3.yAxis)
	end)
	test("Degree elevation preserves multi-span rational derivatives and source controls", function()
		local c = N.insertKnot(N.insertKnot(arc(), 0.25), 0.625, 2)
		local count = #c.points
		local elevated = N.elevateDegree(c, 2)
		assert(c.degree == 2 and #c.points == count and elevated.degree == 4)
		for _, t in { 0, 0.1, 0.25, 0.42, 0.625, 0.9, 1 } do
			local a, b = N.derivatives(c, t), N.derivatives(elevated, t)
			vec(a.position, b.position)
			vec(a.first, b.first, 5e-5)
			vec(a.second, b.second, 0.0004)
		end
	end)
	test("Degree elevation preserves non-unit knot domains and extreme common weight scales", function()
		for _, scale in { 1e-35, 1e150 } do
			local a = arc(scale)
			local c = N.curve(a.points, 2, { knots = { -3, -3, -3, 9, 9, 9 }, weights = a.weights })
			local e = N.elevateDegree(N.insertKnot(c, 0.375), 3)
			assert(e.knots[1] == -3 and e.knots[#e.knots] == 9)
			sameCurve(c, e)
		end
	end)
	test("Surface degree elevation preserves unequal rational row scales and derivatives", function()
		local s = surface()
		local e = N.elevateSurfaceDegree(N.elevateSurfaceDegree(s, "U", 2), "V", 1)
		assert(e.degreeU == 4 and e.degreeV == 3 and s.degreeU == 2 and s.degreeV == 2)
		for i = 0, 10 do
			for j = 0, 8 do
				local a, b = N.surfaceDerivatives(s, i / 10, j / 8), N.surfaceDerivatives(e, i / 10, j / 8)
				vec(a.position, b.position)
				vec(a.du, b.du, 0.00015)
				vec(a.dv, b.dv, 0.00015)
				vec(a.duv, b.duv, 0.001)
				vec(a.normal, b.normal, 5e-5)
			end
		end
	end)
	test("Knot removal recovers inserted rational controls with a uniform error bound", function()
		local a = arc()
		local c = N.insertKnot(a, 0.375, 2)
		local r, info = N.removeKnot(c, 0.375, 2, { tolerance = 1e-5 })
		assert(info.complete and info.removed == 2 and info.errorBound < 1e-5)
		assert(#r.points == 3 and #c.points == 5)
		sameCurve(a, r)
		for i, p in a.points do
			vec(p, r.points[i])
		end
	end)
	test("Knot removal rejects a real kink instead of reporting approximate success", function()
		local c = N.curve(
			{ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 2, Vector3.new(2, 1, 0), Vector3.new(2, 2, 0) },
			2,
			{ knots = { 0, 0, 0, 0.5, 0.5, 1, 1, 1 } }
		)
		local r, info = N.removeKnot(c, 0.5, 1, { tolerance = 1e-6 })
		assert(not info.complete and info.removed == 0 and info.rejectedErrorBound > 1e-6)
		assert(#r.points == #c.points)
		sameCurve(c, r)
	end)
	test("Knot removal tolerance bounds every sampled point for a perturbed curve", function()
		local c = N.insertKnot(arc(), 0.5)
		c.points[2] += Vector3.zAxis * 0.0001
		local unchanged, rejected = N.removeKnot(c, 0.5, 1, { tolerance = 1e-8 })
		assert(rejected.removed == 0)
		sameCurve(unchanged, c)
		local approximate, accepted = N.removeKnot(c, 0.5, 1, { tolerance = 0.001 })
		assert(accepted.complete and accepted.errorBound <= 0.001)
		for i = 0, 100 do
			assert(
				(N.evaluate(c, i / 100) - N.evaluate(approximate, i / 100)).Magnitude
					<= accepted.errorBound + 2e-6
			)
		end
	end)
	test("Knot removal preserves common weight scale and translation", function()
		for _, scale in { 1e-35, 1e150 } do
			local c = arc(scale)
			for i, p in c.points do
				c.points[i] = p + Vector3.new(12, 160, -8)
			end
			local refined = N.insertKnot(c, 0.25, 2)
			local r, info = N.removeKnot(refined, 0.25, 2, { tolerance = 0.0001 })
			assert(info.complete)
			sameCurve(c, r, 0.00005)
		end
	end)
	test("Surface knot removal preserves the complete rational net in both axes", function()
		local s = surface()
		for _, axis in { "U", "V" } do
			local refined = N.insertSurfaceKnot(s, axis, 0.5, 2)
			local r, info = N.removeSurfaceKnot(refined, axis, 0.5, 2, { tolerance = 0.0001 })
			assert(info.complete and info.removed == 2)
			assert(#r.control == #s.control and #r.control[1] == #s.control[1])
			for i = 0, 10 do
				for j = 0, 10 do
					vec(N.evaluateSurface(s, i / 10, j / 10), N.evaluateSurface(r, i / 10, j / 10))
				end
			end
		end
	end)
	test("Surface knot removal rejects a changed row atomically", function()
		local s = N.insertSurfaceKnot(surface(), "V", 0.5)
		s.control[2][2] += Vector3.zAxis * 0.2
		local r, info = N.removeSurfaceKnot(s, "V", 0.5, 1, { tolerance = 1e-6 })
		assert(not info.complete and info.removed == 0)
		for i = 0, 5 do
			for j = 0, 5 do
				vec(N.evaluateSurface(s, i / 5, j / 5), N.evaluateSurface(r, i / 5, j / 5))
			end
		end
	end)
	test("Removal reports absent knots and partial completion without mutating input", function()
		local c = N.insertKnot(arc(), 0.5)
		local r, info = N.removeKnot(c, 0.5, 3)
		assert(not info.complete and info.removed == 1 and #r.points == 3 and #c.points == 4)
		local same, absent = N.removeKnot(c, 0.25)
		assert(absent.removed == 0 and not absent.complete)
		sameCurve(c, same)
	end)
	test("NURBS edit argument errors cancellation and zero-count copies are explicit", function()
		assert(not pcall(N.elevateDegree, arc(), 16))
		assert(not pcall(N.elevateSurfaceDegree, surface(), "X", 1))
		assert(not pcall(N.removeKnot, arc(), 0))
		assert(not pcall(N.removeKnot, arc(), 0.5, 1, { tolerance = -1 }))
		local c = N.insertKnot(arc(), 0.5)
		local n = 0
		assert(not pcall(N.removeKnot, c, 0.5, 1, {
			checkpoint = function()
				n += 1
				error("cancel")
			end,
		}))
		assert(n == 1 and #c.points == 4)
		local same = N.elevateDegree(c, 0)
		same.points[1] = Vector3.one * 9
		vec(c.points[1], Vector3.xAxis)
		local copy, info = N.removeKnot(c, 0.5, 0)
		assert(info.complete and info.removed == 0 and #copy.points == 4)
	end)
	report.success = report.failed == 0
	return report
end
