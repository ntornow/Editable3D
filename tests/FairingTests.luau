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
	local fixtures = require(script.Parent.FairingFixtures)
	local function fixtureMesh(fixture)
		local m = E.Mesh.new()
		for _, p in fixture.positions do
			m:addVertex(Vector3.new(p[1], p[2], p[3]))
		end
		for _, t in fixture.triangles do
			m:addFace(t)
		end
		local selection = {}
		for _, id in fixture.free do
			selection[id] = true
		end
		return m, selection
	end
	local function pyramid()
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.new(0, 0, 1),
				Vector3.new(1, 0, 0),
				Vector3.new(0, 1, 0),
				Vector3.new(-1, 0, 0),
				Vector3.new(0, -1, 0),
			}
		do
			m:addVertex(p)
		end
		for i = 2, 5 do
			m:addFace({ 1, i, (i - 1) % 4 + 2 })
		end
		return m
	end
	test(
		"Eight independent dense constrained solves match coordinates energies and native geometry",
		function()
			for _, fixture in fixtures do
				local m, selection = fixtureMesh(fixture)
				local out, r = E.Sculpt.fair(
					m,
					selection,
					{ order = fixture.order, weights = fixture.mode, requireComplete = true }
				)
				assert(
					r.complete
						and r.linearConverged
						and r.nativeConverged
						and r.geometry.valid
						and r.outputIntersections.intersectionFree
				)
				for id, p in out.vertices do
					local q = fixture.expected[id]
					near(p.X, q[1])
					near(p.Y, q[2])
					near(p.Z, q[3])
				end
				near(r.components[1].energyBefore, fixture.energyBefore, 1e-9)
				near(r.components[1].energyAfter, fixture.energyAfter, 1e-7)
				for id, p in m.vertices do
					if not selection[id] then
						assert(out.vertices[id] == p)
					end
				end
			end
		end
	)
	test("Harmonic fairing has the analytic pinned fan center", function()
		local m = pyramid()
		local out, r = E.Sculpt.fair(m, { [1] = true }, { order = 1, weights = "uniform" })
		assert(r.complete and out.vertices[1] == Vector3.zero and r.modifiedVertices == 1)
		for i = 2, 5 do
			assert(out.vertices[i] == m.vertices[i])
		end
	end)
	test("Uniform biharmonic fairing restores an analytic quadratic with fixed outer bands", function()
		local m, selection = fixtureMesh(fixtures[4])
		local out, r = E.Sculpt.fair(m, selection, { order = 2, weights = "uniform" })
		assert(r.complete)
		for _, p in out.vertices do
			near(p.Z, 0.15 * (p.X * p.X + p.Y * p.Y), 1e-7)
		end
	end)
	test("Obtuse cotangent FEM weights preserve planar affine precision without clamping", function()
		local m, selection = fixtureMesh(fixtures[1])
		for id, p in m.vertices do
			m.vertices[id] = Vector3.new(p.X, p.Y, 2 * p.X - 3 * p.Y + 1)
		end
		m.vertices[13] = Vector3.new(0.42, 0.66, 2 * 0.42 - 3 * 0.66 + 1)
		local out, r = E.Sculpt.fair(m, selection, { order = 1, weights = "cotangent" })
		assert(r.complete and r.components[1].negativeWeights > 0)
		for id, p in out.vertices do
			assert((p - m.vertices[id]).Magnitude < 1e-6)
		end
	end)
	test("Face selections and binary domain masks select the same patch interior", function()
		local m, selection = fixtureMesh(fixtures[1])
		local faces = {}
		for id in m.faces do
			faces[id] = true
		end
		local a, r = E.Sculpt.fair(m, nil, { faces = faces, order = 1, weights = "uniform" })
		local mask = E.Selection.convertDomain(m, faces, "face", "vertex", { mode = "all" })
		local b, q = E.Sculpt.fair(m, mask, { order = 1, weights = "uniform" })
		local c = E.Sculpt.fair(m, selection, { order = 1, weights = "uniform" })
		assert(r.complete and q.complete)
		for id, p in a.vertices do
			assert(p == b.vertices[id] and p == c.vertices[id])
		end
	end)
	test("Explicit pins and world-axis locks retain exact native samples", function()
		local m, selection = fixtureMesh(fixtures[1])
		local out, r = E.Sculpt.fair(
			m,
			selection,
			{ pins = { [13] = true }, lockAxes = { X = true, Y = true }, order = 1 }
		)
		assert(r.complete and out.vertices[13] == m.vertices[13])
		assert(r.components[1].axes[1].locked and r.components[1].axes[2].locked)
		for id, p in out.vertices do
			assert(p.X == m.vertices[id].X and p.Y == m.vertices[id].Y)
		end
	end)
	test("Sharp typed seams protect endpoint positions until explicitly disabled", function()
		local m, selection = fixtureMesh(fixtures[1])
		m = E.Attributes.create(m, "sharp_edge", "edge", "boolean", false)
		m.attributes.sharp_edge.values["12:13"] = true
		local out, r = E.Sculpt.fair(m, selection, { order = 1 })
		assert(r.complete and out.vertices[12] == m.vertices[12] and out.vertices[13] == m.vertices[13])
		local free, q = E.Sculpt.fair(m, selection, { order = 1, preserveSeams = false })
		assert(q.complete and free.vertices[13] ~= m.vertices[13])
	end)
	test("Material and UV corner discontinuities conservatively pin their geometry samples", function()
		local m, selection = fixtureMesh(fixtures[1])
		m.faces[11].material = 5
		m.faces[14].corners[1].uv = Vector2.new(4, 5)
		local protected = require(script.Parent.AttributeSeams).locked(m, m:topology(), {})
		local out, r = E.Sculpt.fair(m, selection, { order = 1 })
		assert(r.complete and next(protected))
		for id in protected do
			assert(out.vertices[id] == m.vertices[id])
		end
	end)
	test(
		"All nongeometric data survives while normals and stale tangent frames are handled explicitly",
		function()
			local m, selection = fixtureMesh(fixtures[1])
			m = E.Attributes.create(m, "v", "vertex", "number", 2)
			m = E.Attributes.create(m, "e", "edge", "boolean", true)
			m = E.Attributes.create(m, "f", "face", "string", "face")
			m = E.Attributes.create(m, "c", "corner", "Vector2", Vector2.one)
			m.attributes.c.values["1:1"] = Vector2.new(8, 9)
			m.groups.mask = { [13] = 0.5 }
			m.weights[13] = { joint = 1 }
			m.faces[1].material = 7
			for _, face in m.faces do
				for _, c in face.corners do
					c.uv = Vector2.new(3, 4)
					c.normal = Vector3.zAxis
					c.tangent = Vector3.xAxis
					c.tangentSign = 1
				end
			end
			local before = E.IO.encode(m)
			local out, r =
				E.Sculpt.fair(m, selection, { order = 1, preserveSeams = false, recalculateNormals = false })
			assert(
				r.complete
					and E.IO.encode(m) == before
					and out.faces[1].material == 7
					and out.weights[13].joint == 1
					and out.groups.mask[13] == 0.5
			)
			assert(out.attributes.c.values["1:1"] == Vector2.new(8, 9))
			for _, face in out.faces do
				for _, c in face.corners do
					assert(
						c.uv == Vector2.new(3, 4)
							and c.normal == Vector3.zAxis
							and c.tangent == nil
							and c.tangentSign == nil
					)
				end
			end
		end
	)
	test("Source selection nested options and pins are captured before callbacks", function()
		local m, selection = fixtureMesh(fixtures[1])
		local pins = {}
		local options = { order = 1, weights = "uniform", pins = pins, lockAxes = {} }
		options.checkpoint = function(s)
			if s.stage == "begin" then
				table.clear(selection)
				pins[13] = true
				options.lockAxes.Z = true
				options.iterations = 0
				m.vertices[13] = Vector3.new(99, 99, 99)
			end
		end
		local out, r = E.Sculpt.fair(m, selection, options)
		assert(r.complete)
		near(out.vertices[13].Z, 0)
		assert(out.vertices[13].X == 0.5)
	end)
	test("Unanchored closed components return unchanged explicit incomplete results", function()
		local m = E.Primitives.box(Vector3.one)
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.fair(m, nil, { preserveSeams = false })
		assert(
			not r.complete
				and not r.applied
				and r.reason == "unanchoredSelection"
				and E.IO.encode(out) == before
		)
		assert(not pcall(E.Sculpt.fair, m, nil, { preserveSeams = false, requireComplete = true }))
	end)
	test("Empty fully fixed and fully axis-locked inputs are exact identities", function()
		local empty, r = E.Sculpt.fair(E.Mesh.new())
		assert(r.complete and not r.applied and next(empty.faces) == nil)
		local m = E.Primitives.box(Vector3.one)
		local before = E.IO.encode(m)
		for _, pair in
			{
				{ {}, { preserveSeams = false } },
				{
					nil,
					{
						preserveSeams = false,
						lockAxes = {
							X = true,
							Y = true,
							Z = true,
						},
					},
				},
			}
		do
			local out, q = E.Sculpt.fair(m, pair[1], pair[2])
			assert(q.complete and not q.applied and E.IO.encode(out) == before)
		end
	end)
	test("Soft linear limits expose partial progress independently of native convergence", function()
		local m, selection = fixtureMesh(fixtures[2])
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.fair(m, selection, { iterations = 0, order = 1 })
		assert(not r.complete and not r.linearConverged and not r.applied and E.IO.encode(out) == before)
		local _, q = E.Sculpt.fair(m, selection, { iterations = 1, order = 1 })
		assert(not q.complete and not q.linearConverged and q.applied and q.geometry.valid)
		assert(not pcall(E.Sculpt.fair, m, selection, { iterations = 0, requireComplete = true }))
	end)
	test("Native backward residual tolerances can fail after the double solve converges", function()
		local m, selection = fixtureMesh(fixtures[5])
		local _, r = E.Sculpt.fair(
			m,
			selection,
			{ order = 1, nativeTolerance = 1e-16, nativeAbsoluteTolerance = 1e-30 }
		)
		assert(
			not r.complete and r.linearConverged and not r.nativeConverged and r.reason == "nativeResidual"
		)
	end)
	test("Normal constraints roll back otherwise converged geometric edits", function()
		local m, selection = fixtureMesh(fixtures[1])
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.fair(m, selection, { order = 1, normalLimit = 0.001 })
		assert(
			not r.complete and not r.applied and r.reason == "geometry" and r.geometry.reason == "normalLimit"
		)
		assert(
			r.modifiedVertices == 0
				and r.maximumDisplacement == 0
				and r.candidateModifiedVertices > 0
				and E.IO.encode(out) == before
		)
	end)
	test("Introduced contact with a fixed component rolls back the complete result", function()
		local a = pyramid()
		local b = E.Mesh.new()
		for _, p in { Vector3.new(-0.05, -0.05, 0), Vector3.new(0.05, -0.05, 0), Vector3.new(0, 0.05, 0) } do
			b:addVertex(p)
		end
		b:addFace({ 1, 2, 3 })
		local m = E.Topology.join({ a, b })
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.fair(m, { [1] = true }, { order = 1, weights = "uniform" })
		assert(
			not r.complete
				and r.reason == "outputIntersections"
				and not r.outputIntersections.intersectionFree
		)
		assert(E.IO.encode(out) == before and not r.applied)
	end)
	test("An input intersection and an incomplete audit cannot masquerade as fairing success", function()
		local m = E.Topology.join({ pyramid(), pyramid() })
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.fair(m, { [1] = true })
		assert(not r.complete and r.reason == "inputIntersections" and E.IO.encode(out) == before)
		local clean, selection = fixtureMesh(fixtures[1])
		local _, q = E.Sculpt.fair(clean, selection, { intersectionOptions = { maxTests = 1 } })
		assert(not q.complete and not q.inputIntersections.complete and q.reason == "inputIntersections")
	end)
	test("Budgets and root or nested cancellation leave all original fields unchanged", function()
		local m, selection = fixtureMesh(fixtures[1])
		local before = E.IO.encode(m)
		for _, options in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{ maxTriangles = 1 },
				{ maxWork = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(s)
						if s.stage == "solved" then
							error("stop")
						end
					end,
				},
				{ intersectionOptions = {
					cancelled = function()
						return true
					end,
				} },
			}
		do
			assert(not pcall(E.Sculpt.fair, m, selection, options))
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Geometry scales and exact rigid transforms preserve the solution", function()
		local fixture = fixtures[1]
		for _, scale in { 2 ^ -40, 2 ^ 40 } do
			local m, selection = fixtureMesh(fixture)
			for id, p in m.vertices do
				m.vertices[id] = Vector3.new(p.Z * scale, p.X * scale, -p.Y * scale)
			end
			local out, r = E.Sculpt.fair(m, selection, { order = 1, weights = "uniform" })
			assert(r.complete)
			for _, face in out.faces do
				for _, corner in face.corners do
					assert(corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-6)
				end
			end
			for id, p in out.vertices do
				local q = fixture.expected[id]
				near(p.X / scale, q[3])
				near(p.Y / scale, q[1])
				near(p.Z / scale, -q[2])
			end
		end
	end)
	test("Disconnected components use their own scale and keep unrelated loose vertices", function()
		local a = pyramid()
		local b = pyramid()
		for id, p in b.vertices do
			b.vertices[id] = Vector3.new((p.X + 10) * 2 ^ 30, p.Y * 2 ^ 30, p.Z * 2 ^ 30)
		end
		for id, p in a.vertices do
			a.vertices[id] = p * 2 ^ -30
		end
		local m = E.Topology.join({ a, b })
		m.vertices[9999] = Vector3.new(7, 8, 9)
		m.nextVertex = 10000
		local out, r = E.Sculpt.fair(m, { [1] = true, [6] = true }, { order = 1, weights = "uniform" })
		assert(
			r.complete
				and out.vertices[1].Z == 0
				and out.vertices[6].Z == 0
				and out.vertices[9999] == m.vertices[9999]
		)
	end)
	test("Sparse IDs preserve source correspondence and exact pins", function()
		local source, selected = fixtureMesh(fixtures[1])
		local m = E.Mesh.new()
		local selection = {}
		for id, p in source.vertices do
			m.vertices[id * 101 + 11] = p
			if selected[id] then
				selection[id * 101 + 11] = true
			end
		end
		for id, face in source.faces do
			local f = require(script.Parent.Util).copy(face)
			for i, v in f.vertices do
				f.vertices[i] = v * 101 + 11
			end
			m.faces[id * 13 + 7] = f
		end
		m.nextVertex, m.nextFace = 10000, 10000
		local out, r = E.Sculpt.fair(m, selection, { order = 1, weights = "uniform" })
		assert(r.complete and r.components[1].id == 20 and out.vertices[112] == m.vertices[112])
		near(out.vertices[1324].Z, 0)
	end)
	test("Invalid schemas numerical controls and fractional selection weights reject", function()
		local m, selection = fixtureMesh(fixtures[1])
		for _, options in
			{
				{ order = 3 },
				{ weights = "bad" },
				{ tolerance = 0 },
				{ nativeTolerance = 0 },
				{ normalLimit = 4 },
				{ pins = false },
				{ pins = { [999] = true } },
				{ faces = false },
				{ lockAxes = { W = true } },
				{ pinBoundary = 1 },
			}
		do
			assert(not pcall(E.Sculpt.fair, m, selection, options))
		end
		assert(not pcall(E.Sculpt.fair, m, { [13] = 0.5 }))
		assert(not pcall(E.Sculpt.fair, m, selection, { faces = { [1] = true } }))
	end)
	test("Fairing composes with fixed-topology multires detail transport", function()
		local base, selection = fixtureMesh(fixtures[1])
		local stack = E.Subdivision.multires(base, 1)
		local reference = stack:get()
		local fine = reference:clone()
		for id, p in fine.vertices do
			if id % 7 == 0 then
				fine.vertices[id] = p + Vector3.new(0, 0, 0.01)
			end
		end
		stack:commit(fine)
		local coarse = stack:select(1)
		local changed, r = E.Sculpt.fair(coarse, selection, { order = 1, weights = "uniform" })
		assert(r.complete)
		stack:commit(changed)
		local actual = stack:select(2)
		local newReference = E.Subdivision.catmullClark(changed, 1)
		for id, p in actual.vertices do
			near(
				(p - newReference.vertices[id]).Magnitude,
				(fine.vertices[id] - reference.vertices[id]).Magnitude,
				1e-6
			)
		end
	end)
	test("Explicit face area validation retains default thresholds and rejects zero area", function()
		local m = pyramid()
		for id, p in m.vertices do
			m.vertices[id] = p * 2 ^ -40
		end
		assert(not m:validate().valid and m:validate({ minimumFaceArea = 0 }).valid)
		for _, value in { -1, math.huge, false, "0" } do
			assert(not pcall(m.validate, m, { minimumFaceArea = value }))
		end
		local flat = E.Mesh.new()
		flat:addVertex(Vector3.zero)
		flat:addVertex(Vector3.xAxis)
		flat:addVertex(Vector3.xAxis * 2)
		flat:addFace({ 1, 2, 3 })
		assert(not flat:validate({ minimumFaceArea = 0 }).valid)
	end)
	test("A larger patch solves within the default shared budget", function()
		local result = require(script.Parent.Examples.FairPatch)(E, 16)
		assert(result.fairing.complete and result.fairing.work <= 50000000)
		assert(result.fairing.outputIntersections.intersectionFree)
		for id, p in result.mesh.vertices do
			near(p.Z, 0, 2e-6)
			if result.source.vertices[id].Z == 0 then
				assert(p == result.source.vertices[id])
			end
		end
	end)
	test("A finite double solution that overflows native positions rolls back", function()
		local m, selection = E.Mesh.new(), {}
		local n = 8
		local function id(i, j)
			return j * (n + 1) + i + 1
		end
		for j = 0, n do
			for i = 0, n do
				local band = math.min(i, j, n - i, n - j)
				m:addVertex(Vector3.new(i, j, band == 0 and 2e38 or 3e38))
				selection[id(i, j)] = band >= 2
			end
		end
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				m:addFace({ id(i, j), id(i + 1, j), id(i + 1, j + 1) })
				m:addFace({ id(i, j), id(i + 1, j + 1), id(i, j + 1) })
			end
		end
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.fair(m, selection, {
			weights = "uniform",
			lockAxes = { X = true, Y = true },
			checkIntersections = false,
		})
		assert(not r.complete and not r.applied and not r.nativeConverged and r.reason == "nativeOverflow")
		assert(E.IO.encode(out) == before and E.IO.encode(m) == before)
	end)
	test("Large native translations retain the anchored plane and exact fixed coordinates", function()
		local m, selection = fixtureMesh(fixtures[1])
		local shift = Vector3.new(2 ^ 20, -(2 ^ 19), 2 ^ 17)
		for id, p in m.vertices do
			m.vertices[id] = p + shift
		end
		local out, r =
			E.Sculpt.fair(m, selection, { order = 1, weights = "uniform", lockAxes = { X = true, Y = true } })
		assert(r.complete and r.nativeConverged)
		for id, p in out.vertices do
			assert(p.Z == shift.Z and p.X == m.vertices[id].X and p.Y == m.vertices[id].Y)
		end
	end)
	test("A faired patch retains its positions UVs and normals through native conversion", function()
		local result = require(script.Parent.Examples.FairPatch)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			for _, p in restored.vertices do
				near(p.Z, 0, 2e-6)
			end
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
