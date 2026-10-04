return function(E)
	local S, N = E.Surfaces, E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, e)
		assert((a - b).Magnitude < (e or 0.0001), tostring(a) .. " != " .. tostring(b))
	end
	test("Rational arcs have exact radii endpoints tangents and curvature in tilted frames", function()
		local frame = CFrame.new(3, -2, 5) * CFrame.Angles(0.4, -0.3, 0.2)
		for _, span in { 0.2, math.pi / 2, math.pi, 2 * math.pi, -1.7, -2 * math.pi } do
			local c = S.arc(frame, 2, 0.3, 0.3 + span)
			for i = 0, 40 do
				local d = N.derivatives(c, i / 40)
				local localP = frame:PointToObjectSpace(d.position)
				assert(math.abs(localP.Magnitude - 2) < 0.00001 and math.abs(localP.Z) < 0.00001)
				assert(math.abs(d.curvature - 0.5) < 0.0001)
			end
			near(
				N.evaluate(c, 0),
				frame:PointToWorldSpace(Vector3.new(2 * math.cos(0.3), 2 * math.sin(0.3), 0))
			)
			near(
				N.evaluate(c, 1),
				frame:PointToWorldSpace(Vector3.new(2 * math.cos(0.3 + span), 2 * math.sin(0.3 + span), 0))
			)
		end
	end)
	test("Compatible rational sections preserve shape across degrees knots and weight units", function()
		local a = S.arc(CFrame.identity, 1, 0, 1.7)
		local b = N.insertKnot(N.elevateDegree(a, 2), 0.37)
		for i, w in b.weights do
			b.weights[i] = w * 1e150
		end
		local c = N.curve({ Vector3.zero, Vector3.one, Vector3.new(2, 0, 0) }, 2)
		local compatible = S.compatible({ a, b, c })
		for k, source in { a, b, c } do
			assert(compatible[k].degree == 4 and #compatible[k].points == #compatible[1].points)
			for i = 0, 30 do
				near(N.evaluate(source, i / 30), N.evaluate(compatible[k], i / 30))
			end
		end
		assert(a.degree == 2 and b.weights[1] > 1e140)
	end)
	test("Extrusion preserves a rational profile and linear displacement", function()
		local c = S.arc(CFrame.identity, 2, 0, math.pi * 1.4)
		local delta = Vector3.new(1, 2, 3)
		local s = S.extrude(c, delta)
		for i = 0, 15 do
			for j = 0, 10 do
				near(N.evaluateSurface(s, i / 15, j / 10), N.evaluate(c, i / 15) + delta * j / 10)
			end
		end
	end)
	test("Ruled surfaces interpolate sections and stay on each ruling", function()
		local a = S.arc(CFrame.identity, 2, 0, math.pi / 2)
		local b = N.curve(
			{ Vector3.new(0, 0, 3), Vector3.new(3, 0, 4), Vector3.new(2, 2, 3) },
			2,
			{ weights = { 1, 0.4, 1.3 } }
		)
		local s = S.ruled(a, b)
		for i = 0, 20 do
			local u = i / 20
			local p, q = N.evaluate(a, u), N.evaluate(b, u)
			near(N.evaluateSurface(s, u, 0), p)
			near(N.evaluateSurface(s, u, 1), q)
			for j = 0, 8 do
				local r = N.evaluateSurface(s, u, j / 8) - p
				assert(
					r:Cross(q - p).Magnitude < 0.0001
						and r:Dot(q - p) > -0.0001
						and r.Magnitude <= (q - p).Magnitude + 0.0001
				)
			end
		end
	end)
	test("Homogeneous loft interpolates every rational section at its supplied parameter", function()
		local curves, params = {}, { 0, 0.2, 0.65, 1 }
		for i, t in params do
			local c = S.arc(CFrame.new(0, 0, 3 * t), 1 + t * t, 0, math.pi / 2)
			if i == 2 then
				c = N.insertKnot(c, 0.3)
			end
			if i == 3 then
				c = N.elevateDegree(c, 1)
			end
			curves[i] = c
		end
		local surface, r = S.loft(curves, 3, { parameters = params })
		assert(r.rank == 4)
		for i, t in params do
			for j = 0, 20 do
				near(N.evaluateSurface(surface, j / 20, t), N.evaluate(curves[i], j / 20))
			end
		end
		-- Between observations, this family has a quadratic radius and linear elevation.
		for i = 0, 20 do
			local t = i / 20
			local p = N.evaluateSurface(surface, 0.37, t)
			assert(math.abs(math.sqrt(p.X * p.X + p.Y * p.Y) - (1 + t * t)) < 0.0001)
			assert(math.abs(p.Z - 3 * t) < 0.0001)
		end
	end)
	test("Rational revolutions preserve axial height and radial distance about an oblique axis", function()
		local axis = Vector3.new(1, 2, 3).Unit
		local origin = Vector3.new(5, -3, 2)
		local c = N.curve(
			{ Vector3.new(2, 0, 0), Vector3.new(3, 1, 0), Vector3.new(2, 2, 1) },
			2,
			{ weights = { 1, 0.6, 1 } }
		)
		local s = S.revolve(c, origin, axis, math.pi * 1.6, { startAngle = 0.2 })
		for i = 0, 15 do
			local p = N.evaluate(c, i / 15) - origin
			local height = p:Dot(axis)
			local radius = (p - axis * height).Magnitude
			for j = 0, 15 do
				local q = N.evaluateSurface(s, i / 15, j / 15) - origin
				assert(math.abs(q:Dot(axis) - height) < 0.00002)
				assert(math.abs((q - axis * q:Dot(axis)).Magnitude - radius) < 0.00002)
			end
		end
	end)
	test("Coons construction preserves all four curved polynomial boundaries", function()
		local bottom = N.curve({ Vector3.zero, Vector3.new(1, -1, 0), Vector3.new(3, 0, 0) }, 2)
		local top = N.curve(
			{ Vector3.new(0, 2, 0), Vector3.new(1, 3, 1), Vector3.new(2, 2.5, 1), Vector3.new(3, 2, 0) },
			3
		)
		local left = N.curve({ Vector3.zero, Vector3.new(-1, 1, 0), Vector3.new(0, 2, 0) }, 2)
		local right = N.curve({ Vector3.new(3, 0, 0), Vector3.new(4, 1, 0), Vector3.new(3, 2, 0) }, 2)
		local s = S.coons(bottom, top, left, right)
		for i = 0, 30 do
			local t = i / 30
			near(N.evaluateSurface(s, t, 0), N.evaluate(bottom, t))
			near(N.evaluateSurface(s, t, 1), N.evaluate(top, t))
			near(N.evaluateSurface(s, 0, t), N.evaluate(left, t))
			near(N.evaluateSurface(s, 1, t), N.evaluate(right, t))
		end
		for i = 0, 10 do
			for j = 0, 10 do
				local u, v = i / 10, j / 10
				local expected = N.evaluate(bottom, u):Lerp(N.evaluate(top, u), v)
					+ N.evaluate(left, v):Lerp(N.evaluate(right, v), u)
					- Vector3.new(3 * u, 2 * v, 0)
				near(N.evaluateSurface(s, u, v), expected)
			end
		end
	end)
	test("Rational sphere cylinder cone and torus satisfy independent implicit equations", function()
		local sphere = S.sphere(CFrame.identity, 2)
		local cylinder = S.cylinder(CFrame.identity, 2, 3)
		local cone = S.cone(CFrame.identity, 2, 3)
		local torus = S.torus(CFrame.identity, 3, 1)
		for i = 0, 16 do
			for j = 0, 20 do
				local u, v = i / 16, j / 20
				local p = N.evaluateSurface(sphere, u, v)
				assert(math.abs(p.Magnitude - 2) < 0.00001)
				p = N.evaluateSurface(cylinder, u, v)
				assert(math.abs(p.X * p.X + p.Y * p.Y - 4) < 0.00002 and math.abs(p.Z - 3 * v) < 0.00001)
				p = N.evaluateSurface(cone, u, v)
				assert(math.abs(math.sqrt(p.X * p.X + p.Y * p.Y) - 2 * (1 - p.Z / 3)) < 0.00001)
				p = N.evaluateSurface(torus, u, v)
				assert(math.abs((math.sqrt(p.X * p.X + p.Y * p.Y) - 3) ^ 2 + p.Z * p.Z - 1) < 0.00001)
			end
		end
	end)
	test("Constructed primitive normals point outward at regular samples", function()
		local sphere = N.surfaceDerivatives(S.sphere(CFrame.identity, 2), 0.37, 0.42)
		assert(sphere.normal:Dot(sphere.position) > 1.9)
		local cone = N.surfaceDerivatives(S.cone(CFrame.identity, 2, 3), 0.37, 0.42)
		assert(cone.normal:Dot(Vector3.new(cone.position.X, cone.position.Y, 0)) > 0)
		local torus = N.surfaceDerivatives(S.torus(CFrame.identity, 3, 1), 0.1, 0.42)
		local radial = Vector3.new(torus.position.X, torus.position.Y, 0).Unit * 3
		assert(torus.normal:Dot(torus.position - radial) > 0.99)
	end)
	test("Construction budgets invalid corners and cancellation reject before scene mutation", function()
		local a = S.arc(CFrame.identity, 1, 0, math.pi)
		assert(not pcall(function()
			S.compatible({ a, a }, { maxControls = 4 })
		end))
		assert(not pcall(function()
			S.loft({ a, a }, 1, { maxWork = 1 })
		end))
		assert(not pcall(function()
			S.loft({ a, a }, 1, {
				checkpoint = function()
					error("cancel")
				end,
			})
		end))
		assert(not pcall(function()
			S.revolve(a, Vector3.zero, Vector3.zero, 1)
		end))
		assert(not pcall(function()
			S.arc(CFrame.identity, 1, 0, 10)
		end))
		assert(not pcall(function()
			S.coons(a, a, a, a)
		end))
	end)
	test("Constructed plane preserves frame dimensions UVs and native mesh positions", function()
		local frame = CFrame.new(2, 3, 4) * CFrame.Angles(0.2, 0.3, 0.4)
		local s = S.plane(frame, Vector2.new(4, 2))
		local mesh = N.tessellate(s, 3, 2)
		near(N.evaluateSurface(s, 0.2, 0.3), frame:PointToWorldSpace(Vector3.new(-1.2, -0.4, 0)))
		local editable = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			for id, p in mesh.vertices do
				near(editable.editable:GetPosition(editable.vertexIds[id]) + editable.origin, p)
			end
			local restored = E.Roblox.fromEditable(editable.editable)
			assert(#restored:triangles() == #mesh:triangles())
		end)
		editable.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
