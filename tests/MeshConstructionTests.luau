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
	local function area(m)
		local total = 0
		for fid in m.faces do
			local _, a = m:faceNormal(fid)
			total += a
		end
		return total
	end
	local function loose(points)
		local m = E.Mesh.new()
		local ids = {}
		for _, p in points do
			table.insert(ids, m:addVertex(p))
		end
		return m, ids
	end
	local function rectangle()
		return loose({
			Vector3.new(0, 0, 0),
			Vector3.new(1, 0, 0),
			Vector3.new(2, 0, 0),
			Vector3.new(3, 0, 0),
			Vector3.new(3, 1, 0),
			Vector3.new(3, 2, 0),
			Vector3.new(2, 2, 0),
			Vector3.new(1, 2, 0),
			Vector3.new(0, 2, 0),
			Vector3.new(0, 1, 0),
		})
	end
	test("Grid fill creates an exact rectangular quad lattice with preserved boundary IDs", function()
		local source, loop = rectangle()
		local mesh, r = M.gridFill(source, loop, 3)
		assert(count(mesh.faces) == 6 and count(mesh.vertices) == 12 and mesh:validate().valid)
		near(area(mesh), 6)
		for j, row in r.grid do
			for i, id in row do
				assert((mesh.vertices[id] - Vector3.new(i - 1, j - 1, 0)).Magnitude < 1e-6)
			end
		end
		assert(count(source.faces) == 0 and count(source.vertices) == 10)
	end)
	test("Grid fill attaches to a hole with automatically consistent winding", function()
		local source = E.Primitives.box()
		source:removeFace(5)
		local mesh, r = M.gridFill(source, { 3, 4, 8, 7 }, 1)
		assert(mesh:validate().closed and #r.addedFaces == 1)
		near(mesh:volume(), 8)
		assert(mesh.faces[r.addedFaces[1]].corners[1].uv)
	end)
	test("Grid fill interpolates vertex skin and group channels and supports boundary offsets", function()
		local source, loop = rectangle()
		local values = {}
		source.groups.x = {}
		for id, p in source.vertices do
			values[id] = p.X
			source.weights[id] = { A = p.X / 3 }
			source.groups.x[id] = p.X / 3
		end
		source = A.set(A.create(source, "x", "vertex", "number", 0), "x", values)
		local mesh, r = M.gridFill(source, loop, 3)
		for _, id in r.addedVertices do
			near(A.get(mesh, "x", id), mesh.vertices[id].X)
			near(mesh.weights[id].A, mesh.vertices[id].X / 3)
			near(mesh.groups.x[id], mesh.vertices[id].X / 3)
		end
		local offset = M.gridFill(source, loop, 2, { offset = 3 })
		near(area(offset), 6)
	end)
	test("Grid fill follows nonplanar boundary rails and rejects invalid or folded cells", function()
		local source, loop = rectangle()
		source:setPosition(2, Vector3.new(1, 0, 0.2))
		local mesh = M.gridFill(source, loop, 3)
		assert(mesh:validate().valid and mesh.vertices[11].Z > 0)
		assert(not pcall(M.gridFill, source, { 1, 2, 3, 4, 5 }, 2))
		assert(not pcall(M.gridFill, source, loop, 5))
		assert(not pcall(M.gridFill, E.Primitives.box(), { 3, 4, 8, 7 }, 1))
		local crossed, ids = loose({ Vector3.zero, Vector3.new(1, 1, 0), Vector3.xAxis, Vector3.yAxis })
		assert(not pcall(M.gridFill, crossed, ids, 1))
	end)
	test("Grid filling is transactional under cancellation and allocation limits", function()
		local source, loop = rectangle()
		local before = E.IO.encode(source)
		assert(not pcall(M.gridFill, source, loop, 3, { maxVertices = 10 }))
		assert(not pcall(M.gridFill, source, loop, 3, { maxFaces = 2 }))
		assert(not pcall(M.gridFill, source, loop, 3, {
			checkpoint = function()
				error("cancel")
			end,
		}))
		assert(E.IO.encode(source) == before)
	end)
	test("Full spin welds the seam and axis poles into a closed polygonal cylinder", function()
		local source, ids = loose({
			Vector3.new(0, -1, 0),
			Vector3.new(2, -1, 0),
			Vector3.new(2, 1, 0),
			Vector3.new(0, 1, 0),
		})
		local mesh, r = M.spin(source, ids, Vector3.zero, Vector3.yAxis, -2 * math.pi, 16, { uv = "sweep" })
		assert(mesh:validate().closed and count(mesh.vertices) == 34 and count(mesh.faces) == 48 and r.merged)
		near(mesh:volume(), 16 * 4 * math.sin(2 * math.pi / 16), 1e-4)
		for i, id in r.rings[1] do
			assert(id == r.rings[#r.rings][i])
		end
	end)
	test("Closed profile spin gives a genus-one torus with independent polygonal volume", function()
		local points = {}
		local n = 12
		for i = 0, n - 1 do
			local t = 2 * math.pi * i / n
			table.insert(points, Vector3.new(3 + math.cos(t), math.sin(t), 0))
		end
		local source, ids = loose(points)
		local mesh =
			M.spin(source, ids, Vector3.zero, Vector3.yAxis, 2 * math.pi, 24, { closedProfile = true })
		assert(
			mesh:validate().closed
				and mesh:validate().eulerCharacteristic == 0
				and count(mesh.faces) == n * 24
		)
		near(
			math.abs(mesh:volume()),
			24 * math.sin(2 * math.pi / 24) * 3 * (n / 2 * math.sin(2 * math.pi / n)),
			0.0002
		)
	end)
	test("Screw positions obey signed pitch and preserve copied vertex data", function()
		local source, ids = loose({ Vector3.new(1, 0, 0), Vector3.new(2, 0, 0) })
		source = A.set(A.create(source, "tag", "vertex", "number", 0), "tag", { [1] = 2, [2] = 7 })
		source.weights[1] = { A = 0.4 }
		source.groups.g = { [1] = 0.6 }
		local mesh, r = M.screw(source, ids, Vector3.zero, Vector3.yAxis, 2, 3, 32, { uv = "sweep" })
		assert(mesh:validate().valid and not r.merged and count(mesh.faces) == 32)
		for i, ring in r.rings do
			near(mesh.vertices[ring[1]].Y, (i - 1) / 32 * 6)
			near(A.get(mesh, "tag", ring[2]), 7)
			near(mesh.weights[ring[1]].A, 0.4)
			near(mesh.groups.g[ring[1]], 0.6)
		end
		assert((mesh.vertices[r.rings[33][2]] - Vector3.new(2, 6, 0)).Magnitude < 1e-5)
	end)
	test("Partial closed-profile spin caps both ends and retains open seam when requested", function()
		local source, ids = loose({
			Vector3.new(1.7, -0.3, 0),
			Vector3.new(2.3, -0.3, 0),
			Vector3.new(2.3, 0.3, 0),
			Vector3.new(1.7, 0.3, 0),
		})
		local mesh = M.spin(
			source,
			ids,
			Vector3.zero,
			Vector3.yAxis,
			math.pi,
			12,
			{ closedProfile = true, cap = true }
		)
		assert(mesh:validate().closed)
		local open, r = M.spin(
			source,
			ids,
			Vector3.zero,
			Vector3.yAxis,
			2 * math.pi,
			24,
			{ closedProfile = true, merge = false }
		)
		assert(not open:validate().closed and not r.merged and open:validate().boundaryEdges == 8)
	end)
	test("Spin attaches a boundary profile and transfers edge face and corner channels", function()
		local source = E.Primitives.grid(1, 1)
		source = A.set(A.create(source, "edge", "edge", "number", 0), "edge", { ["2:4"] = 0.8 })
		source = A.set(A.create(source, "face", "face", "number", 0), "face", { [1] = 4 })
		source =
			A.set(A.create(source, "corner", "corner", "number", 0), "corner", { ["1:3"] = 8, ["1:4"] = 6 })
		local mesh, r = M.spin(source, { 2, 4 }, Vector3.new(0, -2, 0), Vector3.zAxis, math.pi / 4, 4)
		assert(mesh:validate().valid)
		for _, fid in r.addedFaces do
			near(A.get(mesh, "face", fid), 4)
			for i in mesh.faces[fid].corners do
				assert(A.get(mesh, "corner", fid .. ":" .. i) >= 6)
			end
		end
		for _, ring in r.rings do
			local a, b = ring[1], ring[2]
			local key = math.min(a, b) .. ":" .. math.max(a, b)
			near(A.get(mesh, "edge", key), 0.8)
		end
	end)
	test("Spin rejects invalid axes resolution attachment and budgets without mutation", function()
		local source, ids = loose({ Vector3.xAxis, Vector3.new(2, 0, 0) })
		local before = E.IO.encode(source)
		for _, fn in
			{
				function()
					M.spin(source, ids, Vector3.zero, Vector3.zero, 1, 4)
				end,
				function()
					M.spin(source, ids, Vector3.zero, Vector3.yAxis, 2 * math.pi, 2)
				end,
				function()
					M.spin(source, ids, Vector3.zero, Vector3.yAxis, 4 * math.pi, 20)
				end,
				function()
					M.spin(source, ids, Vector3.zero, Vector3.yAxis, 1, 4, { maxVertices = 2 })
				end,
				function()
					M.spin(source, ids, Vector3.zero, Vector3.yAxis, 1, 4, {
						checkpoint = function()
							error("cancel")
						end,
					})
				end,
			}
		do
			assert(not pcall(fn))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Bisect retains both halves with shared seam vertices and unchanged closed volume", function()
		local source = E.Primitives.box()
		local mesh, r = M.bisect(source, Vector3.new(0.25, 0, 0), Vector3.xAxis)
		assert(mesh:validate().closed and count(r.intersections) > 0 and count(r.planeEdges) > 0)
		near(mesh:volume(), 8)
		for _, id in r.intersections do
			near(mesh.vertices[id].X, 0.25)
		end
		near(area(mesh), 24)
	end)
	test("Bisect caps each half of a cube with independent volume and complementary areas", function()
		local source = E.Primitives.box()
		for _, keep in { "positive", "negative" } do
			local mesh, r = M.bisect(
				source,
				Vector3.new(0.25, 0, 0),
				Vector3.xAxis,
				{ keep = keep, cap = true, material = 3 }
			)
			assert(mesh:validate().closed and #r.capLoops == 1 and #r.caps > 0)
			near(mesh:volume(), keep == "positive" and 3 or 5)
			for _, fid in r.caps do
				assert(mesh.faces[fid].material == 3 and mesh.faces[fid].corners[1].uv)
			end
		end
	end)
	test(
		"Bisect concave polygons can create disconnected retained regions without joining across voids",
		function()
			local source, ids = loose({
				Vector3.new(0, 0, 0),
				Vector3.new(3, 0, 0),
				Vector3.new(3, 3, 0),
				Vector3.new(2, 3, 0),
				Vector3.new(2, 1, 0),
				Vector3.new(1, 1, 0),
				Vector3.new(1, 3, 0),
				Vector3.new(0, 3, 0),
			})
			source:addFace(ids)
			local mesh = M.bisect(source, Vector3.new(0, 2, 0), Vector3.yAxis, { keep = "positive" })
			assert(mesh:validate().valid and mesh:validate().surfaceComponents == 2)
			near(area(mesh), 2)
			local both = M.bisect(source, Vector3.new(0, 2, 0), Vector3.yAxis)
			near(area(both), 7)
		end
	)
	test("Bisect cap triangulation retains an annular hole through a torus", function()
		local source = E.Primitives.torus(3, 1, 24, 12)
		local mesh, r =
			M.bisect(source, Vector3.zero, Vector3.yAxis, { keep = "positive", cap = true, tolerance = 1e-6 })
		assert(mesh:validate().closed and #r.capLoops == 2 and mesh:validate().eulerCharacteristic == 0)
		near(mesh:volume(), source:volume() / 2, 0.001)
		for _, fid in r.caps do
			local f = mesh.faces[fid]
			local p = (
				mesh.vertices[f.vertices[1]]
				+ mesh.vertices[f.vertices[2]]
				+ mesh.vertices[f.vertices[3]]
			) / 3
			assert(Vector2.new(p.X, p.Z).Magnitude > 1.9)
		end
	end)
	test("Bisect preserves per-face corner seams and linearly interpolates all vertex data", function()
		local source = E.Primitives.box()
		local heat, corner, face = {}, {}, {}
		source.groups.g = {}
		for id, p in source.vertices do
			heat[id] = p.X + 1
			source.weights[id] = { A = (p.X + 1) / 2 }
			source.groups.g[id] = (p.X + 1) / 2
		end
		for fid, f in source.faces do
			face[fid] = fid
			for i, c in f.corners do
				corner[fid .. ":" .. i] = fid
				c.uv += Vector2.new(fid * 10, 0)
			end
		end
		source = A.set(A.create(source, "heat", "vertex", "number", 0), "heat", heat)
		source = A.set(A.create(source, "corner", "corner", "number", 0), "corner", corner)
		source = A.set(A.create(source, "face", "face", "number", 0), "face", face)
		local mesh, r = M.bisect(source, Vector3.new(0.2, 0, 0), Vector3.xAxis)
		for _, id in r.intersections do
			near(A.get(mesh, "heat", id), 1.2)
			near(mesh.weights[id].A, 0.6)
			near(mesh.groups.g[id], 0.6)
		end
		for old, faces in r.faceMap do
			for _, fid in faces do
				near(A.get(mesh, "face", fid), old)
				for i, c in mesh.faces[fid].corners do
					near(A.get(mesh, "corner", fid .. ":" .. i), old)
					assert(c.uv.X >= old * 10)
				end
			end
		end
	end)
	test("Bisect keeps source-edge channels on split edges and defaults new cut edges", function()
		local source = E.Primitives.box()
		local values = {}
		for key in source:topology().edges do
			values[key] = 2
		end
		source = A.set(A.create(source, "edge", "edge", "number", 0), "edge", values)
		local mesh, r = M.bisect(source, Vector3.zero, Vector3.xAxis, { keep = "positive", cap = true })
		for key in r.maps.edge do
			near(A.get(mesh, "edge", key), 2)
		end
		for key in r.planeEdges do
			near(A.get(mesh, "edge", key), 0)
		end
		assert(mesh:validate().valid)
	end)
	test("Plane cuts through existing vertices and edges retain conformity", function()
		local source = E.Primitives.box()
		local mesh = M.bisect(source, Vector3.zero, Vector3.new(1, 1, 0), { keep = "positive", cap = true })
		assert(mesh:validate().closed)
		near(mesh:volume(), 4)
		local tangent, r =
			M.bisect(source, Vector3.new(1, 0, 0), Vector3.xAxis, { keep = "negative", cap = true })
		assert(#r.caps == 0 and tangent:validate().closed)
		near(tangent:volume(), 8)
	end)
	test("Bisect handles disjoint shells and empty retained sets", function()
		local source = E.Topology.join({
			E.Primitives.box(),
			E.Deform.transform(E.Primitives.box(), CFrame.new(0, 4, 0)),
		})
		local mesh, r = M.bisect(source, Vector3.zero, Vector3.xAxis, { keep = "negative", cap = true })
		assert(mesh:validate().closed and #r.capLoops == 2 and mesh:validate().surfaceComponents == 2)
		near(mesh:volume(), 8)
		local empty =
			M.bisect(source, Vector3.new(10, 0, 0), Vector3.xAxis, { keep = "positive", cap = true })
		assert(count(empty.faces) == 0 and count(empty.vertices) == 0 and empty:validate().valid)
	end)
	test("Bisect cancellation caps and triangle limits fail transactionally", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		for _, options in
			{
				{ cap = true },
				{ keep = "outside" },
				{ maxCutTriangles = 1 },
				{ tolerance = -1 },
				{ maxVertices = 8 },
				{
					checkpoint = function()
						error("cancel")
					end,
				},
			}
		do
			assert(not pcall(M.bisect, source, Vector3.zero, Vector3.xAxis, options))
		end
		assert(
			not pcall(
				M.bisect,
				E.Primitives.grid(2, 2),
				Vector3.zero,
				Vector3.xAxis,
				{ cap = true, keep = "positive" }
			)
		)
		assert(E.IO.encode(source) == before)
	end)
	test("Grid spin and cap cutting compose through native EditableMesh conversion", function()
		local source, ids = loose({
			Vector3.new(0, -1, 0),
			Vector3.new(2, -1, 0),
			Vector3.new(2, 1, 0),
			Vector3.new(0, 1, 0),
		})
		local mesh = M.spin(source, ids, Vector3.zero, Vector3.yAxis, -2 * math.pi, 24)
		mesh = M.bisect(mesh, Vector3.new(0.3, 0, 0), Vector3.xAxis, { keep = "negative", cap = true })
		local h = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(h.editable)
			assert(restored:validate().closed)
			near(restored:volume(), mesh:volume(), 0.0002)
		end)
		h.editable:Destroy()
		assert(ok, err)
	end)
	test("Plane cutting commutes with scale and representable world translations", function()
		local base = M.bisect(
			E.Primitives.box(),
			Vector3.new(0.25, 0, 0),
			Vector3.xAxis,
			{ keep = "negative", cap = true }
		)
		for _, scale in { 0.01, 1, 100 } do
			local translation = Vector3.new(8, 4, -16) * scale
			local source =
				E.Deform.transform(E.Primitives.box(), CFrame.new(translation), Vector3.one * scale)
			local mesh = M.bisect(
				source,
				translation + Vector3.new(0.25 * scale, 0, 0),
				Vector3.xAxis,
				{ keep = "negative", cap = true }
			)
			assert(mesh:validate().closed)
			near(mesh:volume() / scale ^ 3, base:volume(), 0.001)
		end
	end)
	test("Finite knife chord splits one face and inserts matching points into uncut neighbors", function()
		local source = E.Primitives.box()
		local mesh, r =
			M.knife(source, { { face = 5, path = { { edge = 1, t = 0.25 }, { edge = 3, t = 0.75 } } } })
		assert(
			mesh:validate().closed and #r.faceMap[5] == 2 and count(mesh.faces) == 7 and #r.addedVertices == 2
		)
		near(mesh:volume(), 8)
		near(area(mesh), 24)
		assert(#mesh.faces[1].vertices == 5 and #mesh.faces[2].vertices == 5)
	end)
	test("Knife polyline bends inside a face while preserving region area and typed interpolation", function()
		local source, ids =
			loose({ Vector3.zero, Vector3.new(2, 0, 0), Vector3.new(2, 2, 0), Vector3.new(0, 2, 0) })
		source:addFace(ids, {
			{ uv = Vector2.zero },
			{ uv = Vector2.new(1, 0) },
			{ uv = Vector2.one },
			{ uv = Vector2.new(0, 1) },
		})
		source = A.set(A.create(source, "x", "vertex", "number", 0), "x", { [2] = 2, [3] = 2 })
		source = A.set(A.create(source, "xuv", "corner", "number", 0), "xuv", { ["1:2"] = 2, ["1:3"] = 2 })
		source.groups.x = { [2] = 1, [3] = 1 }
		source.weights[2] = { A = 1 }
		source.weights[3] = { A = 1 }
		local mesh, r = M.knife(source, {
			{
				face = 1,
				path = {
					{ edge = 4, t = 0.5 },
					Vector3.new(0.5, 0.7, 0),
					Vector3.new(1.5, 1.3, 0),
					{ edge = 2, t = 0.5 },
				},
			},
		})
		near(area(mesh), 4)
		assert(mesh:validate().valid and #r.paths[1] == 4)
		for _, id in r.addedVertices do
			near(A.get(mesh, "x", id), mesh.vertices[id].X)
			near(mesh.groups.x[id], mesh.vertices[id].X / 2)
			near(mesh.weights[id].A or 0, mesh.vertices[id].X / 2)
		end
		for _, fid in r.faceMap[1] do
			for i, id in mesh.faces[fid].vertices do
				near(A.get(mesh, "xuv", fid .. ":" .. i), mesh.vertices[id].X)
				near(mesh.faces[fid].corners[i].uv.X, mesh.vertices[id].X / 2)
			end
		end
	end)
	test("Knife paths on adjacent faces share canonical edge points but keep corner seams", function()
		local source = E.Primitives.grid(2, 1)
		for _, c in source.faces[2].corners do
			c.uv += Vector2.new(10, 0)
		end
		local mesh, r = M.knife(source, {
			{ face = 1, path = { { edge = 1, t = 0.4 }, { edge = 3, t = 0.6 } } },
			{
				face = 2,
				path = { { edge = 1, t = 0.4 }, { edge = 3, t = 0.6 } },
			},
		})
		assert(mesh:validate().valid and #r.addedVertices == 3 and count(mesh.faces) == 4)
		near(area(mesh), 4)
		for _, fid in r.faceMap[2] do
			for _, c in mesh.faces[fid].corners do
				assert(c.uv.X >= 10)
			end
		end
		assert(r.paths[1][2] == r.paths[2][1])
	end)
	test("Knife supports corner endpoints and subsequent cuts using reported surviving IDs", function()
		local source = E.Primitives.grid(1, 1)
		local mesh, r = M.knife(source, { { face = 1, path = { { corner = 1 }, { corner = 3 } } } })
		assert(count(mesh.faces) == 2 and #r.addedVertices == 0)
		near(area(mesh), 4)
		local second = M.knife(
			mesh,
			{ { face = r.faceMap[1][1], path = { { edge = 1, t = 0.5 }, { edge = 2, t = 0.5 } } } }
		)
		assert(second:validate().valid and count(second.faces) == 3)
		near(area(second), 4)
	end)
	test("Knife interpolates split-edge channels and defaults new interior path edges", function()
		local source = E.Primitives.box()
		local values = {}
		for key in source:topology().edges do
			values[key] = 0.7
		end
		source = A.set(A.create(source, "crease", "edge", "number", 0), "crease", values)
		local mesh, r =
			M.knife(source, { { face = 5, path = { { edge = 1, t = 0.5 }, { edge = 3, t = 0.5 } } } })
		for key in r.maps.edge do
			near(A.get(mesh, "crease", key), 0.7)
		end
		local a, b = r.paths[5][1], r.paths[5][2]
		near(A.get(mesh, "crease", math.min(a, b) .. ":" .. math.max(a, b)), 0)
	end)
	test("Knife rejects boundary-following self-crossing outside and nonplanar paths", function()
		local source = E.Primitives.grid(1, 1)
		local before = E.IO.encode(source)
		for _, path in
			{
				{ { corner = 1 }, { corner = 2 } },
				{ { edge = 1, t = 0.5 }, Vector3.new(2, 0, 0), { edge = 3, t = 0.5 } },
				{ { edge = 1, t = 0.5 }, Vector3.new(0, 1, 0), { edge = 3, t = 0.5 } },
				{
					{ edge = 1, t = 0.5 },
					Vector3.new(0.5, 0, 0.5),
					Vector3.new(-0.5, 0, 0.5),
					Vector3.new(0.5, 0, -0.5),
					{ edge = 3, t = 0.5 },
				},
				{ { corner = 1 }, { corner = 1 } },
			}
		do
			assert(not pcall(M.knife, source, { { face = 1, path = path } }))
		end
		local warped = source:clone()
		warped:setPosition(1, warped.vertices[1] + Vector3.new(0, 0.2, 0))
		assert(not pcall(M.knife, warped, { { face = 1, path = { { corner = 1 }, { corner = 3 } } } }))
		assert(E.IO.encode(source) == before)
	end)
	test("Knife rejects work point and allocation budget exhaustion transactionally", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		local strokes = { { face = 5, path = { { edge = 1, t = 0.25 }, { edge = 3, t = 0.75 } } } }
		for _, options in
			{
				{ maxWork = 1 },
				{ maxPathPoints = 1 },
				{ maxVertices = 8 },
				{ maxFaces = 6 },
				{
					checkpoint = function()
						error("cancel")
					end,
				},
			}
		do
			assert(not pcall(M.knife, source, strokes, options))
		end
		assert(not pcall(M.knife, source, { strokes[1], strokes[1] }))
		assert(E.IO.encode(source) == before)
	end)
	test("Knife bent paths and tilted native roundtrip retain volume and surface area", function()
		local frame = CFrame.new(4, 8, 16) * CFrame.Angles(0.3, 0.7, 0.2)
		local source = E.Deform.transform(E.Primitives.box(), frame)
		local mesh = M.knife(source, {
			{
				face = 5,
				path = {
					{ edge = 1, t = 0.25 },
					frame:PointToWorldSpace(Vector3.new(0.3, 1, 0)),
					{ edge = 3, t = 0.75 },
				},
			},
		})
		assert(mesh:validate().closed)
		near(mesh:volume(), 8, 0.0001)
		near(area(mesh), 24, 0.0001)
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), 8, 0.0001)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test(
		"Rectangular grid attachment preserves the requested corner partition when reversing winding",
		function()
			local source = E.Primitives.grid(5, 4, Vector2.new(5, 4))
			for _, fid in { 7, 8, 9, 12, 13, 14 } do
				source:removeFace(fid)
			end
			local mesh, r = M.gridFill(source, { 8, 9, 10, 11, 17, 23, 22, 21, 20, 14 }, 3)
			near(area(mesh), 20)
			assert(mesh:validate().valid and #r.addedFaces == 6)
			for _, fid in r.addedFaces do
				local normal, a = mesh:faceNormal(fid)
				near(a, 1)
				assert(normal.Y > 0.99)
			end
		end
	)
	test("Bisect retains a coplanar triangle inside a straddling nonplanar polygon exactly once", function()
		local points = {}
		for i = 0, 5 do
			local t = i * math.pi / 3
			table.insert(points, Vector3.new(math.cos(t), math.sin(t), 0))
		end
		local source, ids = loose(points)
		source:addFace(ids)
		local tri = source:faceTriangles(1)[1]
		local changed = 0
		for i, id in ids do
			if not table.find(tri, i) and changed < 2 then
				changed += 1
				source:setPosition(id, source.vertices[id] + Vector3.new(0, 0, changed == 1 and 0.1 or -0.1))
			end
		end
		local function triangleArea(m)
			local total = 0
			for fid, f in m.faces do
				for _, indices in m:faceTriangles(fid) do
					local a, b, c =
						m.vertices[f.vertices[indices[1]]],
						m.vertices[f.vertices[indices[2]]],
						m.vertices[f.vertices[indices[3]]]
					total += (b - a):Cross(c - a).Magnitude / 2
				end
			end
			return total
		end
		local mesh = M.bisect(source, Vector3.zero, Vector3.zAxis)
		assert(mesh:validate().valid)
		near(triangleArea(mesh), triangleArea(source))
	end)
	test("Knife accepts a finite path inside a concave region and rejects a chord across its void", function()
		local source, ids = loose({
			Vector3.new(0, 0, 0),
			Vector3.new(3, 0, 0),
			Vector3.new(3, 3, 0),
			Vector3.new(2, 3, 0),
			Vector3.new(2, 1, 0),
			Vector3.new(1, 1, 0),
			Vector3.new(1, 3, 0),
			Vector3.new(0, 3, 0),
		})
		source:addFace(ids)
		local mesh = M.knife(source, {
			{
				face = 1,
				path = {
					{ edge = 2, t = 0.5 },
					Vector3.new(2.5, 0.5, 0),
					Vector3.new(0.5, 0.5, 0),
					{ edge = 8, t = 0.5 },
				},
			},
		})
		assert(mesh:validate().valid)
		near(area(mesh), 7)
		assert(
			not pcall(
				M.knife,
				source,
				{ { face = 1, path = { { edge = 2, t = 0.5 }, { edge = 8, t = 0.5 } } } }
			)
		)
	end)
	test(
		"Capped tangent cuts discard isolated coplanar sheets instead of closing zero-volume shells",
		function()
			local source = E.Primitives.box()
			local mesh, r = M.bisect(source, Vector3.xAxis, Vector3.xAxis, { keep = "positive", cap = true })
			assert(count(mesh.faces) == 0 and count(r.discardedCoplanarFaces) == 1)
			local joined = E.Topology.join({ source, E.Deform.transform(source, CFrame.new(2, 4, 0)) })
			local cut, rr = M.bisect(joined, Vector3.xAxis, Vector3.xAxis, { keep = "positive", cap = true })
			assert(
				cut:validate().closed
					and cut:validate().surfaceComponents == 1
					and count(rr.discardedCoplanarFaces) == 1
			)
			near(cut:volume(), 8)
		end
	)
	report.success = report.failed == 0
	return report
end
