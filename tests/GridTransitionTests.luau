return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tol)
		assert(math.abs(a - b) <= (tol or 1e-6), tostring(a) .. " differs from " .. tostring(b))
	end
	local function count(t)
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	local function grid(n, field)
		local m = E.Mesh.new()
		local function id(i, j)
			return j * (n + 1) + i + 1
		end
		for j = 0, n do
			for i = 0, n do
				m:addVertex(Vector3.new(i, j, field and field(i, j) or 0))
			end
		end
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
				local corners = {}
				for k, v in ids do
					local p = m.vertices[v]
					corners[k] =
						{ uv = Vector2.new(p.X / n, p.Y / n), tangent = Vector3.xAxis, tangentSign = 1 }
				end
				m:addFace(ids, corners)
			end
		end
		return m, id
	end
	local function selectGroup(selection, n, i, j)
		for y = j * 2, j * 2 + 1 do
			for x = i * 2, i * 2 + 1 do
				selection[y * n + x + 1] = true
			end
		end
	end
	local function options(extra)
		local t = { transitions = true, checkIntersections = false, maxDeviation = 10 }
		for k, v in extra or {} do
			t[k] = v
		end
		return t
	end
	local function run(m, selection, extra, iterations)
		local opt = options(extra)
		opt.faces = selection
		return E.Simplify.unsubdivide(m, iterations or 1, opt)
	end
	test(
		"General grid overlays match 240 independent rational references including boundary flaps",
		function()
			local O = require(script.Parent.GridPatchOverlay)
			local uv = {}
			for j = 0, 2 do
				for i = 0, 2 do
					uv[j * 3 + i + 1] = { 2 * i, 2 * j }
				end
			end
			local function triangles(ids)
				local out = {}
				for _, t in ids do
					table.insert(out, { ids = t, uv = { uv[t[1]], uv[t[2]], uv[t[3]] } })
				end
				return out
			end
			local function pairOrder(a, b)
				return a[1] == b[1] and a[2] < b[2] or a[1] < b[1]
			end
			for _, f in require(script.Parent.GridOverlayFixtures) do
				local positions = {}
				for i, p in f.positions do
					positions[i] = Vector3.new(p[1], p[2], p[3])
				end
				local bound, info = O.bound(
					triangles(f.source),
					triangles(f.target),
					positions,
					function() end
				)
				assert(bound and bound >= f.upper and bound <= f.upper * (1 + 3e-14))
				for _, name in { "overlaps", "flapPairs" } do
					table.sort(info[name], pairOrder)
					assert(#info[name] == #f[name])
					for i, pair in f[name] do
						assert(info[name][i][1] == pair[1] and info[name][i][2] == pair[2])
					end
				end
			end
		end
	)
	test("All sixteen coarse fine frontier patterns preserve a manifold planar disk exactly", function()
		for mask = 0, 15 do
			local m = grid(6)
			local selected = {}
			selectGroup(selected, 6, 1, 1)
			local sides = { { 1, 0 }, { 2, 1 }, { 1, 2 }, { 0, 1 } }
			local groups = 1
			for i, ij in sides do
				if bit32.band(mask, 2 ^ (i - 1)) ~= 0 then
					selectGroup(selected, 6, ij[1], ij[2])
					groups += 1
				end
			end
			local out, r = run(m, selected, { maxDeviation = 0, checkIntersections = true })
			assert(r.complete and r.finalFaces == 36 - 3 * groups and r.errorBound == 0)
			assert(#out.faces[15].vertices == 9 - groups)
			local c = E.Connectivity.analyze(out)
			assert(
				c.valid
					and #c.components == 1
					and #c.boundaryLoops == 1
					and c.components[1].eulerCharacteristic == 1
			)
			assert(r.outputIntersections.intersectionFree)
		end
	end)
	test("A curved center has an analytic whole patch error and a strict deviation gate", function()
		local m = grid(6, function(x, y)
			return x == 3 and y == 3 and 1 or 0
		end)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		local out, r = run(m, selected, { maxDeviation = 1.001 })
		assert(r.complete and #out.faces[15].vertices == 8)
		assert(r.errorBound >= 1 and r.errorBound < 1 + 1e-14)
		local unchanged, s = run(m, selected, { maxDeviation = 0.9 })
		assert(not s.complete and s.appliedLevels == 0 and E.IO.encode(unchanged) == E.IO.encode(m))
	end)
	test("Midpoint pins produce transition polygons while center pins block only their patch", function()
		local m, id = grid(6)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		selectGroup(selected, 6, 2, 1)
		local mid = id(4, 3)
		local out, r = run(m, selected, { maxDeviation = 0, keepVertices = { [mid] = true } })
		assert(r.complete and out.vertices[mid] == m.vertices[mid] and #out.faces[15].vertices == 8)
		local center = id(3, 3)
		local partial, s = run(m, selected, { maxDeviation = 0, keepVertices = { [center] = true } })
		assert(not s.complete and s.appliedLevels == 1 and s.finalFaces == 33)
		assert(partial.vertices[center] == m.vertices[center] and partial.vertices[mid] == m.vertices[mid])
		assert(E.Connectivity.analyze(partial).valid)
	end)
	test("Typed internal seams reject one patch and retain a conforming neighboring frontier", function()
		local m, id = grid(6)
		local center, mid = id(3, 3), id(4, 3)
		local key = math.min(center, mid) .. ":" .. math.max(center, mid)
		m = E.Attributes.set(
			E.Attributes.create(m, "feature", "edge", "boolean", false),
			"feature",
			{ [key] = true }
		)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		selectGroup(selected, 6, 2, 1)
		local out, r = run(m, selected, { seamAttributes = { "feature" }, maxDeviation = 0 })
		assert(not r.complete and r.finalFaces == 33 and out.vertices[center] == m.vertices[center])
		assert(E.Connectivity.index(out).edges[key] and E.Attributes.get(out, "feature", key))
		assert(r.steps[1].components[1].rejections.feature == 1)
	end)
	test("Different half edge values retain the midpoint and both original edge records", function()
		local m, id = grid(6)
		local a, e, b = id(4, 2), id(4, 3), id(4, 4)
		local k1, k2 = math.min(a, e) .. ":" .. math.max(a, e), math.min(e, b) .. ":" .. math.max(e, b)
		m = E.Attributes.set(
			E.Attributes.create(m, "edge_data", "edge", "number", 0),
			"edge_data",
			{ [k1] = 2, [k2] = 7 }
		)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		selectGroup(selected, 6, 2, 1)
		local out, r = run(m, selected, { maxDeviation = 0 })
		assert(r.complete and out.vertices[e] == m.vertices[e])
		assert(E.Attributes.get(out, "edge_data", k1) == 2 and E.Attributes.get(out, "edge_data", k2) == 7)
	end)
	test("Unselected polygons and retained skin groups and attributes preserve their records", function()
		local m = grid(6)
		m.groups.test = {}
		local values = {}
		for id, p in m.vertices do
			values[id] = p.X
			m.groups.test[id] = p.X / 6
			m.weights[id] = { A = 1 - p.X / 6, B = p.X / 6 }
		end
		m = E.Attributes.set(E.Attributes.create(m, "x", "vertex", "number", 0), "x", values)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		local unselected = {}
		for fid in m.faces do
			unselected[fid] = not selected[fid]
		end
		local beforeMesh = E.Topology.extract(m, unselected)
		beforeMesh.attributes = {}
		local before = E.IO.encode(beforeMesh)
		local out, r = run(m, selected, { maxDeviation = 0 })
		local afterMesh = E.Topology.extract(out, unselected)
		afterMesh.attributes = {}
		assert(r.complete and E.IO.encode(afterMesh) == before)
		for id, p in out.vertices do
			assert(p == m.vertices[id] and E.Attributes.get(out, "x", id) == values[id])
			assert(out.groups.test[id] == m.groups.test[id] and out.weights[id].B == m.weights[id].B)
		end
		for _, corner in out.faces[15].corners do
			assert(corner.uv and corner.normal and not corner.tangent and not corner.tangentSign)
		end
	end)
	test("Partial four face selections report unprocessed patches without inventing merges", function()
		local m = grid(6)
		local selected = { [15] = true, [16] = true, [21] = true }
		local out, r = run(m, selected)
		assert(not r.complete and r.appliedLevels == 0 and E.IO.encode(out) == E.IO.encode(m))
		assert(r.steps[1].components[1].rejections.partialPatch == 1)
		local _, legacy = E.Simplify.unsubdivide(m, 1, { faces = selected })
		assert(not legacy.complete and legacy.steps[1].components[1].reason == "partialComponent")
	end)
	test(
		"Further levels report mixed polygon limits while full grids retain multilevel coarsening",
		function()
			local m = grid(6)
			local selected = {}
			selectGroup(selected, 6, 1, 1)
			local out, r = run(m, selected, { maxDeviation = 0 }, 2)
			assert(
				not r.complete and r.appliedLevels == 1 and r.iterationsCompleted == 1 and r.finalFaces == 33
			)
			assert(r.steps[2].components[1].reason == "nonquad" and out:validate().valid)
			local coarse, s = E.Simplify.unsubdivide(grid(8), 2, options({ maxDeviation = 0 }))
			assert(s.complete and s.appliedLevels == 2 and count(coarse.faces) == 4)
		end
	)
	test("Introduced output intersections roll back the whole local coarsening transaction", function()
		local m = grid(2, function(x, y)
			return x == 1 and y == 1 and 0.2 or 0
		end)
		local ids = {}
		for _, p in { Vector3.new(0.9, 1, -0.02), Vector3.new(1.1, 1, -0.02), Vector3.new(1, 1, 0.08) } do
			table.insert(ids, m:addVertex(p))
		end
		m:addFace(ids)
		local before = E.IO.encode(m)
		local out, r = run(
			m,
			{ [1] = true, [2] = true, [3] = true, [4] = true },
			{ maxDeviation = 0.3, checkIntersections = true }
		)
		assert(
			not r.complete
				and r.reason == "outputAudit"
				and r.appliedLevels == 0
				and r.candidateAppliedLevels == 1
		)
		assert(r.inputIntersections.intersectionFree and not r.outputIntersections.intersectionFree)
		assert(E.IO.encode(out) == before and r.errorBound == 0)
	end)

	test("Face corner and edge fields use source correspondence on a permitted merge", function()
		local m = grid(6)
		local fields = { face = {}, corner = {}, edge = {} }
		for fid, f in m.faces do
			fields.face[fid] = fid
			for i, id in f.vertices do
				fields.corner[fid .. ":" .. i] = m.vertices[id].X
			end
		end
		for key in E.Connectivity.index(m).edges do
			fields.edge[key] = 7
		end
		for _, entry in { { "face", "face" }, { "corner", "corner" }, { "edge", "edge" } } do
			m = E.Attributes.set(
				E.Attributes.create(m, entry[1], entry[2], "number", 0),
				entry[1],
				fields[entry[1]]
			)
		end
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		selectGroup(selected, 6, 2, 1)
		local out, r = run(m, selected, { maxDeviation = 0, preserveSeams = false })
		assert(r.complete)
		near(E.Attributes.get(out, "face", 15), (15 + 16 + 21 + 22) / 4)
		for fid, f in out.faces do
			for i, id in f.vertices do
				near(E.Attributes.get(out, "corner", fid .. ":" .. i), out.vertices[id].X)
			end
		end
		for key in E.Connectivity.index(out).edges do
			assert(E.Attributes.get(out, "edge", key) == 7)
		end
	end)
	test("Vertex sharpness preserves a midpoint and prevents removal of a selected center", function()
		local m, id = grid(6)
		local center, mid = id(3, 3), id(4, 3)
		m = E.Attributes.set(
			E.Attributes.create(m, "subdivision_vertex_sharpness", "vertex", "number", 0),
			"subdivision_vertex_sharpness",
			{ [center] = 2, [mid] = 4 }
		)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		selectGroup(selected, 6, 2, 1)
		local out, r = run(m, selected, { maxDeviation = 0 })
		assert(not r.complete and r.finalFaces == 33 and out.vertices[center] and out.vertices[mid])
		assert(E.Attributes.get(out, "subdivision_vertex_sharpness", mid) == 4)
	end)
	test("A hole and original loose vertices retain topology and data", function()
		local m = grid(6)
		local hole = {}
		selectGroup(hole, 6, 1, 1)
		for fid in hole do
			m.faces[fid] = nil
		end
		local loose = m:addVertex(Vector3.new(20, 30, 40))
		m.groups.loose = { [loose] = 0.7 }
		m.weights[loose] = { Bone = 1 }
		local selected = {}
		selectGroup(selected, 6, 0, 0)
		local out, r = run(m, selected, { maxDeviation = 0, checkIntersections = true })
		local c = E.Connectivity.analyze(out)
		assert(r.complete and c.valid and #c.boundaryLoops == 2 and c.components[1].eulerCharacteristic == 0)
		assert(
			out.vertices[loose] == m.vertices[loose]
				and out.groups.loose[loose] == 0.7
				and out.weights[loose].Bone == 1
		)
	end)
	test("Periodic quad phases support a local patch without opening the closed surface", function()
		local m = E.Primitives.torus(3, 1, 8, 8)
		local U = require(script.Parent.Util)
		local phases = require(script.Parent.UnsubdivideTopology).component(
			m,
			m:topology(),
			U.keys(m.vertices),
			U.keys(m.faces),
			function() end
		)
		assert(#phases > 0)
		local selected = {}
		for _, fid in phases[1].groups[2].faces do
			selected[fid] = true
		end
		local out, r = run(m, selected, { maxDeviation = 3, preserveSeams = false, minimumNormalDot = 0 })
		assert(r.complete and r.finalFaces == 61 and E.Connectivity.analyze(out).closed)
		assert(r.steps[1].components[1].recognizedPhases == 4)
	end)
	test("Exact axis transforms scales and sparse IDs preserve the planar bound", function()
		for _, scale in { 2 ^ -15, 1, 2 ^ 15 } do
			local m = grid(6)
			local old = table.clone(m.vertices)
			m.vertices = {}
			m.nextVertex = 2000
			for id, p in old do
				m.vertices[id * 7 + 100] =
					Vector3.new(p.Y * scale, p.Z * scale + 8 * scale, p.X * scale - 16 * scale)
			end
			for _, f in m.faces do
				for i, id in f.vertices do
					f.vertices[i] = id * 7 + 100
				end
			end
			local selected = {}
			selectGroup(selected, 6, 1, 1)
			local out, r = run(m, selected, { maxDeviation = 0 })
			assert(r.complete and r.errorBound == 0 and out:validate().valid)
			for id, p in out.vertices do
				assert(p == m.vertices[id])
			end
		end
	end)
	test("Source and nested selection snapshots precede every user callback", function()
		local m, id = grid(6)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		local expected = run(m, selected, { maxDeviation = 0 })
		local opt = options({ faces = selected, maxDeviation = 0, keepVertices = {} })
		opt.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[1] = Vector3.new(900, 800, 700)
				m.faces[1] = nil
				selected[15] = false
				opt.keepVertices[id(3, 3)] = true
				opt.transitions = false
			end
		end
		local out, r = E.Simplify.unsubdivide(m, 1, opt)
		assert(r.complete and E.IO.encode(out) == E.IO.encode(expected))
	end)
	test("Hard budgets root cancellation and nested intersection cancellation are transactional", function()
		local m = grid(6)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		local before = E.IO.encode(m)
		for _, extra in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{ maxWork = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkIntersections = true,
					intersectionOptions = {
						cancelled = function()
							return true
						end,
					},
				},
			}
		do
			assert(not pcall(run, m, selected, extra))
			assert(E.IO.encode(m) == before)
		end
		local cancel = false
		assert(not pcall(run, m, selected, {
			checkpoint = function(status)
				if status.stage == "component" then
					cancel = true
				end
			end,
			cancelled = function()
				return cancel
			end,
		}))
		assert(E.IO.encode(m) == before)
	end)
	test("Zero levels empty selections and strict incomplete requests have explicit outcomes", function()
		local m = grid(6)
		local out, r = E.Simplify.unsubdivide(m, 0, options())
		assert(r.complete and r.errorBound == 0 and E.IO.encode(out) == E.IO.encode(m))
		local unchanged, s = run(m, {}, { maxDeviation = 0 })
		assert(s.complete and s.reason == "emptySelection" and E.IO.encode(unchanged) == E.IO.encode(m))
		assert(not pcall(run, m, { [15] = true }, { requireComplete = true }))
		assert(not pcall(E.Simplify.unsubdivide, m, 1, { transitions = 1 }))
	end)

	test("Rejected patches trigger a new frontier and revalidation of their surviving neighbors", function()
		local m = grid(6, function(x, y)
			return x == 3 and y == 3 and 1 or 0
		end)
		local selected = {}
		selectGroup(selected, 6, 1, 1)
		selectGroup(selected, 6, 2, 1)
		local out, r = run(m, selected, { maxDeviation = 0.5 })
		local status = r.steps[1].components[1]
		assert(
			not r.complete
				and r.finalFaces == 33
				and status.frontierRounds == 2
				and status.rejections.deviation == 1
		)
		assert(#out.faces[17].vertices == 7 and E.Connectivity.analyze(out).valid)
	end)
	test("A reversed native boundary flap reports a normal constraint without changing geometry", function()
		local m = E.Primitives.torus(3, 1, 8, 8)
		local U = require(script.Parent.Util)
		local phases = require(script.Parent.UnsubdivideTopology).component(
			m,
			m:topology(),
			U.keys(m.vertices),
			U.keys(m.faces),
			function() end
		)
		local selected = {}
		for _, fid in phases[1].groups[1].faces do
			selected[fid] = true
		end
		local out, r = run(m, selected, { maxDeviation = 3, preserveSeams = false, minimumNormalDot = 0 })
		assert(not r.complete and r.appliedLevels == 0 and r.steps[1].components[1].rejections.normal == 1)
		assert(E.IO.encode(out) == E.IO.encode(m))
	end)
	test("A transition panel preserves native position UV and normal topology", function()
		local result = require(script.Parent.Examples.TransitionPanel)(E)
		assert(result.coarsening.complete and result.coarsening.errorBound <= 0.2)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			local _, scan = E.Intersections.mesh(restored)
			assert(scan.complete and scan.intersectionFree)
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)

	test(
		"A remaining cumulative budget still allows independent low error patches on a later level",
		function()
			local m = grid(8, function(x, y)
				return 0.5 * math.max(0, 1 - math.abs(x - 2) / 2) * math.max(0, 1 - math.abs(y - 2) / 2)
			end)
			local out, r = E.Simplify.unsubdivide(m, 2, options({ maxDeviation = 0.6 }))
			assert(
				not r.complete and r.appliedLevels == 2 and r.iterationsCompleted == 1 and r.finalFaces == 7
			)
			assert(r.errorBound <= 0.6 and r.steps[2].components[1].rejections.deviation == 1)
			assert(out:validate().valid)
		end
	)
	report.success = report.failed == 0
	return report
end
