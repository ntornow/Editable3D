return function(E)
	local N, Q = E.NURBS, E.SplineQuery
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function plane(z)
		return N.surface({
			{ Vector3.new(-1, -1, z or 0), Vector3.new(-1, 1, z or 0) },
			{ Vector3.new(1, -1, z or 0), Vector3.new(1, 1, z or 0) },
		}, 1, 1)
	end
	local function contains(box, p)
		for i = 1, 3 do
			if box[i][1] > p[i] or box[i][2] < p[i] then
				return false
			end
		end
		return true
	end
	local function covered(r, p)
		for _, root in r.roots do
			if contains(root.parameterBox, p) then
				return true
			end
		end
		for _, region in r.unresolved do
			if contains(region.parameterBox, p) then
				return true
			end
		end
		return false
	end
	local function near(a, b, t)
		assert((a - b).Magnitude <= (t or 2e-6), tostring(a) .. " ~= " .. tostring(b))
	end
	test("An analytic line-plane crossing is enclosed and globally isolated", function()
		local c = N.curve({ Vector3.new(0.25, 0.5, -1), Vector3.new(0.25, 0.5, 1) }, 1)
		local r = Q.intersectCurveSurface(c, plane(), { requireComplete = true })
		assert(r.complete and #r.roots == 1 and #r.unresolved == 0 and r.coverageCertified)
		local p = r.roots[1]
		assert(p.certified and p.unique and p.accurate and p.contractionNorm < 1)
		assert(contains(p.parameterBox, { 0.5, 0.625, 0.75 }))
		near(p.position, Vector3.new(0.25, 0.5, 0))
		assert(p.errorBound < 1e-5)
	end)
	test("Separated whole domains are certified empty", function()
		local c = N.curve({ Vector3.new(0, 0, 1), Vector3.new(0, 0, 2) }, 1)
		local r = Q.intersectCurveSurface(c, plane())
		assert(r.complete and #r.roots == 0 and #r.unresolved == 0 and r.excluded > 0)
	end)
	test("Three roots at one spatial location retain distinct curve parameters", function()
		local c = N.curve({
			Vector3.new(0.25, 0.5, -0.09375),
			Vector3.new(0.25, 0.5, 0.1354166666667),
			Vector3.new(0.25, 0.5, -0.1354166666667),
			Vector3.new(0.25, 0.5, 0.09375),
		}, 3)
		local r = Q.intersectCurveSurface(c, plane())
		assert(
			r.complete and #r.roots == 3,
			tostring(#r.roots) .. " roots; " .. #r.unresolved .. " unresolved"
		)
		local function z(t)
			local p = {}
			for i, v in c.points do
				p[i] = v.Z
			end
			for n = 3, 1, -1 do
				for i = 1, n do
					p[i] = (1 - t) * p[i] + t * p[i + 1]
				end
			end
			return p[1]
		end
		for k, range in { { 0.1, 0.4 }, { 0.4, 0.6 }, { 0.6, 0.9 } } do
			local lo, hi = range[1], range[2]
			for _ = 1, 48 do
				local m = (lo + hi) / 2
				if z(lo) * z(m) <= 0 then
					hi = m
				else
					lo = m
				end
			end
			assert(math.abs(r.roots[k].curveParameter - (lo + hi) / 2) < 1e-7)
			near(r.roots[k].position, Vector3.new(0.25, 0.5, 0))
		end
	end)
	test("A quadratic paraboloid crossing matches independent analytic parameters", function()
		local p = {}
		local z = { 0.25, -0.25, 0.25 }
		for i = 1, 3 do
			p[i] = {}
			for j = 1, 3 do
				p[i][j] = Vector3.new((i - 1) / 2 - 0.5, (j - 1) / 2 - 0.5, z[i] + z[j])
			end
		end
		local s = N.surface(p, 2, 2)
		local c = N.curve({ Vector3.new(0.125, 0.25, -1), Vector3.new(0.125, 0.25, 1) }, 1)
		local r = Q.intersectCurveSurface(c, s)
		assert(r.complete and #r.roots == 1)
		assert(contains(r.roots[1].parameterBox, { 0.5390625, 0.625, 0.75 }))
		near(r.roots[1].position, Vector3.new(0.125, 0.25, 0.078125))
	end)
	test("Positive rational cylinder intersection encloses the exact circular point", function()
		local s = N.surface({
			{ Vector3.new(1, 0, -1), Vector3.new(1, 0, 1) },
			{ Vector3.new(1, 1, -1), Vector3.new(1, 1, 1) },
			{ Vector3.new(0, 1, -1), Vector3.new(0, 1, 1) },
		}, 2, 1, { weights = { { 1, 1 }, { math.sqrt(0.5), math.sqrt(0.5) }, { 1, 1 } } })
		local c = N.curve({ Vector3.zero, Vector3.new(1.4, 1.4, 0) }, 1)
		local r = Q.intersectCurveSurface(c, s)
		assert(r.complete and #r.roots == 1)
		near(r.roots[1].position, Vector3.new(math.sqrt(0.5), math.sqrt(0.5), 0))
		assert(math.abs(r.roots[1].u - 0.5) < 1e-7 and math.abs(r.roots[1].v - 0.5) < 1e-7)
	end)
	test("Tangencies remain covered and are never mistaken for empty domains", function()
		local c =
			N.curve({ Vector3.new(-0.5, 0, 0.25), Vector3.new(0, 0, -0.25), Vector3.new(0.5, 0, 0.25) }, 2)
		local r = Q.intersectCurveSurface(c, plane(), { maxNodes = 80, maxDepth = 24 })
		assert(not r.complete and #r.unresolved > 0 and covered(r, { 0.5, 0.5, 0.5 }))
	end)
	test("Overlapping curve regions retain coverage under search exhaustion", function()
		local c = N.curve({ Vector3.new(-0.5, 0, 0), Vector3.new(0.5, 0, 0) }, 1)
		local r = Q.intersectCurveSurface(c, plane(), { maxNodes = 40, maxDepth = 16 })
		assert(not r.complete and #r.unresolved > 0)
		for i = 0, 20 do
			local t = i / 20
			assert(covered(r, { t, 0.25 + 0.5 * t, 0.5 }), "Uncovered overlap parameter " .. t)
		end
	end)
	test("Unproved boundary roots stay in the unresolved parameter cover", function()
		local c = N.curve({ Vector3.zero, Vector3.zAxis }, 1)
		local r = Q.intersectCurveSurface(c, plane())
		assert(not r.complete and covered(r, { 0, 0.5, 0.5 }))
		assert(not pcall(Q.intersectCurveSurface, c, plane(), { requireComplete = true }))
	end)
	test("Unclamped non-unit domains and internal knot roots retain full coverage", function()
		local knots = { -1, -0.5, 0, 0.5, 1, 1.5, 2 }
		local c = N.curve(
			{ Vector3.new(0, 0, -2), Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(0, 0, 2) },
			2,
			{ knots = { 2, 3.5, 5, 6.5, 8, 9.5, 11 }, clamped = false }
		)
		local p = {}
		for i = 1, 4 do
			p[i] = {}
			for j = 1, 4 do
				p[i][j] = Vector3.new(i - 2.5, j - 2.5, 0)
			end
		end
		local s = N.surface(p, 2, 2, { knotsU = knots, knotsV = knots, clampedU = false, clampedV = false })
		local r = Q.intersectCurveSurface(c, s)
		assert(r.complete and #r.roots == 1 and r.curvePieces == 2 and r.surfacePieces == 4)
		assert(contains(r.roots[1].parameterBox, { 0.5, 0.5, 0.5 }))
		assert(c.knots[1] == 2 and not c.clamped and not s.clampedU)
	end)
	test("Unequal knot spans and inserted repeated knots preserve the same intersections", function()
		local c = N.curve({ Vector3.new(0.25, 0.5, -1), Vector3.new(0.25, 0.5, 1) }, 1)
		c = N.insertKnot(c, 0.5)
		local s = N.elevateSurfaceDegree(N.elevateSurfaceDegree(plane(), "U", 2), "V", 1)
		s = N.insertSurfaceKnot(s, "U", 0.625, 3)
		s = N.insertSurfaceKnot(s, "V", 0.75, 2)
		local r = Q.intersectCurveSurface(c, s)
		assert(r.complete and #r.roots == 1 and contains(r.roots[1].parameterBox, { 0.5, 0.625, 0.75 }))
	end)
	test("Periodic curve expansion finds every interior plane crossing", function()
		local c = E.Cyclic.curve({
			Vector3.new(0.5, 0, 1),
			Vector3.new(0, 0.5, -1),
			Vector3.new(-0.5, 0, 1),
			Vector3.new(0, -0.5, -1),
		}, 1)
		local r = Q.intersectCurveSurface(c, plane())
		assert(
			r.complete and #r.roots == 4,
			tostring(#r.roots) .. " periodic roots; " .. #r.unresolved .. " unresolved"
		)
		for i, root in r.roots do
			assert(math.abs(root.curveParameter - (i - 0.5) / 4) < 1e-7)
		end
	end)
	test("A periodic surface preserves separate parameter branches at two crossings", function()
		local p = {}
		for i, v in
			{ Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) }
		do
			p[i] = { v - Vector3.zAxis, v + Vector3.zAxis }
		end
		local s = E.Cyclic.surface(p, 1, 1, { cyclicU = true, cyclicV = false })
		local c = N.curve({ Vector3.new(-1, 0.25, 0), Vector3.new(1, 0.25, 0) }, 1)
		local r = Q.intersectCurveSurface(c, s)
		assert(
			r.complete and #r.roots == 2,
			tostring(#r.roots) .. " periodic surface roots; " .. #r.unresolved .. " unresolved"
		)
		near(r.roots[1].position, Vector3.new(-0.75, 0.25, 0))
		near(r.roots[2].position, Vector3.new(0.75, 0.25, 0))
	end)
	test("Large translations keep root certification separate from native position accuracy", function()
		local o = Vector3.one * 1e8
		local s = N.surface({
			{ o + Vector3.new(-16, -16, 0), o + Vector3.new(-16, 16, 0) },
			{ o + Vector3.new(16, -16, 0), o + Vector3.new(16, 16, 0) },
		}, 1, 1)
		local c = N.curve({ o + Vector3.new(0, 0, -16), o + Vector3.new(8, 0, 16) }, 1)
		local r = Q.intersectCurveSurface(c, s)
		assert(not r.complete and #r.roots == 1 and r.roots[1].certified and not r.roots[1].accurate)
		assert(r.roots[1].errorBound >= 4 and r.reason == "precision")
	end)
	test("Input and option snapshots remain stable across callbacks", function()
		local c = N.curve({ Vector3.new(0.25, 0.5, -1), Vector3.new(0.25, 0.5, 1) }, 1)
		local s = plane()
		local changed = false
		local options = { parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 } } }
		options.checkpoint = function(info)
			if info.stage == "begin" then
				c.points[1] = Vector3.one * 99
				s.control[1][1] = Vector3.one * 99
				options.parameterBox[1][2] = 0.1
				changed = true
			end
		end
		local r = Q.intersectCurveSurface(c, s, options)
		assert(
			changed
				and r.complete
				and #r.roots == 1
				and contains(r.roots[1].parameterBox, { 0.5, 0.625, 0.75 })
		)
		r.roots[1].parameterBox[1][1] = 99
		assert(options.parameterBox[1][1] == 0)
	end)
	test("Independent source weight gauges and rigid transforms retain roots", function()
		local c = N.curve(
			{ Vector3.new(0.25, 0.5, -1), Vector3.new(0.25, 0.5, 1) },
			1,
			{ weights = { 0.7, 1.3 } }
		)
		local s = plane()
		local baseline = Q.intersectCurveSurface(c, s)
		for _, scale in { 0.001, 1, 100 } do
			local f = CFrame.new(3, -4, 2) * CFrame.Angles(0.2, -0.3, 0.4)
			local p, w = {}, {}
			for i, v in c.points do
				p[i] = f:PointToWorldSpace(v * scale)
				w[i] = c.weights[i] * 1e100
			end
			local grid, weights = {}, {}
			for i, row in s.control do
				grid[i], weights[i] = {}, {}
				for j, v in row do
					grid[i][j] = f:PointToWorldSpace(v * scale)
					weights[i][j] = 1e-100
				end
			end
			local r = Q.intersectCurveSurface(
				N.curve(p, 1, { weights = w }),
				N.surface(grid, 1, 1, { weights = weights }),
				{ tolerance = 1e-3 }
			)
			assert(r.complete and #r.roots == 1)
			near(
				r.roots[1].position,
				f:PointToWorldSpace(baseline.roots[1].position * scale),
				5e-5 * math.max(1, scale)
			)
		end
	end)
	test("Restricted parameter boxes exclude other branches without changing source domains", function()
		local c = N.curve({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1) }, 1)
		local r = Q.intersectCurveSurface(c, plane(), { parameterBox = { { 0.6, 1 }, { 0, 1 }, { 0, 1 } } })
		assert(r.complete and #r.roots == 0)
		local hit = Q.intersectCurveSurface(
			c,
			plane(),
			{ parameterBox = { { 0.4, 0.6 }, { 0.25, 0.75 }, { 0.25, 0.75 } } }
		)
		assert(hit.complete and #hit.roots == 1 and contains(hit.roots[1].parameterBox, { 0.5, 0.5, 0.5 }))
	end)
	test("Allocation work depth and cancellation limits remain explicit", function()
		local c = N.curve({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1) }, 1)
		for _, o in
			{
				{ maxControls = 1 },
				{ maxCoefficients = 1 },
				{ maxWork = 10 },
				{
					cancelled = function()
						return true
					end,
				},
			}
		do
			assert(not pcall(Q.intersectCurveSurface, c, plane(), o))
		end
		local seen = false
		assert(not pcall(Q.intersectCurveSurface, c, plane(), {
			checkpoint = function(info)
				if info.stage == "search" then
					seen = true
					error("cancel search")
				end
			end,
		}))
		assert(seen)
		local tangent =
			N.curve({ Vector3.new(-0.5, 0, 0.25), Vector3.new(0, 0, -0.25), Vector3.new(0.5, 0, 0.25) }, 2)
		local r = Q.intersectCurveSurface(tangent, plane(), { maxDepth = 0 })
		assert(not r.complete and covered(r, { 0.5, 0.5, 0.5 }) and r.unresolved[1].reason == "depth")
	end)
	test("Malformed domains and nonfinite tolerances reject without source mutation", function()
		local c = N.curve({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1) }, 1)
		for _, o in
			{
				{ tolerance = 0 },
				{ tolerance = 0 / 0 },
				{ parameterTolerance = -1 },
				{ maxDepth = 129 },
				{ maxIterations = 0 },
				{ requireComplete = 1 },
				{ parameterBox = { { 0, 1 }, { 0, 0 }, { 0, 1 } } },
				{ parameterBox = { { -1, 1 }, { 0, 1 }, { 0, 1 } } },
			}
		do
			assert(not pcall(Q.intersectCurveSurface, c, plane(), o))
		end
		assert(c.points[1] == Vector3.new(0, 0, -1))
	end)
	test("Raw-knot interval extraction encloses independent exact curve homogeneous jets", function()
		local B = require(script.Parent.IntervalSpline)
		local I = require(script.Parent.DirectedInterval)
		local fixtures = require(script.Parent.IntervalSplineFixtures)
		local memory = buffer.create(8)
		local function decode(s)
			buffer.writeu32(memory, 0, assert(tonumber(s:sub(9, 16), 16)))
			buffer.writeu32(memory, 4, assert(tonumber(s:sub(1, 8), 16)))
			return buffer.readf64(memory, 0)
		end
		local ctx = {
			maxControls = 10000,
			maxPieces = 2048,
			visit = function() end,
			allocate = function(n)
				assert(n <= 1000000)
			end,
		}
		local c = N.curve({
			Vector3.new(0.25, -0.5, 0),
			Vector3.new(0.75, 0.5, 1),
			Vector3.new(1.25, -0.25, -1),
			Vector3.new(2, 0, 0.5),
		}, 2, { weights = { 0.5, 1.5, 0.75, 2 }, knots = { -2, -1, 0, 0.375, 1, 2, 3 }, clamped = false })
		local model = B.prepare(c, false, Vector3.zero, ctx)
		for _, f in fixtures.curve do
			local t = decode(f.t)
			local result = B.evaluate(model, { { t, t } }, ctx)
			for _, pair in
				{
					{ result.value, f.value },
					{ result.derivatives[1], f.derivative },
					{ result.box, f.position },
				}
			do
				for k, e in pair[2] do
					assert(I.leq(pair[1][k][1], decode(e[1])) and I.leq(decode(e[2]), pair[1][k][2]))
				end
			end
		end
	end)
	test("Nonseparable rational tensor jets enclose 49 independent exact Fraction samples", function()
		local B = require(script.Parent.IntervalSpline)
		local I = require(script.Parent.DirectedInterval)
		local fixtures = require(script.Parent.IntervalSplineFixtures)
		local memory = buffer.create(8)
		local function decode(s)
			buffer.writeu32(memory, 0, assert(tonumber(s:sub(9, 16), 16)))
			buffer.writeu32(memory, 4, assert(tonumber(s:sub(1, 8), 16)))
			return buffer.readf64(memory, 0)
		end
		local p, w = {}, {}
		for i = 1, 3 do
			p[i], w[i] = {}, {}
			for j = 1, 4 do
				p[i][j] = Vector3.new((i - 1) * 0.5, (j - 2) * 0.25, ((i * j) % 5) * 0.125)
				w[i][j] = 0.5 + ((i * 3 + j) % 7) / 8
			end
		end
		local s = N.surface(p, 2, 2, { weights = w, knotsV = { -3, -1, 2, 3.5, 5, 7, 9 }, clampedV = false })
		local ctx = {
			maxControls = 10000,
			maxPieces = 2048,
			visit = function() end,
			allocate = function(n)
				assert(n <= 1000000)
			end,
		}
		local model = B.prepare(s, true, Vector3.zero, ctx)
		for _, f in fixtures.surface do
			local u, v = decode(f.u), decode(f.v)
			local result = B.evaluate(model, { { u, u }, { v, v } }, ctx)
			for _, pair in
				{
					{ result.value, f.value },
					{ result.derivatives[1], f.du },
					{ result.derivatives[2], f.dv },
					{ result.box, f.position },
				}
			do
				for k, e in pair[2] do
					assert(I.leq(pair[1][k][1], decode(e[1])) and I.leq(decode(e[2]), pair[1][k][2]))
				end
			end
		end
	end)
	test("Certified surface probe meshes retain native UVs and normals", function()
		local result = require(script.Parent.Examples.IntersectionProbe)(E)
		local root = result.intersections.roots[1]
		near(root.position, Vector3.new(0.125, 0.25, 0.078125))
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			for _, f in restored.faces do
				for _, c in f.corners do
					assert(c.uv and c.normal and math.abs(c.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Subnormal parameter endpoints and knot intervals cannot produce false certificates", function()
		local memory = buffer.create(8)
		buffer.writeu32(memory, 0, 1)
		local tiny = buffer.readf64(memory, 0)
		local c = N.curve({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1) }, 1)
		assert(
			not pcall(
				Q.intersectCurveSurface,
				c,
				plane(),
				{ parameterBox = { { tiny, 1 }, { 0, 1 }, { 0, 1 } } }
			)
		)
		local bad = N.curve({ Vector3.new(0, 0, -1), Vector3.zero, Vector3.new(0, 0, 1) }, 1)
		bad.knots[3] = tiny
		assert(not pcall(Q.intersectCurveSurface, bad, plane()))
	end)
	test("Root caps and projected extraction allocations cannot silently drop search regions", function()
		local c = N.curve({
			Vector3.new(0.25, 0.5, -0.09375),
			Vector3.new(0.25, 0.5, 0.1354166666667),
			Vector3.new(0.25, 0.5, -0.1354166666667),
			Vector3.new(0.25, 0.5, 0.09375),
		}, 3)
		local r = Q.intersectCurveSurface(c, plane(), { maxRoots = 1 })
		assert(not r.complete and #r.roots == 1 and #r.unresolved > 0 and covered(r, { 0.5, 0.625, 0.75 }))
		local line = N.curve({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1) }, 1)
		assert(not pcall(Q.intersectCurveSurface, line, plane(), { maxCoefficients = 24 }))
		assert(not pcall(Q.intersectCurveSurface, N.insertKnot(line, 0.25), plane(), { maxPieces = 1 }))
	end)
	report.success = report.failed == 0
	return report
end
