return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, why = pcall(fn)
		if ok then
			report.passed += 1
		else
			report.failed += 1
		end
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(why) or nil })
	end
	local function near(a, b, eps)
		assert(math.abs(a - b) <= (eps or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function vec(a, b, eps)
		assert((a - b).Magnitude <= (eps or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	test("quaternion composition agrees with independent CFrame transforms", function()
		local Q = E.Quaternion
		local a = CFrame.Angles(0.7, -0.4, 0.9)
		local b = CFrame.Angles(-1.2, 0.8, 0.1)
		local q = Q.multiply(Q.fromCFrame(a), Q.fromCFrame(b))
		for _, v in { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, Vector3.new(2, 3, 4) } do
			vec(Q.rotate(q, v), (a * b):VectorToWorldSpace(v))
		end
		near(math.abs(Q.dot(Q.multiply(q, Q.inverse(q)), Q.identity)), 1)
	end)
	test("quaternion half turns, shortest spherical path and angular integration", function()
		local Q = E.Quaternion
		for _, axis in { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis, Vector3.new(1, 2, 3).Unit } do
			local q = Q.fromCFrame(CFrame.fromAxisAngle(axis, math.pi))
			near(math.abs(Q.dot(q, Q.fromAxisAngle(axis, math.pi))), 1)
			local mid = Q.slerp(Q.identity, q, 0.5)
			local _, angle = Q.toAxisAngle(mid)
			near(angle, math.pi / 2)
		end
		local antipode = Q.slerp(Q.identity, { 0, 0, 0, -1 }, 0.5)
		near(antipode[4], 1)
		local q = Q.integrate(Q.identity, Vector3.yAxis * math.pi, 1 / 2)
		vec(Q.rotate(q, Vector3.xAxis), -Vector3.zAxis)
	end)
	test("curve BVH nearest segment, signed lateral distance and arc length", function()
		local path = E.Stroke.path({ Vector3.zero, Vector3.new(2, 0, 0), Vector3.new(2, 0, 2) })
		local hit = path:closest(Vector3.new(1, 0, 0.4), Vector3.yAxis)
		near(hit.distance, 0.4)
		near(hit.signedDistance, -0.4)
		near(hit.arc, 1)
		near(hit.fraction, 0.25)
		vec(path:sample(3), Vector3.new(2, 0, 1))
		assert(path:closest(Vector3.new(-5, 0, 0), nil, 1) == nil)
		local pts = {}
		for i = 0, 100 do
			pts[i + 1] = Vector3.new(i * 0.1, 0, 0)
		end
		local long = E.Stroke.path(pts)
		near(long:closest(Vector3.new(4.567, 2, 0)).distance, 2)
		near(long:closest(Vector3.new(4.567, 2, 0)).arc, 4.567)
	end)
	test("stroke compact support, endpoint continuity and ridge/trough profile", function()
		local S = E.Stroke
		local path = S.path({ Vector3.new(-2, 0, 0), Vector3.new(2, 0, 0) })
		near(S.field(path, Vector3.zero, Vector3.yAxis, { radius = 1 }), 1)
		near(S.field(path, Vector3.new(0, 0, 1), Vector3.yAxis, { radius = 1 }), 0)
		near(S.field(path, Vector3.new(-2, 0, 0), Vector3.yAxis, { radius = 1 }), 0)
		assert(S.profile(0.57, 1, "fold") < 0 and S.profile(0, 1, "fold") > 0.99)
		assert(S.profile(0, 1, "crease") == -1)
	end)
	test("stroke displacement mask and source immutability", function()
		local grid = E.Primitives.grid(8, 8, Vector2.new(4, 4))
		local path = E.Stroke.path({ Vector3.new(-2, 0, 0), Vector3.new(2, 0, 0) })
		local mask = {}
		for id, p in grid.vertices do
			if p.X >= 0 then
				mask[id] = 0.5
			end
		end
		local out, r =
			E.Stroke.sculpt(grid, path, { radius = 1, height = 0.4, mask = mask, direction = Vector3.yAxis })
		assert(r.affectedVertices > 0)
		near(r.maxDisplacement, 0.2)
		for id, p in grid.vertices do
			near(p.Y, 0)
			if p.X < 0 or math.abs(p.Z) >= 1 then
				vec(out.vertices[id], p)
			end
		end
		assert(out:validate().valid)
	end)
	test("morphs preserve seams and support additive unnormalized weights", function()
		local m = E.Mesh.new()
		m:addVertex(Vector3.zero)
		m:addVertex(Vector3.xAxis)
		m:addVertex(Vector3.yAxis)
		m:addFace(
			{ 1, 2, 3 },
			{
				{ normal = Vector3.zAxis, uv = Vector2.zero, color = Color3.new(0.3, 0.4, 0.5), alpha = 0.8 },
				{ normal = Vector3.zAxis },
				{ normal = Vector3.zAxis },
			}
		)
		local target = m:clone()
		target.vertices[1] = Vector3.zAxis * 2
		target.faces[1].corners[1].uv = Vector2.one
		target.faces[1].corners[1].normal = Vector3.xAxis
		target.faces[1].corners[1].color = Color3.new(0.5, 0.2, 0.6)
		local delta = E.Morph.fromMeshes(m, target, "Raise")
		local out = E.Morph.evaluate(m, { delta }, { 0.5 })
		vec(out.vertices[1], Vector3.zAxis)
		vec(out.faces[1].corners[1].normal, Vector3.new(1, 0, 1).Unit)
		near(out.faces[1].corners[1].uv.X, 0.5)
		near(out.faces[1].corners[1].color.G, 0.3)
		vec(E.Morph.evaluate(m, { delta }, { -1 }).vertices[1], -Vector3.zAxis * 2)
		vec(m.vertices[1], Vector3.zero)
	end)
	test("morph transfer uses independent triangle barycentric weights", function()
		local m = E.Mesh.new()
		m:addVertex(Vector3.zero)
		m:addVertex(Vector3.new(2, 0, 0))
		m:addVertex(Vector3.new(0, 2, 0))
		m:addFace({ 1, 2, 3 })
		local target = E.Mesh.new()
		target:addVertex(Vector3.new(0.5, 0.5, 0.1))
		local delta = { positions = { [1] = Vector3.zero, [2] = Vector3.zAxis * 2, [3] = Vector3.zAxis * 4 } }
		local out, r = E.Morph.transfer(m, target, delta, { maxDistance = 0.2 })
		vec(out.positions[1], Vector3.zAxis * 1.5)
		near(r.maxSourceDistance, 0.1)
		assert(not pcall(function()
			E.Morph.transfer(m, target, delta, { maxDistance = 0.05 })
		end))
	end)
	test("timeline cubic derivatives are scaled by key interval", function()
		local T = E.Timeline
		local c = T.channel(
			"value",
			{ 1, 3 },
			{ { 0 }, { 2 } },
			{ interpolation = "CUBICSPLINE", inTangents = { { 0 }, { 0 } }, outTangents = { { 2 }, { 0 } } }
		)
		near(T.sampleChannel(c, 2)[1], 1.5)
		local h = 1e-5
		near((T.sampleChannel(c, 1 + h)[1] - T.sampleChannel(c, 1)[1]) / h, 2, 1e-4)
		near(T.sampleChannel(c, -100)[1], 0)
		near(T.sampleChannel(c, 100)[1], 2)
	end)
	test("timeline boundaries, looping, quaternion interpolation and layers", function()
		local T, Q = E.Timeline, E.Quaternion
		local step = T.channel(
			"weights",
			{ 0, 1, 2 },
			{ { 0, 1 }, { 0.5, 0.5 }, { 1, 0 } },
			{ interpolation = "STEP", node = 2 }
		)
		near(T.sampleChannel(step, 0.999)[1], 0)
		near(T.sampleChannel(step, 1)[1], 0.5)
		local clip = T.clip({ step }, "Steps")
		near(T.sample(clip, 3, { loop = true })[2].weights[1], 0.5)
		near(T.sample(clip, 2.5, { loop = true, pingPong = true })[2].weights[1], 0.5)
		local rotation = T.channel(
			"rotation",
			{ 0, 2 },
			{ Q.identity, Q.fromAxisAngle(Vector3.yAxis, math.pi) }
		)
		vec(Q.rotate(T.sampleChannel(rotation, 1), Vector3.xAxis), -Vector3.zAxis)
		local out = T.layer(
			{ [1] = { translation = { 1, 2, 3 }, scale = { 2, 2, 2 }, rotation = Q.identity } },
			{ [1] = { translation = { 4, 0, 0 }, scale = { 2, 1, 1 }, rotation = Q.fromAxisAngle(
				Vector3.yAxis,
				math.pi
			) } },
			0.5,
			true
		)
		near(out[1].translation[1], 3)
		near(out[1].scale[1], 3)
		vec(Q.rotate(out[1].rotation, Vector3.xAxis), -Vector3.zAxis)
	end)
	test("invalid motion data rejects", function()
		assert(not pcall(function()
			E.Timeline.channel("value", { 0, 0 }, { { 0 }, { 1 } })
		end))
		assert(not pcall(function()
			E.Timeline.channel("rotation", { 0 }, { { 0, 0, 0, 2 } })
		end))
		assert(not pcall(function()
			E.Timeline.channel(
				"value",
				{ 0 },
				{ { 0 } },
				{ interpolation = "CUBICSPLINE", inTangents = { { 0 } }, outTangents = { { 0 } } }
			)
		end))
		local c = E.Timeline.channel("value", { 0 }, { { 1 } })
		assert(not pcall(function()
			E.Timeline.clip({ c, c })
		end))
	end)
	report.success = report.failed == 0
	return report
end
