return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local S, A = E.Subdivision, E.Attributes
	local EC, VC = "subdivision_edge_sharpness", "subdivision_vertex_sharpness"
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b)
		if typeof(a) == "Vector3" then
			assert((a - b).Magnitude < 2e-6, tostring(a) .. " ~= " .. tostring(b))
		else
			assert(math.abs(a - b) < 1e-6, tostring(a) .. " ~= " .. tostring(b))
		end
	end
	local function edge(a, b)
		return a < b and a .. ":" .. b or b .. ":" .. a
	end
	local function cube()
		local m = E.Primitives.box(Vector3.one * 2)
		local others = {}
		for v in m:topology().neighbors[1] do
			table.insert(others, v)
		end
		table.sort(others)
		return m, others
	end
	local function edgeVertex(m, key)
		local keys = {}
		for k in m:topology().edges do
			table.insert(keys, k)
		end
		table.sort(keys)
		local count = 0
		for _ in m.vertices do
			count += 1
		end
		return count + assert(table.find(keys, key))
	end
	test("Uncreased Catmull Clark cube reproduces the analytic corner mask", function()
		local m = cube()
		local out = S.catmullClark(m, 1)
		for id, p in m.vertices do
			near(out.vertices[id], p * 5 / 9)
		end
		assert(out:validate().closed and out:validate().faces == 24)
	end)
	test("Infinite creases preserve cube shape through repeated refinement", function()
		local m = cube()
		local edges = {}
		for k in m:topology().edges do
			edges[k] = 10
		end
		m = S.crease(m, edges)
		local out = S.catmullClark(m, 3)
		near(out:volume(), 8)
		for _, p in out.vertices do
			near(math.max(math.abs(p.X), math.abs(p.Y), math.abs(p.Z)), 1)
		end
		for _, value in out.attributes[EC].values do
			assert(value == 10)
		end
		assert(out:validate().closed and m.attributes[EC].values["1:2"] == 10)
	end)
	test("Two edge crease and three edge corner masks use their correct incident neighbours", function()
		local m, n = cube()
		local p = m.vertices[1]
		local edges = { [edge(1, n[1])] = 10, [edge(1, n[2])] = 10 }
		local out = S.catmullClark(S.crease(m, edges), 1)
		near(out.vertices[1], p * 0.75 + (m.vertices[n[1]] + m.vertices[n[2]]) * 0.125)
		edges[edge(1, n[3])] = 10
		near(S.catmullClark(S.crease(m, edges), 1).vertices[1], p)
		near(S.catmullClark(S.crease(m, { [edge(1, n[1])] = 10 }), 1).vertices[1], p * 5 / 9)
	end)
	test("Unequal fractional creases average transition sharpness instead of choosing one edge", function()
		local m, n = cube()
		local p = m.vertices[1]
		local marked = S.crease(m, { [edge(1, n[1])] = 0.2, [edge(1, n[2])] = 0.8 })
		local out = S.catmullClark(marked, 1)
		local crease = p * 0.75 + (m.vertices[n[1]] + m.vertices[n[2]]) * 0.125
		near(out.vertices[1], (p * 5 / 9):Lerp(crease, 0.5))
		assert(next(out.attributes[EC].values) == nil)
	end)
	test("Corner to crease transitions use the child crease directions", function()
		local m, n = cube()
		local p = m.vertices[1]
		local out = S.catmullClark(
			S.crease(m, { [edge(1, n[1])] = 2, [edge(1, n[2])] = 2, [edge(1, n[3])] = 0.6 }),
			1
		)
		local crease = p * 0.75 + (m.vertices[n[1]] + m.vertices[n[2]]) * 0.125
		near(out.vertices[1], crease:Lerp(p, 0.6))
	end)
	test("Vertex sharpness participates in the joint fractional transition", function()
		local m, n = cube()
		local p = m.vertices[1]
		local marked = S.crease(m, { [edge(1, n[1])] = 0.4, [edge(1, n[2])] = 0.8 }, { [1] = 0.2 })
		near(S.catmullClark(marked, 1).vertices[1], (p * 5 / 9):Lerp(p, 1.4 / 3))
		local out = S.catmullClark(S.crease(m, nil, { [1] = 10 }), 3)
		near(out.vertices[1], p)
		near(A.get(out, VC, 1), 10)
		assert(A.get(out, VC, 9) == 0)
	end)
	test("Fractional edge points interpolate independently from vertex crease masks", function()
		local m, n = cube()
		local key = edge(1, n[1])
		local e = m:topology().edges[key]
		local sum = m.vertices[e.a] + m.vertices[e.b]
		for _, fid in e.faces do
			local center = Vector3.zero
			for _, v in m.faces[fid].vertices do
				center += m.vertices[v]
			end
			sum += center / #m.faces[fid].vertices
		end
		local midpoint = (m.vertices[e.a] + m.vertices[e.b]) * 0.5
		local out = S.catmullClark(S.crease(m, { [key] = 0.25 }), 1)
		near(out.vertices[edgeVertex(m, key)], (sum / 4):Lerp(midpoint, 0.25))
	end)
	test("Uniform sharpness decays once per level and preserves only parent edge children", function()
		local m, n = cube()
		local key = edge(1, n[1])
		local marked = S.crease(m, { [key] = 2.5 }, { [1] = 2.5 })
		for level, expected in { 1.5, 0.5, 0 } do
			local out = S.catmullClark(marked, level)
			local count = 0
			for _, value in out.attributes[EC].values do
				near(value, expected)
				count += 1
			end
			assert(count == (level < 3 and 2 ^ level or 0))
			near(A.get(out, VC, 1), expected)
		end
		assert(A.get(marked, EC, key) == 2.5)
	end)
	test("Chaikin crease propagation varies with the sharp neighbours at each endpoint", function()
		local m, n = cube()
		local k1, k2 = edge(1, n[1]), edge(1, n[2])
		local marked = S.crease(m, { [k1] = 2, [k2] = 4 })
		local out = S.catmullClark(marked, 1, { creasing = "chaikin" })
		near(A.get(out, EC, edge(1, edgeVertex(m, k1))), 1.5)
		near(A.get(out, EC, edge(n[1], edgeVertex(m, k1))), 1)
		near(A.get(out, EC, edge(1, edgeVertex(m, k2))), 2.5)
		near(A.get(out, EC, edge(n[2], edgeVertex(m, k2))), 3)
		assert(out:validate().closed)
	end)
	test("Boundary controls preserve optional corners without authoring implicit creases", function()
		local m = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3, 4 })
		m = S.crease(m, {}, {})
		near(S.catmullClark(m, 1).vertices[1], Vector3.new(0.125, 0.125, 0))
		for _, mode in { "edgeAndCorner", "fixed" } do
			local out = S.catmullClark(m, 2, { boundary = mode })
			near(out.vertices[1], Vector3.zero)
			assert(next(out.attributes[EC].values) == nil and next(out.attributes[VC].values) == nil)
		end
	end)
	test("Multires respects crease options and preserves source channels during coarse commits", function()
		local m = cube()
		local edges = {}
		for k in m:topology().edges do
			edges[k] = 10
		end
		m = S.crease(m, edges)
		local multi = S.multires(m, 2)
		local before = multi:get()
		near(before:volume(), 8)
		multi:select(1)
		local edited = multi:get()
		for id, p in edited.vertices do
			edited:setPosition(id, p + Vector3.new(3, 4, 5))
		end
		multi:commit(edited)
		multi:select(3)
		local after = multi:get()
		for id, p in before.vertices do
			near(after.vertices[id], p + Vector3.new(3, 4, 5))
		end
		near(after:volume(), 8)
		assert(m.vertices[1] ~= edited.vertices[1])
	end)
	test("Subdivision rejects malformed crease data disconnected fans budgets and cancellation", function()
		local m = cube()
		local before = E.IO.encode(m)
		for _, fn in
			{
				function()
					S.crease(m, { ["1:2"] = -1 })
				end,
				function()
					S.crease(m, { ["1:2"] = 11 })
				end,
				function()
					S.crease(m, { ["1:2"] = 0 / 0 })
				end,
				function()
					S.crease(m, { ["1:99"] = 1 })
				end,
				function()
					S.catmullClark(m, 1, { maxFaces = 23 })
				end,
				function()
					S.catmullClark(m, 1, { maxVertices = 25 })
				end,
				function()
					S.catmullClark(m, 17)
				end,
				function()
					S.catmullClark(m, 1, { boundary = "bad" })
				end,
				function()
					S.catmullClark(m, 1, { creasing = "bad" })
				end,
				function()
					S.catmullClark(m, 2, {
						checkpoint = function()
							error("cancelled")
						end,
					})
				end,
			}
		do
			assert(not pcall(fn))
		end
		local fan = E.Topology.join({ m, E.Deform.transform(m, CFrame.new(2, 2, 2)) })
		fan = E.Topology.weld(fan, 1e-5)
		assert(not pcall(S.catmullClark, fan, 1))
		assert(E.IO.encode(m) == before)
	end)
	test("Infinite crease normals remain split across hard edges after subdivision", function()
		local m = cube()
		local edges = {}
		for key in m:topology().edges do
			edges[key] = 10
		end
		local out = S.catmullClark(S.crease(m, edges), 2)
		for fid, f in out.faces do
			local normal = out:faceNormal(fid)
			for _, c in f.corners do
				near(c.normal, normal)
			end
		end
	end)
	test("Sharp normal channels survive splitting and direct normal recalculation", function()
		local m = cube()
		local edges = {}
		for key in m:topology().edges do
			edges[key] = true
		end
		m = A.set(A.create(m, "sharp_edge", "edge", "boolean", false, "max"), "sharp_edge", edges)
		m:recalculateNormals()
		for fid, f in m.faces do
			for _, c in f.corners do
				near(c.normal, m:faceNormal(fid))
			end
		end
		local out = E.Topology.splitEdge(m, 1, 2)
		for fid, f in out.faces do
			for _, c in f.corners do
				near(c.normal, out:faceNormal(fid))
			end
		end
		assert(not pcall(function()
			m:recalculateNormals(nil, { ["1:99"] = true })
		end))
	end)
	report.success = report.failed == 0
	return report
end
