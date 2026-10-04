return function(E)
	local N = E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function vec(a, b, eps)
		assert((a - b).Magnitude < (eps or 2e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function near(a, b, eps)
		assert(math.abs(a - b) < (eps or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local arc = N.curve(
		{ Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis },
		2,
		{ weights = { 1, math.sqrt(0.5), 1 } }
	)
	local function cylinder()
		local control, weights = {}, {}
		for i, p in arc.points do
			control[i] = { p, p + Vector3.zAxis * 2 }
			weights[i] = { arc.weights[i], arc.weights[i] }
		end
		return N.surface(control, 2, 1, { weights = weights })
	end
	test("NURBS circular arc has exact endpoints radius and curvature", function()
		vec(N.evaluate(arc, 0), Vector3.xAxis)
		vec(N.evaluate(arc, 1), Vector3.yAxis)
		for i = 0, 20 do
			local r = N.derivatives(arc, i / 20)
			near(r.position.Magnitude, 1)
			near(r.position:Dot(r.first), 0)
			near(r.curvature, 1, 2e-5)
		end
		vec(N.derivatives(arc, 0).first, Vector3.yAxis * math.sqrt(2))
		vec(N.derivatives(arc, 1).first, -Vector3.xAxis * math.sqrt(2))
	end)
	test("NURBS first and second derivatives match independent finite differences", function()
		local c = N.curve(
			{ Vector3.zero, Vector3.new(1, 2, 1), Vector3.new(2, -1, 2), Vector3.new(4, 1, 0) },
			3,
			{ weights = { 1, 0.7, 2, 1 } }
		)
		for _, t in { 0.13, 0.4, 0.8 } do
			local h = 0.002
			local a, b, r = N.evaluate(c, t - h), N.evaluate(c, t + h), N.derivatives(c, t)
			vec(r.first, (b - a) / (2 * h), 0.0003)
			vec(r.second, (b - 2 * r.position + a) / (h * h), 0.2)
		end
	end)
	test("NURBS knot domain and common weight scale do not change normalized derivatives", function()
		for _, factor in { 1e-35, 1e150 } do
			local c = N.curve(
				arc.points,
				2,
				{ knots = { 2, 2, 2, 6, 6, 6 }, weights = { factor, math.sqrt(0.5) * factor, factor } }
			)
			for _, t in { 0, 0.23, 0.76, 1 } do
				local a, b = N.derivatives(arc, t), N.derivatives(c, t)
				vec(a.position, b.position)
				vec(a.first, b.first)
				vec(a.second, b.second)
			end
		end
	end)
	test("NURBS insertion preserves the rational curve and increases control count", function()
		local c = N.insertKnot(N.insertKnot(arc, 0.31), 0.7, 2)
		assert(#c.points == 6 and #arc.points == 3)
		for i = 0, 80 do
			vec(N.evaluate(c, i / 80), N.evaluate(arc, i / 80))
		end
		assert(not pcall(N.insertKnot, c, 0.7))
	end)
	test("NURBS split reparameterizes both halves and scales their derivatives", function()
		local a, b = N.split(arc, 0.37)
		for i = 0, 30 do
			local t = i / 30
			vec(N.evaluate(a, t), N.evaluate(arc, t * 0.37))
			vec(N.evaluate(b, t), N.evaluate(arc, 0.37 + t * 0.63))
		end
		vec(N.derivatives(a, 0.4).first, N.derivatives(arc, 0.4 * 0.37).first * 0.37)
		vec(N.evaluate(a, 1), N.evaluate(b, 0))
	end)
	test("NURBS reverse preserves shape and reverses tangents", function()
		local c = N.reverse(N.insertKnot(arc, 0.3))
		for i = 0, 20 do
			local t = i / 20
			vec(N.evaluate(c, t), N.evaluate(arc, 1 - t))
			vec(N.derivatives(c, t).first, -N.derivatives(arc, 1 - t).first)
		end
	end)
	test("NURBS repeated knots use the right derivative except at the final endpoint", function()
		local c = N.curve(
			{ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 2, Vector3.new(2, 1, 0), Vector3.new(2, 2, 0) },
			2,
			{ knots = { 0, 0, 0, 0.5, 0.5, 1, 1, 1 } }
		)
		vec(N.evaluate(c, 0.5), Vector3.xAxis * 2)
		vec(N.derivatives(c, 0.5).first, Vector3.yAxis * 4)
		local a, b = N.split(c, 0.5)
		vec(N.derivatives(a, 1).first, Vector3.xAxis * 2)
		vec(N.derivatives(b, 0).first, Vector3.yAxis * 2)
	end)
	test("NURBS surface gives an exact rational cylinder and signed curvature", function()
		local s = cylinder()
		for i = 0, 10 do
			for j = 0, 4 do
				local d = N.surfaceDerivatives(s, i / 10, j / 4)
				local radial = Vector3.new(d.position.X, d.position.Y, 0)
				near(radial.Magnitude, 1)
				near(d.position.Z, j / 2)
				vec(d.normal, radial)
				near(d.meanCurvature, -0.5, 2e-5)
				near(d.gaussianCurvature, 0)
				vec(d.duv, Vector3.zero)
			end
		end
	end)
	test("NURBS mixed surface derivatives agree with independent differences", function()
		local g, w = {}, {}
		for i = 1, 3 do
			g[i], w[i] = {}, {}
			for j = 1, 3 do
				g[i][j] = Vector3.new(i - 1, j - 1, (i - 1) * (j - 1) * 0.3)
				w[i][j] = 1 + (i * j) % 3 * 0.2
			end
		end
		local s = N.surface(g, 2, 2, { weights = w })
		local u, v, h = 0.37, 0.63, 0.002
		local d = N.surfaceDerivatives(s, u, v)
		vec(d.du, (N.evaluateSurface(s, u + h, v) - N.evaluateSurface(s, u - h, v)) / (2 * h), 0.001)
		vec(d.dv, (N.evaluateSurface(s, u, v + h) - N.evaluateSurface(s, u, v - h)) / (2 * h), 0.001)
		vec(
			d.duv,
			(N.surfaceDerivatives(s, u, v + h).du - N.surfaceDerivatives(s, u, v - h).du) / (2 * h),
			0.001
		)
	end)
	test("NURBS surface insertion keeps unequal column weight scales", function()
		local s = cylinder()
		s.weights[1][2] = 2.4
		s.weights[3][1] = 0.3
		local r = N.insertSurfaceKnot(N.insertSurfaceKnot(s, "U", 0.42, 2), "V", 0.67)
		assert(#r.control == 5 and #r.control[1] == 3)
		for i = 0, 12 do
			for j = 0, 9 do
				vec(N.evaluateSurface(r, i / 12, j / 9), N.evaluateSurface(s, i / 12, j / 9))
			end
		end
	end)
	test("NURBS surface split and reversal retain parameter correspondence", function()
		local s = cylinder()
		for _, axis in { "U", "V" } do
			local a, b = N.splitSurface(s, axis, 0.4)
			local r = N.reverseSurface(s, axis)
			for i = 0, 5 do
				for j = 0, 5 do
					local u, v = i / 5, j / 5
					vec(
						N.evaluateSurface(a, u, v),
						N.evaluateSurface(s, axis == "U" and u * 0.4 or u, axis == "V" and v * 0.4 or v)
					)
					vec(
						N.evaluateSurface(b, u, v),
						N.evaluateSurface(
							s,
							axis == "U" and 0.4 + u * 0.6 or u,
							axis == "V" and 0.4 + v * 0.6 or v
						)
					)
					vec(
						N.evaluateSurface(r, u, v),
						N.evaluateSurface(s, axis == "U" and 1 - u or u, axis == "V" and 1 - v or v)
					)
				end
			end
		end
	end)
	test("NURBS isoparametric curves preserve rational surface weights", function()
		local s = cylinder()
		s.weights[2][2] = 0.2
		s.weights[1][1] = 1.7
		for _, axis in { "U", "V" } do
			local c = N.isoCurve(s, axis, 0.35)
			for i = 0, 15 do
				local t = i / 15
				vec(
					N.evaluate(c, t),
					N.evaluateSurface(s, axis == "U" and t or 0.35, axis == "V" and t or 0.35)
				)
			end
		end
	end)
	test("NURBS tessellation retains analytic normals UVs material and native positions", function()
		local mesh = N.tessellate(cylinder(), 12, 4, { material = 3 })
		assert(#mesh:triangles() == 96 and mesh:validate().valid)
		for _, f in mesh.faces do
			assert(f.material == 3)
			for i, id in f.vertices do
				local p = mesh.vertices[id]
				vec(f.corners[i].normal, Vector3.new(p.X, p.Y, 0))
				assert(f.corners[i].uv)
			end
		end
		local bundle = E.Roblox.toModel(mesh, { collisionFidelity = Enum.CollisionFidelity.Box })
		local ok, err = pcall(function()
			assert(#bundle.handles == 1)
			for id, sourceId in bundle.handles[1].sourceVertices do
				local h = bundle.handles[1]
				vec(
					h.part.CFrame:PointToWorldSpace(h.editable:GetPosition(h.vertexIds[id])),
					mesh.vertices[sourceId]
				)
			end
		end)
		E.Roblox.destroy(bundle)
		assert(ok, err)
	end)
	test("NURBS editing owns its controls and preserves world-offset accuracy", function()
		local p = table.clone(arc.points)
		local c = N.curve(p, 2, { weights = arc.weights })
		p[1] = Vector3.one * 9
		vec(N.evaluate(c, 0), Vector3.xAxis)
		local shift = Vector3.new(12, 160, -8)
		local points = {}
		for i, q in c.points do
			points[i] = q + shift
		end
		local translated = N.insertKnot(N.curve(points, 2, { weights = c.weights }), 0.45)
		for i = 0, 10 do
			vec(N.evaluate(translated, i / 10), N.evaluate(c, i / 10) + shift, 3e-5)
		end
	end)
	test("NURBS rejects invalid controls knots parameters budgets and singular sampling", function()
		assert(not pcall(N.curve, arc.points, 2, { weights = { 1, 0, 1 } }))
		assert(not pcall(N.curve, arc.points, 2, { knots = { 0, 0, 0.2, 0.4, 1, 1 } }))
		assert(not pcall(N.evaluate, arc, -0.01))
		assert(not pcall(N.split, arc, 1))
		assert(not pcall(N.tessellate, cylinder(), 100, 100, { maxVertices = 50 }))
		assert(not pcall(N.surface, { { Vector3.zero, Vector3.one }, { Vector3.zero } }, 1, 1))
		local s = N.surface({ { Vector3.zero, Vector3.zero }, { Vector3.one, Vector3.one } }, 1, 1)
		assert(not N.surfaceDerivatives(s, 0.5, 0.5).regular)
		assert(not pcall(N.tessellate, s, 2, 2))
		local callbacks = 0
		assert(not pcall(N.tessellate, cylinder(), 5, 5, {
			checkpoint = function()
				callbacks += 1
				error("cancel")
			end,
		}))
		assert(callbacks == 1)
	end)
	report.success = report.failed == 0
	return report
end
