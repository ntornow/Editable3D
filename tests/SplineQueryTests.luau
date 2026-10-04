return function(E)
	local N, Q, S = E.NURBS, E.SplineQuery, E.Surfaces
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, e)
		assert((a - b).Magnitude < (e or 0.0001), tostring(a) .. " != " .. tostring(b))
	end
	test("Prepared curve and surface evaluators retain independent immutable snapshots", function()
		local c = S.arc(CFrame.identity, 1, 0, math.pi / 2)
		local eval = N.compileCurve(c)
		local point = eval.evaluate(0.37)
		c.points[2] = Vector3.zero
		near(eval.evaluate(0.37), point)
		assert((N.evaluate(c, 0.37) - point).Magnitude > 0.1)
		assert(not pcall(function()
			eval.evaluate = function() end
		end))
		local s = S.sphere(CFrame.identity, 2)
		local surface = N.compileSurface(s)
		local d = surface.derivatives(0.37, 0.42)
		s.control[1][1] += Vector3.one
		near(surface.evaluate(0.37, 0.42), d.position)
	end)
	test("Bezier patch extraction preserves rational parameters and mixed derivatives", function()
		local s = S.torus(CFrame.identity, 3, 1)
		s = N.insertSurfaceKnot(N.insertSurfaceKnot(s, "U", 0.37), "V", 0.63)
		local patches = N.bezierPatches(s)
		assert(#patches == 25)
		for _, patch in patches do
			for _, uv in { { 0, 0 }, { 1, 1 }, { 0.37, 0.42 } } do
				local u, v = uv[1], uv[2]
				local a = N.surfaceDerivatives(patch.surface, u, v)
				local b = N.surfaceDerivatives(
					s,
					patch.u0 + (patch.u1 - patch.u0) * u,
					patch.v0 + (patch.v1 - patch.v0) * v
				)
				near(a.position, b.position)
				near(a.du, b.du * (patch.u1 - patch.u0), 0.0001)
				near(a.duv, b.duv * (patch.u1 - patch.u0) * (patch.v1 - patch.v0), 0.0003)
			end
		end
	end)
	test("Arc length bounds contain exact circle length and converge", function()
		local circle = S.arc(CFrame.identity, 2, 0, 2 * math.pi)
		local r = Q.length(circle, { tolerance = 0.0001 })
		assert(r.converged and r.lowerBound <= 4 * math.pi + 1e-5 and r.upperBound >= 4 * math.pi - 1e-5)
		assert(math.abs(r.length - 4 * math.pi) < 0.00011 and r.errorBound <= 0.0001)
		local coarse = Q.length(circle, { tolerance = 0.03 })
		assert(coarse.segments < r.segments)
	end)
	test("Length handles straight rational curves zero length and nonuniform multiple spans", function()
		local line = N.curve(
			{ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 3 },
			2,
			{ weights = { 1, 0.2, 4 } }
		)
		local r = Q.length(line)
		assert(r.converged and math.abs(r.length - 3) < 1e-6)
		local zero = Q.length(N.curve({ Vector3.one, Vector3.one }, 1))
		assert(zero.length == 0 and zero.converged)
		local c = N.insertKnot(S.arc(CFrame.identity, 1, 0, 1.7), 0.37)
		local d = Q.length(c, { tolerance = 0.0001 })
		assert(math.abs(d.length - 1.7) < 0.00011)
	end)
	test("Adaptive curve sampling bounds geometric deviation between samples", function()
		local c = S.arc(CFrame.identity, 2, 0, math.pi * 1.5)
		local points, r = Q.sample(c, { tolerance = 0.001 })
		assert(r.converged and r.errorBound <= 0.001 and #points == #r.parameters)
		for i = 1, #points - 1 do
			assert(r.parameters[i] < r.parameters[i + 1])
			near(points[i], N.evaluate(c, r.parameters[i]))
			local a, b = points[i], points[i + 1]
			local d = b - a
			for j = 0, 8 do
				local p = N.evaluate(c, r.parameters[i] + (r.parameters[i + 1] - r.parameters[i]) * j / 8)
				local t = math.clamp((p - a):Dot(d) / d:Dot(d), 0, 1)
				assert((p - a - d * t).Magnitude <= r.errorBound + 1e-5)
			end
		end
	end)
	test("Closest curve finds exact radial circle projection with a global distance bound", function()
		local c = S.arc(CFrame.identity, 2, 0, 2 * math.pi)
		local target = Vector3.new(3, 4, 1)
		local r = Q.closestCurve(c, target, { tolerance = 0.0002 })
		assert(r.converged and r.errorBound <= 0.0002)
		near(r.position, Vector3.new(1.2, 1.6, 0), 0.0002)
		assert(math.abs(r.distance - math.sqrt(10)) < 0.0002)
		near(r.position, N.evaluate(c, r.parameter))
	end)
	test("Closest curve respects constrained endpoints and multiple local minima", function()
		local line = N.curve({ Vector3.zero, Vector3.xAxis }, 1)
		local r = Q.closestCurve(line, Vector3.new(3, 1, 0))
		near(r.position, Vector3.xAxis)
		local c = N.curve(
			{ Vector3.new(-3, 0, 0), Vector3.new(-1, 4, 0), Vector3.new(1, -4, 0), Vector3.new(3, 0, 0) },
			3
		)
		local target = Vector3.new(0.7, 0.1, 0)
		r = Q.closestCurve(c, target, { tolerance = 0.0001 })
		assert(r.converged)
		local brute = math.huge
		local evaluator = N.compileCurve(c)
		for i = 0, 10000 do
			brute = math.min(brute, (evaluator.evaluate(i / 10000) - target).Magnitude)
		end
		assert(r.distance <= brute + 0.0001 and r.lowerBound <= brute + 0.0001)
	end)
	test("Closest surface projects onto the interior and boundary of a tilted plane", function()
		local frame = CFrame.new(4, 5, 6) * CFrame.Angles(0.4, 0.2, -0.3)
		local s = S.plane(frame, Vector2.new(4, 2))
		for _, p in { Vector3.new(0.7, -0.3, 2), Vector3.new(4, 3, 1) } do
			local r = Q.closestSurface(s, frame:PointToWorldSpace(p), { tolerance = 0.0001 })
			assert(r.converged)
			near(
				r.position,
				frame:PointToWorldSpace(Vector3.new(math.clamp(p.X, -2, 2), math.clamp(p.Y, -1, 1), 0)),
				0.001
			)
		end
	end)
	test("Closest rational surface finds sphere and torus projections with bounded gaps", function()
		local target = Vector3.new(3, 2, 1)
		local r =
			Q.closestSurface(S.sphere(CFrame.identity, 2), target, { tolerance = 0.001, maxNodes = 10000 })
		assert(r.converged, tostring(r.reason) .. " gap " .. r.errorBound)
		near(r.position, target.Unit * 2, 0.002)
		local t = Vector3.new(5, 0, 0.5)
		local expected = Vector3.new(3, 0, 0) + Vector3.new(2, 0, 0.5).Unit
		r = Q.closestSurface(S.torus(CFrame.identity, 3, 1), t, { tolerance = 0.001 })
		assert(r.converged, tostring(r.reason) .. " gap " .. r.errorBound)
		near(r.position, expected, 0.003)
	end)
	test("Queries report incomplete budgets and preserve inputs on cancellation", function()
		local c = S.arc(CFrame.identity, 2, 0, 2 * math.pi)
		local r = Q.length(c, { tolerance = 1e-8, maxNodes = 1 })
		assert(not r.converged and r.reason)
		local _, s = Q.sample(c, { tolerance = 1e-8, maxNodes = 1 })
		assert(not s.converged and s.errorBound > 1e-8)
		r = Q.closestCurve(c, Vector3.new(3, 4, 1), { tolerance = 1e-9, maxNodes = 1 })
		assert(not r.converged and r.errorBound > 1e-9)
		local count = #c.points
		assert(not pcall(function()
			Q.sample(c, {
				checkpoint = function()
					error("cancel")
				end,
			})
		end))
		assert(#c.points == count)
		assert(not pcall(function()
			Q.closestCurve(c, Vector3.one, { tolerance = -1 })
		end))
	end)
	test("Closest query and length are invariant to common rational weight scale", function()
		local c = S.arc(CFrame.identity, 2, 0, math.pi * 1.5)
		local a = Q.closestCurve(c, Vector3.new(3, 2, 1), { tolerance = 0.0001 })
		local length = Q.length(c, { tolerance = 0.0001 })
		for i, w in c.weights do
			c.weights[i] = w * 1e150
		end
		local b = Q.closestCurve(c, Vector3.new(3, 2, 1), { tolerance = 0.0001 })
		local scaled = Q.length(c, { tolerance = 0.0001 })
		assert(a.converged and b.converged and scaled.converged)
		near(a.position, b.position)
		assert(math.abs(length.length - scaled.length) < 0.0001)
	end)
	report.success = report.failed == 0
	return report
end
