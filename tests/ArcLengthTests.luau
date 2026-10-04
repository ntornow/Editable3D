return function(E)
	local A, N, S, Q = E.ArcLength, E.NURBS, E.Surfaces, E.SplineQuery
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert((a - b).Magnitude <= (tolerance or 0.0003), tostring(a) .. " ~= " .. tostring(b))
	end
	test("Inverse arc length finds positions on nonuniform rational straight curves", function()
		local c = N.curve({ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 4 }, 2, { weights = { 1, 0.1, 7 } })
		local map = A.prepare(c, { tolerance = 1e-5 })
		assert(map.converged and map.length == 4)
		for _, distance in { 0, 0.01, 0.3, 1, 2.7, 4 } do
			local r = map.atLength(distance)
			assert(r.converged and r.errorBound <= 1e-5)
			near(r.position, Vector3.xAxis * distance, 1.1e-5)
			near(r.position, N.evaluate(c, r.parameter), 1e-6)
		end
		assert(math.abs(map.atLength(2).parameter - 0.5) > 0.1)
	end)
	test("Arc length map bounds circle length and inverts independent angular distances", function()
		local c = S.arc(CFrame.identity, 2, 0, 1.5 * math.pi)
		local map = A.prepare(c, { tolerance = 0.0002 })
		assert(
			map.converged and map.lowerBound <= 3 * math.pi + 1e-5 and map.upperBound >= 3 * math.pi - 1e-5
		)
		for _, fraction in { 0, 0.13, 0.25, 0.51, 0.79, 1 } do
			local r = map.atFraction(fraction)
			assert(r.converged and r.errorBound <= 0.0002)
			local angle = fraction * 1.5 * math.pi
			near(r.position, Vector3.new(2 * math.cos(angle), 2 * math.sin(angle), 0))
		end
		assert(map.atFraction(0).parameter == 0 and map.atFraction(1).parameter == 1)
	end)
	test("Uniform distance samples on rational circles have independent equal angle spacing", function()
		local c = S.arc(CFrame.identity, 3, 0, 2 * math.pi)
		local points, r = A.sample(c, 25, { tolerance = 0.0005 })
		assert(r.converged and #points == 25 and #r.parameters == 25)
		for i, p in points do
			local theta = (i - 1) * math.pi / 12
			near(p, Vector3.new(3 * math.cos(theta), 3 * math.sin(theta), 0), 0.0006)
			if i > 1 then
				assert(r.parameters[i] > r.parameters[i - 1])
			end
		end
	end)
	test("Inverse queries handle corners nonuniform knots and zero-length spans", function()
		local c = N.curve(
			{ Vector3.zero, Vector3.xAxis, Vector3.xAxis, Vector3.new(1, 3, 0) },
			1,
			{ knots = { 0, 0, 0.2, 0.6, 1, 1 } }
		)
		local map = A.prepare(c, { tolerance = 1e-5 })
		assert(map.length == 4)
		near(map.atLength(0.5).position, Vector3.new(0.5, 0, 0), 2e-5)
		near(map.atLength(2.5).position, Vector3.new(1, 1.5, 0), 2e-5)
		local r = map.atLength(1)
		assert(r.converged and r.parameter >= 0.2 and r.parameter <= 0.6)
		local zero = A.prepare(N.curve({ Vector3.one, Vector3.one }, 1))
		assert(zero.length == 0 and zero.atFraction(0.4).converged)
		assert(not pcall(zero.atLength, 0.1))
	end)
	test("Prepared length maps are immutable snapshots across control and weight edits", function()
		local c = S.arc(CFrame.identity, 1, 0, math.pi)
		local map = A.prepare(c)
		local expected = map.atFraction(0.37).position
		c.points[2], c.weights[2] = Vector3.one * 10, 20
		near(map.atFraction(0.37).position, expected, 1e-6)
		assert(not pcall(function()
			map.length = 100
		end))
	end)
	test("Arc length intervals survive weight scaling uniform size scaling and translation", function()
		local c = S.arc(CFrame.new(64, -32, 16), 4, 0, 1.7)
		for i, w in c.weights do
			c.weights[i] = w * 1e120
		end
		local map = A.prepare(c, { tolerance = 0.002 })
		local r = map.atFraction(0.61)
		assert(map.converged and r.converged)
		near(
			r.position,
			Vector3.new(64 + 4 * math.cos(1.7 * 0.61), -32 + 4 * math.sin(1.7 * 0.61), 16),
			0.0021
		)
	end)
	test("Length and inverse budgets expose nonconvergence without claiming solved distances", function()
		local c = S.arc(CFrame.identity, 1, 0, 2 * math.pi)
		local coarse = A.prepare(c, { maxNodes = 1, tolerance = 1e-8 })
		assert(not coarse.converged)
		local r = coarse.atFraction(0.37)
		assert(not r.converged and r.reason and r.errorBound > 1e-8)
		r = A.parameter(c, 0.73, { maxIterations = 1 })
		assert(not r.converged and r.reason == "Iteration budget exhausted")
		local _, samples = coarse.sample(5)
		assert(not samples.converged)
	end)
	test("Arc length inputs sample budgets and cancellation reject atomically", function()
		local c = S.arc(CFrame.identity, 1, 0, math.pi)
		local count, first = #c.points, c.points[1]
		for _, fn in
			{
				function()
					A.prepare(c, { tolerance = -1 })
				end,
				function()
					A.prepare(c, { maxLeaves = 1 })
				end,
				function()
					A.sample(c, 100, { maxSamples = 10 })
				end,
				function()
					A.sample(c, 100, { maxWork = 10 })
				end,
				function()
					A.parameter(c, -1)
				end,
				function()
					A.prepare(c).atFraction(1.1)
				end,
				function()
					A.prepare(c, {
						checkpoint = function()
							error("cancelled")
						end,
					})
				end,
			}
		do
			assert(not pcall(fn))
		end
		assert(#c.points == count and c.points[1] == first)
	end)
	test("Tangent-controlled rational samples bound derivatives throughout every segment", function()
		local c = N.curve(
			{ Vector3.zero, Vector3.new(0, 3, 0), Vector3.new(4, -2, 1), Vector3.new(5, 1, 0) },
			3,
			{ weights = { 1, 0.3, 2, 1 } }
		)
		local points, r = Q.sample(c, { tolerance = 0.1, maxAngle = 0.04 })
		assert(r.converged and r.tangentErrorBound <= 0.04)
		local eval = N.compileCurve(c)
		for i = 1, #points - 1 do
			local direction = (points[i + 1] - points[i]).Unit
			for j = 0, 12 do
				local t = r.parameters[i] + (r.parameters[i + 1] - r.parameters[i]) * j / 12
				local tangent = eval.derivatives(t).first.Unit
				assert(math.acos(math.clamp(tangent:Dot(direction), -1, 1)) <= r.tangentErrorBound + 0.0002)
			end
		end
	end)
	test("Tangent sampling resolves backtracking and detects stationary curves", function()
		local c = N.curve({ Vector3.zero, Vector3.xAxis, Vector3.zero }, 2)
		local points, r = Q.sample(c, { tolerance = 2, maxAngle = 0.1 })
		assert(r.converged and #points >= 3)
		near(points[1], Vector3.zero)
		near(points[#points], Vector3.zero)
		local zero = N.curve({ Vector3.one, Vector3.one, Vector3.one }, 2)
		local _, stationary = Q.sample(zero, { maxAngle = 0.1 })
		assert(stationary.converged and stationary.stationarySegments == 1)
	end)
	test("Tangent budgets and invalid angles remain explicit", function()
		local c = S.arc(CFrame.identity, 1, 0, math.pi)
		local _, r = Q.sample(c, { tolerance = 2, maxAngle = 1e-6, maxNodes = 1 })
		assert(not r.converged and r.tangentErrorBound > 1e-6)
		assert(not pcall(Q.sample, c, { maxAngle = 0 }))
		assert(not pcall(Q.sample, c, { maxAngle = math.pi }))
	end)
	report.success = report.failed == 0
	return report
end
