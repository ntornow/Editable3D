return function(E)
	local B, N = E.Bezier, E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert((a - b).Magnitude < (tolerance or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function fixture()
		return B.new({ Vector3.zero, Vector3.new(2, 2, 0), Vector3.new(5, 0, 1) }, {
			mode = "free",
			durations = { 2, 3 },
			left = { Vector3.new(-1, 0, 0), Vector3.new(1, 2, -1), Vector3.new(5, 1, 1) },
			right = { Vector3.new(0, 2, 0), Vector3.new(3, 2, 1), Vector3.new(6, 0, 1) },
		})
	end
	test("Vector Bezier handles interpolate piecewise lines with explicit duration parameters", function()
		local c = B.new(
			{ Vector3.zero, Vector3.xAxis * 2, Vector3.new(2, 3, 0) },
			{ mode = "vector", durations = { 2, 3 } }
		)
		near(B.evaluate(c, 0.2), Vector3.xAxis)
		near(B.evaluate(c, 0.4), Vector3.xAxis * 2)
		near(B.evaluate(c, 0.7), Vector3.new(2, 1.5, 0))
		near(B.derivatives(c, 0.2).first, Vector3.xAxis * 5)
		near(B.derivatives(c, 0.7).first, Vector3.yAxis * 5)
	end)
	test("Free Bezier evaluation matches an independent cubic polynomial", function()
		local c = fixture()
		local a, b = c.nodes[1], c.nodes[2]
		for i = 0, 20 do
			local t = i / 20
			local s = 1 - t
			local expected = a.position * s ^ 3
				+ a.right * (3 * s * s * t)
				+ b.left * (3 * s * t * t)
				+ b.position * t ^ 3
			near(B.evaluate(c, t * 0.4), expected)
		end
		assert(#B.toNURBS(c).points == 7)
	end)
	test("Aligned handle movement preserves opposite length and a common tangent", function()
		local c = B.setMode(fixture(), 2, "aligned")
		local length = (c.nodes[2].right - c.nodes[2].position).Magnitude
		local edited = B.setHandle(c, 2, "left", Vector3.new(2, 4, 1))
		local node = edited.nodes[2]
		assert(math.abs((node.right - node.position).Magnitude - length) < 1e-6)
		assert((node.left - node.position).Unit:Dot((node.right - node.position).Unit) < -0.99999)
		near(c.nodes[2].left, B.setMode(fixture(), 2, "aligned").nodes[2].left)
		local free = B.setHandle(fixture(), 2, "left", Vector3.zero)
		near(free.nodes[2].right, fixture().nodes[2].right)
	end)
	test("Moving a Bezier point transports free handles and resolves adjacent automatic handles", function()
		local c = fixture()
		local delta = Vector3.new(3, -2, 1)
		local moved = B.setPoint(c, 2, c.nodes[2].position + delta)
		near(moved.nodes[2].left, c.nodes[2].left + delta)
		near(moved.nodes[2].right, c.nodes[2].right + delta)
		near(moved.nodes[1].right, c.nodes[1].right)
		local automatic = B.new({ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 2 })
		local changed = B.setPoint(automatic, 3, Vector3.new(2, 2, 0))
		assert(changed.nodes[2].right.Y > 0 and automatic.nodes[2].right.Y == 0)
	end)
	test("Manual automatic and vector handles transition to editable modes", function()
		local automatic = B.new({ Vector3.zero, Vector3.xAxis, Vector3.new(2, 1, 0) })
		local a = B.setHandle(automatic, 2, "right", Vector3.new(2, 2, 0))
		assert(a.nodes[2].mode == "aligned" and automatic.nodes[2].mode == "auto")
		local v = B.setMode(automatic, 2, "vector")
		local moved = B.setHandle(v, 2, "right", Vector3.new(3, 2, 0))
		assert(moved.nodes[2].mode == "free")
		near(moved.nodes[2].left, v.nodes[2].left)
	end)
	test(
		"De Casteljau splitting preserves shape and normalized derivatives across nonuniform spans",
		function()
			local c = fixture()
			local split = B.split(c, 1, 0.37)
			assert(#split.nodes == 4 and #c.nodes == 3)
			local a, b = N.compileCurve(B.toNURBS(c)), N.compileCurve(B.toNURBS(split))
			for i = 0, 100 do
				local t = i / 100
				near(a.evaluate(t), b.evaluate(t))
				near(a.derivatives(t).first, b.derivatives(t).first, 0.00003)
			end
		end
	)
	test("Open reversal preserves the complete curve under complementary parameters", function()
		local c = fixture()
		local reversed = B.reverse(c)
		for i = 0, 50 do
			near(B.evaluate(reversed, i / 50), B.evaluate(c, 1 - i / 50))
		end
		near(B.derivatives(reversed, 0.25).first, -B.derivatives(c, 0.75).first)
	end)
	test("Closed chain wrap splitting and reversal preserve the seam and winding", function()
		local c = B.new(
			{ Vector3.zero, Vector3.xAxis * 2, Vector3.new(2, 2, 0), Vector3.yAxis * 2 },
			{ closed = true, durations = { 1, 2, 3, 4 } }
		)
		local split, reverse = B.split(c, 4, 0.31), B.reverse(c)
		near(B.evaluate(c, 0), B.evaluate(c, 1))
		for i = 0, 40 do
			near(B.evaluate(split, i / 40), B.evaluate(c, i / 40))
			near(B.evaluate(reverse, i / 40), B.evaluate(c, 1 - i / 40))
		end
	end)
	test("Bezier edits reject invalid nodes durations handle values and precision collapse", function()
		local c = fixture()
		for _, fn in
			{
				function()
					B.setPoint(c, 99, Vector3.zero)
				end,
				function()
					B.setHandle(c, 1, "bad", Vector3.zero)
				end,
				function()
					B.setHandle(c, 1, "left", Vector3.new(math.huge, 0, 0))
				end,
				function()
					B.setMode(c, 1, "bad")
				end,
				function()
					B.split(c, 1, 0)
				end,
				function()
					B.new({ Vector3.zero, Vector3.one }, { durations = { 0 } })
				end,
				function()
					B.new({ Vector3.zero, Vector3.one }, { closed = "yes" })
				end,
				function()
					B.toNURBS(
						B.new({ Vector3.zero, Vector3.one, Vector3.xAxis }, { durations = { 1e100, 1 } })
					)
				end,
			}
		do
			assert(not pcall(fn))
		end
		near(c.nodes[1].position, Vector3.zero)
	end)
	test("Edited Bezier chains compose with bounded length sampling and native mesh sweeps", function()
		local c = B.new({ Vector3.zero, Vector3.new(0, 2, 0), Vector3.new(1, 4, 0) })
		local path, r = E.ArcLength.sample(B.toNURBS(c), 12, { tolerance = 0.001 })
		assert(r.converged)
		local mesh = E.Curves.sweep(E.Curves.circle(0.1, 6), path)
		assert(mesh:validate().closed)
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			assert(math.abs(restored:volume() - mesh:volume()) < 1e-5)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
