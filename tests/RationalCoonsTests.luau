return function(E)
	local N, S = E.NURBS, E.Surfaces
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, t)
		assert((a - b).Magnitude < (t or 6e-6), tostring(a) .. " ~= " .. tostring(b))
	end
	local function rejects(fn)
		assert(not pcall(fn), "Expected rejection")
	end
	local function boundaries(p, q)
		local points, weights = {}, {}
		for side = 1, 4 do
			local degree = side <= 2 and p or q
			points[side], weights[side] = {}, {}
			for i = 0, degree do
				local t = i / degree
				local hump = (i == 0 or i == degree) and 0 or math.sin(math.pi * t)
				points[side][i + 1] = side == 1 and Vector3.new(3 * t, -0.3 * hump, 0.2 * hump)
					or side == 2 and Vector3.new(3 * t, 2 + 0.2 * hump, -0.1 * hump)
					or side == 3 and Vector3.new(-0.2 * hump, 2 * t, 0.3 * hump)
					or Vector3.new(3 + 0.4 * hump, 2 * t, -0.2 * hump)
				weights[side][i + 1] = 0.4 + ((i * 7 + side * 3) % 11) * 0.09
			end
		end
		local out = {}
		for i = 1, 4 do
			out[i] = N.curve(points[i], i <= 2 and p or q, { weights = weights[i] })
		end
		return out
	end
	local function construct(c, options)
		return S.coons(c[1], c[2], c[3], c[4], options)
	end
	local function expected(c, u, v)
		local p00, p10, p01, p11 =
			N.evaluate(c[1], 0), N.evaluate(c[1], 1), N.evaluate(c[2], 0), N.evaluate(c[2], 1)
		return N.evaluate(c[1], u):Lerp(N.evaluate(c[2], u), v)
			+ N.evaluate(c[3], v):Lerp(N.evaluate(c[4], v), u)
			- p00:Lerp(p10, u):Lerp(p01:Lerp(p11, u), v)
	end
	local function check(c, s, tolerance)
		local eval = N.compileSurface(s)
		for i = 0, 16 do
			local t = i / 16
			near(eval.evaluate(t, 0), N.evaluate(c[1], t), tolerance)
			near(eval.evaluate(t, 1), N.evaluate(c[2], t), tolerance)
			near(eval.evaluate(0, t), N.evaluate(c[3], t), tolerance)
			near(eval.evaluate(1, t), N.evaluate(c[4], t), tolerance)
		end
		for i = 0, 6 do
			for j = 0, 6 do
				local u, v = i / 6, j / 6
				near(eval.evaluate(u, v), expected(c, u, v), tolerance)
			end
		end
	end
	test("Rational boundaries of degrees one through eight reproduce the classical blend", function()
		for degree = 1, 8 do
			local c = boundaries(degree, 9 - degree)
			local s, r = construct(c, { returnReport = true })
			assert(
				r.complete
					and r.degreeU == 2 * degree + 1
					and r.degreeV == 2 * (9 - degree) + 1
					and r.constructionErrorBound <= 1e-5
			)
			for _, row in s.weights do
				for _, w in row do
					assert(w > 0 and w < math.huge)
				end
			end
			check(c, s)
		end
	end)
	test("Default return remains one surface and detailed reports require explicit opt in", function()
		local c = boundaries(2, 2)
		assert(select("#", construct(c)) == 1)
		local s, r = construct(c, { returnReport = true })
		assert(s.kind == "surface" and r.complete and not r.regularityChecked)
		rejects(function()
			construct(c, { requireComplete = false })
		end)
	end)
	test("Quarter circle Coons boundaries yield an exact rational cylindrical strip", function()
		local bottom = S.arc(CFrame.identity, 2, 0, math.pi / 2)
		local top = N.curve(
			{ Vector3.new(2, 0, 3), Vector3.new(2, 2, 3), Vector3.new(0, 2, 3) },
			2,
			{ weights = { 1, math.sqrt(0.5), 1 } }
		)
		-- Snap the nominal trigonometric endpoint to the same native shared corner.
		bottom.points[3] = Vector3.new(0, 2, 0)
		local left = N.curve({ bottom.points[1], top.points[1] }, 1)
		local right = N.curve({ bottom.points[3], top.points[3] }, 1)
		local s, r = S.coons(bottom, top, left, right, { returnReport = true })
		assert(r.complete and s.degreeU == 5 and s.degreeV == 1)
		for i = 0, 15 do
			for j = 0, 8 do
				local u, v = i / 15, j / 8
				local d = N.surfaceDerivatives(s, u, v)
				assert(math.abs(d.position.X * d.position.X + d.position.Y * d.position.Y - 4) < 5e-6)
				near(d.position, N.evaluate(bottom, u) + Vector3.new(0, 0, 3 * v))
				near(d.dv, Vector3.new(0, 0, 3))
				near(d.du, N.derivatives(bottom, u).first, 1e-5)
			end
		end
	end)
	test("Mixed degrees and nonuniform independent knot spans share a conforming control net", function()
		local c = boundaries(2, 3)
		c[1] = N.insertKnot(c[1], 0.23, 1)
		c[2] = N.insertKnot(N.elevateDegree(c[2], 1), 0.67, 2)
		c[3] = N.insertKnot(c[3], 0.31, 2)
		c[4] = N.insertKnot(c[4], 0.78, 1)
		local s, r = construct(c, { returnReport = true })
		assert(r.complete and r.patches == 9 and s.degreeU == 6 and s.degreeV == 7)
		check(c, s)
		for _, u in { 0.23, 0.67 } do
			for _, v in { 0.31, 0.78, 0.57 } do
				near(N.evaluateSurface(s, u - 1e-7, v), N.evaluateSurface(s, u + 1e-7, v), 5e-6)
			end
		end
	end)
	test("Unclamped active domains retain their boundary parameterization", function()
		local points = {}
		for i = 1, 6 do
			points[i] = Vector3.new(i - 2, 0, 0.1 * math.sin(i))
		end
		local b = N.curve(points, 2, { clamped = false, weights = { 1, 0.6, 1.2, 0.8, 1.5, 1 } })
		local tpoints = {}
		for i, p in points do
			tpoints[i] = p + Vector3.new(0, 2, 0)
		end
		local t = N.curve(tpoints, 2, { clamped = false, weights = table.clone(b.weights) })
		local c = {
			b,
			t,
			N.curve({ N.evaluate(b, 0), N.evaluate(t, 0) }, 1),
			N.curve({ N.evaluate(b, 1), N.evaluate(t, 1) }, 1),
		}
		local s, r = construct(c, { returnReport = true })
		assert(r.complete and r.knotNormalizationAllowance >= 0)
		check(c, s)
	end)
	test("Independent common weight scales preserve the surface and positive tensor weights", function()
		local c = boundaries(3, 2)
		local a = construct(c)
		for side, scale in { 1e120, 1e-120, 1e90, 1e-90 } do
			for i, w in c[side].weights do
				c[side].weights[i] = w * scale
			end
		end
		local b, r = construct(c, { returnReport = true })
		assert(r.complete)
		for i = 0, 9 do
			for j = 0, 9 do
				near(N.evaluateSurface(a, i / 9, j / 9), N.evaluateSurface(b, i / 9, j / 9))
			end
		end
	end)
	test("Polynomial boundaries retain their lower degrees and arbitrary common weights", function()
		local c = boundaries(4, 3)
		for i, curve in c do
			curve.weights = table.create(#curve.points, i * 13)
		end
		local s, r = construct(c, { returnReport = true })
		assert(r.complete and s.degreeU == 4 and s.degreeV == 3)
		check(c, s)
	end)
	test("Analytic surface derivatives agree with independently differentiated Coons formulas", function()
		local c = boundaries(3, 4)
		local s = construct(c)
		for _, uv in { { 0.19, 0.71 }, { 0.62, 0.23 }, { 0.4, 0.5 }, { 0, 0.27 }, { 1, 0.8 } } do
			local u, v = uv[1], uv[2]
			local b, t, l, r =
				N.derivatives(c[1], u), N.derivatives(c[2], u), N.derivatives(c[3], v), N.derivatives(c[4], v)
			local p00, p10, p01, p11 =
				N.evaluate(c[1], 0), N.evaluate(c[1], 1), N.evaluate(c[2], 0), N.evaluate(c[2], 1)
			local du = b.first:Lerp(t.first, v) + r.position - l.position - (p10 - p00):Lerp(p11 - p01, v)
			local dv = t.position - b.position + l.first:Lerp(r.first, u) - (p01 - p00):Lerp(p11 - p10, u)
			local actual = N.surfaceDerivatives(s, u, v)
			near(actual.du, du, 2e-5)
			near(actual.dv, dv, 2e-5)
			near(actual.duv, t.first - b.first + r.first - l.first - (p11 - p01 - p10 + p00), 8e-5)
		end
	end)
	test("Affine transforms and common geometric scales commute with construction", function()
		local c = boundaries(2, 3)
		local a = construct(c)
		local frame = CFrame.new(7, -3, 5) * CFrame.Angles(0.2, 0.4, -0.7)
		for _, scale in { 0.001, 1, 100 } do
			local d = {}
			for side, curve in c do
				local points = {}
				for i, p in curve.points do
					points[i] = frame:PointToWorldSpace(p * scale)
				end
				d[side] = N.curve(points, curve.degree, curve)
			end
			local b, r = construct(d, { returnReport = true, maxError = 0.001 })
			assert(r.complete)
			for i = 0, 5 do
				for j = 0, 5 do
					near(
						N.evaluateSurface(b, i / 5, j / 5),
						frame:PointToWorldSpace(N.evaluateSurface(a, i / 5, j / 5) * scale),
						math.max(8e-6, scale * 4e-6)
					)
				end
			end
		end
	end)
	test("Corner mismatch is bounded and mismatched input rejects beyond its tolerance", function()
		local c = boundaries(2, 2)
		c[3].points[1] += Vector3.new(0, 0, 2e-6)
		local s, r = construct(c, { returnReport = true })
		assert(r.complete and r.cornerMismatch > 1e-6 and r.boundaryErrorBound >= r.cornerMismatch)
		for i = 0, 20 do
			local u = i / 20
			assert(
				(N.evaluateSurface(s, u, 0) - N.evaluate(c[1], u)).Magnitude <= r.boundaryErrorBound + 5e-7
			)
		end
		rejects(function()
			construct(c, { tolerance = 1e-7 })
		end)
	end)
	test("Large translations expose native reconstruction error instead of hiding precision loss", function()
		local c = boundaries(2, 2)
		for _, curve in c do
			for i, p in curve.points do
				curve.points[i] = p * 64 + Vector3.new(1e8, 1e8, 1e8)
			end
		end
		rejects(function()
			construct(c)
		end)
		local s, r = construct(c, { returnReport = true, requireComplete = false })
		assert(
			not r.complete
				and r.reason == "precision"
				and r.constructionErrorBound > 1e-5
				and s.kind == "surface"
		)
	end)
	test("Output degrees controls patches work and cancellation have bounded failure", function()
		local c = boundaries(3, 3)
		for _, o in
			{
				{ maxDegree = 6 },
				{ maxControls = 20 },
				{ maxIntermediateControls = 2 },
				{ maxWork = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					constructionCheckpoint = function()
						error("stop")
					end,
				},
			}
		do
			rejects(function()
				construct(c, o)
			end)
		end
		c[1] = N.insertKnot(c[1], 0.5)
		rejects(function()
			construct(c, { maxPatches = 1 })
		end)
		local calls = 0
		rejects(function()
			construct(c, {
				constructionCheckpoint = function(status)
					calls += 1
					if status.work >= 256 then
						error("stop during work")
					end
				end,
			})
		end)
		assert(calls >= 2)
	end)
	test("Construction never mutates source controls weights knots or option tables", function()
		local c = boundaries(2, 3)
		local snapshots = {}
		for i, curve in c do
			snapshots[i] = {
				points = table.clone(curve.points),
				weights = table.clone(curve.weights),
				knots = table.clone(curve.knots),
			}
		end
		local o: any = { returnReport = true }
		construct(c, o)
		for i, curve in c do
			for j, p in curve.points do
				assert(p == snapshots[i].points[j] and curve.weights[j] == snapshots[i].weights[j])
			end
			for j, k in curve.knots do
				assert(k == snapshots[i].knots[j])
			end
		end
		assert(o.maxError == nil and o.returnReport == true)
	end)
	test("Invalid scalar inputs curve kinds weights and degree budgets reject", function()
		local c = boundaries(2, 2)
		for _, o in
			{
				{ tolerance = -1 },
				{ maxError = -1 },
				{ maxDegree = 18 },
				{ maxWork = 0 },
				{
					returnReport = true,
					maxError = 0,
				},
			}
		do
			rejects(function()
				construct(c, o)
			end)
		end
		c[1].weights[2] = 0
		rejects(function()
			construct(c)
		end)
		c = boundaries(2, 2)
		c[1].kind = "surface"
		rejects(function()
			construct(c)
		end)
	end)
	test("Reported whole-patch error bounds cover independent double precision evaluations", function()
		local function casteljau(data, t)
			for count = #data - 1, 1, -1 do
				local nextValues = {}
				for i = 1, count do
					local h = {}
					for k = 1, 4 do
						h[k] = (1 - t) * data[i][k] + t * data[i + 1][k]
					end
					nextValues[i] = h
				end
				data = nextValues
			end
			return data[1]
		end
		local function curvePoint(c, t)
			local h = {}
			for i, p in c.points do
				local w = c.weights[i]
				h[i] = { p.X * w, p.Y * w, p.Z * w, w }
			end
			local a = casteljau(h, t)
			return { a[1] / a[4], a[2] / a[4], a[3] / a[4] }
		end
		local function surfacePoint(s, u, v)
			local rows = {}
			for i, row in s.control do
				local h = {}
				for j, p in row do
					local w = s.weights[i][j]
					h[j] = { p.X * w, p.Y * w, p.Z * w, w }
				end
				rows[i] = casteljau(h, v)
			end
			local a = casteljau(rows, u)
			return { a[1] / a[4], a[2] / a[4], a[3] / a[4] }
		end
		for degree = 2, 6 do
			local c = boundaries(degree, 3)
			local s, r = construct(c, { returnReport = true })
			local corners =
				{ curvePoint(c[1], 0), curvePoint(c[1], 1), curvePoint(c[2], 0), curvePoint(c[2], 1) }
			for i = 0, 10 do
				for j = 0, 10 do
					local u, v = i / 10, j / 10
					local b, t, l, right =
						curvePoint(c[1], u), curvePoint(c[2], u), curvePoint(c[3], v), curvePoint(c[4], v)
					local actual = surfacePoint(s, u, v)
					local error = 0
					for k = 1, 3 do
						local ideal = (1 - v) * b[k]
							+ v * t[k]
							+ (1 - u) * l[k]
							+ u * right[k]
							- (
								(1 - u) * (1 - v) * corners[1][k]
								+ u * (1 - v) * corners[2][k]
								+ (1 - u) * v * corners[3][k]
								+ u * v * corners[4][k]
							)
						error += (actual[k] - ideal) ^ 2
					end
					assert(math.sqrt(error) <= r.constructionErrorBound + 1e-12)
				end
			end
		end
	end)
	test("Independent raw knot domains preserve normalized parameters with explicit conditioning", function()
		local c = boundaries(3, 2)
		c[1] = N.insertKnot(c[1], 0.23)
		c[4] = N.insertKnot(c[4], 0.71)
		local baseline = construct(c)
		for side, curve in c do
			for i, k in curve.knots do
				curve.knots[i] = (side - 3) * 2 + (side + 1) * k
			end
		end
		local s, r = construct(c, { returnReport = true })
		assert(r.complete and r.knotNormalizationAllowance > 0)
		check(c, s)
		for i = 0, 5 do
			for j = 0, 5 do
				near(N.evaluateSurface(s, i / 5, j / 5), N.evaluateSurface(baseline, i / 5, j / 5))
			end
		end
		for _, curve in c do
			local a, b = curve.knots[1], curve.knots[#curve.knots]
			for i, k in curve.knots do
				curve.knots[i] = 1e12 + (k - a) / (b - a)
			end
		end
		local _, bad = construct(c, { returnReport = true, requireComplete = false })
		assert(not bad.complete and bad.knotNormalizationAllowance > bad.maxError)
	end)
	test("Boundary orientation changes transpose and reverse the same classical surface", function()
		local c = boundaries(2, 3)
		local s = construct(c)
		local transposed = S.coons(c[3], c[4], c[1], c[2])
		local reversed = S.coons(N.reverse(c[1]), N.reverse(c[2]), c[4], c[3])
		for i = 0, 7 do
			for j = 0, 7 do
				local u, v = i / 7, j / 7
				near(N.evaluateSurface(transposed, v, u), N.evaluateSurface(s, u, v))
				near(N.evaluateSurface(reversed, 1 - u, v), N.evaluateSurface(s, u, v))
			end
		end
	end)
	test("Degree seventeen Coons output remains editable and exposes rational boundary isocurves", function()
		local c = boundaries(8, 2)
		local s = construct(c)
		local edited = N.insertSurfaceKnot(s, "U", 0.37, 2)
		local a, b = N.splitSurface(edited, "U", 0.37)
		local boundary = N.isoCurve(s, "U", 0)
		assert(boundary.degree == 17)
		for i = 0, 12 do
			local t = i / 12
			near(N.evaluate(boundary, t), N.evaluate(c[1], t))
			near(N.evaluateSurface(a, t, 0.63), N.evaluateSurface(s, t * 0.37, 0.63))
			near(N.evaluateSurface(b, t, 0.63), N.evaluateSurface(s, 0.37 + t * 0.63, 0.63))
		end
		local transposed = E.SurfaceEdit.transpose(s)
		near(N.evaluateSurface(transposed, 0.3, 0.7), N.evaluateSurface(s, 0.7, 0.3))
	end)
	test("Ill-conditioned positive weights return explicit precision diagnostics", function()
		local c = boundaries(2, 2)
		for _, curve in c do
			curve.weights = { 1e-15, 1, 1e-15 }
		end
		local s, r = construct(c, { returnReport = true, requireComplete = false })
		assert(not r.complete and r.reason == "precision")
		for _, row in s.weights do
			for _, w in row do
				assert(w > 0)
			end
		end
		rejects(function()
			construct(c)
		end)
	end)
	test("Rational Coons tessellation retains native UVs normals and valid geometry", function()
		local result = require(script.Parent.Examples.RationalCoonsPanel)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			for _, f in restored.faces do
				for _, c in f.corners do
					assert(
						c.normal
							and math.abs(c.normal.Magnitude - 1) < 1e-5
							and c.uv
							and c.uv.X >= 0
							and c.uv.X <= 1
							and c.uv.Y >= 0
							and c.uv.Y <= 1
					)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Zero corner tolerance retains exact shared native endpoints despite independent weights", function()
		for degree = 1, 8 do
			local c = boundaries(degree, 3)
			local s, r = construct(c, { returnReport = true, tolerance = 0 })
			assert(r.complete and r.cornerMismatch == 0)
			near(N.evaluateSurface(s, 1, 1), Vector3.new(3, 2, 0))
		end
	end)
	report.success = report.failed == 0
	return report
end
