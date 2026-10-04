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
	local function grid(n, curved, symmetric)
		n = n or 4
		local m = E.Mesh.new()
		local function id(i, j)
			return j * (n + 1) + i + 1
		end
		for j = 0, n do
			for i = 0, n do
				local x, y = i - n / 2, j - n / 2
				m:addVertex(Vector3.new(x, y, curved and (0.15 * x * x + 0.25 * y * y + 0.07 * x * y) or 0))
			end
		end
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				local a, b, c, d = id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1)
				if symmetric and i >= n / 2 then
					m:addFace({ a, b, d })
					m:addFace({ b, c, d })
				else
					m:addFace({ a, b, c })
					m:addFace({ a, c, d })
				end
			end
		end
		return m, id
	end
	local function reduce(m, target, options)
		return E.Simplify.decimate(m, target, options)
	end
	local fast = { checkIntersections = false, preserveSeams = false, preserveBoundary = false }
	local function opts(extra)
		local out = table.clone(fast)
		for k, v in extra or {} do
			out[k] = v
		end
		return out
	end
	local function mirrored(m, axis, origin)
		local out = m:clone()
		for id, p in out.vertices do
			out.vertices[id] = Vector3.new(
				axis == "X" and 2 * origin - p.X or p.X,
				axis == "Y" and 2 * origin - p.Y or p.Y,
				axis == "Z" and 2 * origin - p.Z or p.Z
			)
		end
		return E.Topology.reverse(out)
	end
	test("Segment quadrics match an independent analytic quadratic and reversed parameter", function()
		local Q = require(script.Parent.CollapseQuadric)
		local q = Q.zero()
		for _, p in { { { 1, 0, 0 }, -0.25, 3 }, { { 0, 1, 0 }, -0.75, 2 }, { { 0, 0, 1 }, 0.5, 1 } } do
			q = Q.add(q, Q.plane(p[1], p[2], p[3]))
		end
		local _, t, cost = Q.segment(q, { 0, 0, 0 }, { 1, 1, 1 })
		near(t, 7 / 24, 1e-14)
		near(cost, 101 / 96, 1e-14)
		local _, u = Q.segment(q, { 1, 1, 1 }, { 0, 0, 0 })
		near(u, 1 - t, 1e-14)
		local flat = Q.plane({ 0, 0, 1 }, 0, 1)
		local _, middle = Q.segment(flat, { 0, 0, 0 }, { 1, 2, 0 })
		near(middle, 0.5)
		local _, endpoint = Q.segment(flat, { 0, 0, 1 }, { 0, 0, 2 })
		near(endpoint, 0)
	end)
	test("Outward vertex distances enclose 64 independent high precision references", function()
		local B = require(script.Parent.CollapseBound)
		for _, f in require(script.Parent.CollapseBoundFixtures) do
			local bound = B.distance(f.a, f.b)
			assert(bound >= f.upper, "Distance underestimates reference")
			assert(bound <= f.upper * (1 + 2e-14), "Distance enclosure is unexpectedly wide")
		end
	end)
	test("Sphere targets preserve closed topology and expose complete correspondence", function()
		local m = E.Primitives.sphere(1, 12, 6)
		local before = E.IO.encode(m)
		local out, r = reduce(m, nil, { ratio = 2 / 3, maxIterations = 100 })
		assert(r.complete and r.targetReached and r.collapses > 0 and out:validate().closed)
		assert(r.finalFaces <= r.targetFaces and r.errorBound > 0 and r.inputIntersections.intersectionFree)
		assert(math.abs(out:volume() / m:volume() - 1) < 0.6 and E.IO.encode(m) == before)
		for id in m.vertices do
			assert(out.vertices[r.sourceVertexToOutput[id]])
		end
		for fid in out.faces do
			assert(m.faces[r.outputFaceToSource[fid]])
		end
	end)
	test("Affine triangle images cover output and satisfy sampled two sided correspondence bounds", function()
		local m = grid(5, true)
		local out, r = reduce(m, 22, opts())
		assert(r.complete)
		local top = E.Connectivity.index(out)
		local source = E.Topology.triangulate(m)
		local covered = {}
		local maximum = 0
		for fid, f in source.faces do
			local unique = {}
			for _, id in f.vertices do
				unique[r.sourceVertexToOutput[id]] = true
			end
			local ids = {}
			for id in unique do
				table.insert(ids, id)
			end
			if #ids == 3 then
				local image = assert(out.faces[fid])
				for _, id in image.vertices do
					assert(unique[id])
				end
				covered[fid] = true
			elseif #ids == 2 then
				assert(top.edges[math.min(ids[1], ids[2]) .. ":" .. math.max(ids[1], ids[2])])
			else
				assert(#top.vertices[ids[1]].corners > 0)
			end
			for i = 0, 8 do
				for j = 0, 8 - i do
					local weights = { i / 8, j / 8, 1 - (i + j) / 8 }
					local a, b = { 0, 0, 0 }, { 0, 0, 0 }
					for k, id in f.vertices do
						local p, q = m.vertices[id], out.vertices[r.sourceVertexToOutput[id]]
						for axis, pair in { { p.X, q.X }, { p.Y, q.Y }, { p.Z, q.Z } } do
							a[axis] += pair[1] * weights[k]
							b[axis] += pair[2] * weights[k]
						end
					end
					local d = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
					assert(d <= r.errorBound * (1 + 1e-14))
					maximum = math.max(maximum, d)
				end
			end
		end
		for fid in out.faces do
			assert(covered[fid])
		end
		near(maximum, r.errorBound, 1e-12)
	end)
	test("A zero deviation budget refuses movement even when planar quadric cost is zero", function()
		local m = grid(4)
		local out, r = reduce(m, 8, opts({ maxDeviation = 0 }))
		assert(not r.complete and r.collapses == 0 and r.errorBound == 0 and r.rejections.deviation > 0)
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
		local _, s = reduce(m, 8, opts())
		assert(s.complete and s.errorBound > 0)
		for _, step in s.collapseLog do
			assert(step.quadricError == 0)
		end
	end)
	test("Finite deviation budgets are checked against original native vertices after every step", function()
		local m = grid(5, true)
		local out, r = reduce(m, 4, opts({ maxDeviation = 1.1 }))
		assert(r.collapses > 0 and r.errorBound <= 1.1)
		for _, step in r.collapseLog do
			assert(step.errorBound <= 1.1)
		end
		for id, p in m.vertices do
			local q = out.vertices[r.sourceVertexToOutput[id]]
			assert(math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 + (p.Z - q.Z) ^ 2) <= r.errorBound)
		end
	end)
	test("Pins retain exact native positions and IDs while accepting neighboring collapses", function()
		local m, id = grid(5, true)
		local pins = { [id(2, 2)] = true, [id(4, 3)] = true }
		local out, r = reduce(m, 16, opts({ pins = pins }))
		assert(r.collapses > 0)
		for v in pins do
			assert(out.vertices[v] == m.vertices[v] and r.sourceVertexToOutput[v] == v)
		end
	end)
	test("Masks groups attributes and fields multiply and zero values fix vertices", function()
		local m, id = grid(5, true)
		local mask, group, values = {}, {}, {}
		for v, p in m.vertices do
			mask[v] = p.X < 0 and 0 or 1
			group[v] = p.Y < 0 and 0 or 0.5
			values[v] = v == id(3, 3) and 0 or 1
		end
		m.groups.reduce = group
		m = E.Attributes.set(E.Attributes.create(m, "reduce", "vertex", "number", 1), "reduce", values)
		local out, r = reduce(
			m,
			8,
			opts({
				mask = mask,
				group = "reduce",
				attribute = "reduce",
				maskField = function(_, v)
					return v == id(4, 4) and 0 or 1
				end,
			})
		)
		assert(r.collapses > 0)
		for v, p in m.vertices do
			if mask[v] == 0 or group[v] == 0 or values[v] == 0 or v == id(4, 4) then
				assert(out.vertices[v] == p)
			end
		end
	end)
	test("Face selections preserve every unselected triangle and its vertices", function()
		local m = grid(5, true)
		local selected, unchanged = {}, {}
		for fid, f in m.faces do
			selected[fid] = m.vertices[f.vertices[1]].X >= 0
			if not selected[fid] then
				for _, id in f.vertices do
					unchanged[id] = true
				end
			end
		end
		local out, r = reduce(m, 12, opts({ faces = selected }))
		assert(r.collapses > 0)
		for id in unchanged do
			assert(out.vertices[id] == m.vertices[id])
		end
		for fid, f in m.faces do
			if not selected[fid] then
				local q = assert(out.faces[fid])
				for i, id in f.vertices do
					assert(q.vertices[i] == id)
				end
			end
		end
	end)
	test("Boundary protection is the default and opt in boundary collapse preserves the loop", function()
		local m = grid(5, true)
		local a, r = reduce(m, 20, { preserveSeams = false, checkIntersections = false })
		local before = E.Connectivity.index(m)
		for _, edge in before.edges do
			if #edge.faces == 1 then
				assert(a.vertices[edge.a] == m.vertices[edge.a] and a.vertices[edge.b] == m.vertices[edge.b])
			end
		end
		local b, s = reduce(m, 12, opts())
		local analysis = E.Connectivity.analyze(b)
		assert(r.collapses > 0 and s.complete and analysis.valid and #analysis.boundaryLoops == 1)
		assert(analysis.components[1].eulerCharacteristic == 1)
	end)
	test("Endpoint and midpoint controls expose the actual interpolation parameter", function()
		local m = grid(4, true)
		for _, placement in { "endpoints", "midpoint", "segment" } do
			local _, r = reduce(m, 20, opts({ placement = placement, maxIterations = 5 }))
			assert(r.collapses > 0)
			for _, step in r.collapseLog do
				for _, op in step.operations do
					assert(op.t >= 0 and op.t <= 1)
					if placement == "endpoints" then
						assert(op.t == 0)
					elseif placement == "midpoint" then
						assert(op.t == 0.5)
					end
				end
			end
		end
	end)
	test("Disconnected mirrored components collapse in atomic exact reflection pairs", function()
		local a = grid(3, true)
		for id, p in a.vertices do
			a.vertices[id] = p + Vector3.new(-4, 0, 0)
		end
		local m = E.Topology.join({ a, mirrored(a, "X", 0) })
		local out, r = reduce(m, 16, opts({ symmetry = { axis = "X" } }))
		assert(r.complete and r.collapses % 2 == 0 and E.Connectivity.analyze(out).components[2])
		for _, step in r.collapseLog do
			assert(step.kind == "pair" and #step.operations == 2)
		end
		local positions = {}
		for _, p in out.vertices do
			positions[tostring(p)] = true
		end
		for _, p in out.vertices do
			assert(positions[tostring(Vector3.new(-p.X, p.Y, p.Z))])
		end
	end)
	test("A symmetric connected grid supports paired and shared plane collapses", function()
		local m = grid(4, false, true)
		local out, r = reduce(m, 8, opts({ symmetry = { axis = "X" } }))
		assert(r.complete and out:validate().valid)
		local S = require(script.Parent.CollapseSymmetry)
		assert(S.build(out, { axis = "X" }, function() end))
	end)
	test("Asymmetric triangulation ambiguous vertices and nonrepresentable planes are rejected", function()
		local m = grid(4)
		assert(not pcall(reduce, m, 8, opts({ symmetry = { axis = "X" } })))
		local n = grid(4, false, true)
		n:addVertex(n.vertices[1])
		assert(not pcall(reduce, n, 8, opts({ symmetry = { axis = "X" } })))
		assert(not pcall(reduce, grid(4, false, true), 8, opts({ symmetry = { axis = "X", origin = 0.1 } })))
	end)
	test("Topology type and component coverage prevent deleting a triangle or closed component", function()
		local m = E.Mesh.new()
		m:addVertex(Vector3.zero)
		m:addVertex(Vector3.xAxis)
		m:addVertex(Vector3.yAxis)
		m:addFace({ 1, 2, 3 })
		local out, r = reduce(m, 0, opts())
		assert(not r.complete and r.reason == "constraints" and count(out.faces) == 1)
		local boxes = E.Topology.join({
			E.Primitives.box(),
			E.Deform.transform(E.Primitives.box(), CFrame.new(4, 0, 0)),
		})
		local b, s = reduce(boxes, 0, opts())
		local c = E.Connectivity.analyze(b)
		assert(not s.complete and c.closed and #c.components == 2)
		for _, component in c.components do
			assert(component.eulerCharacteristic == 2)
		end
	end)
	test("Soft iteration limits return valid partial results and strict completion throws", function()
		local m = grid(4, true)
		local _, zero = reduce(m, 4, opts({ maxIterations = 0 }))
		local out, one = reduce(m, 4, opts({ maxIterations = 1 }))
		assert(zero.collapses == 0 and not zero.complete and zero.reason == "iterations")
		assert(one.collapses == 1 and one.applied and not one.complete and out:validate().valid)
		assert(not pcall(reduce, m, 4, opts({ maxIterations = 0, requireComplete = true })))
	end)
	test("Snapshots isolate source selections and nested options before user callbacks", function()
		local m, id = grid(4, true)
		local pin = id(2, 2)
		local expected, er = reduce(m, 12, opts({ pins = { [pin] = true }, maxIterations = 4 }))
		local settings = opts({ pins = { [pin] = true }, maxIterations = 4 })
		settings.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[1] = Vector3.new(100, 200, 300)
				m.faces[1] = nil
				settings.pins[pin] = false
				settings.maxIterations = 0
			end
		end
		local out, r = reduce(m, 12, settings)
		assert(
			E.IO.encode(out) == E.IO.encode(expected)
				and r.collapses == er.collapses
				and r.originalFaces == 32
		)
	end)
	test("Empty meshes and loose vertices preserve source records", function()
		local empty = E.Mesh.new()
		empty:addVertex(Vector3.new(4, 5, 6))
		local out, r = reduce(empty, 0, opts())
		assert(r.complete and out.vertices[1] == empty.vertices[1] and r.sourceVertexToOutput[1] == 1)
		local m = grid(4, true)
		local loose = m:addVertex(Vector3.new(99, 88, 77))
		local n, s = reduce(m, 12, opts())
		assert(
			s.complete and n.vertices[loose] == m.vertices[loose] and s.sourceVertexToOutput[loose] == loose
		)
	end)
	test("Geometry scales and large translations retain valid native bounds", function()
		for _, scale in { 2 ^ -40, 1, 2 ^ 40 } do
			local m = grid(4, true)
			for id, p in m.vertices do
				m.vertices[id] = Vector3.new(p.X * scale, p.Y * scale, p.Z * scale)
			end
			local out, r = reduce(m, 16, opts())
			assert(r.complete and out:validate({ minimumFaceArea = 0 }).valid and r.errorBound > 0)
		end
		local m = grid(4, true)
		for id, p in m.vertices do
			m.vertices[id] = p + Vector3.new(2 ^ 20, -2 ^ 20, 2 ^ 20)
		end
		local out, r = reduce(m, 16, opts())
		assert(r.collapses > 0 and out:validate().valid)
	end)
	test("Input overlap and incomplete scans return an unchanged source with an explicit failure", function()
		local m = E.Topology.join({
			E.Primitives.box(),
			E.Deform.transform(E.Primitives.box(), CFrame.new(0.5, 0.5, 0.5)),
		})
		local before = E.IO.encode(m)
		local out, r = reduce(m, 4, { preserveSeams = false })
		assert(
			not r.complete
				and not r.applied
				and r.reason == "inputIntersections"
				and E.IO.encode(out) == before
		)
		local source = grid(4)
		local unchanged, s = reduce(source, 8, { intersectionOptions = { maxTests = 1 } })
		assert(not s.complete and E.IO.encode(source) == E.IO.encode(unchanged))
	end)
	test("Allocation work and cancellation failures leave caller data unchanged", function()
		local m = grid(4, true)
		local before = E.IO.encode(m)
		for _, extra in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxTriangles = 1 },
				{ maxCorners = 1 },
				{ maxFaceVertices = 2 },
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
			assert(not pcall(reduce, m, 8, opts(extra)))
			assert(E.IO.encode(m) == before)
		end
		local calls = 0
		assert(not pcall(
			reduce,
			m,
			8,
			opts({
				cancelled = function()
					calls += 1
					return calls > 100
				end,
			})
		))
		assert(calls > 100 and E.IO.encode(m) == before)
	end)
	test("Invalid options selections nonfinite values and topology fail without mutation", function()
		local m = grid(4)
		for _, extra in
			{
				{ pins = false },
				{ pins = { [999] = true } },
				{ pins = { [1] = 0.5 } },
				{ mask = { [1] = 2 } },
				{ faces = { [999] = true } },
				{ maxIterations = -1 },
				{ placement = false },
				{ placement = "free" },
				{ minimumNormalDot = 2 },
				{ weightFactor = -1 },
				{ maxDeviation = -1 },
				{ maxError = 0 / 0 },
				{ preserveBoundary = 0 },
				{ symmetry = { axis = "Q" } },
				{ ratio = 0.5 },
			}
		do
			assert(not pcall(reduce, m, 8, opts(extra)))
		end
		for _, ratio in { -0.1, 1.1, 0 / 0 } do
			assert(not pcall(reduce, m, nil, opts({ ratio = ratio })))
		end
		assert(not pcall(reduce, m, nil, opts()))
		local invalid = m:clone()
		invalid:addFace(invalid.faces[1].vertices)
		assert(not pcall(reduce, invalid, 8, opts()))
	end)

	test("New output intersections roll back every accepted collapse and source data", function()
		local m = E.Primitives.grid(4, 4, Vector2.new(4, 4))
		for id, p in m.vertices do
			m.vertices[id] = Vector3.new(p.X, p.Z, 0.3 * (p.X * p.X + p.Z * p.Z))
		end
		-- This small vertical triangle intersects the first reduced chord, above the original panel.
		local p = Vector3.new(-2 / 3, 0.17803128, 0.34659064)
		local wall = E.Mesh.new()
		wall:addVertex(p + Vector3.new(-0.01, 0, -0.01))
		wall:addVertex(p + Vector3.new(0.01, 0, -0.01))
		wall:addVertex(p + Vector3.new(0, 0, 0.01))
		wall:addFace({ 1, 2, 3 })
		local source = E.Topology.join({ m, wall })
		local faces = {}
		for fid in m.faces do
			faces[fid] = true
		end
		local before = E.IO.encode(source)
		local out, r = reduce(source, 5, { faces = faces, preserveSeams = false, maxIterations = 1 })
		assert(
			r.reason == "outputIntersections"
				and r.candidateCollapses == 1
				and r.collapses == 0
				and not r.applied
		)
		assert(r.inputIntersections.intersectionFree and not r.outputIntersections.intersectionFree)
		assert(E.IO.encode(out) == before and E.IO.encode(source) == before)
	end)
	test("Sparse source IDs and loose data survive typed transfer and representative mapping", function()
		local m = grid(4, true)
		local shifted = m:clone()
		shifted.vertices = {}
		shifted.nextVertex = 1000
		for id, p in m.vertices do
			shifted.vertices[id * 7 + 100] = p
		end
		for _, f in shifted.faces do
			for i, id in f.vertices do
				f.vertices[i] = id * 7 + 100
			end
		end
		local out, r = reduce(shifted, 16, opts())
		assert(r.complete)
		for id in shifted.vertices do
			assert(out.vertices[r.sourceVertexToOutput[id]])
		end
		for id in out.vertices do
			assert(shifted.vertices[id])
		end
	end)
	test("Separate component normalization handles widely different geometric scales", function()
		local tiny, large = grid(4, true), grid(4, true)
		for id, p in tiny.vertices do
			tiny.vertices[id] = p * 2 ^ -40
		end
		for id, p in large.vertices do
			large.vertices[id] = (p + Vector3.new(8, 0, 0)) * 2 ^ 40
		end
		local m = E.Topology.join({ tiny, large })
		local selected = {}
		for fid in tiny.faces do
			selected[fid] = true
		end
		local out, r = reduce(m, 48, opts({ faces = selected }))
		assert(r.complete and r.errorBound < 2 ^ -35 and E.Connectivity.analyze(out).components[2])
		for id, p in m.vertices do
			if id > count(tiny.vertices) then
				assert(out.vertices[id] == p)
			end
		end
	end)
	test("All reflection axes support exact nonzero origins", function()
		for _, axis in { "X", "Y", "Z" } do
			local a = grid(3)
			local shift = axis == "X" and Vector3.new(-4, 0, 0)
				or axis == "Y" and Vector3.new(0, -4, 0)
				or Vector3.new(0, 0, -4)
			for id, p in a.vertices do
				a.vertices[id] = p + shift
			end
			local source = E.Topology.join({ a, mirrored(a, axis, 3.25) })
			local out, r = reduce(source, 20, opts({ symmetry = { axis = axis, origin = 3.25 } }))
			assert(
				r.complete
					and require(script.Parent.CollapseSymmetry).build(
						out,
						{ axis = axis, origin = 3.25 },
						function() end
					)
			)
		end
	end)
	test("A reduced symmetric panel survives native position UV and normal conversion", function()
		local result = require(script.Parent.Examples.ReducedPanel)(E)
		assert(result.reduction.complete and result.reduction.errorBound <= 2)
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

	test("Shared plane symmetry absorbs both counterparts into one unchanged survivor", function()
		local m, id = grid(4, false, true)
		local center, left, right = id(2, 2), id(1, 2), id(3, 2)
		local map = {}
		for v in m.vertices do
			map[v] = v == center and 1 or v == left and 2 or v == right and 3 or 200 + v
		end
		local source = m:clone()
		source.vertices = {}
		local pins = {}
		for v, p in m.vertices do
			source.vertices[map[v]] = p
			pins[map[v]] = map[v] ~= 2 and map[v] ~= 3
		end
		for _, f in source.faces do
			for i, v in f.vertices do
				f.vertices[i] = map[v]
			end
		end
		local out, r = reduce(source, 28, opts({ symmetry = { axis = "X" }, pins = pins, maxIterations = 1 }))
		assert(r.complete and r.collapseLog[1].kind == "shared" and r.collapses == 2)
		assert(out.vertices[1] == source.vertices[1] and not out.vertices[2] and not out.vertices[3])
	end)
	test("A self reflected crossing edge collapses onto its plane and respects exact pins", function()
		local m = E.Mesh.new()
		for _, p in { { -1, 0 }, { 1, 0 }, { 0, 1 }, { 0, -1 }, { -3, 0 }, { 3, 0 }, { 0, 3 }, { 0, -3 } } do
			m:addVertex(Vector3.new(p[1], p[2], 0))
		end
		for _, f in
			{
				{ 1, 2, 3 },
				{ 2, 1, 4 },
				{ 5, 1, 3 },
				{ 5, 3, 7 },
				{ 6, 3, 2 },
				{ 6, 7, 3 },
				{ 5, 8, 4 },
				{
					5,
					4,
					1,
				},
				{
					6,
					4,
					8,
				},
				{
					6,
					2,
					4,
				},
			}
		do
			m:addFace(f)
		end
		local pins = {}
		for id in m.vertices do
			pins[id] = id > 2
		end
		local out, r = reduce(m, 8, opts({ symmetry = { axis = "X" }, pins = pins, maxIterations = 1 }))
		assert(r.complete and r.collapses == 1 and r.collapseLog[1].kind == "crossing")
		assert(out.vertices[1] == Vector3.zero and not out.vertices[2])
		pins[1] = true
		local blocked, s = reduce(m, 8, opts({ symmetry = { axis = "X" }, pins = pins, maxIterations = 1 }))
		assert(s.collapses == 0 and not s.complete)
		for id, p in m.vertices do
			assert(blocked.vertices[id] == p)
		end
	end)

	test("Subdivision vertex sharpness retains exact corner samples and typed feature values", function()
		local m, id = grid(4, true)
		local corner = id(2, 2)
		m = E.Attributes.set(
			E.Attributes.create(m, "subdivision_vertex_sharpness", "vertex", "number", 0),
			"subdivision_vertex_sharpness",
			{ [corner] = 3 }
		)
		local out, r = reduce(m, 16, opts({ preserveSeams = true }))
		assert(r.collapses > 0 and out.vertices[corner] == m.vertices[corner])
		assert(E.Attributes.get(out, "subdivision_vertex_sharpness", corner) == 3)
	end)
	report.success = report.failed == 0
	return report
end
