return function(E)
	local C, N = E.Cyclic, E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function vec(a, b, tolerance)
		assert((a - b).Magnitude <= (tolerance or 1e-4), tostring(a) .. " ~= " .. tostring(b))
	end
	local function curve(degree, options)
		local points = {}
		for i = 1, math.max(degree + 2, 6) do
			local a = 2 * math.pi * (i - 1) / math.max(degree + 2, 6)
			points[i] = Vector3.new(2 * math.cos(a), math.sin(a), 0.2 * math.sin(2 * a))
		end
		return C.curve(points, degree, options)
	end
	local function same(a, b, tolerance)
		local aa, bb = N.compileCurve(C.toNURBS(a)), N.compileCurve(C.toNURBS(b))
		for i = 0, 80 do
			vec(aa.evaluate(i / 80), bb.evaluate(i / 80), tolerance)
		end
	end
	local function torus()
		local p, w = {}, {}
		for i = 1, 6 do
			p[i], w[i] = {}, {}
			local u = (i - 1) * 2 * math.pi / 6
			for j = 1, 5 do
				local v = (j - 1) * 2 * math.pi / 5
				p[i][j] =
					Vector3.new((3 + math.cos(v)) * math.cos(u), math.sin(v), (3 + math.cos(v)) * math.sin(u))
				w[i][j] = 1 + 0.25 * math.sin(u + 2 * v)
			end
		end
		return C.surface(
			p,
			3,
			2,
			{ weights = w, intervalsU = { 1, 2, 1, 3, 1, 2 }, intervalsV = { 1, 2, 1, 1, 3 } }
		)
	end
	local function surfaceSame(a, b, tolerance)
		local aa, bb = N.compileSurface(C.surfaceToNURBS(a)), N.compileSurface(C.surfaceToNURBS(b))
		for i = 0, 10 do
			for j = 0, 10 do
				vec(aa.evaluate(i / 10, j / 10), bb.evaluate(i / 10, j / 10), tolerance)
			end
		end
	end
	test("Cyclic elevation preserves rational positions and all supported degrees", function()
		for degree = 1, 7 do
			local a = curve(degree)
			for i in a.weights do
				a.weights[i] = 0.7 + i / 10
			end
			local b, r = C.elevateDegree(a, 1, { tolerance = 1e-4 })
			assert(r.complete and r.elevated == 1 and b.kind == "cyclicCurve" and b.degree == degree + 1)
			assert(#b.points == 2 * #a.points and r.errorBound <= 1e-4)
			same(a, b, math.max(r.errorBound * 1.1, 2e-6))
		end
	end)
	test("Elevation retains nonuniform parameterization and seam derivatives", function()
		local a = curve(3, { intervals = { 1, 2, 1, 3, 2, 1 }, weights = { 1, 2, 0.7, 1.2, 2, 1 } })
		local b, r = C.elevateDegree(a, 2, { tolerance = 1e-4 })
		assert(r.complete and #b.points == 18)
		same(a, b, 1e-5)
		for _, t in { 0, 0.03, 0.27, 0.81, 1 } do
			local da, db = C.derivatives(a, t), C.derivatives(b, t)
			vec(da.first, db.first, 0.0002)
			vec(da.second, db.second, 0.003)
		end
		vec(C.derivatives(b, 0).first, C.derivatives(b, 1).first, 0.0002)
		vec(C.derivatives(b, 0).second, C.derivatives(b, 1).second, 0.003)
	end)
	test("Repeated knots and seam multiplicities survive elevation", function()
		local a = curve(3, { intervals = { 0, 1, 0, 2, 3, 0 } })
		local b, r = C.elevateDegree(a, 2, { tolerance = 1e-4 })
		assert(r.complete and #b.points == 12)
		same(a, b, 1e-5)
		local changed = C.curve(b.points, b.degree, b)
		changed.points[1] += Vector3.zAxis
		vec(C.evaluate(changed, 0), C.evaluate(changed, 1), 1e-5)
	end)
	test("Degree zero count is an independent descriptor and excessive degree rejects", function()
		local a = curve(8)
		local b, r = C.elevateDegree(a, 0)
		assert(r.complete and r.elevated == 0 and r.work == 0)
		b.points[1] += Vector3.one
		assert(b.points[1] ~= a.points[1] and b.intervals ~= a.intervals and b.weights ~= a.weights)
		assert(not pcall(C.elevateDegree, a, 1))
	end)
	test("Periodic inserted knots remove with a conservative whole-curve error bound", function()
		for _, t in { 0.03125, 0.375, 0.96875 } do
			local a = curve(3, { weights = { 1, 0.7, 2, 1.1, 0.8, 1.5 } })
			local inserted = C.insertKnot(a, t)
			local b, r = C.removeKnot(inserted, t, 1, { tolerance = 0.0001 })
			assert(r.complete and r.removed == 1 and #b.points == #a.points, r.reason)
			same(inserted, b, math.max(r.errorBound * 1.1, 3e-6))
			same(a, b, 1e-5)
		end
	end)
	test("Repeated removal and missing knots return explicit partial results", function()
		local a = curve(3)
		local inserted = C.insertKnot(a, 0.375, 3)
		local b, r = C.removeKnot(inserted, 0.375, 4, { tolerance = 0.0001 })
		assert(not r.complete and r.removed == 3 and r.reason and #b.points == #a.points, r.reason)
		same(a, b, 1e-5)
		local unchanged, missing = C.removeKnot(a, 0.123, 1)
		assert(not missing.complete and missing.removed == 0 and missing.errorBound == 0)
		same(a, unchanged, 1e-7)
	end)
	test("Nonremovable periodic knots retain source geometry and report rejection", function()
		local a = curve(2)
		local b, r = C.removeKnot(a, 0.5, 1, { tolerance = 1e-8 })
		assert(not r.complete and r.removed == 0 and r.rejectedErrorBound > r.tolerance)
		same(a, b, 1e-7)
		local approximate, accepted = C.removeKnot(a, 0.5, 1, { tolerance = 10 })
		assert(accepted.complete and #approximate.points == #a.points - 1)
		same(a, approximate, accepted.errorBound * 1.001)
	end)
	test("Removal is equivariant under weight scale and moderate rigid transforms", function()
		local a = C.insertKnot(curve(3), 0.375)
		local frame = CFrame.new(4, -3, 2) * CFrame.Angles(0.3, -0.5, 0.2)
		local moved = C.curve(a.points, a.degree, a)
		for i, p in moved.points do
			moved.points[i] = frame:PointToWorldSpace(p)
			moved.weights[i] *= 1e80
		end
		local b, r = C.removeKnot(a, 0.375, 1, { tolerance = 0.001 })
		local c, s = C.removeKnot(moved, 0.375, 1, { tolerance = 0.001 })
		assert(r.complete and s.complete)
		for i = 0, 20 do
			vec(C.evaluate(c, i / 20), frame:PointToWorldSpace(C.evaluate(b, i / 20)), 2e-5)
		end
	end)
	test("Control and matrix work budgets reject before an unbounded solve", function()
		local a = curve(3)
		for _, options in
			{
				{ maxControls = 7 },
				{ maxMatrixEntries = 10 },
				{ maxWork = 1 },
				{ rankTolerance = -1 },
				{
					tolerance = -1,
				},
			}
		do
			assert(not pcall(C.elevateDegree, a, 1, options))
		end
		local calls = 0
		assert(not pcall(C.elevateDegree, a, 1, {
			checkpoint = function()
				calls += 1
				if calls > 2 then
					error("cancel")
				end
			end,
		}))
		assert(calls == 3)
		assert(not pcall(C.elevateDegree, a, 1, {
			cancelled = function()
				return true
			end,
		}))
	end)
	test("Elevation rejects a tolerance below measured native-control rounding", function()
		local a = curve(3, { weights = { 1, 0.7, 2, 1.1, 0.8, 1.5 } })
		local b, r = C.elevateDegree(a, 1, { tolerance = 0 })
		assert(not r.complete and r.elevated == 0 and r.rejectedErrorBound > 0)
		same(a, b, 1e-7)
	end)
	test("Both periodic surface directions elevate with nonseparable rational weights", function()
		local a = torus()
		for _, axis in { "U", "V" } do
			local b, r = C.elevateSurfaceDegree(a, axis, 1, { tolerance = 0.001 })
			assert(r.complete and b.kind == "cyclicSurface" and b.cyclicU and b.cyclicV, r.reason)
			surfaceSame(a, b, 0.00002)
			local expanded = C.surfaceToNURBS(b)
			for _, t in { 0, 0.3, 0.7, 1 } do
				vec(N.evaluateSurface(expanded, 0, t), N.evaluateSurface(expanded, 1, t), 1e-5)
				vec(N.evaluateSurface(expanded, t, 0), N.evaluateSurface(expanded, t, 1), 1e-5)
			end
		end
	end)
	test("Surface knot removal uses a shared homogeneous tensor-product bound", function()
		local a = torus()
		for _, axis in { "U", "V" } do
			local inserted = C.insertSurfaceKnot(a, axis, 0.375)
			local b, r = C.removeSurfaceKnot(inserted, axis, 0.375, 1, { tolerance = 0.001 })
			assert(r.complete and r.removed == 1, r.reason)
			surfaceSame(inserted, b, math.max(r.errorBound * 1.001, 4e-6))
			surfaceSame(a, b, 1e-5)
		end
	end)
	test("Mixed periodic and open surfaces preserve the untouched open direction", function()
		local a = torus()
		a = C.surface(a.control, 3, 2, { weights = a.weights, cyclicV = false, intervalsU = a.intervalsU })
		local b, r = C.elevateSurfaceDegree(a, "U", 1, { tolerance = 0.001 })
		assert(r.complete and b.cyclicU and not b.cyclicV and #b.control[1] == #a.control[1])
		for i, knot in a.knotsV do
			assert(b.knotsV[i] == knot)
		end
		surfaceSame(a, b, 1e-5)
		assert(not pcall(C.elevateSurfaceDegree, a, "V", 1))
	end)
	test("Surface failure never changes one row independently of the rest", function()
		local a = torus()
		local b, r = C.removeSurfaceKnot(a, "U", 0.3, 1, { tolerance = 1e-10 })
		assert(not r.complete and r.removed == 0)
		surfaceSame(a, b, 1e-7)
		assert(not pcall(C.elevateSurfaceDegree, a, "U", 1, { maxSurfaceControls = 40 }))
		assert(not pcall(C.removeSurfaceKnot, a, "U", 0))
	end)
	test("Elevated cyclic surfaces tessellate as closed native meshes", function()
		local s, r = C.elevateSurfaceDegree(torus(), "U", 1, { tolerance = 0.001 })
		assert(r.complete)
		local mesh = N.tessellate(C.surfaceToNURBS(s), 12, 10, { closedU = true, closedV = true })
		assert(mesh:validate().closed)
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			assert(math.abs(restored:volume() - mesh:volume()) < 0.0001)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Elevated degree-one loops match independent rational line segments", function()
		local a = C.curve(
			{ Vector3.zero, Vector3.xAxis * 2, Vector3.new(2, 3, 0), Vector3.yAxis * 3 },
			1,
			{ weights = { 1, 2, 3, 0.5 }, intervals = { 1, 1, 1, 1 } }
		)
		local b, r = C.elevateDegree(a, 4, { tolerance = 0.0001 })
		assert(r.complete)
		for segment = 1, 4 do
			local nextIndex = segment % 4 + 1
			for i = 0, 8 do
				local t = i / 8
				local w = (1 - t) * a.weights[segment] + t * a.weights[nextIndex]
				local expected = a.points[segment] * ((1 - t) * a.weights[segment] / w)
					+ a.points[nextIndex] * (t * a.weights[nextIndex] / w)
				vec(C.evaluate(b, (segment - 1 + t) / 4), expected, 2e-6)
			end
		end
	end)
	test("Approximate surface removal bounds changes in rational cross-row blending", function()
		local a = torus()
		local b, r = C.removeSurfaceKnot(a, "U", 0.3, 1, { tolerance = 100 })
		assert(r.complete and r.errorBound > 0)
		surfaceSame(a, b, r.errorBound * 1.001)
		local unchanged, rejected = C.elevateDegree(curve(3), 1, { rankTolerance = 2 })
		assert(not rejected.complete and rejected.reason and unchanged.degree == 3)
	end)
	report.success = report.failed == 0
	return report
end
