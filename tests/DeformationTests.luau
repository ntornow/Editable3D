return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function vec(a, b, epsilon)
		assert((a - b).Magnitude < (epsilon or 2e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function grid(n)
		local m = E.Mesh.new()
		for y = 0, n do
			for x = 0, n do
				m:addVertex(Vector3.new(x, y, 0))
			end
		end
		for y = 0, n - 1 do
			for x = 0, n - 1 do
				local a = y * (n + 1) + x + 1
				m:addFace({ a, a + 1, a + n + 2, a + n + 1 })
			end
		end
		return m:recalculateNormals()
	end
	test("surface binding is an identity including out-of-face residuals", function()
		local target, source = grid(1), grid(1)
		source = E.Deform.map(source, function(p)
			return p * 3 + Vector3.new(-1, -1, 0.3)
		end)
		local binding, r = E.SurfaceDeform.bind(source, target)
		assert(r.boundVertices == 4 and r.unboundVertices == 0)
		local out = binding:evaluate(target)
		for id, p in source.vertices do
			vec(out.vertices[id], p)
		end
	end)
	test("surface frame transports rigid rotation and off-surface thickness", function()
		local target = grid(1)
		local source = E.Deform.map(grid(3), function(p)
			return p / 3 + Vector3.zAxis * 0.25
		end)
		local binding = E.SurfaceDeform.bind(source, target)
		local frame = CFrame.new(2, -3, 4) * CFrame.Angles(0.7, -1.2, 0.4)
		local out = binding:evaluate(E.Deform.transform(target, frame))
		for id, p in source.vertices do
			vec(out.vertices[id], frame:PointToWorldSpace(p))
		end
	end)
	test("surface affine mode follows in-plane shear and exterior offsets", function()
		local target, source = grid(1), grid(1)
		source = E.Deform.map(source, function(p)
			return p * 2 - Vector3.one * 0.5
		end)
		local binding = E.SurfaceDeform.bind(source, target)
		local function shear(p)
			return Vector3.new(2 * p.X + 0.7 * p.Y, 3 * p.Y, p.Z)
		end
		local out = binding:evaluate(E.Deform.map(target, shear), { mode = "AFFINE" })
		for id, p in source.vertices do
			vec(out.vertices[id], shear(p))
		end
	end)
	test("surface masks, distance exclusions and influence retain source", function()
		local target, source = grid(1), grid(1)
		source.vertices[4] += Vector3.zAxis * 3
		local binding, r =
			E.SurfaceDeform.bind(source, target, { mask = { [1] = 0.5, [2] = 1, [4] = 1 }, maxDistance = 1 })
		assert(r.boundVertices == 2 and r.unboundVertices == 1 and r.maskedVertices == 1)
		local out = binding:evaluate(E.Deform.transform(target, CFrame.new(0, 0, 2)), { influence = 0.5 })
		vec(out.vertices[1], source.vertices[1] + Vector3.zAxis * 0.5)
		vec(out.vertices[2], source.vertices[2] + Vector3.zAxis)
		vec(out.vertices[3], source.vertices[3])
		vec(out.vertices[4], source.vertices[4])
	end)
	test("surface binding rejects changed topology and collapsed controls", function()
		local target = grid(1)
		local binding = E.SurfaceDeform.bind(target, target)
		local changed = target:clone()
		changed:addVertex(Vector3.one)
		assert(not pcall(function()
			binding:evaluate(changed)
		end))
		changed = E.Deform.map(target, function(p)
			return Vector3.new(p.X, 0, 0)
		end)
		assert(not pcall(function()
			binding:evaluate(changed)
		end))
	end)
	test("surface binding retains UV seams materials weights and groups", function()
		local target = grid(1)
		target.faces[1].corners[1].uv = Vector2.new(0.2, 0.7)
		target.faces[1].material = 4
		target.weights[1] = { root = 0.7 }
		target.groups.test = { [1] = 0.6 }
		local out = E.SurfaceDeform.bind(target, target):evaluate(target)
		assert(out.faces[1].corners[1].uv == target.faces[1].corners[1].uv and out.faces[1].material == 4)
		assert(out.weights[1].root == 0.7 and out.groups.test[1] == 0.6)
		out.groups.test[1] = 0
		assert(target.groups.test[1] == 0.6)
	end)
	test("harmonic boundary anchors reproduce an analytic linear displacement", function()
		local m = grid(6)
		local anchors = {}
		for id, p in m.vertices do
			if p.X == 0 or p.X == 6 or p.Y == 0 or p.Y == 6 then
				anchors[id] = p + Vector3.new(0, 0, 2 * p.X - 0.5 * p.Y)
			end
		end
		for _, weights in { "UNIFORM", "COTANGENT" } do
			local out, r = E.Laplacian.bind(m, { weights = weights }):solve(anchors, { order = 1 })
			assert(r.converged)
			for id, p in m.vertices do
				vec(out.vertices[id], p + Vector3.new(0, 0, 2 * p.X - 0.5 * p.Y))
			end
		end
	end)
	test("biharmonic translation preserves geometric detail with one anchor", function()
		local m = grid(4)
		m = E.Deform.map(m, function(p)
			return p + Vector3.zAxis * math.sin(p.X * 1.5) * 0.2
		end)
		local delta = Vector3.new(0.7, -0.4, 1.2)
		local out, r = E.Laplacian.bind(m):solve({ [1] = m.vertices[1] + delta })
		assert(r.converged)
		for id, p in m.vertices do
			vec(out.vertices[id], p + delta, 5e-5)
		end
	end)
	test("Laplacian solve handles sparse IDs and exact independent anchors", function()
		local m = grid(3)
		m.vertices[90] = m.vertices[1]
		m.vertices[1] = nil
		for _, f in m.faces do
			for i, id in f.vertices do
				if id == 1 then
					f.vertices[i] = 90
				end
			end
		end
		local anchors = { [90] = Vector3.new(-1, -2, -3), [16] = Vector3.new(4, 5, 6) }
		local bound = E.Laplacian.bind(m)
		local out, r = bound:solve(anchors)
		assert(r.converged and r.anchors == 2 and r.freeVertices == 14)
		assert(out.vertices[90] == anchors[90] and out.vertices[16] == anchors[16])
		vec(m.vertices[90], Vector3.zero)
		local second = bound:solve({ [90] = Vector3.zero, [16] = Vector3.new(3, 3, 0) })
		for id, p in m.vertices do
			vec(second.vertices[id], p)
		end
	end)
	test("unconstrained components and isolated vertices remain fixed", function()
		local m = E.Topology.join({ grid(2), E.Deform.transform(grid(2), CFrame.new(5, 0, 0)) })
		local isolated = m:addVertex(Vector3.new(9, 9, 9))
		local out, r = E.Laplacian.bind(m):solve({ [1] = Vector3.zAxis })
		assert(r.inactiveVertices == 10)
		for id = 10, 18 do
			vec(out.vertices[id], m.vertices[id])
		end
		vec(out.vertices[isolated], m.vertices[isolated])
		for id = 1, 9 do
			vec(out.vertices[id], m.vertices[id] + Vector3.zAxis)
		end
	end)
	test("nonconvergence is explicit and approximate return is opt-in", function()
		local m = grid(6)
		local binding = E.Laplacian.bind(m)
		local anchors = { [1] = Vector3.zAxis, [49] = m.vertices[49] }
		assert(not pcall(function()
			binding:solve(anchors, { maxIterations = 1 })
		end))
		local _, r = binding:solve(anchors, { maxIterations = 1, requireConvergence = false })
		assert(not r.converged and r.axes[3].residual > 0)
	end)
	test("Laplacian cancellation and input errors leave source unchanged", function()
		local m = grid(10)
		local binding = E.Laplacian.bind(m)
		local anchors = { [1] = Vector3.zAxis, [121] = m.vertices[121] }
		local calls = 0
		assert(not pcall(function()
			binding:solve(anchors, {
				checkpoint = function()
					calls += 1
					error("cancelled")
				end,
			})
		end))
		assert(calls == 1)
		vec(m.vertices[1], Vector3.zero)
		assert(not pcall(function()
			binding:solve({ [900] = Vector3.zero })
		end))
		assert(not pcall(function()
			binding:solve(anchors, { order = 3 })
		end))
	end)
	test("polyline stroke has connected miter joins and exact width", function()
		local m = E.Curves.stroke2D({ Vector2.new(0, 0), Vector2.new(2, 0), Vector2.new(2, 2) }, 0.4)
		assert(#E.Topology.components(m) == 1 and m:validate().valid)
		vec(m.vertices[3], Vector3.new(1.8, 0.2, 0))
		vec(m.vertices[4], Vector3.new(2.2, -0.2, 0))
		assert(m:faceNormal(1).Z > 0.99)
		local solid = E.Modifiers.solidify(m, 0.3)
		assert(solid:validate().closed and solid:validate().valid)
		assert(math.abs(solid:volume() - 4 * 0.4 * 0.3) < 1e-5)
	end)
	test("closed stroke UV seam, square caps and excessive miters", function()
		local m = E.Curves.stroke2D(
			{ Vector2.new(0, 0), Vector2.new(2, 0), Vector2.new(2, 2), Vector2.new(0, 2) },
			0.2,
			{ closed = true }
		)
		assert(m:validate().valid and #E.Topology.components(m) == 1)
		assert(m.faces[4].corners[2].uv.X == 1 and m.faces[1].corners[1].uv.X == 0)
		assert(E.Modifiers.solidify(m, 0.1):validate().closed)
		m = E.Curves.stroke2D({ Vector2.zero, Vector2.xAxis }, 0.2, { cap = "SQUARE" })
		local lo, hi = m:bounds()
		vec(lo, Vector3.new(-0.1, -0.1, 0))
		vec(hi, Vector3.new(1.1, 0.1, 0))
		assert(not pcall(function()
			E.Curves.stroke2D({ Vector2.zero, Vector2.xAxis, Vector2.new(0, 0.01) }, 1)
		end))
	end)
	test("solidify retains duplicated weights groups and rim material", function()
		local m = grid(1)
		m.faces[1].material = 3
		m.weights[1] = { root = 1 }
		m.groups.edge = { [1] = 0.6 }
		local out = E.Modifiers.solidify(m, 0.2)
		assert(out.weights[1].root == 1 and out.weights[2].root == 1)
		assert(out.groups.edge[1] == 0.6 and out.groups.edge[2] == 0.6)
		for _, f in out.faces do
			assert(f.material == 3)
		end
		out.weights[1].root = 0
		assert(m.weights[1].root == 1 and out.weights[2].root == 1)
	end)
	test("tiny translated triangles retain area orientation and triangulation", function()
		local m = E.Mesh.new()
		local a = m:addVertex(Vector3.new(10, 140, 9))
		local b = m:addVertex(Vector3.new(10.0002, 140.0001, 9))
		local c = m:addVertex(Vector3.new(10, 140.0002, 9.0001))
		local fid = m:addFace({ a, b, c })
		local expected = (m.vertices[b] - m.vertices[a]):Cross(m.vertices[c] - m.vertices[a])
		local normal, area = m:faceNormal(fid)
		vec(normal, expected.Unit)
		assert(math.abs(area - expected.Magnitude / 2) < 1e-12)
		assert(m:validate().valid and #m:triangles() == 1)
	end)
	report.success = report.failed == 0
	return report
end
