return function(E)
	local C, N = E.Cyclic, E.NURBS
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
		local p, w, d = {}, {}, {}
		for i = 1, degree + 5 do
			local a = (i - 1) * 2 * math.pi / (degree + 5)
			p[i] = Vector3.new(math.cos(a) * 2, math.sin(a), math.cos(a * 2) * 0.3)
			w[i] = 0.3 + (i % 3) * 0.5
			d[i] = 0.5 + (i % 4) * 0.25
		end
		return C.curve(p, degree, { weights = w, intervals = d })
	end
	local function seam(c)
		local a, b = C.derivatives(c, 0), C.derivatives(c, 1)
		near(a.position, b.position)
		if c.degree >= 2 then
			near(a.first, b.first, 0.001)
		end
		if c.degree >= 3 then
			near(a.second, b.second, 0.02)
		end
	end
	test("Periodic weighted curves close with derivatives for degrees one through eight", function()
		for d = 1, 8 do
			seam(curve(d))
		end
	end)
	test("Unique cyclic control edits update both sides of the seam", function()
		local c = curve(3)
		local original = C.evaluate(c, 0)
		c.points[2] += Vector3.new(0.3, 0.1, -0.2)
		c.weights[2] *= 2
		seam(c)
		assert((original - C.evaluate(c, 0)).Magnitude > 0.05)
		local copy = C.toNURBS(c)
		copy.points[2] = Vector3.zero
		assert(c.points[2] ~= Vector3.zero)
	end)
	test("Cyclic reversal preserves rational parameter correspondence", function()
		for degree = 1, 5 do
			local c = curve(degree)
			local reversed = C.reverse(c)
			for i = 0, 40 do
				near(C.evaluate(c, i / 40), C.evaluate(reversed, 1 - i / 40))
				if i > 0 and i < 40 then
					near(C.derivatives(c, i / 40).first, -C.derivatives(reversed, 1 - i / 40).first, 0.001)
				end
			end
		end
	end)
	test("Rotating the seam changes its parameter origin without changing shape", function()
		local c = curve(3)
		local total = 0
		for _, d in c.intervals do
			total += d
		end
		for _, offset in { -2, 1, 3, 11 } do
			local shift = 0
			for i = 1, offset % #c.points do
				shift += c.intervals[i]
			end
			local rotated = C.rotateSeam(c, offset)
			for i = 0, 40 do
				near(C.evaluate(rotated, i / 40), C.evaluate(c, (i / 40 + shift / total) % 1))
			end
			seam(rotated)
		end
	end)
	test("Cyclic insertion preserves geometry near and across the seam", function()
		for degree = 1, 5 do
			for _, t in { 0.01, 0.37, 0.99 } do
				local c = curve(degree)
				local inserted = C.insertKnot(c, t)
				assert(#inserted.points == #c.points + 1)
				for i = 0, 60 do
					near(C.evaluate(c, i / 60), C.evaluate(inserted, i / 60), 0.0002)
				end
				seam(inserted)
			end
		end
	end)
	test("Repeated cyclic insertion preserves rational shape and refuses excessive multiplicity", function()
		local c = curve(3)
		local d = C.insertKnot(c, 0.37, 3)
		for i = 0, 40 do
			near(C.evaluate(c, i / 40), C.evaluate(d, i / 40))
		end
		assert(not pcall(function()
			C.insertKnot(d, 0.37)
		end))
	end)
	local function surface(both)
		local p, w = {}, {}
		for i = 1, 7 do
			p[i], w[i] = {}, {}
			local a = (i - 1) * math.pi * 2 / 7
			for j = 1, 6 do
				local b = (j - 1) * math.pi * 2 / 6
				p[i][j] =
					Vector3.new(math.cos(a) * (3 + math.cos(b)), math.sin(a) * (3 + math.cos(b)), math.sin(b))
				w[i][j] = 0.4 + (i * j % 5) * 0.3
			end
		end
		return C.surface(p, 3, 3, { weights = w, cyclicV = both })
	end
	test("Doubly periodic rational surface closes in both directions after unique control edits", function()
		local s = surface(true)
		s.control[2][2] += Vector3.new(0.2, 0.3, 0.1)
		s.weights[2][2] *= 1.4
		for i = 0, 20 do
			local a, b = C.surfaceDerivatives(s, 0, i / 20), C.surfaceDerivatives(s, 1, i / 20)
			near(a.position, b.position)
			near(a.du, b.du, 0.001)
			near(a.dv, b.dv, 0.001)
			a, b = C.surfaceDerivatives(s, i / 20, 0), C.surfaceDerivatives(s, i / 20, 1)
			near(a.position, b.position)
			near(a.du, b.du, 0.001)
			near(a.dv, b.dv, 0.001)
		end
	end)
	test("Periodic and open surface insertion retains nonseparable rational weights", function()
		for _, both in { true, false } do
			local s = surface(both)
			local edited = C.insertSurfaceKnot(C.insertSurfaceKnot(s, "U", 0.03), "V", 0.83)
			for i = 0, 12 do
				for j = 0, 10 do
					near(
						C.evaluateSurface(s, i / 12, j / 10),
						C.evaluateSurface(edited, i / 12, j / 10),
						0.0002
					)
				end
			end
			assert(edited.cyclicV == both)
		end
	end)
	test("Surface reverse and seam rotation preserve parameter correspondence", function()
		local s = surface(true)
		local r = C.reverseSurface(s, "V")
		local moved = C.rotateSurfaceSeam(s, "U", 2)
		for i = 0, 10 do
			for j = 0, 10 do
				near(C.evaluateSurface(s, i / 10, 1 - j / 10), C.evaluateSurface(r, i / 10, j / 10))
				near(
					C.evaluateSurface(s, (i / 10 + 2 / 7) % 1, j / 10),
					C.evaluateSurface(moved, i / 10, j / 10)
				)
			end
		end
		local n = C.surfaceToNURBS(s)
		local clamped = N.clampSurface(N.clampSurface(n, "U"), "V")
		near(C.evaluateSurface(s, 0.21, 0.73), N.evaluateSurface(clamped, 0.21, 0.73))
	end)
	test("Periodic descriptors reject broken dimensions invalid intervals and allocation budgets", function()
		local c = curve(3)
		assert(not pcall(function()
			C.curve(c.points, 3, { intervals = table.create(#c.points, 0) })
		end))
		assert(not pcall(function()
			C.curve(c.points, 3, { maxControls = 5 })
		end))
		local s = surface(true)
		assert(not pcall(function()
			C.surface(s.control, 3, 3, { maxControls = 10 })
		end))
		assert(not pcall(function()
			C.insertKnot(c, 0)
		end))
		assert(not pcall(function()
			C.rotateSurfaceSeam(surface(false), "V", 1)
		end))
	end)
	report.success = report.failed == 0
	return report
end
