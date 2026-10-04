return function(E)
	local P = E.Predicates
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local fixtures = require(script.Parent.PredicateFixtures)
	for _, kind in { "orient2D", "orient3D", "inCircle", "inSphere" } do
		test(kind .. " matches an independent exact rational oracle across coordinate scales", function()
			local count, fallback = 0, 0
			for index, case in fixtures do
				if case.kind == kind then
					local result, _, used = P[kind](table.unpack(case.points))
					assert(
						result == case.expected,
						"Fixture " .. index .. ": " .. result .. " != " .. case.expected
					)
					count += 1
					if used then
						fallback += 1
					end
				end
			end
			assert(count >= 48)
			if kind ~= "orient3D" then
				assert(fallback > 0)
			end
		end)
	end
	test("Predicate conventions distinguish orientation inside outside and exact boundaries", function()
		local a, b, c = Vector2.zero, Vector2.xAxis, Vector2.yAxis
		assert(P.orient2D(a, b, c) == 1 and P.orient2D(a, c, b) == -1)
		assert(P.inCircle(a, b, c, Vector2.new(0.5, 0.5)) == 1)
		assert(P.inCircle(a, b, c, Vector2.new(2, 2)) == -1 and P.inCircle(a, b, c, Vector2.one) == 0)
		local o, x, y, z = Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
		assert(P.orient3D(o, x, y, z) == 1)
		assert(P.inSphere(o, x, y, z, Vector3.one * 0.25) == 1)
		assert(P.inSphere(o, y, x, z, Vector3.one * 0.25) == -1)
		assert(P.inSphere(o, x, y, z, Vector3.one) == 0 and P.inSphere(o, x, y, z, Vector3.one * 2) == -1)
	end)
	test(
		"Segment classification includes proper crossing endpoints overlap and zero-length segments",
		function()
			local r = P.intersectSegments2D(Vector2.zero, Vector2.one, Vector2.new(0, 1), Vector2.new(1, 0))
			assert(
				r.kind == "point"
					and r.proper
					and r.point == Vector2.one * 0.5
					and math.abs(r.t - 0.5) < 1e-12
					and math.abs(r.u - 0.5) < 1e-12
			)
			r = P.intersectSegments2D(Vector2.zero, Vector2.xAxis, Vector2.xAxis, Vector2.one)
			assert(r.kind == "point" and not r.proper and r.point == Vector2.xAxis)
			local overlap =
				P.intersectSegments2D(Vector2.zero, Vector2.xAxis * 3, Vector2.xAxis * 2, Vector2.xAxis)
			assert(
				overlap.kind == "overlap"
					and overlap.points[1] == Vector2.xAxis
					and overlap.points[2] == Vector2.xAxis * 2
			)
			assert(overlap.rangeB[1] == 1 and overlap.rangeB[2] == 0)
			r = P.intersectSegments2D(Vector2.one, Vector2.one, Vector2.zero, Vector2.one * 2)
			assert(r.kind == "point" and r.t == 0)
			assert(
				P.intersectSegments2D(Vector2.zero, Vector2.xAxis, Vector2.yAxis, Vector2.one).kind == "none"
			)
		end
	)
	test("Intersection coordinates survive cancellation that erases the segment parameter offset", function()
		local big = 2 ^ 100
		local r = P.intersectSegments2D(
			Vector2.new(-big, 0),
			Vector2.new(big, 0),
			Vector2.new(1, -1),
			Vector2.new(1, 1)
		)
		assert(r.kind == "point" and r.point == Vector2.new(1, 0) and r.coordinates.x == 1)
		-- t rounds to one half, so evaluating A+(B-A)*t would incorrectly give X=0.
		assert(r.t == 0.5)
	end)
	test(
		"Exact segment classification rejects near-collinear separated geometry without epsilon snapping",
		function()
			local tiny = 2 ^ -100
			assert(not P.onSegment2D(Vector2.new(0.5, tiny), Vector2.zero, Vector2.xAxis))
			assert(
				P.intersectSegments2D(Vector2.zero, Vector2.xAxis, Vector2.new(0, tiny), Vector2.new(1, tiny)).kind
					== "none"
			)
			assert(P.onSegment2D(Vector2.new(0.5, 0), Vector2.zero, Vector2.xAxis))
		end
	)
	test("Predicates reject nonfinite or non-native input coordinates", function()
		assert(not pcall(function()
			P.orient2D({ X = 0, Y = 0 }, Vector2.zero, Vector2.one)
		end))
		assert(not pcall(function()
			P.orient3D(Vector3.zero, Vector3.one, Vector3.xAxis, Vector3.new(math.huge, 0, 0))
		end))
	end)
	test("Exact fallback remains finite near the native coordinate exponent limits", function()
		for _, scale in { 2 ^ -126, 2 ^ 126 } do
			local a, b, c = Vector2.new(-scale, 0), Vector2.new(scale, 0), Vector2.new(0, scale)
			assert(P.orient2D(a, b, c) == 1 and P.inCircle(a, b, c, Vector2.zero) == 1)
			assert(P.inCircle(a, b, c, Vector2.new(0, -scale)) == 0)
			local o, x, y, z =
				Vector3.zero, Vector3.new(scale, 0, 0), Vector3.new(0, scale, 0), Vector3.new(0, 0, scale)
			assert(P.orient3D(o, x, y, z) == 1)
			assert(P.inSphere(o, x, y, z, Vector3.new(scale, scale, scale)) == 0)
		end
	end)
	report.success = report.failed == 0
	return report
end
