return function(E)
	local S = E.Simplify
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
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
			return i * (n + 1) + j + 1
		end
		for i = 0, n do
			for j = 0, n do
				m:addVertex(Vector3.new(i, j, field and field(i, j) or 0))
			end
		end
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
				local corners = {}
				for k, v in ids do
					local p = m.vertices[v]
					corners[k] = { uv = Vector2.new(p.X / n, p.Y / n) }
				end
				m:addFace(ids, corners)
			end
		end
		return m, id
	end
	local function fixtureMesh(fixture)
		local m = E.Mesh.new()
		for _, p in fixture.positions do
			m:addVertex(Vector3.new(p[1], p[2], p[3]))
		end
		local function id(i, j)
			return i * 3 + j + 1
		end
		for i = 0, 1 do
			for j = 0, 1 do
				local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
				for _ = 1, fixture.rotations[i * 2 + j + 1] do
					table.insert(ids, table.remove(ids, 1))
				end
				m:addFace(ids)
			end
		end
		return m
	end
	test("Even quad grids coarsen through full levels with an exact zero bound", function()
		for _, case in { { 2, 1, 1 }, { 4, 2, 1 }, { 8, 2, 4 } } do
			local m = grid(case[1])
			local out, r = S.unsubdivide(m, case[2], { maxDeviation = 0, requireComplete = true })
			assert(
				r.complete
					and r.finalFaces == case[3]
					and r.iterationsCompleted == case[2]
					and r.errorBound == 0
			)
			assert(out:validate().valid)
			for id, p in out.vertices do
				assert(m.vertices[id] == p)
			end
			for _, face in out.faces do
				assert(#face.vertices == 4)
			end
		end
	end)
	test("Odd grids and polygon components report inability without inventing a cage", function()
		local m = grid(5)
		local before = E.IO.encode(m)
		local out, r = S.unsubdivide(m, 1, { maxDeviation = 0 })
		assert(not r.complete and r.finalFaces == 25 and E.IO.encode(out) == before)
		assert(r.steps[1].components[1].reason == "unrecognized")
		local triangles = E.Topology.triangulate(grid(2))
		local _, q = S.unsubdivide(triangles, 1)
		assert(not q.complete and q.steps[1].components[1].reason == "nonquad")
	end)
	test("Subdivided boxes recover coarse connectivity while retaining current samples", function()
		local source = E.Subdivision.catmullClark(E.Primitives.box(Vector3.new(2, 2, 2)), 1)
		local out, r = S.unsubdivide(source, 1, { maxDeviation = 1 })
		assert(r.complete and r.finalFaces == 6 and count(out.vertices) == 8 and out:validate().closed)
		assert(r.errorBound > 0.44 and r.errorBound < 0.45)
		for id, p in out.vertices do
			assert(source.vertices[id] == p and math.abs(p.X) < 1)
		end
		local unchanged, q = S.unsubdivide(source, 1, { maxDeviation = 0 })
		assert(not q.complete and q.finalFaces == 24 and count(unchanged.vertices) == count(source.vertices))
	end)
	test("The whole-patch error includes intersections of different triangulation diagonals", function()
		local m = grid(2, function(x, y)
			return math.max(0, (x + y) / 2 - 1)
		end)
		local f = m.faces[3]
		table.insert(f.vertices, table.remove(f.vertices, 1))
		table.insert(f.corners, table.remove(f.corners, 1))
		local _, r = S.unsubdivide(m, 1, { maxDeviation = 0.3, minimumNormalDot = 0 })
		assert(r.complete and r.errorBound >= 0.25 and r.errorBound < 0.250000000001)
		local _, q = S.unsubdivide(m, 1, { maxDeviation = 0.1, minimumNormalDot = 0 })
		assert(not q.complete and q.finalFaces == 4)
	end)
	test(
		"Eighty exact Fraction overlays bound geometry and classify positive-area triangle overlaps",
		function()
			local B = require(script.Parent.UnsubdivideBound)
			local T = require(script.Parent.UnsubdivideTopology)
			local U = require(script.Parent.Util)
			for _, fixture in require(script.Parent.UnsubdivideFixtures) do
				local m = fixtureMesh(fixture)
				local phases = T.component(
					m,
					m:topology(),
					U.keys(m.vertices),
					U.keys(m.faces),
					function() end
				)
				assert(#phases == 1)
				local phase = phases[1]
				local group = phase.groups[1]
				local triangles = {}
				for fid in m.faces do
					triangles[fid] = m:faceTriangles(fid)
				end
				local target = E.Mesh.new()
				target.vertices = table.clone(m.vertices)
				target:addFace(group.loop)
				local bound, chart = B.patch(
					m,
					group,
					phase,
					triangles,
					target:faceTriangles(1),
					function() end
				)
				assert(bound >= fixture.upper and bound <= fixture.upper * (1 + 1e-12))
				for i, a in chart.source do
					for j, b in chart.target do
						assert(B.overlaps(a, b) == fixture.overlaps[i][j])
					end
				end
			end
		end
	)
	test("Whole connected-component selection retains unselected meshes", function()
		local a = grid(2)
		local b = E.Deform.transform(grid(2), CFrame.new(5, 0, 0))
		local m = E.Topology.join({ a, b })
		local selected = {}
		for fid = 1, 4 do
			selected[fid] = true
		end
		local out, r = S.unsubdivide(m, 1, { faces = selected, maxDeviation = 0 })
		assert(r.complete and r.finalFaces == 5 and out:validate().valid)
		for fid = 5, 8 do
			assert(table.concat(out.faces[fid].vertices, ",") == table.concat(m.faces[fid].vertices, ","))
		end
		local unchanged, q = S.unsubdivide(a, 1, { faces = { [1] = true }, maxDeviation = 0 })
		assert(not q.complete and q.finalFaces == 4 and q.steps[1].components[1].reason == "partialComponent")
		assert(E.IO.encode(unchanged) == E.IO.encode(a))
	end)
	test("Recognized disconnected components can return a diagnostic partial result", function()
		local m = E.Topology.join({ grid(3), E.Deform.transform(grid(2), CFrame.new(5, 0, 0)) })
		local out, r = S.unsubdivide(m, 1, { maxDeviation = 0 })
		assert(not r.complete and r.finalFaces == 10 and r.appliedLevels == 1 and r.iterationsCompleted == 0)
		assert(
			r.steps[1].acceptedComponents == 1 and r.steps[1].rejectedComponents == 1 and out:validate().valid
		)
		assert(not pcall(S.unsubdivide, m, 1, { maxDeviation = 0, requireComplete = true }))
	end)
	test("Pins and geometric features constrain phase acceptance", function()
		local m, id = grid(2)
		local _, pin = S.unsubdivide(m, 1, { keepVertices = { [id(1, 1)] = true }, maxDeviation = 0 })
		assert(not pin.complete and pin.steps[1].components[1].rejections.keepVertex == 1)
		m = E.Attributes.create(m, "sharp_edge", "edge", "boolean", false)
		m.attributes.sharp_edge.values[id(0, 1) .. ":" .. id(1, 1)] = true
		local _, feature = S.unsubdivide(m, 1, { maxDeviation = 0 })
		assert(not feature.complete and feature.steps[1].components[1].rejections.feature == 1)
		local _, ignored = S.unsubdivide(m, 1, { maxDeviation = 0, preserveSeams = false })
		assert(ignored.complete)
		local vertex = E.Attributes.create(grid(2), "subdivision_vertex_sharpness", "vertex", "number", 0)
		vertex.attributes.subdivision_vertex_sharpness.values[id(1, 1)] = 10
		local _, v = S.unsubdivide(vertex, 1, { maxDeviation = 0 })
		assert(not v.complete and v.steps[1].components[1].rejections.feature == 1)
	end)
	test("UV and typed face/corner discontinuities are protected", function()
		for _, kind in { "uv", "face", "corner" } do
			local m = grid(2)
			if kind == "uv" then
				m.faces[1].corners[3].uv += Vector2.new(1, 0)
			else
				m = E.Attributes.create(m, "seam", kind, "number", 0)
				m.attributes.seam.values[kind == "face" and 1 or "1:3"] = 1
			end
			local _, r = S.unsubdivide(m, 1, { maxDeviation = 0 })
			assert(not r.complete and r.steps[1].components[1].rejections.seam == 1)
		end
	end)
	test("New coarse edges retain constant features and reject changing edge data", function()
		local m, id = grid(2)
		m = E.Attributes.create(m, "sharp_edge", "edge", "number", 0)
		m.attributes.sharp_edge.values[id(0, 0) .. ":" .. id(1, 0)] = 2
		m.attributes.sharp_edge.values[id(1, 0) .. ":" .. id(2, 0)] = 2
		local out, r = S.unsubdivide(m, 1, { maxDeviation = 0 })
		assert(r.complete and out.attributes.sharp_edge.values[id(0, 0) .. ":" .. id(2, 0)] == 2)
		m.attributes.sharp_edge.values[id(1, 0) .. ":" .. id(2, 0)] = 4
		local _, q = S.unsubdivide(m, 1, { maxDeviation = 0 })
		assert(not q.complete and q.steps[1].components[1].rejections.edgeData == 1)
		local merged, b = S.unsubdivide(m, 1, { maxDeviation = 0, preserveSeams = false })
		assert(b.complete and merged.attributes.sharp_edge.values[id(0, 0) .. ":" .. id(2, 0)] == 3)
	end)
	test("Source data and corner correspondence survive an allowed field approximation", function()
		local m = grid(2)
		m = E.Attributes.create(m, "density", "face", "number", 0)
		for fid = 1, 4 do
			m.attributes.density.values[fid] = fid
		end
		m = E.Attributes.create(m, "sample", "vertex", "number", 0.2)
		m = E.Attributes.create(m, "stamp", "corner", "number", 7)
		m.groups.sample = { [1] = 0.6 }
		m.weights[1] = { Bone = 1 }
		local before = E.IO.encode(m)
		local out, r = S.unsubdivide(m, 1, { maxDeviation = 0, preserveSeams = false })
		assert(r.complete and out.attributes.density.values[1] == 2.5)
		assert(out.groups.sample[1] == 0.6 and out.weights[1].Bone == 1)
		for _, c in out.faces[1].corners do
			assert(c.uv and c.normal)
		end
		assert(E.IO.encode(m) == before)
	end)
	test("A cumulative deviation budget applies across requested levels", function()
		local m = grid(4, function(x, y)
			return 0.01 * (x * x + y * y)
		end)
		local _, r = S.unsubdivide(m, 2, { maxDeviation = 1 })
		assert(r.complete and #r.steps == 2 and r.errorBound >= r.steps[1].errorBound + r.steps[2].errorBound)
		local limit = (r.steps[1].errorBound + r.errorBound) / 2
		local partial, q = S.unsubdivide(m, 2, { maxDeviation = limit })
		assert(not q.complete and q.iterationsCompleted == 1 and q.appliedLevels == 1 and q.finalFaces == 4)
		assert(q.errorBound <= limit and partial:validate().valid)
	end)
	test("Callbacks see a detached source and option snapshot", function()
		local m = grid(4)
		local options = { maxDeviation = 0 }
		options.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[1] = Vector3.new(100, 100, 100)
				options.maxDeviation = -1
			end
		end
		local out, r = S.unsubdivide(m, 2, options)
		assert(r.complete and r.errorBound == 0 and out.vertices[1] == Vector3.zero)
	end)
	test("Cancellation and allocation/work limits leave the caller unchanged", function()
		local m = grid(4)
		local before = E.IO.encode(m)
		for _, options in
			{
				{ maxWork = 1 },
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(s)
						if s.stage == "component" then
							error("stop")
						end
					end,
				},
			}
		do
			assert(not pcall(S.unsubdivide, m, 1, options))
			assert(E.IO.encode(m) == before)
		end
	end)
	test("Invalid arguments, topology and source intersections reject", function()
		local m = grid(2)
		for _, n in { -1, 0.5, 17 } do
			assert(not pcall(S.unsubdivide, m, n))
		end
		for _, options in
			{
				{ maxDeviation = -1 },
				{ minimumNormalDot = 2 },
				{ faces = { [99] = true } },
				{ keepVertices = { [99] = true } },
				{ preserveSeams = 1 },
				{ seamAttributes = { "missing" } },
			}
		do
			assert(not pcall(S.unsubdivide, m, 1, options))
		end
		local bad = m:clone()
		bad.faces[1].vertices[2] = bad.faces[1].vertices[1]
		assert(not pcall(S.unsubdivide, bad, 1))
		assert(not pcall(S.unsubdivide, E.Topology.join({ m, m }), 1))
	end)
	test("Zero iterations and an empty selection are geometric identities", function()
		local m = grid(2)
		local before = E.IO.encode(m)
		local out, r = S.unsubdivide(m, 0)
		assert(r.complete and E.IO.encode(out) == before and r.appliedLevels == 0)
		local empty, q = S.unsubdivide(m, 2, { faces = {} })
		assert(q.complete and q.reason == "emptySelection" and E.IO.encode(empty) == before)
	end)
	test("A new collision introduced by coarsening makes completion false", function()
		local m = grid(2, function(x, y)
			return x == 1 and y == 1 and 0.2 or 0
		end)
		local ids = {}
		for _, p in { Vector3.new(0.9, 1, -0.02), Vector3.new(1.1, 1, -0.02), Vector3.new(1, 1, 0.08) } do
			table.insert(ids, m:addVertex(p))
		end
		m:addFace(ids)
		local out, r = S.unsubdivide(
			m,
			1,
			{ faces = { [1] = true, [2] = true, [3] = true, [4] = true }, maxDeviation = 0.3 }
		)
		assert(
			r.finalFaces == 2
				and out:validate().valid
				and not r.complete
				and r.reason == "outputIntersections"
		)
		assert(r.inputIntersections.intersectionFree and not r.outputIntersections.intersectionFree)
	end)
	test("Closed periodic grids expose four phases and honor retained-vertex pins", function()
		local m = E.Mesh.new()
		local n = 6
		local function id(i, j)
			return (i % n) * n + (j % n) + 1
		end
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				local t, p = 2 * math.pi * i / n, 2 * math.pi * j / n
				m:addVertex(
					Vector3.new((3 + math.cos(p)) * math.cos(t), (3 + math.cos(p)) * math.sin(t), math.sin(p))
				)
			end
		end
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				m:addFace({ id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) })
			end
		end
		local out, r = S.unsubdivide(m, 1, { maxDeviation = 3, keepVertices = { [1] = true } })
		assert(r.complete and r.finalFaces == 9 and out:validate().closed and out.vertices[1])
		local status = r.steps[1].components[1]
		assert(status.recognizedPhases == 4 and status.rejections.keepVertex == 3)
		local _, q = S.unsubdivide(m, 1, { maxDeviation = 3, keepVertices = { [1] = true, [2] = true } })
		assert(not q.complete and q.steps[1].components[1].rejections.keepVertex == 4)
		local _, a = S.unsubdivide(m, 1, { maxDeviation = 3 })
		local _, b = S.unsubdivide(m, 1, { maxDeviation = 3 })
		assert(
			a.complete
				and b.complete
				and table.concat(a.steps[1].components[1].retainedVertices, ",")
					== table.concat(b.steps[1].components[1].retainedVertices, ",")
		)
	end)
	test("Rigid transforms, scales and sparse IDs retain the recognized grid", function()
		local original = grid(4)
		local frame = CFrame.new(100, -20, 30) * CFrame.Angles(0.3, -0.2, 0.1)
		for _, scale in { 0.01, 1000 } do
			local m = E.Mesh.new()
			for id, p in original.vertices do
				m.vertices[13 * id + 9] = frame:PointToWorldSpace(p * scale)
				m.nextVertex = math.max(m.nextVertex, 13 * id + 10)
			end
			for fid, f in original.faces do
				local ids = {}
				for i, id in f.vertices do
					ids[i] = 13 * id + 9
				end
				m.faces[7 * fid + 11] =
					{ vertices = ids, corners = table.clone(f.corners), material = f.material }
				m.nextFace = math.max(m.nextFace, 7 * fid + 12)
			end
			local out, r = S.unsubdivide(m, 2, { maxDeviation = math.max(1e-5, 1e-6 * scale) })
			assert(r.complete and r.finalFaces == 1 and count(out.vertices) == 4)
			for id, p in out.vertices do
				assert(m.vertices[id] == p)
			end
			assert(out:validate().valid)
		end
	end)
	test("Large common translations cancel exactly in a linear native grid", function()
		local m = grid(4, function(x, y)
			return x + 2 * y
		end)
		for id, p in m.vertices do
			m.vertices[id] = p * 8 + Vector3.new(2 ^ 20, -2 ^ 20, 2 ^ 20)
		end
		local _, r = S.unsubdivide(m, 2, { maxDeviation = 0 })
		assert(r.complete and r.errorBound == 0)
		local collapsed = grid(2)
		for id, p in collapsed.vertices do
			collapsed.vertices[id] = p + Vector3.new(1e9, 1e9, 1e9)
		end
		assert(not pcall(S.unsubdivide, collapsed, 1))
	end)
	test("Coarse cages retain UVs and finite normals through native conversion", function()
		local result = require(script.Parent.Examples.CoarseCage)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid and restored:validate().closed and count(restored.faces) == 48)
			for _, face in restored.faces do
				for _, c in face.corners do
					assert(c.uv and c.normal and math.abs(c.normal.Magnitude - 1) < 1e-5)
					assert(c.uv.X >= 0 and c.uv.X <= 1 and c.uv.Y >= 0 and c.uv.Y <= 1)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
