return function(E)
	local N, S, C = E.NURBS, E.Surfaces, E.Cyclic
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, t)
		assert((a - b).Magnitude <= (t or 2e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function rejects(fn)
		assert(not pcall(fn), "Expected rejection")
	end
	local function patch(offset, degree, rational)
		local p, w = {}, {}
		for i = 0, degree do
			p[i + 1], w[i + 1] = {}, {}
			for j = 0, degree do
				p[i + 1][j + 1] = Vector3.new(offset + i / degree, j / degree, 0.2 * math.sin(i * 0.7 + j))
				w[i + 1][j + 1] = rational and (0.7 + ((i * 7 + j * 3) % 9) * 0.08) or 1
			end
		end
		return N.surface(p, degree, degree, { weights = w })
	end
	local function derivative(s, border, t)
		if s.kind == "cyclicSurface" then
			s = C.surfaceToNURBS(s)
		end
		local uAxis, zero = border:sub(1, 1) == "U", border:sub(2) == "0"
		local cross = zero and 0 or 1
		local d = N.surfaceDerivatives(s, uAxis and cross or t, uAxis and t or cross)
		return d.position, (uAxis and d.du or d.dv) * (zero and -1 or 1), uAxis and d.duu or d.dvv
	end
	local function check(a, ea, b, eb, order, reverse, scale)
		for i = 0, 40 do
			local t = i / 40
			local p, d, dd = derivative(a, ea, t)
			local q, e, ee = derivative(b, eb, reverse and 1 - t or t)
			near(p, q)
			if order >= 1 then
				near(d, -e * (scale or 1), 7e-5)
			end
			if order >= 2 then
				near(dd, ee * (scale or 1) ^ 2, 2e-4)
			end
		end
	end
	test("Polynomial C0 join is the independent weighted border average", function()
		local a, b = patch(0, 3), patch(1.2, 3)
		local x, y, r = S.join(a, "U1", b, "U0", { order = 0, stiffnessA = 3 })
		assert(r.complete and r.solver.rank == 4)
		for j = 1, 4 do
			local expected = (a.control[4][j] * 3 + b.control[1][j]) / 4
			near(x.control[4][j], expected, 2e-7)
			near(y.control[1][j], expected, 2e-7)
		end
		for i = 1, 3 do
			for j = 1, 4 do
				assert(x.control[i][j] == a.control[i][j])
			end
		end
		check(x, "U1", y, "U0", 0)
	end)
	test("C1 and C2 joins match independent polynomial control stencils", function()
		for order = 1, 2 do
			local a, b = patch(0, 3), patch(1.2, 3)
			local x, y, r = S.join(a, "U1", b, "U0", { order = order, fixedA = true })
			assert(r.complete)
			for j = 1, 4 do
				near(y.control[1][j], a.control[4][j], 2e-7)
				near(y.control[2][j], 2 * a.control[4][j] - a.control[3][j], 3e-7)
				if order == 2 then
					near(y.control[3][j], 4 * a.control[4][j] - 4 * a.control[3][j] + a.control[2][j], 8e-7)
				end
			end
			check(x, "U1", y, "U0", order)
		end
	end)
	test("Rational fixed-weight border constraints hold beyond the solve coefficients", function()
		for order = 0, 2 do
			local a, b = patch(0, 2, true), patch(1.1, 2, true)
			local x, y, r = S.join(a, "U1", b, "U0", { order = order })
			assert(r.complete)
			check(x, "U1", y, "U0", order)
			for i, row in a.weights do
				for j, w in row do
					assert(x.weights[i][j] == w and y.weights[i][j] == b.weights[i][j])
				end
			end
		end
	end)
	test("Every border orientation supports reversed matching and cross scales", function()
		for _, ea in { "U0", "U1", "V0", "V1" } do
			for _, eb in { "U0", "U1", "V0", "V1" } do
				local x, y, r =
					S.join(patch(0, 2), ea, patch(0.3, 2), eb, { order = 2, reverse = true, crossScale = 2 })
				assert(r.complete)
				check(x, ea, y, eb, 2, true, 2)
			end
		end
	end)
	test("Mixed degrees and nonuniform knot spans use complete common partitions", function()
		local a, b = patch(0, 2), patch(1.1, 3)
		a = N.insertSurfaceKnot(a, "V", 0.27)
		b = N.insertSurfaceKnot(b, "V", 0.63, 2)
		local x, y, r = S.join(a, "U1", b, "U0", { order = 2 })
		assert(r.complete and r.spans == 3 and x.degreeV == 2 and y.degreeV == 3)
		check(x, "U1", y, "U0", 2)
	end)
	test("Exact pins and fixed patches retain their original controls", function()
		local a, b = patch(0, 3), patch(1.1, 3)
		local pins = { ["4:1"] = true, ["4:2"] = Vector3.new(3, 0.4, 0.5) }
		local x, y, r = S.join(a, "U1", b, "U0", { order = 1, fixedA = true, pinsB = pins })
		assert(r.complete and y.control[4][1] == b.control[4][1] and y.control[4][2] == pins["4:2"])
		for i, row in a.control do
			for j, p in row do
				assert(x.control[i][j] == p)
			end
		end
		check(x, "U1", y, "U0", 1)
	end)
	test("Incompatible fixed borders and displacement limits cannot report success", function()
		local a, b = patch(0, 2), patch(3, 2)
		local _, _, r = S.join(a, "U1", b, "U0", { fixedA = true, fixedB = true, requireComplete = false })
		assert(not r.complete and r.positionErrorBound >= 1.9)
		rejects(function()
			S.join(a, "U1", b, "U0", { fixedA = true, fixedB = true })
		end)
		local _, _, limit = S.join(a, "U1", b, "U0", { maxDisplacement = 0.01, requireComplete = false })
		assert(not limit.complete and limit.reason == "displacement")
	end)
	test("Input controls weights knots and options are independent snapshots", function()
		local a, b = patch(0, 2, true), patch(1.1, 2, true)
		local p, w, k = a.control[1][1], a.weights[1][1], a.knotsU[1]
		local options = { order = 0, pinsA = { ["1:1"] = true } }
		local x, y = S.join(a, "U1", b, "U0", options)
		x.control[1][1] = Vector3.one * 99
		y.weights[1][1] = 99
		assert(
			a.control[1][1] == p
				and a.weights[1][1] == w
				and a.knotsU[1] == k
				and options.pinsA["1:1"] == true
		)
	end)
	test("Common rational weight gauges preserve the joined geometry", function()
		local a, b = patch(0, 2, true), patch(1.1, 2, true)
		local x, y = S.join(a, "U1", b, "U0", { order = 1 })
		for i, row in a.weights do
			for j, w in row do
				row[j] = w * 1e100
				b.weights[i][j] *= 1e-100
			end
		end
		local u, v = S.join(a, "U1", b, "U0", { order = 1 })
		for i, row in x.control do
			for j, p in row do
				near(p, u.control[i][j], 3e-6)
				near(y.control[i][j], v.control[i][j], 3e-6)
			end
		end
	end)
	test("Cancellation and explicit matrix variable span and work budgets are enforced", function()
		local a, b = patch(0, 3), patch(1.1, 3)
		for _, o in
			{
				{ maxControls = 3 },
				{ maxVariables = 1 },
				{ maxMatrixEntries = 1 },
				{ maxConstraints = 1 },
				{ maxWork = 100 },
				{
					cancelled = function()
						return true
					end,
				},
			}
		do
			rejects(function()
				S.join(a, "U1", b, "U0", o)
			end)
		end
		local seen = false
		rejects(function()
			S.join(a, "U1", b, "U0", {
				checkpoint = function(s)
					if s.stage == "solve" then
						seen = true
						error("stop")
					end
				end,
			})
		end)
		assert(seen)
	end)
	test("Invalid order flags pin keys and nonpositive stiffness reject", function()
		for _, o in
			{
				{ order = 3 },
				{ order = -1 },
				{ crossScale = 0 },
				{ reverse = 1 },
				{ pinsA = { ["01:1"] = true } },
				{ stiffnessB = 0 },
				{ tolerance = -1 },
				{ firstTolerance = 0 / 0 },
				{ rankTolerance = 1 },
			}
		do
			rejects(function()
				S.join(patch(0, 2), "U1", patch(1, 2), "U0", o)
			end)
		end
		rejects(function()
			S.join(patch(0, 2), "X1", patch(1, 2), "U0")
		end)
	end)
	test("Unclamped surfaces retain their raw domains and cross-boundary derivatives", function()
		local p, q = {}, {}
		for i = 1, 4 do
			p[i], q[i] = {}, {}
			for j = 1, 4 do
				p[i][j] = Vector3.new(i, j, 0.1 * i * j)
				q[i][j] = Vector3.new(i + 3, j, 0.2 * math.sin(i + j))
			end
		end
		local a = N.surface(p, 2, 2, {
			clampedU = false,
			clampedV = false,
			knotsU = { -20, -15, -10, -4, 5, 10, 15 },
			knotsV = {
				-1,
				-0.5,
				0,
				0.4,
				1,
				1.4,
				2,
			},
		})
		local b = N.surface(q, 2, 2, {
			clampedU = false,
			clampedV = false,
			knotsU = { -2, -1, 0, 0.6, 1, 2, 3 },
			knotsV = {
				-4,
				-1,
				2,
				4,
				7,
				9,
				12,
			},
		})
		local x, y, r = S.join(a, "U1", b, "U0", { order = 2 })
		assert(r.complete and not x.clampedU and not y.clampedV)
		for i, k in a.knotsU do
			assert(x.knotsU[i] == k)
		end
		for i, k in b.knotsV do
			assert(y.knotsV[i] == k)
		end
		check(x, "U1", y, "U0", 2)
	end)
	test("Along-border periodic controls remain unique and closed through C2 joining", function()
		local p, q = {}, {}
		for i = 1, 6 do
			p[i], q[i] = {}, {}
			local theta = (i - 1) * math.pi / 3
			for j = 1, 4 do
				p[i][j] = Vector3.new(math.cos(theta), j - 1, math.sin(theta))
				q[i][j] = Vector3.new(1.2 * math.cos(theta), j + 2.2, 1.2 * math.sin(theta))
			end
		end
		local a = C.surface(p, 3, 3, { cyclicV = false, intervalsU = { 1, 2, 1, 2, 1, 3 } })
		local b = C.surface(q, 3, 3, { cyclicV = false, intervalsU = { 1, 2, 1, 2, 1, 3 } })
		local x, y, r = S.join(a, "V1", b, "V0", { order = 2, fixedA = true })
		assert(r.complete and x.kind == "cyclicSurface" and y.cyclicU and #y.control == 6)
		check(x, "V1", y, "V0", 2)
		for _, s in { x, y } do
			for i = 0, 6 do
				near(C.evaluateSurface(s, 0, i / 6), C.evaluateSurface(s, 1, i / 6), 2e-6)
			end
		end
		rejects(function()
			S.join(a, "U0", b, "V0")
		end)
	end)
	test("Rigid transforms and scale preserve the minimum-displacement solution", function()
		local a, b = patch(0, 3), patch(1.1, 3)
		local x, y = S.join(a, "U1", b, "U0", { order = 2 })
		local f = CFrame.new(4, -5, 2) * CFrame.Angles(0.2, 0.4, -0.3)
		for _, scale in { 0.001, 1, 100 } do
			local function transform(s)
				local p = {}
				for i, row in s.control do
					p[i] = {}
					for j, v in row do
						p[i][j] = f:PointToWorldSpace(v * scale)
					end
				end
				return N.surface(p, s.degreeU, s.degreeV, s)
			end
			local u, v, r = S.join(
				transform(a),
				"U1",
				transform(b),
				"U0",
				{ order = 2, tolerance = 0.001, firstTolerance = 0.002, secondTolerance = 0.005 }
			)
			assert(r.complete)
			for i, row in x.control do
				for j, p in row do
					near(u.control[i][j], f:PointToWorldSpace(p * scale), 3e-5 * math.max(1, scale))
					near(
						v.control[i][j],
						f:PointToWorldSpace(y.control[i][j] * scale),
						3e-5 * math.max(1, scale)
					)
				end
			end
		end
	end)
	test("Independent double Bernstein jets lie inside every reported residual bound", function()
		local function independent(s, t, last)
			local p = s.degreeU
			local h = {}
			for i, row in s.control do
				h[i] = {}
				for j, v in row do
					local w = s.weights[i][j]
					h[i][j] = { v.X * w, v.Y * w, v.Z * w, w }
				end
			end
			local jets = { {}, {}, {} }
			for j = 1, #s.control[1] do
				for d = 1, 3 do
					jets[d][j] = {}
				end
				local i = last and p + 1 or 1
				local step = last and -1 or 1
				for k = 1, 4 do
					jets[1][j][k] = h[i][j][k]
					jets[2][j][k] = p * (h[i][j][k] - h[i + step][j][k])
					jets[3][j][k] = p * (p - 1) * (h[i][j][k] - 2 * h[i + step][j][k] + h[i + 2 * step][j][k])
				end
			end
			local result = {}
			for d = 1, 3 do
				local data = jets[d]
				for count = #data - 1, 1, -1 do
					local out = {}
					for i = 1, count do
						out[i] = {}
						for k = 1, 4 do
							out[i][k] = (1 - t) * data[i][k] + t * data[i + 1][k]
						end
					end
					data = out
				end
				result[d] = data[1]
			end
			local out = { {}, {}, {} }
			for k = 1, 3 do
				out[1][k] = result[1][k] / result[1][4]
				out[2][k] = (result[2][k] - out[1][k] * result[2][4]) / result[1][4]
				out[3][k] = (result[3][k] - 2 * out[2][k] * result[2][4] - out[1][k] * result[3][4])
					/ result[1][4]
			end
			return out
		end
		for degree = 2, 4 do
			local x, y, r = S.join(
				patch(0, degree, true),
				"U1",
				patch(1.1, degree, true),
				"U0",
				{ order = 2, requireComplete = false }
			)
			local bounds = { r.positionErrorBound, r.firstDerivativeErrorBound, r.secondDerivativeErrorBound }
			for i = 0, 50 do
				local a, b = independent(x, i / 50, true), independent(y, i / 50, false)
				for d = 1, 3 do
					local sum = 0
					for k = 1, 3 do
						sum += (a[d][k] + (d == 2 and 1 or -1) * b[d][k]) ^ 2
					end
					assert(math.sqrt(sum) <= bounds[d] + 1e-11)
				end
			end
		end
	end)
	test("Fixed rational reference remains noncollapsed when denominators are compatible", function()
		local a, b = patch(0, 3), patch(1.1, 3)
		for i, row in a.weights do
			for j in row do
				row[j] = ({ 1, 0.7, 0.8, 1 })[j]
				b.weights[i][j] = row[j] * ({ 1, 0.8, 1.2, 0.9 })[i]
			end
		end
		local x, y, r = S.join(a, "U1", b, "U0", { order = 2, fixedA = true })
		assert(r.complete)
		check(x, "U1", y, "U0", 2)
		local p = derivative(x, "U1", 0)
		local q = derivative(x, "U1", 1)
		assert((p - q).Magnitude > 0.9)
		for i, row in a.control do
			for j, p0 in row do
				assert(x.control[i][j] == p0)
			end
		end
	end)
	test("Fixed incompatible rational reference reports an unsatisfied whole border", function()
		local a, b = patch(0, 2, true), patch(1.1, 2, true)
		local _, _, r = S.join(a, "U1", b, "U0", { order = 1, fixedA = true, requireComplete = false })
		assert(not r.complete and r.solver.dependentResidual > 1e-9)
		rejects(function()
			S.join(a, "U1", b, "U0", { fixedA = true })
		end)
	end)
	test("Native precision loss and zero tolerances stay explicit", function()
		local a, b = patch(0, 3), patch(1.2, 3)
		for _, s in { a, b } do
			for i, row in s.control do
				for j, p in row do
					row[j] = p * 16 + Vector3.new(1e8, -1e8, 1e8)
				end
			end
		end
		local _, _, r = S.join(a, "U1", b, "U0", { order = 2, requireComplete = false })
		assert(not r.complete)
		local _, _, zero = S.join(
			patch(0, 2),
			"U1",
			patch(1.1, 2),
			"U0",
			{ order = 0, tolerance = 0, requireComplete = false }
		)
		assert(not zero.complete)
	end)
	test("Reversed nonuniform borders and per-control stiffness preserve their contracts", function()
		local a, b = patch(0, 3), patch(1.1, 3)
		a = N.insertSurfaceKnot(a, "V", 0.23)
		b = N.insertSurfaceKnot(b, "V", 0.64)
		local x, y, r = S.join(
			a,
			"U1",
			b,
			"U0",
			{ order = 1, reverse = true, stiffnessA = { ["4:1"] = 3, ["4:2"] = 0.4 } }
		)
		assert(r.complete and r.spans == 3)
		check(x, "U1", y, "U0", 1, true)
	end)
	test("Degree-nine border bases retain exact degree and knot layouts", function()
		local a = N.elevateSurfaceDegree(patch(0, 2), "V", 7)
		local b = N.elevateSurfaceDegree(patch(1.1, 2), "V", 8)
		local x, y, r = S.join(a, "U1", b, "U0", { order = 1 })
		assert(r.complete and x.degreeV == 9 and y.degreeV == 10)
		check(x, "U1", y, "U0", 1)
	end)
	test("Joined rational panels retain native mesh normals and independent UV charts", function()
		local result = require(script.Parent.Examples.JoinedPanels)(E)
		assert(result.join.complete and not result.join.regularityChecked)
		check(result.surfaces[1], "U1", result.surfaces[2], "U0", 1)
		for _, mesh in result.meshes do
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				assert(restored:validate().valid)
				for _, face in restored.faces do
					for _, c in face.corners do
						assert(c.uv and c.normal and math.abs(c.normal.Magnitude - 1) < 1e-5)
					end
				end
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end
	end)
	test(
		"Linear cross directions and already joined patches retain valid zero-curvature constraints",
		function()
			local a = N.surface({
				{ Vector3.new(0, 0, 0), Vector3.new(0, 1, 0) },
				{ Vector3.new(1, 0, 0), Vector3.new(1, 1, 0) },
			}, 1, 1)
			local b = N.surface({
				{ Vector3.new(1, 0, 0), Vector3.new(1, 1, 0) },
				{ Vector3.new(2, 0, 0), Vector3.new(2, 1, 0) },
			}, 1, 1)
			local x, y, r = S.join(a, "U1", b, "U0", { order = 2 })
			assert(r.complete and r.maximumDisplacement == 0)
			check(x, "U1", y, "U0", 2)
		end
	)
	report.success = report.failed == 0
	return report
end
