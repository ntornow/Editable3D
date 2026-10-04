return function(E)
	local A = E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 2e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function field(p)
		return 2 * p.X - 3 * p.Z + 7
	end
	local function decorate(mesh)
		local m = mesh:clone()
		local values = { field = {}, cornerField = {}, edge = {}, label = {}, flag = {} }
		m.groups.gradient = {}
		for id, p in m.vertices do
			values.field[id] = field(p)
			values.flag[id] = false
			m.groups.gradient[id] = (p.X + 2) / 4
			m.weights[id] = { Left = (2 - p.X) / 4, Right = (p.X + 2) / 4 }
		end
		for fid, f in m.faces do
			values.label[fid] = "surface"
			f.material = 3
			for i, id in f.vertices do
				local p = m.vertices[id]
				values.cornerField[fid .. ":" .. i] = field(p)
				f.corners[i].uv = Vector2.new((p.X + 2) / 4, (p.Z + 2) / 4)
				f.corners[i].normal = Vector3.yAxis
			end
		end
		for key in E.Connectivity.index(m).edges do
			values.edge[key] = 9
		end
		for _, d in
			{
				{ "field", "vertex", "number", 0 },
				{ "cornerField", "corner", "number", 0 },
				{ "edge", "edge", "number", 0 },
				{ "label", "face", "string", "" },
				{ "flag", "vertex", "boolean", true },
			}
		do
			m = A.set(A.create(m, d[1], d[2], d[3], d[4]), d[1], values[d[1]])
		end
		return m
	end
	local function disabled(names)
		return { names = names, corners = false, materials = false, groups = false, weights = false }
	end
	test(
		"Surface projection reconstructs independent affine fields on a different grid in every domain",
		function()
			local source = decorate(E.Primitives.grid(1, 1, Vector2.new(4, 4)))
			local target =
				E.Deform.transform(E.Primitives.grid(3, 3, Vector2.new(3, 3)), CFrame.new(0, 0.25, 0))
			local beforeS, beforeT = E.IO.encode(source), E.IO.encode(target)
			local out, r = A.project(source, target)
			assert(r.complete and r.sourceCharts == 1 and r.queries > 0 and out:validate().valid)
			for id, p in out.vertices do
				assert(p == target.vertices[id] and A.get(out, "flag", id) == false)
				near(A.get(out, "field", id), field(p))
				near(out.groups.gradient[id], (p.X + 2) / 4)
				near(out.weights[id].Right, (p.X + 2) / 4)
				near(out.weights[id].Left + out.weights[id].Right, 1)
			end
			for fid, f in out.faces do
				assert(f.material == 3 and A.get(out, "label", fid) == "surface")
				for i, id in f.vertices do
					local p = out.vertices[id]
					near(A.get(out, "cornerField", fid .. ":" .. i), field(p))
					near(f.corners[i].uv.X, (p.X + 2) / 4)
					near(f.corners[i].uv.Y, (p.Z + 2) / 4)
					assert(f.corners[i].normal == Vector3.yAxis)
				end
			end
			for key in E.Connectivity.index(out).edges do
				near(A.get(out, "edge", key), 9)
			end
			assert(#A.names(E.IO.decode(E.IO.encode(out))) == 5)
			assert(E.IO.encode(source) == beforeS and E.IO.encode(target) == beforeT)
		end
	)
	test(
		"Face anchored connected charts reconstruct corner discontinuities at shared target vertices",
		function()
			local source = E.Primitives.grid(2, 1, Vector2.new(4, 4))
			local values = {}
			for fid, f in source.faces do
				for i, id in f.vertices do
					local p = source.vertices[id]
					f.corners[i].uv = Vector2.new(p.X + 10 * fid, p.Z)
					values[fid .. ":" .. i] = "chart" .. fid
				end
			end
			source = A.set(A.create(source, "chart", "corner", "string", ""), "chart", values)
			local target =
				E.Deform.transform(E.Primitives.grid(2, 1, Vector2.new(3, 3)), CFrame.new(0, 0.1, 0))
			local out, r = A.project(source, target, { maxDistance = 0.2 })
			assert(r.complete and r.sourceCharts == 2)
			for fid, f in out.faces do
				for i, id in f.vertices do
					near(f.corners[i].uv.X, out.vertices[id].X + 10 * fid)
					assert(A.get(out, "chart", fid .. ":" .. i) == "chart" .. fid)
				end
			end
		end
	)
	test("Nearest corner mode explicitly samples across source chart boundaries", function()
		local source = E.Primitives.grid(2, 1, Vector2.new(4, 4))
		for fid, f in source.faces do
			for _, c in f.corners do
				c.uv = Vector2.new(fid, 0)
			end
		end
		local target = E.Primitives.grid(1, 1, Vector2.new(3, 3))
		local nearest, r = A.project(source, target, { cornerMode = "nearest" })
		assert(r.complete)
		for _, f in nearest.faces do
			for i, id in f.vertices do
				near(f.corners[i].uv.X, nearest.vertices[id].X < 0 and 1 or 2)
			end
		end
		local chart = A.project(source, target)
		local first = chart.faces[1].corners[1].uv.X
		for _, c in chart.faces[1].corners do
			near(c.uv.X, first)
		end
	end)
	test(
		"Vertex projection masks and factors blend selected channels and preserve unrelated target data",
		function()
			local source = E.Primitives.grid(1, 1, Vector2.new(4, 4))
			source = A.create(source, "value", "vertex", "number", 0)
			local values = {}
			for id in source.vertices do
				values[id] = 10
			end
			source = A.set(source, "value", values)
			local target = A.create(source, "retained", "face", "string", "untouched")
			local zeros = {}
			for id in target.vertices do
				zeros[id] = 0
			end
			target = A.set(target, "value", zeros)
			local options = disabled({ "value" })
			options.factor = 0.25
			options.masks = { vertex = { [1] = 0.5, [2] = true, [3] = false } }
			local out, r = A.project(source, target, options)
			near(A.get(out, "value", 1), 1.25)
			near(A.get(out, "value", 2), 2.5)
			near(A.get(out, "value", 3), 0)
			near(A.get(out, "value", 4), 0)
			assert(A.get(out, "retained", 1) == "untouched" and r.matched.vertex == 2 and r.queries == 2)
		end
	)
	test("Categorical projection uses largest barycentric contribution with deterministic ties", function()
		local source = E.Mesh.new()
		local a, b, c =
			source:addVertex(Vector3.new(0, 0, 0)),
			source:addVertex(Vector3.new(2, 0, 0)),
			source:addVertex(Vector3.new(0, 0, 2))
		source:addFace({ a, c, b })
		source = A.set(
			A.create(source, "name", "vertex", "string", ""),
			"name",
			{ [a] = "A", [b] = "B", [c] = "C" }
		)
		local target = E.Mesh.new()
		local id = target:addVertex(Vector3.new(1.4, 0.2, 0.2))
		local out, r = A.project(source, target, disabled({ "name" }))
		assert(r.complete and A.get(out, "name", id) == "B")
		local first = E.IO.encode(out)
		assert(E.IO.encode(A.project(source, target, disabled({ "name" }))) == first)
	end)
	test("Edge projection agrees with independent closest segment distances", function()
		local source = E.Primitives.grid(1, 1, Vector2.new(4, 4))
		local values = {}
		local n = 0
		local edges = E.Connectivity.index(source).edges
		for key in edges do
			n += 1
			values[key] = n
		end
		source = A.set(A.create(source, "edge", "edge", "number", 0), "edge", values)
		local target =
			E.Deform.transform(E.Primitives.grid(2, 2, Vector2.new(2, 2)), CFrame.new(0.2, 0.1, 0.1))
		local out = A.project(source, target, disabled({ "edge" }))
		for key, e in E.Connectivity.index(out).edges do
			local p = (out.vertices[e.a] + out.vertices[e.b]) / 2
			local best, expected = math.huge, nil
			for old, edge in edges do
				local a, b = source.vertices[edge.a], source.vertices[edge.b]
				local d = b - a
				local t = math.clamp((p - a):Dot(d) / d:Dot(d), 0, 1)
				local distance = (p - (a + d * t)).Magnitude
				if distance < best then
					best, expected = distance, values[old]
				end
			end
			near(A.get(out, "edge", key), expected)
		end
	end)
	test("Unmatched projection keeps target values and reports incomplete correspondence", function()
		local source = decorate(E.Primitives.grid(1, 1, Vector2.new(4, 4)))
		local target = E.Deform.transform(source, CFrame.new(0, 10, 0))
		local options = disabled({ "field" })
		options.maxDistance = 1
		options.unmatched = "keep"
		local out, r = A.project(source, target, options)
		assert(not r.complete and r.matched.vertex == 0 and next(r.unmatched.vertex))
		assert(E.IO.encode(out) == E.IO.encode(target))
		options.unmatched = "error"
		assert(not pcall(A.project, source, target, options))
	end)
	test("Source face restrictions keep spatial projection on the chosen sheet", function()
		local lower = E.Primitives.grid(1, 1, Vector2.new(4, 4))
		local upper = E.Deform.transform(lower, CFrame.new(0, 1, 0))
		local source = E.Topology.join({ lower, upper })
		source = A.set(A.create(source, "sheet", "face", "number", 0), "sheet", { [1] = 1, [2] = 2 })
		local target = E.Deform.transform(lower, CFrame.new(0, 0.1, 0))
		local options = disabled({ "sheet" })
		options.sourceFaces = { [2] = true }
		local out, r = A.project(source, target, options)
		assert(r.complete and r.sourceCharts == 1 and A.get(out, "sheet", 1) == 2)
		near(r.maxSourceDistance, 0.9)
	end)
	test("Sharp edge channels split otherwise continuous source charts", function()
		local source = E.Primitives.grid(2, 1, Vector2.new(4, 4))
		local mark = {}
		for key, e in E.Connectivity.index(source).edges do
			if #e.faces == 2 then
				mark[key] = true
			end
		end
		source = A.set(A.create(source, "feature", "edge", "boolean", false), "feature", mark)
		local options = disabled({})
		options.corners = true
		options.seamAttributes = { "feature" }
		local _, r = A.project(source, source, options)
		assert(r.sourceCharts == 2 and r.complete)
	end)
	test("Projected fields are invariant under shared rigid transformations and scale", function()
		local source = decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)))
		local target = E.Deform.transform(E.Primitives.grid(3, 3, Vector2.new(3, 3)), CFrame.new(0, 0.2, 0))
		for _, scale in { 0.01, 10 } do
			local frame = CFrame.new(3, 7, -2) * CFrame.Angles(0.3, 0.7, -0.2)
			local a = E.Deform.transform(source, frame, Vector3.one * scale)
			local b = E.Deform.transform(target, frame, Vector3.one * scale)
			local out, r = A.project(a, b)
			assert(r.complete and r.sourceCharts == 1)
			for id in out.vertices do
				near(A.get(out, "field", id), field(target.vertices[id]), 0.001)
			end
		end
	end)
	test("Projection preserves empty schemas without inventing geometry", function()
		local source = decorate(E.Primitives.grid(1, 1, Vector2.new(4, 4)))
		local out, r = A.project(source, E.Mesh.new())
		assert(
			r.complete
				and r.queries == 0
				and not next(out.vertices)
				and #A.names(out) == 5
				and out.groups.gradient
		)
		assert(not next(E.IO.decode(E.IO.encode(out)).faces))
	end)
	test(
		"Projection rejects incompatible schemas invalid masks budgets and cancellation transactionally",
		function()
			local source = decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)))
			local target = E.Primitives.grid(3, 3, Vector2.new(3, 3))
			local beforeS, beforeT = E.IO.encode(source), E.IO.encode(target)
			for _, options in
				{
					{ maxWork = 1 },
					{ maxQueries = 1 },
					{ maxElements = 1 },
					{ factor = -1 },
					{ masks = { vertex = { [1] = 2 } } },
					{ masks = { vertex = { [999] = 1 } } },
					{ uvTolerance = -1 },
					{ cornerMode = "invalid" },
					{ sourceFaces = { [999] = true } },
					{ names = { "missing" } },
					{
						cancelled = function()
							return true
						end,
					},
					{
						checkpoint = function()
							error("cancel projection")
						end,
					},
				}
			do
				assert(not pcall(A.project, source, target, options))
			end
			local incompatible = A.create(target, "field", "face", "number", 0)
			assert(not pcall(A.project, source, incompatible))
			assert(E.IO.encode(source) == beforeS and E.IO.encode(target) == beforeT)
		end
	)
	test("Projection references sparse source IDs rather than array positions", function()
		local source = E.Mesh.new()
		for i = 1, 17 do
			source:addVertex(Vector3.new(i, 5, 0))
		end
		local a, b, c =
			source:addVertex(Vector3.new(-1, 0, -1)),
			source:addVertex(Vector3.new(1, 0, -1)),
			source:addVertex(Vector3.new(-1, 0, 1))
		source:addFace({ a, c, b })
		source = A.set(A.create(source, "field", "vertex", "number", 0), "field", {
			[a] = field(source.vertices[a]),
			[b] = field(source.vertices[b]),
			[c] = field(source.vertices[c]),
		})
		local target = E.Mesh.new()
		local id = target:addVertex(Vector3.new(-0.5, 0.2, -0.5))
		local out, r = A.project(source, target, disabled({ "field" }))
		near(A.get(out, "field", id), field(target.vertices[id]))
		for _, ref in r.maps.vertex[id] do
			assert(ref[1] >= 18)
		end
	end)
	test("Face and corner masks blend their own domains without moving the mesh", function()
		local source = E.Primitives.grid(1, 1, Vector2.new(4, 4))
		for _, f in source.faces do
			for _, c in f.corners do
				c.uv = Vector2.one
			end
		end
		source = A.set(A.create(source, "faceValue", "face", "number", 0), "faceValue", { [1] = 20 })
		source = A.create(source, "cornerValue", "corner", "number", 0)
		local values = {}
		for i = 1, 4 do
			values["1:" .. i] = 20
		end
		source = A.set(source, "cornerValue", values)
		local target = A.set(source, "faceValue", { [1] = 2 })
		for _, f in target.faces do
			for _, c in f.corners do
				c.uv = Vector2.zero
			end
		end
		for i = 1, 4 do
			values["1:" .. i] = 2
		end
		target = A.set(target, "cornerValue", values)
		local out = A.project(source, target, {
			factor = 0.5,
			groups = false,
			weights = false,
			materials = false,
			masks = { face = { [1] = 0.5 }, corner = { ["1:1"] = 0.5 } },
		})
		near(A.get(out, "faceValue", 1), 6.5)
		near(A.get(out, "cornerValue", "1:1"), 6.5)
		near(out.faces[1].corners[1].uv.X, 0.25)
		for i = 2, 4 do
			near(A.get(out, "cornerValue", "1:" .. i), 2)
			assert(out.faces[1].corners[i].uv == Vector2.zero)
		end
		for id, p in target.vertices do
			assert(out.vertices[id] == p)
		end
	end)
	test("Voxel reconstruction projects all source schemas groups skin and intrinsic corner data", function()
		local source = decorate(E.Primitives.sphere(1.3, 8, 4))
		local before = E.IO.encode(source)
		local out, r = E.Remesh.voxel(source, 0.6)
		assert(
			r.complete
				and r.transferred
				and r.projection.complete
				and out:validate().closed
				and #A.names(out) == 5
		)
		local index = E.Spatial.new(source)
		for id, p in out.vertices do
			local hit = index:closest(p)
			local closest = Vector3.zero
			local total = 0
			for _, ref in r.projection.maps.vertex[id] do
				closest += source.vertices[ref[1]] * ref[2]
				total += ref[2]
			end
			closest /= total
			near((p - closest).Magnitude, hit.distance)
			near(A.get(out, "field", id), field(closest))
			near(out.groups.gradient[id], (closest.X + 2) / 4)
			near(out.weights[id].Left + out.weights[id].Right, 1)
			assert(A.get(out, "flag", id) == false)
		end
		for fid, f in out.faces do
			assert(f.material == 3 and A.get(out, "label", fid) == "surface")
			for _, c in f.corners do
				assert(typeof(c.uv) == "Vector2")
			end
		end
		assert(E.IO.encode(source) == before)
	end)
	test(
		"Explicit voxel geometry-only mode preserves reconstruction positions and reports skipped transfer",
		function()
			local source = decorate(E.Primitives.sphere(1.3, 8, 4))
			local full = E.Remesh.voxel(source, 0.7)
			local raw, r = E.Remesh.voxel(source, 0.7, { transfer = false })
			assert(r.complete and not r.transferred and #A.names(raw) == 0)
			for id, p in raw.vertices do
				assert(full.vertices[id] == p)
			end
			for fid, f in raw.faces do
				for i, id in f.vertices do
					assert(full.faces[fid].vertices[i] == id)
				end
			end
		end
	)
	test("Voxel Boolean projection preserves operand ownership and cutter corner correspondence", function()
		local a = E.Primitives.sphere(1.3, 8, 4)
		local b = E.Deform.transform(E.Primitives.sphere(1, 8, 4), CFrame.new(0.8, 0, 0))
		local function label(m, name)
			local values = {}
			for fid in m.faces do
				values[fid] = name
			end
			return A.set(A.create(m, "owner", "face", "string", ""), "owner", values)
		end
		a, b = label(a, "A"), label(b, "B")
		local out, r = E.Remesh.boolean(a, b, "subtract", 0.6, { materialOffsetB = 10 })
		assert(r.complete and out:validate().closed and r.inputMaps and r.sourceRefs)
		local seenA, seenB = false, false
		for fid, f in out.faces do
			local owner = A.get(out, "owner", fid)
			assert(owner == "A" or owner == "B")
			seenA = seenA or owner == "A"
			seenB = seenB or owner == "B"
			assert(f.material == (owner == "A" and 1 or 11))
		end
		assert(seenA and seenB)
		for old, joined in r.inputMaps.b.corner do
			assert(r.sourceRefs.corner[joined].operand == "b" and r.sourceRefs.corner[joined].id == old)
		end
	end)
	test("Voxel source sampling and allocation limits cancel without modifying input", function()
		local source = decorate(E.Primitives.sphere(1.3, 8, 4))
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxSourceTriangleSamples = 1 },
				{ maxCells = 1 },
				{ maxVertices = 2 },
				{ maxFaces = 2 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function()
						error("cancel voxel")
					end,
				},
				{ transfer = { maxQueries = 1 } },
			}
		do
			assert(not pcall(E.Remesh.voxel, source, 0.6, options))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Projected UVs and normalized skin survive native EditableMesh conversion", function()
		local source = decorate(E.Primitives.grid(1, 1, Vector2.new(4, 4)))
		local rig = E.Rig.new()
		local left, right = rig:addBone("Left"), rig:addBone("Right")
		for id, w in source.weights do
			source.weights[id] = { [left] = w.Left, [right] = w.Right }
		end
		local target = E.Deform.transform(E.Primitives.grid(3, 3, Vector2.new(3, 3)), CFrame.new(0, 0.2, 0))
		local out = A.project(source, target)
		local handle = E.Roblox.toEditable(out, { rig = rig })
		local ok, err = pcall(function()
			local restored, _, bones = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			for id, p in restored.vertices do
				local x = p.X + handle.origin.X
				for bone, w in restored.weights[id] do
					if bones.bones[bone].name == "Right" then
						near(w, (x + 2) / 4)
					end
				end
			end
			for _, f in restored.faces do
				for i, id in f.vertices do
					near(f.corners[i].uv.X, (restored.vertices[id].X + handle.origin.X + 2) / 4)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Maximum projection distance includes its boundary and zero factor makes no queries", function()
		local source = decorate(E.Primitives.grid(1, 1, Vector2.new(4, 4)))
		local target = E.Deform.transform(E.Primitives.grid(2, 2, Vector2.new(3, 3)), CFrame.new(0, 0.25, 0))
		local options = disabled({ "field" })
		options.maxDistance = 0.25
		local out, r = A.project(source, target, options)
		assert(r.complete)
		for id, p in out.vertices do
			near(A.get(out, "field", id), field(p))
		end
		options.factor = 0
		options.maxDistance = 0
		local inactive, empty = A.project(source, target, options)
		assert(empty.complete and empty.queries == 0)
		for id in inactive.vertices do
			near(A.get(inactive, "field", id), 0)
		end
	end)
	test("A periodic seam keeps both UV sides within one connected source chart", function()
		local source = E.Mesh.new()
		local lower, upper = {}, {}
		for i = 1, 8 do
			local angle = 2 * math.pi * (i - 1) / 8
			lower[i] = source:addVertex(Vector3.new(math.cos(angle), -1, math.sin(angle)))
			upper[i] = source:addVertex(Vector3.new(math.cos(angle), 1, math.sin(angle)))
		end
		for i = 1, 8 do
			local j = i % 8 + 1
			source:addFace({ lower[i], upper[i], upper[j], lower[j] }, {
				{ uv = Vector2.new((i - 1) / 8, 0) },
				{ uv = Vector2.new((i - 1) / 8, 1) },
				{ uv = Vector2.new(i / 8, 1) },
				{ uv = Vector2.new(i / 8, 0) },
			})
		end
		local options = disabled({})
		options.corners = true
		local out, r = A.project(source, source, options)
		assert(r.complete and r.sourceCharts == 1)
		for fid, f in out.faces do
			for i, c in f.corners do
				assert((c.uv - source.faces[fid].corners[i].uv).Magnitude < 1e-6)
			end
		end
		local refined = E.Adaptive.refine(source, 0.7, { maxOperations = 100 })
		local projected, rr = A.project(source, refined, options)
		assert(rr.complete and rr.sourceCharts == 1)
		for fid, f in projected.faces do
			for i, c in f.corners do
				assert((c.uv - refined.faces[fid].corners[i].uv).Magnitude < 1e-5)
			end
		end
	end)
	report.success = report.failed == 0
	return report
end
