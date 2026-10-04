return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(
			math.abs(a - b) <= (tolerance or 1e-6) * math.max(1, math.abs(b)),
			tostring(a) .. " differs from " .. tostring(b)
		)
	end
	local function fan(n, height)
		local m = E.Mesh.new()
		m:addVertex(Vector3.new(0, 0, height or 1))
		for i = 0, n - 1 do
			m:addVertex(Vector3.new(math.cos(2 * math.pi * i / n), math.sin(2 * math.pi * i / n), 0))
		end
		for i = 0, n - 1 do
			m:addFace({ 1, i + 2, (i + 1) % n + 2 })
		end
		return m
	end
	local function fixtureMesh(fixture)
		local m = E.Mesh.new()
		for _, p in fixture.positions do
			m:addVertex(Vector3.new(p[1], p[2], p[3]))
		end
		for _, t in fixture.triangles do
			m:addFace(t)
		end
		return m
	end
	test("Analytic pyramid fans recover regular planar center and boundary angles", function()
		for _, n in { 3, 4, 5, 6, 12 } do
			local m = fan(n)
			local out, r = E.Unwrap.angleBased(
				m,
				{ pins = { [2] = Vector2.zero, [3] = Vector2.xAxis }, requireComplete = true }
			)
			assert(
				r.complete
					and r.angleConverged
					and r.reconstructionConverged
					and r.nativeOrientation
					and r.overlapFree
			)
			for i = 1, n do
				near(r.optimizedAngles[3 * i - 2], 2 * math.pi / n)
				near(r.optimizedAngles[3 * i - 1], (math.pi - 2 * math.pi / n) / 2)
			end
			near(out.faces[1].corners[1].uv.X, 0.5)
			near(out.faces[1].corners[1].uv.Y, 0.5 / math.tan(math.pi / n))
		end
	end)
	test("Nine independent dense constrained reference solutions match native-source angle optima", function()
		for _, fixture in require(script.Parent.AngleBasedFixtures) do
			local _, r = E.Unwrap.angleBased(fixtureMesh(fixture), { requireComplete = true })
			for i, target in fixture.target do
				near(r.targetAngles[i], target, 1e-12)
			end
			for i, angle in fixture.angles do
				near(r.optimizedAngles[i], angle, 1e-7)
			end
			near(r.angleOptimization.energy, fixture.energy, 1e-9)
			assert(r.angleOptimization.constraintResidual < 1e-8 and r.angleOptimization.relativeStep < 1e-8)
		end
	end)
	test("Planar concave polygon triangulations retain zero intrinsic angle distortion", function()
		local m = E.Mesh.new()
		for _, p in { { 0, 0 }, { 3, 0 }, { 3, 1 }, { 1, 1 }, { 1, 3 }, { 0, 3 } } do
			m:addVertex(Vector3.new(p[1], p[2], 0))
		end
		m:addFace({ 1, 2, 3, 4, 5, 6 })
		local out, r = E.Unwrap.angleBased(m, { pins = { [1] = Vector2.zero, [2] = Vector2.new(3, 0) } })
		assert(r.complete and r.angleOptimization.energy < 1e-20 and r.overlapFree)
		for i, corner in out.faces[1].corners do
			near(corner.uv.X, m.vertices[i].X)
			near(corner.uv.Y, m.vertices[i].Y)
		end
	end)
	test("Normalized wheel constraints avoid high-valence product underflow", function()
		local S = require(script.Parent.AngleConstraintSystem)
		local n, a, b = 1000, 0.001, 0.002
		local angles, indices = {}, {}
		for i = 1, n do
			angles[3 * i - 2], angles[3 * i - 1], angles[3 * i] = math.pi - a - b, a, b
			indices[i] = 3 * i - 2
		end
		local values, rows = S.evaluate(angles, { indices }, function() end, true)
		near(values[#values], math.sin(a) - math.sin(b), 1e-12)
		near(rows[#rows].values[1], math.cos(a) / n, 1e-12)
		near(rows[#rows].values[#rows[#rows].values], -math.cos(b) / n, 1e-12)
		assert(math.sin(a) ^ n == 0 and math.sin(b) ^ n == 0)
	end)
	test("Analytic constraint Jacobians agree with independent central differences", function()
		local S = require(script.Parent.AngleConstraintSystem)
		local fixture = require(script.Parent.AngleBasedFixtures)[5]
		local angles = fixture.angles
		local indices = {}
		for i = 1, #fixture.triangles do
			indices[i] = 3 * i - 2
		end
		local _, rows = S.evaluate(angles, { indices }, function() end, true)
		for index = 1, #angles do
			local a, b = table.clone(angles), table.clone(angles)
			a[index] += 1e-6
			b[index] -= 1e-6
			local va = S.evaluate(a, { indices }, function() end, false)
			local vb = S.evaluate(b, { indices }, function() end, false)
			for row, r in rows do
				local derivative = 0
				for k, j in r.indices do
					if j == index then
						derivative += r.values[k]
					end
				end
				near(derivative, (va[row] - vb[row]) / 2e-6, 1e-8)
			end
		end
	end)
	test("Two boundary pins fix a similarity in the non-square texture metric", function()
		local pins = { [2] = Vector2.new(0.25, 0.5), [3] = Vector2.new(0.25, 0.625) }
		local out, r = E.Unwrap.angleBased(
			fan(4),
			{ pins = pins, textureSize = Vector2.new(1024, 512), requireComplete = true }
		)
		assert(r.complete and out.faces[1].corners[2].uv == pins[2] and out.faces[1].corners[3].uv == pins[3])
		near(out.faces[1].corners[1].uv.X, 0.21875)
		near(out.faces[1].corners[1].uv.Y, 0.5625)
	end)
	test("Geometry transforms scales and unused sparse vertices preserve intrinsic targets", function()
		local m = fan(6)
		local _, base = E.Unwrap.angleBased(m)
		for _, scale in { 2 ^ -12, 1, 2 ^ 12 } do
			local mesh = m:clone()
			for id, p in mesh.vertices do
				mesh.vertices[id] = Vector3.new(p.Y * scale, p.X * scale, -p.Z * scale)
			end
			mesh.vertices[10000] = Vector3.new(10, 20, 30)
			local out, r = E.Unwrap.angleBased(mesh)
			assert(r.complete and out.vertices[10000] == mesh.vertices[10000])
			for i, angle in r.targetAngles do
				near(angle, base.targetAngles[i], 1e-12)
			end
		end
	end)
	test("Finite native rounding collapse and coordinate overflow cannot report success", function()
		local m = fan(4)
		local _, r = E.Unwrap.angleBased(
			m,
			{ pins = { [2] = Vector2.new(2 ^ 30, 2 ^ 30), [3] = Vector2.new(2 ^ 30 + 128, 2 ^ 30) } }
		)
		assert(not r.complete and not r.nativeOrientation and r.reason == "nativeOrientation")
		local source = fan(12)
		local before = E.IO.encode(source)
		local unchanged, q =
			E.Unwrap.angleBased(source, { pins = { [2] = Vector2.zero, [3] = Vector2.new(3e38, 0) } })
		assert(not q.complete and q.reason == "nativeOverflow" and E.IO.encode(unchanged) == before)
		local _, tiny =
			E.Unwrap.angleBased(m, { pins = { [2] = Vector2.zero, [3] = Vector2.new(2 ^ -70, 0) } })
		assert(tiny.complete)
	end)
	test("Optimization reconstruction and native angle tolerances fail independently", function()
		local m = fan(4)
		local _, a = E.Unwrap.angleBased(m, { iterations = 0 })
		assert(not a.complete and not a.angleConverged and a.angleOptimization.reason == "iterationLimit")
		local _, b = E.Unwrap.angleBased(m, { linearIterations = 0 })
		assert(not b.complete and b.angleOptimization.reason == "linearSolve")
		local _, c = E.Unwrap.angleBased(m, { reconstructionIterations = 0 })
		assert(not c.complete and c.angleConverged and not c.reconstructionConverged)
		local _, d = E.Unwrap.angleBased(fan(3), { reconstructionAngleTolerance = 1e-15 })
		assert(
			not d.complete
				and d.angleConverged
				and d.reconstructionConverged
				and d.reason == "nativeAngleResidual"
		)
		assert(not pcall(E.Unwrap.angleBased, m, { iterations = 0, requireComplete = true }))
	end)
	test("Positive local orientations do not hide global UV overlap", function()
		local m = E.Mesh.new()
		local n = 18
		for i = 0, n do
			local angle = 3 * math.pi * i / n
			for _, radius in { 2, 3 } do
				m:addVertex(Vector3.new(radius * math.cos(angle), radius * math.sin(angle), 0))
			end
		end
		for i = 0, n - 1 do
			m:addFace({ 2 * i + 1, 2 * i + 2, 2 * i + 4, 2 * i + 3 })
		end
		local _, r = E.Unwrap.angleBased(m, { maxOverlaps = 0 })
		assert(
			not r.complete
				and r.nativeOrientation
				and r.reason == "uvOverlap"
				and r.overlapCount > 0
				and r.overlapsTruncated
		)
		local _, q = E.Unwrap.angleBased(m, { checkOverlaps = false })
		assert(q.complete and not q.overlapChecked and q.overlapFree == nil)
	end)
	test("All source data survives while changed UVs invalidate tangent frames", function()
		local m = fan(4)
		for _, face in m.faces do
			for _, c in face.corners do
				c.uv = Vector2.new(4, 5)
				c.normal = Vector3.zAxis
				c.tangent = Vector3.xAxis
				c.tangentSign = 1
			end
		end
		m = E.Attributes.create(m, "v", "vertex", "number", 2)
		m = E.Attributes.create(m, "e", "edge", "boolean", false)
		m = E.Attributes.create(m, "f", "face", "string", "label")
		m = E.Attributes.create(m, "c", "corner", "Vector2", Vector2.one)
		m.attributes.c.values["1:1"] = Vector2.new(8, 9)
		m.weights[1] = { a = 0.25, b = 0.75 }
		m.groups.mask = { [1] = 0.3 }
		m.faces[1].material = 7
		local before = E.IO.encode(m)
		local out, r = E.Unwrap.angleBased(m)
		assert(
			r.complete
				and E.IO.encode(m) == before
				and out.attributes.c.values["1:1"] == Vector2.new(8, 9)
				and out.weights[1].b == 0.75
				and out.groups.mask[1] == 0.3
				and out.faces[1].material == 7
		)
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
		for _, face in out.faces do
			for _, c in face.corners do
				assert(c.normal == Vector3.zAxis and c.tangent == nil and c.tangentSign == nil)
			end
		end
	end)
	test("Mesh pins and option snapshots precede angle-solver callbacks", function()
		local m = fan(4)
		local options = { pins = { [2] = Vector2.zero, [3] = Vector2.xAxis } }
		options.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[1] = Vector3.new(99, 99, 99)
				options.pins[3] = Vector2.new(99, 99)
				options.minimumAngle = 1
			end
		end
		local out, r = E.Unwrap.angleBased(m, options)
		assert(
			r.complete
				and out.vertices[1] == Vector3.new(0, 0, 1)
				and out.faces[1].corners[3].uv == Vector2.xAxis
		)
	end)
	test("Disk topology pin schemas source allocations and cancellation are enforced", function()
		local m = fan(4)
		for _, options in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{ maxTriangles = 1 },
				{ maxWork = 1 },
				{ minimumAngle = 0 },
				{ iterations = 501 },
				{ pins = { [1] = Vector2.zero, [2] = Vector2.one } },
				{ pins = { [2] = Vector2.zero, [3] = Vector2.zero } },
				{ textureSize = Vector2.new(1.5, 2) },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(s)
						if s.stage == "angleIteration" then
							error("stop")
						end
					end,
				},
			}
		do
			assert(not pcall(E.Unwrap.angleBased, m, options))
		end
		assert(not pcall(E.Unwrap.angleBased, E.Primitives.box(Vector3.one)))
		local disconnected = E.Topology.join({ m, E.Deform.transform(m, CFrame.new(10, 0, 0)) })
		assert(not pcall(E.Unwrap.angleBased, disconnected))
	end)
	test("Multi-chart angle unwrap audits the final packed native atlas", function()
		local m = E.Primitives.torus(3, 1, 12, 8)
		local seams = E.Unwrap.autoSeams(
			m,
			{ angleLimit = math.rad(45), normalCone = math.rad(60), maxChartFaces = 12 }
		)
		local before = E.IO.encode(m)
		local out, r = E.Unwrap.unwrap(m, seams, {
			method = "angle",
			textureSize = Vector2.new(1024, 512),
			packing = { margin = 4 },
			requireComplete = true,
		})
		assert(
			r.complete
				and r.applied
				and r.charts == 14
				and r.packing.marginCertified
				and r.nativeAudit.overlapFree
				and r.nativeAudit.maximumAngleResidual < 1e-5
				and E.IO.encode(m) == before
		)
		assert(E.UV.analyze(out).overlapFree)
		for _, q in r.reports do
			assert(q.complete)
		end
	end)
	test("Atlas failures are transactional and work/cancellation is shared across children", function()
		local m = E.Primitives.box(Vector3.new(4, 2, 1))
		local seams = E.Unwrap.autoSeams(m)
		local before = E.IO.encode(m)
		local out, r = E.Unwrap.unwrap(m, seams, { method = "angle", packing = { margin = 2 } })
		assert(not r.complete and r.reason == "packing" and not r.applied and E.IO.encode(out) == before)
		assert(not pcall(E.Unwrap.unwrap, m, seams, { method = "angle", maxWork = 1000 }))
		assert(not pcall(
			E.Unwrap.unwrap,
			m,
			seams,
			{ method = "angle", packing = {
				cancelled = function()
					return true
				end,
			} }
		))
		assert(
			not pcall(
				E.Unwrap.unwrap,
				m,
				seams,
				{ method = "angle", pins = { [1] = Vector2.zero, [2] = Vector2.one } }
			)
		)
		assert(E.IO.encode(m) == before)
	end)
	test("Infeasible angle bounds report numerical failure instead of clamped success", function()
		local _, r = E.Unwrap.angleBased(fan(12), { minimumAngle = 0.6 })
		assert(not r.complete and not r.angleConverged and r.angleOptimization.constraintResidual > 1e-8)
	end)
	test("Sparse source IDs retain pin and face-corner report correspondence", function()
		local source, m = fan(5), E.Mesh.new()
		for id, p in source.vertices do
			m.vertices[id * 101 + 11] = p
		end
		for id, face in source.faces do
			local f = require(script.Parent.Util).copy(face)
			for i, vertex in f.vertices do
				f.vertices[i] = vertex * 101 + 11
			end
			m.faces[id * 13 + 7] = f
		end
		m.nextVertex, m.nextFace = 10000, 10000
		local out, r = E.Unwrap.angleBased(m, { pins = { [213] = Vector2.zero, [314] = Vector2.xAxis } })
		assert(r.complete and out.faces[20].corners[2].uv == Vector2.zero)
		assert(r.triangles[1].face == 20 and r.triangles[1].vertices[1] == 112)
		near(out.faces[20].corners[1].uv.Y, 0.5 / math.tan(math.pi / 5))
	end)
	test("Atlas snapshots capture typed cuts nested options and source data before callbacks", function()
		local m = E.Primitives.box(Vector3.new(4, 2, 1))
		local seams = E.Unwrap.autoSeams(m)
		m = E.Attributes.create(m, "uv_seam", "edge", "boolean", false)
		m.attributes.uv_seam.values = seams
		m.weights[1], m.groups.mask = { joint = 1 }, { [1] = 0.5 }
		m.faces[1].material = 9
		local original = m.vertices[1]
		local options = { method = "angle", packing = { margin = 0.01 } }
		options.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[1] = Vector3.new(99, 99, 99)
				table.clear(seams)
				options.packing.margin = 2
			end
		end
		local out, r = E.Unwrap.unwrap(m, nil, options)
		assert(r.complete and r.charts == 6 and out.vertices[1] == original)
		assert(out.weights[1].joint == 1 and out.groups.mask[1] == 0.5 and out.faces[1].material == 9)
		assert(next(out.attributes.uv_seam.values) and next(r.seams))
	end)
	test("Closed charts and collapsed interior cuts reject before atlas construction", function()
		assert(not pcall(E.Unwrap.unwrap, E.Primitives.box(Vector3.one), {}, { method = "angle" }))
		local m = fixtureMesh(require(script.Parent.AngleBasedFixtures)[6])
		local boundary = {}
		for _, edge in m:topology().edges do
			if #edge.faces == 1 then
				boundary[edge.a], boundary[edge.b] = true, true
			end
		end
		local key
		for candidate, edge in m:topology().edges do
			if not boundary[edge.a] and not boundary[edge.b] then
				key = candidate
				break
			end
		end
		assert(key and not pcall(E.Unwrap.unwrap, m, { [key] = true }, { method = "angle" }))
	end)
	test("Angle atlas survives native EditableMesh UV and normal conversion", function()
		local result = require(script.Parent.Examples.AngleAtlas)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid and restored:validate().closed)
			local analysis = E.UV.analyze(restored, { textureSize = Vector2.new(1024, 512) })
			assert(analysis.complete and analysis.overlapFree and analysis.allPositive)
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Empty angle charts and atlases return stable identity results", function()
		local m = E.Mesh.new()
		local a, r = E.Unwrap.angleBased(m)
		local b, q = E.Unwrap.unwrap(m, nil, { method = "angle" })
		assert(r.complete and q.complete and next(a.faces) == nil and next(b.faces) == nil)
	end)
	report.success = report.failed == 0
	return report
end
