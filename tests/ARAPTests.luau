return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function vec(a, b, eps)
		assert((a - b).Magnitude < (eps or 2e-5), tostring(a) .. " != " .. tostring(b))
	end
	local points =
		{ Vector3.new(-1, -1, -1), Vector3.new(2, 0, -1), Vector3.new(0, 3, 1), Vector3.new(-1, 1, 3) }
	test("proper rotation fit recovers independent CFrames including half turns", function()
		for _, cf in
			{
				CFrame.Angles(0.4, 0.9, -0.7),
				CFrame.Angles(math.pi, 0, 0),
				CFrame.Angles(0, math.pi, 0),
				CFrame.Angles(0, 0, math.pi),
			}
		do
			local target = {}
			for i, p in points do
				target[i] = cf:VectorToWorldSpace(p)
			end
			local fitted, r = E.Registration.rotation(points, target)
			assert(not r.ambiguous)
			for i, p in points do
				vec(fitted:VectorToWorldSpace(p), target[i])
			end
			assert(fitted.RightVector:Cross(fitted.UpVector):Dot(-fitted.LookVector) > 0.99999)
		end
	end)
	test("weighted rigid and positive similarity fits recover placement", function()
		local frame = CFrame.new(5, -2, 8) * CFrame.Angles(0.7, -0.2, 1.2)
		local target = {}
		for i, p in points do
			target[i] = frame:PointToWorldSpace(p * 2.7)
		end
		local a, b = table.clone(points), table.clone(target)
		table.insert(a, Vector3.one * 90)
		table.insert(b, Vector3.one * -20)
		local fit = E.Registration.fit(a, b, { scale = true, weights = { 1, 3, 2, 1, 0 } })
		assert(math.abs(fit.scale - 2.7) < 1e-5 and fit.rms < 1e-5)
		for i, p in points do
			vec(fit.frame:PointToWorldSpace(p * fit.scale), target[i])
		end
		local rigid = E.Registration.fit(points, target)
		assert(rigid.scale == 1 and rigid.rms > 1)
	end)
	test("rigid fitting preserves reciprocal direction and refuses reflection", function()
		local cf = CFrame.new(1, 2, 3) * CFrame.Angles(0.3, 0.6, 0.9)
		local target = {}
		for i, p in points do
			target[i] = cf:PointToWorldSpace(p)
		end
		local reverse = E.Registration.fit(target, points)
		for i, p in target do
			vec(reverse.frame:PointToWorldSpace(p), points[i])
		end
		for i, p in points do
			target[i] = p * Vector3.new(-1, 1, 1)
		end
		local fit = E.Registration.fit(points, target)
		assert(
			fit.rms > 0.1
				and fit.frame.RightVector:Cross(fit.frame.UpVector):Dot(-fit.frame.LookVector) > 0.99999
		)
	end)
	test("ambiguous rotations use the closest reference within the optimal space", function()
		local reference = CFrame.Angles(0, 0, 0.7)
		local rotation, r = E.Registration.rotation(
			{ Vector3.zero },
			{ Vector3.zero },
			{ reference = reference }
		)
		assert(r.ambiguous)
		vec(rotation.RightVector, reference.RightVector)
		rotation, r = E.Registration.rotation({ Vector3.xAxis }, { Vector3.yAxis })
		assert(r.ambiguous)
		vec(rotation.RightVector, Vector3.yAxis)
		vec(rotation:VectorToWorldSpace(Vector3.zAxis), Vector3.zAxis)
	end)
	test("registration rejects invalid weights and undefined similarity scale", function()
		assert(not pcall(function()
			E.Registration.rotation(points, points, { weights = { 1, -1, 1, 1 } })
		end))
		assert(not pcall(function()
			E.Registration.rotation(points, points, { weights = { 0, 0, 0, 0 } })
		end))
		assert(not pcall(function()
			E.Registration.fit({ Vector3.one }, { Vector3.zero }, { scale = true })
		end))
		assert(not pcall(function()
			E.Registration.rotation(points, points, { weights = { 1e308, 1e308, 1e308, 1e308 } })
		end))
	end)
	test("registration is invariant to confidence units and ignores zero-weight outliers", function()
		local frame = CFrame.new(3, -4, 2) * CFrame.Angles(0.4, 0.7, -0.6)
		local a, b = table.clone(points), {}
		for i, p in points do
			b[i] = frame:PointToWorldSpace(p * 1.7)
		end
		table.insert(a, Vector3.one * 1e30)
		table.insert(b, -Vector3.one * 1e30)
		for _, factor in { 1e-35, 1, 1e150 } do
			local fit = E.Registration.fit(
				a,
				b,
				{ weights = { factor, factor * 3, factor * 2, factor, 0 }, scale = true }
			)
			assert(fit.rms < 1e-5 and math.abs(fit.scale - 1.7) < 1e-5)
			for i, p in points do
				vec(fit.frame:PointToWorldSpace(p * fit.scale), b[i])
			end
		end
		local tiny, target = {}, {}
		for i, p in points do
			tiny[i] = p * 1e-20
			target[i] = frame:VectorToWorldSpace(tiny[i])
		end
		local rotation = E.Registration.rotation(tiny, target)
		vec(rotation.RightVector, frame.RightVector)
	end)
	test("ARAP rigid initial pose is a zero-energy fixed point with exact anchors", function()
		local m = E.Primitives.grid(6, 4, Vector2.new(4, 3))
		local cf = CFrame.new(2, 3, 4) * CFrame.Angles(0.7, 1.3, 0.9)
		local initial = E.Deform.transform(m, cf)
		local anchors = { [1] = initial.vertices[1], [7] = initial.vertices[7], [35] = initial.vertices[35] }
		local out, r = E.ARAP.bind(m):solve(anchors, { initial = initial, maxIterations = 4 })
		assert(r.converged and r.energy < 1e-9)
		for id, p in initial.vertices do
			vec(out.vertices[id], p)
		end
	end)
	test("ARAP reduces bending energy monotonically and retains exact boundary targets", function()
		local m = E.Geometry.parametric(function(u, v)
			return Vector3.new(u * 6, v * 2, 0.12 * math.sin(v * 8))
		end, 12, 4)
		local anchors = {}
		for id, p in m.vertices do
			if p.X < 0.01 then
				anchors[id] = p
			elseif p.X > 5.99 then
				anchors[id] = Vector3.new(4, 3, 0)
					+ CFrame.Angles(0, 0, 0.9):VectorToWorldSpace(p - Vector3.new(6, 0, 0))
			end
		end
		local initial = E.Laplacian.bind(m):solve(anchors, { order = 1 })
		local out, r = E.ARAP.bind(m):solve(anchors, { initial = initial, maxIterations = 45 })
		assert(r.linearConverged and r.energy < r.energyHistory[1] * 0.8)
		for i = 2, #r.energyHistory do
			assert(r.energyHistory[i] <= r.energyHistory[i - 1] + 1e-5)
		end
		for id, p in anchors do
			assert(out.vertices[id] == p)
		end
		assert(out:validate().valid)
	end)
	test("ARAP unanchored components stay fixed and source attributes survive", function()
		local box = E.Primitives.box(Vector3.one)
		box.groups.detail = { [1] = 0.6 }
		box.weights[1] = { root = 1 }
		local m = E.Topology.join({ box, E.Deform.transform(box, CFrame.new(4, 0, 0)) })
		local anchors = {}
		for id = 1, 8 do
			anchors[id] = m.vertices[id] + Vector3.yAxis
		end
		local out, r = E.ARAP.bind(m):solve(anchors)
		assert(r.inactiveVertices == 8)
		for id = 9, 16 do
			assert(out.vertices[id] == m.vertices[id])
		end
		assert(out.groups.detail[1] == 0.6 and out.weights[1].root == 1)
		assert(out.faces[1].corners[1].uv == m.faces[1].corners[1].uv)
	end)
	test("ARAP sparse IDs, cancellation, budgets and nonconvergence are explicit", function()
		local m = E.Primitives.grid(8, 4, Vector2.new(4, 2))
		m.vertices[1000] = m.vertices[1]
		m.vertices[1] = nil
		for _, f in m.faces do
			for i, id in f.vertices do
				if id == 1 then
					f.vertices[i] = 1000
				end
			end
		end
		local anchors = { [1000] = m.vertices[1000] + Vector3.new(0, 2, 0), [45] = m.vertices[45] }
		local b = E.ARAP.bind(m)
		local _, r = b:solve(anchors, { maxIterations = 1 })
		assert(not r.converged)
		assert(not pcall(function()
			b:solve(anchors, { maxIterations = 1, requireConvergence = true })
		end))
		local calls = 0
		assert(not pcall(function()
			b:solve(anchors, {
				checkpoint = function()
					calls += 1
					error("cancelled")
				end,
			})
		end))
		assert(calls == 1)
		assert(not pcall(function()
			E.ARAP.bind(m, { maxVertices = 4 })
		end))
		assert(not pcall(function()
			b:solve({ [9999] = Vector3.zero })
		end))
		assert(m.vertices[1000].Y == 0)
	end)
	test("ARAP results are stable under a large world translation", function()
		local m = E.Primitives.grid(5, 3, Vector2.new(3, 2))
		local offset = Vector3.new(15, 140, -12)
		local a = { [1] = m.vertices[1] + Vector3.yAxis * 0.5, [24] = m.vertices[24] }
		local out = E.ARAP.bind(m):solve(a, { maxIterations = 20 })
		local translated = E.Deform.transform(m, CFrame.new(offset))
		local b = {}
		for id, p in a do
			b[id] = p + offset
		end
		local moved = E.ARAP.bind(translated):solve(b, { maxIterations = 20 })
		for id, p in out.vertices do
			vec(moved.vertices[id] - offset, p, 6e-5)
		end
	end)
	report.success = report.failed == 0
	return report
end
