return function(E)
	local M, A = E.MeshEdit, E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, e)
		assert(math.abs(a - b) < (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function count(t)
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	local function allEdges(m)
		local s = {}
		for key, e in m:topology().edges do
			if #e.faces == 2 then
				s[key] = true
			end
		end
		return s
	end
	local function allVertices(m)
		local s = {}
		for id in m.vertices do
			s[id] = true
		end
		return s
	end
	local function area(m)
		local sum = 0
		for fid in m.faces do
			local _, a = m:faceNormal(fid)
			sum += a
		end
		return sum
	end
	local function prism()
		local m = E.Mesh.new()
		local points = {
			Vector2.new(0, 0),
			Vector2.new(3, 0),
			Vector2.new(3, 1),
			Vector2.new(1, 1),
			Vector2.new(1, 3),
			Vector2.new(0, 3),
		}
		for _, z in { 0, 2 } do
			for _, p in points do
				m:addVertex(Vector3.new(p.X, p.Y, z))
			end
		end
		m:addFace({ 6, 5, 4, 3, 2, 1 })
		m:addFace({ 7, 8, 9, 10, 11, 12 })
		for i = 1, 6 do
			local j = i % 6 + 1
			m:addFace({ i, j, j + 6, i + 6 })
		end
		return m:recalculateNormals(0)
	end
	test("Single and adjacent edge chamfers preserve closure and independent wedge volumes", function()
		local box = E.Primitives.box()
		local w = 0.2
		local one, r = M.bevelEdges(box, { ["1:2"] = true }, w)
		assert(one:validate().closed and count(one.faces) == 7 and #r.strips["1:2"] == 1)
		near(one:volume(), 8 - w * w)
		local two = M.bevelEdges(box, { ["1:2"] = true, ["1:4"] = true }, w)
		assert(two:validate().closed)
		near(two:volume(), 8 - 2 * w * w + w ^ 3 / 3)
		local three = M.bevelEdges(box, { ["1:2"] = true, ["1:4"] = true, ["1:5"] = true }, w)
		assert(three:validate().closed)
		near(three:volume(), 8 - 3 * w * w + 2 * w ^ 3 / 3)
	end)
	test("Whole cube chamfer produces the analytic edge-and-corner truncated volume", function()
		local box = E.Primitives.box()
		local w = 0.2
		local mesh, r = M.bevelEdges(box, allEdges(box), w)
		assert(
			mesh:validate().closed
				and count(mesh.vertices) == 24
				and count(mesh.faces) == 26
				and count(r.joins) == 8
		)
		near(mesh:volume(), 8 - 12 * w * w + 16 * w ^ 3 / 3)
	end)
	test("Circular edge profiles match independently integrated polygonal quarter circles", function()
		local source = E.Primitives.box()
		local w = 0.2
		for _, segments in { 2, 4, 8, 16 } do
			local mesh = M.bevelEdges(source, { ["1:2"] = true }, w, { segments = segments })
			assert(mesh:validate().closed)
			local removed = w * w - segments * w * w / 2 * math.sin(math.pi / (2 * segments))
			near(mesh:volume(), 8 - 2 * removed, 0.0001)
		end
	end)
	test("Rounded cube spherical junctions converge toward the analytic rounded-box volume", function()
		local source = E.Primitives.box()
		local w = 0.2
		local L = 2 - 2 * w
		local exact = L ^ 3 + 6 * L ^ 2 * w + 3 * math.pi * L * w * w + 4 * math.pi * w ^ 3 / 3
		local previous = math.huge
		for _, segments in { 2, 4, 8 } do
			local mesh, r = M.bevelEdges(source, allEdges(source), w, { segments = segments })
			local error = math.abs(mesh:volume() - exact)
			assert(mesh:validate().closed and count(r.sphericalJoins) == 8 and error < previous)
			previous = error
			for v, loops in r.joinLoops do
				local center = source.vertices[v] * 0.8
				for _, loop in loops do
					for _, id in loop do
						near((mesh.vertices[id] - center).Magnitude, w, 0.00001)
					end
				end
			end
		end
		assert(previous < 0.006)
	end)
	test(
		"Linear multi-segment profiles conform to terminal chords without changing chamfer volume",
		function()
			local source = E.Primitives.box()
			for _, selection in { { ["1:2"] = true }, { ["1:2"] = true, ["1:4"] = true }, allEdges(source) } do
				local flat = M.bevelEdges(source, selection, 0.2, { segments = 1 })
				local segmented = M.bevelEdges(source, selection, 0.2, { segments = 4, profile = "linear" })
				assert(segmented:validate().closed)
				near(segmented:volume(), flat:volume())
			end
		end
	)
	test("Custom monotone profiles and cutoff joins preserve closed manifold topology", function()
		local source = E.Primitives.box()
		local profile = { Vector2.new(1, 0), Vector2.new(0.2, 0.2), Vector2.new(0, 1) }
		local mesh, r = M.bevelEdges(
			source,
			allEdges(source),
			0.2,
			{ segments = 4, profile = profile, join = "cutoff", material = 7 }
		)
		assert(mesh:validate().closed and mesh:volume() > 7.5 and mesh:volume() < 8)
		for _, faces in r.strips do
			for _, fid in faces do
				assert(mesh.faces[fid].material == 7)
			end
		end
		for _, faces in r.joins do
			for _, fid in faces do
				assert(mesh.faces[fid].material == 7)
			end
		end
	end)
	test("Vertex chamfers remove exactly the expected tetrahedra", function()
		local source = E.Primitives.box()
		local w = 0.2
		local one = M.bevelVertices(source, { [1] = true }, w)
		assert(one:validate().closed)
		near(one:volume(), 8 - w ^ 3 / 6)
		local all = M.bevelVertices(source, allVertices(source), w)
		assert(all:validate().closed and count(all.faces) == 14)
		near(all:volume(), 8 - 8 * w ^ 3 / 6)
	end)
	test("Rounded vertex bevels triangulate non-star-shaped cap boundaries without gaps", function()
		local source = E.Primitives.box()
		local mesh, r = M.bevelVertices(source, allVertices(source), 0.2, { segments = 4 })
		assert(
			mesh:validate().closed
				and count(r.triangulatedJoins) == 8
				and mesh:volume() < 8
				and mesh:volume() > 7.98
		)
	end)
	test("Open planar vertex bevel retains the boundary and rounds its corners", function()
		local source = E.Primitives.grid(1, 1)
		local flat = M.bevelVertices(source, allVertices(source), 0.2)
		assert(flat:validate().valid and not flat:validate().closed and count(flat.faces) == 1)
		near(area(flat), 4 - 4 * 0.2 ^ 2 / 2)
		local rounded = M.bevelVertices(source, allVertices(source), 0.2, { segments = 4 })
		assert(
			rounded:validate().valid
				and count(rounded.faces) == 1
				and area(rounded) > area(flat)
				and area(rounded) < 4
		)
	end)
	test("Concave solid bevels handle reentrant edges and reflex polygon corners", function()
		local source = prism()
		assert(source:validate().closed)
		near(source:volume(), 10)
		local reentrant = M.bevelEdges(source, { ["4:10"] = true }, 0.1, { segments = 3 })
		assert(reentrant:validate().closed and reentrant:volume() > 10)
		local all = M.bevelEdges(source, allEdges(source), 0.1, { segments = 2 })
		assert(all:validate().closed and all:volume() < 10)
		local vertices = M.bevelVertices(source, { [4] = true, [10] = true }, 0.1, { segments = 2 })
		assert(vertices:validate().closed)
	end)
	test("Reflex edge termination can retain its original vertex without extending a source edge", function()
		local source = prism()
		local mesh = M.bevelEdges(source, { ["3:4"] = true }, 0.1, { segments = 3 })
		assert(mesh:validate().closed and mesh:volume() > 9.9 and mesh:volume() < 10.1)
	end)
	test("Higher-valence convex junctions and non-right dihedral profiles remain closed", function()
		local m = E.Mesh.new()
		for _, p in
			{ Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis }
		do
			m:addVertex(p)
		end
		for _, face in
			{
				{ 1, 3, 5 },
				{ 3, 2, 5 },
				{ 2, 4, 5 },
				{ 4, 1, 5 },
				{ 3, 1, 6 },
				{ 2, 3, 6 },
				{ 4, 2, 6 },
				{
					1,
					4,
					6,
				},
			}
		do
			m:addFace(face)
		end
		local mesh = M.bevelEdges(m, allEdges(m), 0.08, { segments = 3 })
		assert(mesh:validate().closed and mesh:volume() > 0 and mesh:volume() < m:volume())
		for _, n in { 3, 5, 8 } do
			local source = E.Primitives.cylinder(2, 3, n)
			local beveled = M.bevelEdges(source, allEdges(source), 0.1, { segments = 3 })
			assert(beveled:validate().closed and beveled:volume() < source:volume())
		end
	end)
	test("Weighted selections and modifier channel limits produce the intended bevel amount", function()
		local source = E.Primitives.box()
		local weighted = M.bevelEdges(source, { ["1:2"] = 0.5 }, 0.2)
		near(weighted:volume(), 8 - 0.1 ^ 2)
		source = A.set(A.create(source, "bevel", "edge", "number", 0), "bevel", { ["1:2"] = 0.5 })
		local modifier = E.Modifiers.bevel(source, 0.2, { weightAttribute = "bevel" })
		near(modifier:volume(), weighted:volume())
		local vertices = E.Modifiers.bevel(source, 0.2, { affect = "vertices", selection = { [1] = true } })
		near(vertices:volume(), 8 - 0.2 ^ 3 / 6)
		local unchanged = E.Modifiers.bevel(source, 0.2, { angle = math.pi * 0.75 })
		near(unchanged:volume(), 8)
	end)
	test("Bevel transfers typed channels UV seams skin weights groups and materials", function()
		local source = E.Primitives.box()
		local vertex, face, corner, edge = {}, {}, {}, {}
		source.groups.g = {}
		for id, p in source.vertices do
			vertex[id] = 2
			source.weights[id] = { A = 0.3, B = 0.7 }
			source.groups.g[id] = 0.6
		end
		for fid, f in source.faces do
			face[fid] = fid
			f.material = fid
			for i, c in f.corners do
				corner[fid .. ":" .. i] = fid
				c.uv += Vector2.new(fid * 10, 0)
			end
		end
		for key in source:topology().edges do
			edge[key] = 0.4
		end
		for _, spec in
			{
				{ "v", "vertex", vertex },
				{ "f", "face", face },
				{ "c", "corner", corner },
				{ "e", "edge", edge },
			}
		do
			source = A.set(A.create(source, spec[1], spec[2], "number", 0), spec[1], spec[3])
		end
		local mesh, r = M.bevelEdges(source, allEdges(source), 0.2, { segments = 3 })
		for id in mesh.vertices do
			near(A.get(mesh, "v", id), 2)
			near(mesh.weights[id].A, 0.3)
			near(mesh.groups.g[id], 0.6)
		end
		for fid in source.faces do
			near(A.get(mesh, "f", fid), fid)
			assert(mesh.faces[fid].material == fid)
			for i, c in mesh.faces[fid].corners do
				near(A.get(mesh, "c", fid .. ":" .. i), fid)
				assert(c.uv.X >= fid * 10)
			end
		end
		for key in r.maps.edge do
			near(A.get(mesh, "e", key), 0.4)
		end
		for key in mesh:topology().edges do
			if not r.maps.edge[key] then
				near(A.get(mesh, "e", key), 0)
			end
		end
	end)
	test("Asymmetric edge widths sew distinct endpoint cuts and retain valid fans", function()
		local source = E.Primitives.box()
		local mesh = M.bevelEdges(
			source,
			{ ["1:2"] = 1, ["1:4"] = 0.4, ["1:5"] = 0.7 },
			0.2,
			{ segments = 3 }
		)
		assert(mesh:validate().closed and mesh:volume() > 7.8 and mesh:volume() < 8)
	end)
	test("Coplanar internal edge bevels remain flat and conform at open boundaries", function()
		local source = E.Primitives.grid(2, 1)
		local mesh, r = M.bevelEdges(source, { ["2:5"] = true }, 0.1, { segments = 4 })
		assert(mesh:validate().valid and not mesh:validate().closed and #r.strips["2:5"] == 4)
		near(area(mesh), 4)
		for _, p in mesh.vertices do
			near(p.Y, 0)
		end
	end)
	test("Empty bevel selections preserve the mesh and leave source data untouched", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		local mesh, r = M.bevelEdges(source, {}, 0.2)
		assert(#r.addedVertices == 0 and #r.addedFaces == 0 and mesh:validate().closed)
		near(mesh:volume(), 8)
		assert(E.IO.encode(source) == before)
	end)
	test("Bevel rejects consumed edges faces invalid profiles and source boundary selections", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		for _, fn in
			{
				function()
					M.bevelEdges(source, allEdges(source), 1)
				end,
				function()
					M.bevelVertices(source, allVertices(source), 1.1)
				end,
				function()
					M.bevelEdges(source, { ["1:2"] = true }, 0.1, { segments = 65 })
				end,
				function()
					M.bevelEdges(source, { ["1:2"] = 2 }, 0.1)
				end,
				function()
					M.bevelEdges(source, { ["1:2"] = true }, 0.1, {
						profile = {
							Vector2.new(1, 0),
							Vector2.new(0.2, 0.8),
							Vector2.new(0.5, 0.6),
							Vector2.new(0, 1),
						},
					})
				end,
				function()
					M.bevelEdges(E.Primitives.grid(1, 1), { ["1:2"] = true }, 0.1)
				end,
				function()
					M.bevelEdges(source, allEdges(source), 0.1, { miterLimit = 1 })
				end,
			}
		do
			assert(not pcall(fn))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Bevel allocation work and cancellation failures are transactional", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxVertices = 8 },
				{ maxFaces = 6 },
				{ maxWork = 1 },
				{ maxElements = 5 },
				{
					checkpoint = function()
						error("cancel")
					end,
				},
			}
		do
			assert(not pcall(M.bevelEdges, source, allEdges(source), 0.2, options))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Bevels compose through native EditableMesh conversion with volume and closure intact", function()
		local source = E.Primitives.box()
		local mesh = E.Modifiers.bevel(source, 0.2, { segments = 3 })
		mesh = E.Normals.recalculate(mesh, { weighting = "areaAngle" })
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), mesh:volume(), 0.0001)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Bevel geometry commutes with uniform scale and representable translations", function()
		local source = E.Primitives.box()
		local reference = M.bevelEdges(source, allEdges(source), 0.2, { segments = 3 })
		for _, scale in { 0.01, 1, 100 } do
			local translation = Vector3.new(8, 4, -16) * scale
			local input = E.Deform.transform(source, CFrame.new(translation), Vector3.one * scale)
			local mesh = M.bevelEdges(input, allEdges(input), 0.2 * scale, { segments = 3 })
			assert(mesh:validate().closed)
			near(mesh:volume() / scale ^ 3, reference:volume(), 0.001)
		end
	end)
	test("Bevel face rails preserve affine source fields and varying skin weights", function()
		local source = E.Primitives.box()
		local values = {}
		source.groups.x = {}
		for id, p in source.vertices do
			values[id] = p.X + 1
			source.weights[id] = { A = (p.X + 1) / 2, B = (1 - p.X) / 2 }
			source.groups.x[id] = (p.X + 1) / 2
		end
		source = A.set(A.create(source, "x", "vertex", "number", 0), "x", values)
		local mesh = M.bevelEdges(source, allEdges(source), 0.2, { segments = 3 })
		for fid in source.faces do
			for _, id in mesh.faces[fid].vertices do
				near(A.get(mesh, "x", id), mesh.vertices[id].X + 1)
				near(mesh.weights[id].A, (mesh.vertices[id].X + 1) / 2)
				near(mesh.groups.x[id], (mesh.vertices[id].X + 1) / 2)
			end
		end
	end)
	test("Bevel junctions support an eight-valence apex with partial edge selection", function()
		local source = E.Mesh.new()
		source:addVertex(Vector3.new(0, 2, 0))
		local base = {}
		for i = 0, 7 do
			local t = i * math.pi / 4
			table.insert(base, source:addVertex(Vector3.new(math.cos(t), 0, math.sin(t))))
		end
		source:addFace(base)
		for i, id in base do
			source:addFace({ 1, base[i % 8 + 1], id })
		end
		assert(source:validate().closed)
		local mesh = M.bevelEdges(
			source,
			{ ["1:2"] = true, ["1:4"] = true, ["1:6"] = true, ["1:8"] = true },
			0.08,
			{ segments = 3 }
		)
		assert(mesh:validate().closed and mesh:volume() > 0 and mesh:volume() < source:volume())
	end)
	test("Bevel profiles rotate with an arbitrary frame while preserving their volume", function()
		local source = E.Primitives.box()
		local frame = CFrame.new(8, 4, -16) * CFrame.Angles(0.3, 0.5, 0.7)
		local reference = M.bevelEdges(source, allEdges(source), 0.2, { segments = 3 })
		local transformed = E.Deform.transform(source, frame)
		local mesh = M.bevelEdges(transformed, allEdges(transformed), 0.2, { segments = 3 })
		assert(mesh:validate().closed)
		near(mesh:volume(), reference:volume(), 0.0002)
	end)
	report.success = report.failed == 0
	return report
end
