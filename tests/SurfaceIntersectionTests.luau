return function(E)
	local N, Q = E.NURBS, E.SplineQuery
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function horizontal(z, size)
		local s = size or 1
		return N.surface({
			{ Vector3.new(-s, -s, z), Vector3.new(-s, s, z) },
			{ Vector3.new(s, -s, z), Vector3.new(s, s, z) },
		}, 1, 1)
	end
	local function vertical()
		return N.surface({
			{ Vector3.new(-2, 0, -2), Vector3.new(-2, 0, 2) },
			{ Vector3.new(2, 0, -2), Vector3.new(2, 0, 2) },
		}, 1, 1)
	end
	local function parabola()
		local p, h = {}, { 1, -1, 1 }
		for i = 1, 3 do
			p[i] = { Vector3.new(i - 2, -1, h[i]), Vector3.new(i - 2, 1, h[i]) }
		end
		return N.surface(p, 2, 1)
	end
	local function contains(box, p)
		for i, x in p do
			if box[i][1] > x or box[i][2] < x then
				return false
			end
		end
		return true
	end
	local function coverage(r, p)
		for _, c in r.curves do
			if contains(c.parameterBox, p) then
				return true
			end
		end
		for _, c in r.unresolved do
			if contains(c.parameterBox, p) then
				return true
			end
		end
		return false
	end
	local function checkCurve(c, exact)
		assert(c.certified and c.uniqueGraph and c.contractionNorm < 1 and c.accurate)
		assert(#c.samples == #c.segments + 1 and #c.segments > 0)
		for i, s in c.segments do
			assert(s.first == i and s.last == i + 1 and s.accurate and s.certified)
			local a, b = c.samples[i], c.samples[i + 1]
			assert(a.parameter == s.parameterRange[1] and b.parameter == s.parameterRange[2])
			for j = 0, 16 do
				local t = j / 16
				local p = exact(a.parameter * (1 - t) + b.parameter * t)
				local line = a.position * (1 - t) + b.position * t
				-- Vector3's arithmetic rounds again; permit that separate test-side error.
				assert(
					(p - line).Magnitude <= s.errorBound + 3e-7,
					tostring((p - line).Magnitude) .. " > " .. s.errorBound
				)
			end
		end
	end
	test("Two planes yield one ordered certified intersection arc", function()
		local r = Q.intersectSurfaces(horizontal(0), vertical(), { requireComplete = true })
		assert(
			r.complete
				and r.coverageCertified
				and #r.curves == 1
				and #r.unresolved == 0
				and r.segmentCount == 1
		)
		assert(not r.componentTopologyCertified)
		local c = r.curves[1]
		assert(c.parameterAxis == 1 and c.parameterRange[1] == 0 and c.parameterRange[2] == 1)
		checkCurve(c, function(t)
			return Vector3.new(2 * t - 1, 0, 0)
		end)
		assert(contains(c.samples[1].parameterBox, { 0, 0.5, 0.25, 0.5 }))
		assert(contains(c.samples[2].parameterBox, { 1, 0.5, 0.75, 0.5 }))
		assert(contains(c.segments[1].tangentBox, { 2, 0, 0 }))
	end)
	test("Separated surfaces have a certified empty full-domain cover", function()
		local r = Q.intersectSurfaces(horizontal(0), horizontal(1), { requireComplete = true })
		assert(r.complete and #r.curves == 0 and #r.unresolved == 0 and r.excluded == 1)
	end)
	test("Parabolic intersection chord bounds cover independent analytic points", function()
		local r = Q.intersectSurfaces(parabola(), vertical(), { tolerance = 0.001, requireComplete = true })
		assert(#r.curves == 1 and r.segmentCount > 1 and r.segmentCount < 1000)
		checkCurve(r.curves[1], function(t)
			local x = 2 * t - 1
			return Vector3.new(x, 0, x * x)
		end)
		for _, s in r.curves[1].segments do
			local lo, hi = s.parameterRange[1], s.parameterRange[2]
			assert(
				contains(s.tangentBox, { 2, 0, 8 * lo - 4 }) and contains(s.tangentBox, { 2, 0, 8 * hi - 4 })
			)
		end
	end)
	test("Tighter requested chord error refines the same analytic arc", function()
		local a = Q.intersectSurfaces(parabola(), vertical(), { tolerance = 0.01, requireComplete = true })
		local b = Q.intersectSurfaces(parabola(), vertical(), { tolerance = 0.0005, requireComplete = true })
		assert(b.segmentCount > a.segmentCount and b.curves[1].errorBound <= 0.0005)
	end)
	test("Positive rational circular arc stays inside analytic radial bounds", function()
		local s = N.surface({
			{ Vector3.new(1, 0, -1), Vector3.new(1, 0, 1) },
			{ Vector3.new(1, 1, -1), Vector3.new(1, 1, 1) },
			{ Vector3.new(0, 1, -1), Vector3.new(0, 1, 1) },
		}, 2, 1, { weights = { { 1, 1 }, { math.sqrt(0.5), math.sqrt(0.5) }, { 1, 1 } } })
		local r = Q.intersectSurfaces(
			s,
			horizontal(0, 2),
			{ tolerance = 0.002, maxNodes = 1000, requireComplete = true }
		)
		assert(#r.curves >= 1)
		for _, c in r.curves do
			assert(c.parameterAxis == 1)
			checkCurve(c, function(t)
				local w = math.sqrt(0.5)
				local den = (1 - t) ^ 2 + 2 * w * t * (1 - t) + t * t
				return Vector3.new(
					((1 - t) ^ 2 + 2 * w * t * (1 - t)) / den,
					(2 * w * t * (1 - t) + t * t) / den,
					0
				)
			end)
		end
	end)
	test("C0 piece boundaries retain a kink under first-derivative chord bounds", function()
		local a = N.surface({
			{ Vector3.new(-1, -1, 1), Vector3.new(-1, 1, 1) },
			{ Vector3.new(0, -1, 0), Vector3.new(0, 1, 0) },
			{ Vector3.new(1, -1, 1), Vector3.new(1, 1, 1) },
		}, 1, 1)
		local r = Q.intersectSurfaces(a, vertical(), { tolerance = 0.005, requireComplete = true })
		for _, c in r.curves do
			checkCurve(c, function(t)
				return Vector3.new(2 * t - 1, 0, math.abs(2 * t - 1))
			end)
		end
	end)
	test("Coincident and tangential patches stay unresolved under search limits", function()
		for _, a in { horizontal(0), parabola() } do
			local r = Q.intersectSurfaces(a, horizontal(0), { maxNodes = 20, maxDepth = 8 })
			assert(not r.complete and #r.unresolved > 0 and r.coverageCertified)
			assert(coverage(r, { 0.5, 0.5, 0.5, 0.5 }))
		end
	end)
	test("Dependent boundary roots are retained without claiming complete ownership", function()
		local b = N.surface({
			{ Vector3.new(-1, 0, -1), Vector3.new(-1, 0, 1) },
			{ Vector3.new(1, 0, -1), Vector3.new(1, 0, 1) },
		}, 1, 1)
		local r = Q.intersectSurfaces(horizontal(0), b, { maxNodes = 80, maxDepth = 8 })
		assert(not r.complete and coverage(r, { 0, 0.5, 0, 0.5 }) and coverage(r, { 1, 0.5, 1, 0.5 }))
		assert(not pcall(Q.intersectSurfaces, horizontal(0), b, { maxNodes = 1, requireComplete = true }))
	end)
	test("Snapshots precede callbacks that mutate sources and option ranges", function()
		local a, b = horizontal(0), vertical()
		local options = { parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }, requireComplete = true }
		options.checkpoint = function()
			a.control[1][1] = Vector3.new(999, 999, 999)
			b.weights[1][1] = 999
			options.parameterBox[1][2] = 0.1
		end
		local r = Q.intersectSurfaces(a, b, options)
		assert(r.complete and r.curves[1].parameterRange[2] == 1 and r.curves[1].samples[1].position.X == -1)
	end)
	test("Restricted ranges retain original normalized parameters", function()
		local r = Q.intersectSurfaces(
			horizontal(0),
			vertical(),
			{ parameterBox = { { 0.25, 0.75 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }, requireComplete = true }
		)
		local c = r.curves[1]
		assert(c.parameterRange[1] == 0.25 and c.parameterRange[2] == 0.75)
		assert(contains(c.samples[1].parameterBox, { 0.25, 0.5, 0.375, 0.5 }))
	end)
	test("Segment and depth limits retain certified graphs with explicit approximation failure", function()
		local r = Q.intersectSurfaces(parabola(), vertical(), { maxSegments = 1, tolerance = 1e-7 })
		assert(not r.complete and r.segmentCount == 1 and #r.unresolved == 0 and r.curves[1].certified)
		assert(not r.curves[1].accurate and r.curves[1].segments[1].reason == "segments")
		local d = Q.intersectSurfaces(parabola(), vertical(), { maxDepth = 0, tolerance = 1e-7 })
		assert(not d.complete and d.curves[1].segments[1].reason == "depth")
	end)
	test("Invalid ranges, nonpositive tolerances, cancellation and hard budgets reject", function()
		for _, options in
			{
				{ tolerance = 0 },
				{ parameterTolerance = 0 },
				{ parameterBox = { { 0, 1 } } },
				{ parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0.5, 0.5 } } },
				{ maxDepth = 129 },
				{ maxIterations = 129 },
				{ maxNodes = 0 },
				{ maxCurves = 0 },
				{ maxSegments = 0 },
				{ requireComplete = "yes" },
				{ maxWork = 1 },
				{ maxCoefficients = 1 },
				{ maxControls = 1 },
				{
					cancelled = function()
						return true
					end,
				},
			}
		do
			assert(not pcall(Q.intersectSurfaces, horizontal(0), vertical(), options))
		end
	end)
	test("A closed circular intersection is covered while graph coordinates change", function()
		local p, h = {}, { 0.25, -0.25, 0.25 }
		for i = 1, 3 do
			p[i] = {}
			for j = 1, 3 do
				p[i][j] = Vector3.new((i - 1) / 2 - 0.5, (j - 1) / 2 - 0.5, h[i] + h[j])
			end
		end
		local r = Q.intersectSurfaces(
			N.surface(p, 2, 2),
			horizontal(0.125),
			{ tolerance = 0.002, maxNodes = 1000, requireComplete = true }
		)
		local axes = {}
		for _, c in r.curves do
			axes[c.parameterAxis] = true
			assert(c.accurate and c.certified)
			for _, s in c.samples do
				local position = s.position
				assert(
					math.abs(position.X * position.X + position.Y * position.Y - 0.125) < 1e-6
						and math.abs(position.Z - 0.125) < 1e-6
				)
			end
		end
		assert((axes[1] or axes[3]) and (axes[2] or axes[4]))
		for i = 0, 128 do
			local t = 2 * math.pi * i / 128
			local x, y = math.sqrt(0.125) * math.cos(t), math.sqrt(0.125) * math.sin(t)
			assert(
				coverage(r, { x + 0.5, y + 0.5, (x + 1) / 2, (y + 1) / 2 }),
				"Lost analytic circle parameter"
			)
		end
	end)
	test("Disconnected analytic lines retain both parameter branches", function()
		local p, h = {}, { 0.1875, -0.3125, 0.1875 }
		for i = 1, 3 do
			p[i] = { Vector3.new((i - 1) / 2 - 0.5, -0.5, h[i]), Vector3.new((i - 1) / 2 - 0.5, 0.5, h[i]) }
		end
		local r = Q.intersectSurfaces(
			N.surface(p, 2, 1),
			horizontal(0),
			{ tolerance = 0.002, maxNodes = 1000, requireComplete = true }
		)
		assert(#r.curves >= 2)
		for _, u in { 0.25, 0.75 } do
			for j = 0, 16 do
				local v = j / 16
				assert(coverage(r, { u, v, (u + 0.5) / 2, (v + 0.5) / 2 }))
			end
		end
		local limited = Q.intersectSurfaces(
			N.surface(p, 2, 1),
			horizontal(0),
			{ maxNodes = 100, maxCurves = 1, tolerance = 0.01 }
		)
		assert(not limited.complete and #limited.curves == 1 and #limited.unresolved > 0)
	end)
	test("Nonseparable rational tensor weights preserve independent centerline samples", function()
		local p, w = {}, { { 1, 2, 1 }, { 2, 1, 2 }, { 1, 3, 1 } }
		for i = 1, 3 do
			p[i] = {}
			for j = 1, 3 do
				p[i][j] = Vector3.new(i - 2, j - 2, (i - 2) ^ 2)
			end
		end
		local a = N.surface(p, 2, 2, { weights = w })
		local r =
			Q.intersectSurfaces(a, vertical(), { tolerance = 0.005, maxNodes = 1000, requireComplete = true })
		for _, c in r.curves do
			assert(c.parameterAxis == 1)
			checkCurve(c, function(t)
				return N.evaluateSurface(a, t, 0.5)
			end)
		end
	end)
	test("Unique periodic surface controls yield seam-inclusive ordered arcs", function()
		local p = {}
		for _, v in
			{ Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) }
		do
			table.insert(p, { v - Vector3.zAxis, v + Vector3.zAxis })
		end
		local s = E.Cyclic.surface(p, 1, 1, { cyclicU = true, cyclicV = false })
		local r = Q.intersectSurfaces(
			s,
			horizontal(0, 2),
			{ tolerance = 0.01, maxNodes = 1000, requireComplete = true }
		)
		for _, c in r.curves do
			assert(c.parameterAxis == 1)
			checkCurve(c, function(t)
				return E.Cyclic.evaluateSurface(s, t, 0.5)
			end)
		end
		assert(coverage(r, { 0, 0.5, 0.75, 0.5 }) and coverage(r, { 1, 0.5, 0.75, 0.5 }))
	end)
	test("Nonunit unclamped knot domains preserve normalized curve coordinates", function()
		local a, b = horizontal(0), vertical()
		a = N.surface(
			a.control,
			1,
			1,
			{ knotsU = { -2, 2, 7, 9 }, knotsV = { -4, 1, 3, 6 }, clampedU = false, clampedV = false }
		)
		b = N.surface(
			b.control,
			1,
			1,
			{ knotsU = { -10, -2, 3, 8 }, knotsV = { -9, -1, 2, 7 }, clampedU = false, clampedV = false }
		)
		local r = Q.intersectSurfaces(a, b, { requireComplete = true })
		checkCurve(r.curves[1], function(t)
			return Vector3.new(2 * t - 1, 0, 0)
		end)
	end)
	test("Rigid transforms scales and independent weight gauges retain intersections", function()
		local frame = CFrame.new(7, -3, 2) * CFrame.Angles(0.2, -0.4, 0.3)
		for _, scale in { 0.001, 1, 100 } do
			local a, b = horizontal(0), vertical()
			for index, s in { a, b } do
				for i, row in s.control do
					for j, p in row do
						s.control[i][j] = frame:PointToWorldSpace(p * scale)
						s.weights[i][j] = index == 1 and 1e100 or 1e-100
					end
				end
			end
			local r = Q.intersectSurfaces(a, b, { tolerance = 0.001, requireComplete = true })
			assert(r.complete and #r.curves == 1)
			for _, p in r.curves[1].samples do
				local target = frame:PointToWorldSpace(Vector3.new(2 * p.parameter - 1, 0, 0) * scale)
				assert((p.position - target).Magnitude <= 2e-5 * math.max(1, scale))
			end
		end
	end)
	test("Large translated native rounding remains an explicit approximation failure", function()
		local a, b = horizontal(0), vertical()
		for _, s in { a, b } do
			for i, row in s.control do
				for j, p in row do
					s.control[i][j] = Vector3.new(1e8 + p.X * 16, p.Y, p.Z)
				end
			end
		end
		local r = Q.intersectSurfaces(
			a,
			b,
			{ tolerance = 0.001, parameterBox = { { 0.2, 0.8 }, { 0, 1 }, { 0, 1 }, { 0, 1 } } }
		)
		assert(not r.complete and #r.unresolved == 0 and r.curves[1].certified)
		assert(r.curves[1].samples[1].errorBound > 1 and not r.curves[1].accurate)
	end)
	test("Surface intersection source geometry survives a native UV normal round trip", function()
		local s = parabola()
		local r = Q.intersectSurfaces(s, vertical(), { tolerance = 0.01, requireComplete = true })
		local mesh = N.tessellate(s, 8, 6)
		local native = E.Roblox.toEditable(mesh).editable
		local ok, err = pcall(function()
			local copy = E.Roblox.fromEditable(native)
			assert(copy:validate().valid)
			for _, face in copy.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal)
				end
			end
			assert(r.complete and #r.curves[1].samples > 2)
		end)
		native:Destroy()
		assert(ok, err)
	end)
	test("Swapped and transposed surfaces select different free parameter coordinates", function()
		local swapped = Q.intersectSurfaces(vertical(), horizontal(0), { requireComplete = true })
		assert(#swapped.curves == 1 and swapped.curves[1].parameterAxis == 3)
		checkCurve(swapped.curves[1], function(t)
			return Vector3.new(2 * t - 1, 0, 0)
		end)
		local a = horizontal(0)
		local transposed =
			N.surface({ { a.control[1][1], a.control[2][1] }, { a.control[1][2], a.control[2][2] } }, 1, 1)
		local r = Q.intersectSurfaces(transposed, vertical(), { requireComplete = true })
		assert(r.curves[1].parameterAxis == 2)
		checkCurve(r.curves[1], function(t)
			return Vector3.new(2 * t - 1, 0, 0)
		end)
	end)
	test("Sampling callbacks cancel without changing source controls", function()
		local a, b = parabola(), vertical()
		local first = a.control[1][1]
		local seen = false
		assert(not pcall(Q.intersectSurfaces, a, b, {
			checkpoint = function(info)
				if info.stage == "sample" then
					seen = true
					error("stop sampling")
				end
			end,
		}))
		assert(seen and a.control[1][1] == first)
	end)
	return report
end
