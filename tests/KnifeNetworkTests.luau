return function(E)
	local M, A = E.MeshEdit, E.Attributes
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
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 1e-5), a .. " ~= " .. b)
	end
	local function square()
		local m = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.new(8, 0, 0), Vector3.new(8, 8, 0), Vector3.new(0, 8, 0) } do
			m:addVertex(p)
		end
		m:addFace(
			{ 1, 2, 3, 4 },
			{ { uv = Vector2.zero }, { uv = Vector2.xAxis }, { uv = Vector2.one }, { uv = Vector2.yAxis } },
			"surface"
		)
		return m
	end
	local function v(x, y)
		return Vector3.new(x, y, 0)
	end
	local function area(m)
		local sum = 0
		for fid in m.faces do
			local _, a = m:faceNormal(fid)
			sum += a
		end
		return sum
	end
	local function verify(m, r)
		assert(m:validate().valid and r.complete)
		local index = E.Connectivity.index(m)
		for _, path in r.paths do
			for i = 1, #path - 1 do
				local a, b = path[i], path[i + 1]
				assert(index.edges[math.min(a, b) .. ":" .. math.max(a, b)], "Missing knife segment")
			end
		end
	end
	test("Knife network free endpoints create a retained interior edge without changing area", function()
		local source = square()
		local m, r = M.knifeNetwork(source, { { face = 1, path = { v(2, 3), v(6, 5) } } })
		assert(#r.addedVertices == 2 and count(m.faces) == 6 and #r.faceMap[1] == 6)
		assert(count(source.vertices) == 4 and count(source.faces) == 1)
		near(area(m), 64)
		verify(m, r)
	end)
	test("Knife network crossing strokes share intersections and preserve source face winding", function()
		for _, flip in { false, true } do
			local source = square()
			if flip then
				source = E.Normals.flip(source)
			end
			local m, r = M.knifeNetwork(source, {
				{ face = 1, path = { { edge = 1, t = 0.5 }, { edge = 3, t = 0.5 } } },
				{ face = 1, path = { { edge = 2, t = 0.5 }, { edge = 4, t = 0.5 } } },
			})
			assert(#r.addedVertices == 5 and count(m.faces) == 8)
			assert(#r.paths[1] == 3 and r.paths[1][2] == r.paths[2][2])
			for fid in m.faces do
				assert(m:faceNormal(fid):Dot(source:faceNormal(1)) > 0.9999)
			end
			near(area(m), 64)
			verify(m, r)
		end
	end)
	test("Closed and self-crossing knife paths retain all finite segments", function()
		local source = square()
		local m, r = M.knifeNetwork(source, {
			{ face = 1, path = { v(1, 1), v(7, 7), v(1, 7), v(7, 1), v(1, 1) } },
			{ face = 1, path = { v(4, 4), v(4, 6) } },
		})
		assert(r.paths[1][1] == r.paths[1][#r.paths[1]] and r.paths[1][2] == r.paths[2][1])
		near(area(m), 64)
		verify(m, r)
	end)
	test("Overlapping knife strokes share topology and retain every source stroke ID", function()
		local m, r = M.knifeNetwork(square(), {
			{ face = 1, path = { v(1, 4), v(7, 4) } },
			{ face = 1, path = { v(6, 4), v(2, 4) } },
			{ face = 1, path = { v(2, 4), v(6, 4), v(2, 4) } },
		})
		assert(#r.addedVertices == 4 and #r.paths[1] == 4)
		local a, b = r.paths[2][1], r.paths[2][2]
		local edge = r.networks[1].constrainedEdges[math.min(a, b) .. ":" .. math.max(a, b)]
		assert(edge.strokes[1] and edge.strokes[2] and edge.strokes[3])
		verify(m, r)
	end)
	test("Knife network boundary paths and corner contacts use existing boundary identities", function()
		local m, r = M.knifeNetwork(square(), {
			{ face = 1, path = { { edge = 1, t = 0.25 }, { edge = 1, t = 0.75 }, v(4, 4), { corner = 4 } } },
		})
		assert(#r.addedVertices == 3 and r.paths[1][4] == 4)
		near(area(m), 64)
		verify(m, r)
	end)
	test("Network cuts of a closed solid insert conforming points in uncut neighbors", function()
		local source = E.Primitives.box()
		local m, r = M.knifeNetwork(source, {
			{ face = 5, path = { { edge = 1, t = 0.5 }, { edge = 3, t = 0.5 } } },
			{ face = 5, path = { { edge = 2, t = 0.5 }, { edge = 4, t = 0.5 } } },
		})
		assert(m:validate().closed and #r.faceMap[5] == 8 and count(m.faces) == 13)
		near(m:volume(), 8)
		near(area(m), 24)
		verify(m, r)
	end)
	test("Adjacent knife networks share edge points while preserving per-face UV seams", function()
		local source = E.Primitives.grid(2, 1)
		for _, c in source.faces[2].corners do
			c.uv += Vector2.new(10, 0)
		end
		local m, r = M.knifeNetwork(source, {
			{ face = 1, path = { { edge = 1, t = 0.4 }, { edge = 3, t = 0.6 } } },
			{ face = 2, path = { { edge = 1, t = 0.4 }, { edge = 3, t = 0.6 } } },
		})
		assert(#r.addedVertices == 3)
		local shared = 0
		for _, a in r.paths[1] do
			if table.find(r.paths[2], a) then
				shared += 1
			end
		end
		assert(shared == 1)
		for _, fid in r.faceMap[2] do
			for _, c in m.faces[fid].corners do
				assert(c.uv.X >= 10)
			end
		end
		for _, fid in r.faceMap[1] do
			for _, c in m.faces[fid].corners do
				assert(c.uv.X <= 1)
			end
		end
		near(area(m), 4)
		verify(m, r)
	end)
	test("Knife intersections transfer vertex corner face edge skin and group channels", function()
		local source = square()
		source = A.set(A.create(source, "x", "vertex", "number", 0), "x", { [2] = 8, [3] = 8 })
		source = A.set(A.create(source, "xuv", "corner", "number", 0), "xuv", { ["1:2"] = 8, ["1:3"] = 8 })
		source = A.set(A.create(source, "label", "face", "string", ""), "label", { [1] = "source" })
		source = A.set(A.create(source, "rim", "edge", "number", 0), "rim", { ["1:2"] = 5 })
		source.groups.x = { [2] = 1, [3] = 1 }
		source.weights[2], source.weights[3] = { A = 1 }, { A = 1 }
		local m, r = M.knifeNetwork(source, {
			{ face = 1, path = { { edge = 1, t = 0.5 }, v(5, 7) } },
			{ face = 1, path = { v(1, 3), v(7, 3) } },
		})
		assert(#r.paths[1] == 3 and #r.paths[2] == 3)
		for _, id in r.addedVertices do
			near(A.get(m, "x", id), m.vertices[id].X)
			near(m.groups.x[id], m.vertices[id].X / 8)
			near(m.weights[id].A or 0, m.vertices[id].X / 8)
		end
		for fid, face in m.faces do
			assert(face.material == "surface" and A.get(m, "label", fid) == "source")
			for i, id in face.vertices do
				near(A.get(m, "xuv", fid .. ":" .. i), m.vertices[id].X)
				near(face.corners[i].uv.X, m.vertices[id].X / 8)
				near(face.corners[i].uv.Y, m.vertices[id].Y / 8)
			end
		end
		local rim = r.paths[1][1]
		near(A.get(m, "rim", "1:" .. rim), 5)
		near(A.get(m, "rim", "2:" .. rim), 5)
		verify(m, r)
	end)
	test("Network knife works in all dominant projection planes and rigid transforms", function()
		for _, frame in
			{
				CFrame.identity,
				CFrame.Angles(math.pi / 2, 0, 0),
				CFrame.Angles(0, math.pi / 2, 0),
				CFrame.new(16, -8, 32) * CFrame.Angles(0.2, 0.4, 0.3),
			}
		do
			local source = E.Deform.transform(square(), frame)
			local m, r = M.knifeNetwork(source, {
				{ face = 1, path = { frame:PointToWorldSpace(v(2, 3)), frame:PointToWorldSpace(v(6, 5)) } },
			}, { planeTolerance = 1e-4 })
			assert(#r.addedVertices == 2)
			near(area(m), 64, 1e-3)
			for fid in m.faces do
				assert(m:faceNormal(fid):Dot(source:faceNormal(1)) > 0.9999)
			end
			verify(m, r)
		end
	end)
	test("Knife network errors and cancellation leave all source domains unchanged", function()
		local source = square()
		local before = E.IO.encode(source)
		local strokes = { { face = 1, path = { v(2, 3), v(6, 5) } } }
		for _, options in
			{
				{ maxVertices = 4 },
				{ maxFaces = 1 },
				{ maxPathPoints = 1 },
				{ maxNetworkVertices = 4 },
				{ maxNetworkSegments = 4 },
				{ maxNetworkTriangles = 2 },
				{ maxWork = 5 },
				{
					checkpoint = function()
						error("cancel network")
					end,
				},
			}
		do
			assert(not pcall(M.knifeNetwork, source, strokes, options))
		end
		for _, path in
			{
				{ v(0, 0), v(2, 2) },
				{ v(2, 2), v(20, 2) },
				{ v(2, 2), Vector3.new(3, 3, 1) },
				{ v(2, 2), v(2, 2) },
				{ { edge = 1, t = 0 }, v(2, 2) },
			}
		do
			assert(not pcall(M.knifeNetwork, source, { { face = 1, path = path } }))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Concave source faces retain interior paths and reject cuts across missing regions", function()
		local source = E.Mesh.new()
		for _, p in { v(0, 0), v(8, 0), v(8, 2), v(2, 2), v(2, 8), v(0, 8) } do
			source:addVertex(p)
		end
		source:addFace({ 1, 2, 3, 4, 5, 6 })
		local m, r = M.knifeNetwork(source, { { face = 1, path = { v(1, 7), v(1, 1), v(7, 1) } } })
		near(area(m), 28)
		verify(m, r)
		assert(not pcall(M.knifeNetwork, source, { { face = 1, path = { v(1, 7), v(7, 1) } } }))
	end)
	test("Repeated network edits and native mesh roundtrips retain closed topology", function()
		local source = E.Primitives.box()
		local m = M.knifeNetwork(source, {
			{ face = 5, path = { { edge = 1, t = 0.5 }, { edge = 3, t = 0.5 } } },
			{ face = 5, path = { { edge = 2, t = 0.5 }, { edge = 4, t = 0.5 } } },
		})
		local face = m.faces[5]
		local center = Vector3.zero
		for _, id in face.vertices do
			center += m.vertices[id] / #face.vertices
		end
		m = M.knifeNetwork(m, { { face = 5, path = { { corner = 1 }, center } } })
		assert(m:validate().closed)
		local handle = E.Roblox.toEditable(m)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), 8)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Empty knife network calls return an independent unchanged mesh", function()
		local source = square()
		local m, r = M.knifeNetwork(source, {})
		assert(count(m.faces) == 1 and #r.addedVertices == 0 and next(r.faceMap) == nil)
		m.vertices[1] = v(1, 1)
		assert(source.vertices[1] == Vector3.zero)
	end)
	report.success = report.failed == 0
	return report
end
