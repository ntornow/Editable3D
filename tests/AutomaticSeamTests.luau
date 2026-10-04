return function(E)
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
	local function grid(n, hole)
		local m = E.Mesh.new()
		local function id(i, j)
			return i * (n + 1) + j + 1
		end
		for i = 0, n do
			for j = 0, n do
				m:addVertex(Vector3.new(i, j, 0))
			end
		end
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				if not hole or i == 0 or j == 0 or i == n - 1 or j == n - 1 then
					local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
					local corners = {}
					for k, v in ids do
						corners[k] = { uv = Vector2.new(m.vertices[v].X, m.vertices[v].Y) }
					end
					m:addFace(ids, corners)
				end
			end
		end
		m:removeUnused()
		return m, id
	end
	local function chartCheck(mesh, seams, result)
		assert(result.complete)
		local flat, unwrap = E.Unwrap.unwrap(mesh, seams, { method = "harmonic", iterations = 3000 })
		assert(unwrap.charts == #result.charts)
		for _, r in unwrap.reports do
			assert(r.converged)
		end
		local visited = {}
		for _, chart in result.charts do
			assert(
				chart.boundaryLoops == 1
					and chart.eulerCharacteristic == 1
					and chart.vertices - chart.edges + #chart.faces == 1
			)
			for _, fid in chart.faces do
				assert(not visited[fid] and result.faceToChart[fid] == chart.id)
				visited[fid] = true
			end
		end
		assert(count(visited) == count(mesh.faces))
		return flat
	end
	test("Planar grids recover ordinary interior edges and independent Euler counts", function()
		local m = grid(4)
		local seams, r = E.Unwrap.autoSeams(m, { angleLimit = 0, normalCone = 0 })
		assert(
			#r.charts == 1
				and r.charts[1].vertices == 25
				and r.charts[1].edges == 40
				and r.charts[1].boundaryEdges == 16
				and r.recoveredEdges == 9
		)
		for key, edge in m:topology().edges do
			assert((seams[key] == true) == (#edge.faces == 1))
		end
		chartCheck(m, seams, r)
	end)
	test("Tree-only and bounded cycle recovery still produce complete disk cuts", function()
		local m = grid(4)
		for _, options in { { recoverCycles = false }, { maxClosureTests = 0 }, { maxClosureTests = 2 } } do
			local seams, r = E.Unwrap.autoSeams(m, options)
			chartCheck(m, seams, r)
			assert(#r.charts == 1 and r.closureTests <= (options.maxClosureTests or 0))
			if options.maxClosureTests then
				assert(r.closureLimited)
			end
		end
	end)
	test("Holed panels acquire a represented cut joining their boundaries", function()
		local m = grid(5, true)
		local original = E.Connectivity.analyze(m)
		assert(original.eulerCharacteristic == 0 and #original.boundaryLoops == 2)
		local seams, r = E.Unwrap.autoSeams(m)
		assert(#r.charts == 1 and r.charts[1].boundaryEdges > original.boundaryEdges)
		local flat = chartCheck(m, seams, r)
		local a = E.UV.analyze(flat)
		assert(a.complete and a.overlapFree and a.consistentOrientation)
	end)
	test("Default hard-surface seams produce six useful conformal box charts", function()
		local m = E.Primitives.box(Vector3.new(4, 3, 2))
		local seams, r = E.Unwrap.autoSeams(m)
		assert(#r.charts == 6 and count(seams) == 12)
		local out, unwrap = E.Unwrap.unwrap(m, seams, { method = "lscm" })
		assert(unwrap.charts == 6)
		for _, q in unwrap.reports do
			assert(q.converged and q.distortion.maxAngleRadians < 1e-5)
		end
		assert(E.UV.analyze(out).overlapFree)
	end)
	test("Closed sphere and genus-one torus have valid single disk cuts at wide limits", function()
		for _, m in { E.Primitives.sphere(2, 8, 4), E.Primitives.torus(3, 1, 6, 6) } do
			assert(m:validate().closed)
			local seams, r = E.Unwrap.autoSeams(m, { angleLimit = math.pi, normalCone = math.pi })
			assert(#r.charts == 1 and count(seams) > 0)
			chartCheck(m, seams, r)
		end
	end)
	test("Normal cones and chart-face bounds limit automatically grown regions", function()
		local m = E.Primitives.torus(3, 1, 8, 6)
		local seams, r =
			E.Unwrap.autoSeams(m, { angleLimit = math.pi, normalCone = math.rad(70), maxChartFaces = 7 })
		assert(#r.charts >= 7)
		for _, chart in r.charts do
			assert(#chart.faces <= 7 and chart.maximumNormalAngle <= math.rad(70) + 1e-6)
		end
		chartCheck(m, seams, r)
	end)
	test("Explicit isolated interior seams cannot disappear during corner quotient recovery", function()
		local m, id = grid(3)
		local key = id(1, 1) .. ":" .. id(1, 2)
		local seams, r = E.Unwrap.autoSeams(m, { seams = { [key] = true } })
		assert(seams[key] and r.reasons[key] == "explicit")
		local flat = chartCheck(m, seams, r)
		local edge = m:topology().edges[key]
		local a, b = flat.faces[edge.faces[1]], flat.faces[edge.faces[2]]
		local different = false
		for _, vertex in { edge.a, edge.b } do
			local ia, ib = table.find(a.vertices, vertex), table.find(b.vertices, vertex)
			different = different or a.corners[ia].uv ~= b.corners[ib].uv
		end
		assert(different)
	end)
	test("Boolean numeric and custom edge feature channels are retained cuts", function()
		for _, kind in
			{
				{ "uv_seam", "boolean", true },
				{ "sharp_edge", "boolean", true },
				{ "subdivision_edge_sharpness", "number", 2 },
				{ "custom", "number", 0.5 },
			}
		do
			local m, id = grid(3)
			m = E.Attributes.create(m, kind[1], "edge", kind[2], if kind[2] == "boolean" then false else 0)
			local key = id(1, 1) .. ":" .. id(1, 2)
			m.attributes[kind[1]].values[key] = kind[3]
			local seams, r =
				E.Unwrap.autoSeams(m, { seamAttributes = kind[1] == "custom" and { "custom" } or nil })
			assert(seams[key] and r.reasons[key] == "attribute")
			chartCheck(m, seams, r)
		end
	end)
	test("Materials and preexisting UV discontinuities have explicit delimiter controls", function()
		local m = grid(2)
		m.faces[1].material = 2
		local _, r = E.Unwrap.autoSeams(m)
		assert(#r.charts == 2)
		local _, q = E.Unwrap.autoSeams(m, { splitMaterials = false })
		assert(#q.charts == 1)
		m = grid(2)
		for _, c in m.faces[1].corners do
			c.uv += Vector2.new(10, 0)
		end
		local _, a = E.Unwrap.autoSeams(m, { preserveUVSeams = true })
		local _, b = E.Unwrap.autoSeams(m)
		assert(#a.charts == 2 and #b.charts == 1)
	end)
	test("Disconnected components and concave polygons remain separate valid charts", function()
		local m = E.Topology.join({ grid(2), E.Deform.transform(grid(2), CFrame.new(10, 0, 0)) })
		local seams, r = E.Unwrap.autoSeams(m)
		assert(#r.charts == 2)
		chartCheck(m, seams, r)
		local polygon = E.Mesh.new()
		for _, p in { { 0, 0 }, { 3, 0 }, { 3, 1 }, { 1, 1 }, { 1, 3 }, { 0, 3 } } do
			polygon:addVertex(Vector3.new(p[1], p[2], 0))
		end
		polygon:addFace({ 1, 2, 3, 4, 5, 6 })
		local cuts, q = E.Unwrap.autoSeams(polygon)
		assert(#q.charts == 1 and count(cuts) == 6)
		chartCheck(polygon, cuts, q)
	end)
	test("Source corner data every typed domain skin and groups remain untouched", function()
		local m = grid(2)
		m = E.Attributes.create(m, "v", "vertex", "number", 3)
		m = E.Attributes.create(m, "e", "edge", "boolean", false)
		m = E.Attributes.create(m, "f", "face", "string", "panel")
		m = E.Attributes.create(m, "c", "corner", "Vector2", Vector2.one)
		m.attributes.v.values[1] = 8
		m.weights[1] = { a = 0.2, b = 0.8 }
		m.groups.mask = { [1] = 0.7 }
		m.faces[1].corners[1].color = Color3.new(0.2, 0.3, 0.4)
		local before = E.IO.encode(m)
		local seams, r = E.Unwrap.autoSeams(m)
		assert(E.IO.encode(m) == before and r.complete and count(seams) > 0)
	end)
	test("Source and settings snapshots precede every user callback", function()
		local m, id = grid(3)
		local key = id(1, 1) .. ":" .. id(1, 2)
		local options = { seams = { [key] = true }, maxChartFaces = 9 }
		options.checkpoint = function(status)
			if status.stage == "begin" then
				options.seams[key] = false
				options.maxChartFaces = 1
				m.vertices[1] = Vector3.new(999, 999, 999)
			end
		end
		local seams, r = E.Unwrap.autoSeams(m, options)
		assert(seams[key] and r.reasons[key] == "explicit" and #r.charts == 1)
	end)
	test("Rigid frames and power-of-two scale preserve planar boundary decisions", function()
		local m = grid(3)
		local expected = E.Unwrap.autoSeams(m)
		for _, scale in { 2 ^ -12, 1, 2 ^ 12 } do
			local transformed = m:clone()
			for id, p in transformed.vertices do
				transformed.vertices[id] =
					Vector3.new(p.Y * scale + 2 ^ 18, p.X * scale - 2 ^ 18, -p.Z * scale)
			end
			if scale == 2 ^ -12 then
				for id, p in m.vertices do
					transformed.vertices[id] = Vector3.new(p.Y * scale, p.X * scale, -p.Z * scale)
				end
			end
			local seams, r = E.Unwrap.autoSeams(transformed)
			assert(r.complete and count(seams) == count(expected))
			for key in expected do
				assert(seams[key])
			end
		end
	end)
	test("Input operation and late callback limits reject without source mutations", function()
		local m = grid(3)
		local before = E.IO.encode(m)
		for _, options in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{ maxWork = 1 },
				{ maxCharts = 1, maxChartFaces = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(status)
						if status.stage == "chartForest" then
							error("stop")
						end
					end,
				},
			}
		do
			assert(not pcall(E.Unwrap.autoSeams, m, options))
			assert(E.IO.encode(m) == before)
		end
		for _, options in
			{
				{ angleLimit = -1 },
				{ normalCone = 4 },
				{ maxChartFaces = 0 },
				{ maxClosureTests = -1 },
				{ seams = { bad = true } },
				{ preserveUVSeams = 1 },
				{ seamAttributes = { "absent" } },
			}
		do
			assert(not pcall(E.Unwrap.autoSeams, m, options))
		end
	end)
	test("Empty meshes and nonmanifold or degenerate sources have explicit outcomes", function()
		local seams, r = E.Unwrap.autoSeams(E.Mesh.new())
		assert(r.complete and #r.charts == 0 and next(seams) == nil)
		local m = grid(1)
		m:addFace({ 1, 3, 4, 2 })
		assert(not pcall(E.Unwrap.autoSeams, m))
		local bad = E.Mesh.new()
		bad:addVertex(Vector3.zero)
		bad:addVertex(Vector3.xAxis)
		bad:addVertex(Vector3.new(2, 0, 0))
		bad:addFace({ 1, 2, 3 })
		assert(not pcall(E.Unwrap.autoSeams, bad))
	end)
	test("Sparse ordered IDs retain chart partitions and deterministic cut decisions", function()
		local source = grid(4, true)
		local cuts = E.Unwrap.autoSeams(source)
		local m = source:clone()
		m.vertices, m.faces = {}, {}
		for id, p in source.vertices do
			m.vertices[id * 101 + 11] = p
		end
		for fid, face in source.faces do
			local f = require(script.Parent.Util).copy(face)
			for i, id in f.vertices do
				f.vertices[i] = id * 101 + 11
			end
			m.faces[fid * 13 + 7] = f
		end
		m.nextVertex, m.nextFace = 10000, 10000
		local seams, r = E.Unwrap.autoSeams(m)
		assert(#r.charts == 1 and r.charts[1].id == 20 and count(seams) == count(cuts))
		for key in cuts do
			local parts = string.split(key, ":")
			assert(
				seams[(assert(tonumber(parts[1])) * 101 + 11) .. ":" .. (assert(tonumber(parts[2])) * 101 + 11)]
			)
		end
		local again, q = E.Unwrap.autoSeams(m)
		assert(q.work == r.work and count(again) == count(seams))
		for key in seams do
			assert(again[key])
		end
	end)
	test("Triangulated planar panels and boxes retain useful polygon-scale regions", function()
		local m = E.Topology.triangulate(grid(3))
		local seams, r = E.Unwrap.autoSeams(m)
		assert(#r.charts == 1 and r.charts[1].vertices == 16 and r.charts[1].boundaryEdges == 12)
		chartCheck(m, seams, r)
		local box = E.Topology.triangulate(E.Primitives.box(Vector3.new(2, 3, 4)))
		local cuts, q = E.Unwrap.autoSeams(box)
		assert(#q.charts == 6)
		for _, chart in q.charts do
			assert(#chart.faces == 2 and chart.boundaryEdges == 4)
		end
		chartCheck(box, cuts, q)
	end)
	test("Automatically seamed torus atlas survives native UV and normal conversion", function()
		local result = require(script.Parent.Examples.AutomaticAtlas)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid and restored:validate().closed)
			local analysis = E.UV.analyze(restored)
			assert(analysis.complete and analysis.overlapFree and analysis.consistentOrientation)
			for _, face in restored.faces do
				for _, c in face.corners do
					assert(c.uv and c.normal and math.abs(c.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
