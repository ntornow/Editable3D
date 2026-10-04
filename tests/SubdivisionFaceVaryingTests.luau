return function(E)
	local S, A = E.Subdivision, E.Attributes
	local PREFIX = "subdivision_fvar_topology:"
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tol)
		if typeof(a) == "number" then
			assert(math.abs(a - b) < (tol or 2e-6), tostring(a) .. " ~= " .. tostring(b))
		elseif typeof(a) == "Color3" then
			near(a.R, b.R, tol)
			near(a.G, b.G, tol)
			near(a.B, b.B, tol)
		else
			assert((a - b).Magnitude < (tol or 2e-6), tostring(a) .. " ~= " .. tostring(b))
		end
	end
	local function edge(a, b)
		return a < b and a .. ":" .. b or b .. ":" .. a
	end
	local function grid(nx, ny)
		local m = E.Mesh.new()
		local function id(i, j)
			return i * (ny + 1) + j + 1
		end
		for i = 0, nx do
			for j = 0, ny do
				m:addVertex(Vector3.new(i, j, 0))
			end
		end
		for i = 0, nx - 1 do
			for j = 0, ny - 1 do
				local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
				local corners = {}
				for k, v in ids do
					local p = m.vertices[v]
					corners[k] = {
						uv = Vector2.new(p.X, p.Y),
						color = Color3.new(p.X / nx, p.Y / ny, 0.3),
						alpha = p.X / nx,
					}
				end
				m:addFace(ids, corners)
			end
		end
		return m, id
	end
	local function cornersAt(mesh, id, fn)
		for fid, face in mesh.faces do
			for i, v in face.vertices do
				if v == id then
					fn(face.corners[i], fid .. ":" .. i, fid, i)
				end
			end
		end
	end
	local function uniqueAt(mesh, id, token)
		local seen = {}
		cornersAt(mesh, id, function(_, key)
			seen[A.get(mesh, PREFIX .. token, key)] = true
		end)
		local n = 0
		for _ in seen do
			n += 1
		end
		return n
	end
	local function stamp(mesh)
		local values = {}
		for fid, f in mesh.faces do
			for i, v in f.vertices do
				local p = mesh.vertices[v]
				values[fid .. ":" .. i] = p.X ^ 2 + p.Y ^ 3
			end
		end
		return A.set(A.create(mesh, "stamp", "corner", "number", 0), "stamp", values)
	end
	local function compareData(a, b)
		for fid, face in a.faces do
			for i, corner in face.corners do
				for _, name in { "uv", "color", "alpha" } do
					if corner[name] then
						near(corner[name], b.faces[fid].corners[i][name], 4e-6)
					end
				end
			end
		end
		for name, c in a.attributes do
			local d = assert(b.attributes[name])
			if name:sub(1, #PREFIX) ~= PREFIX then
				for key, value in c.values do
					near(value, d.values[key] or d.default, 4e-6)
				end
			end
		end
	end
	test("Legacy subdivision retains linear corner fields and creates no topology metadata", function()
		local m = grid(2, 2)
		local out = S.catmullClark(m, 1)
		cornersAt(out, 1, function(c)
			near(c.uv, Vector2.zero)
		end)
		near(out.vertices[1], Vector3.new(0.125, 0.125, 0))
		assert(not out.attributes[PREFIX .. "uv"])
	end)
	test("Smooth continuous UVs follow the independent positional projection", function()
		local m = grid(3, 3)
		local out = S.catmullClark(m, 2, { faceVarying = { uv = "smooth" } })
		for _, face in out.faces do
			for i, v in face.vertices do
				local p = out.vertices[v]
				near(face.corners[i].uv, Vector2.new(p.X, p.Y), 4e-6)
			end
		end
		assert(out:validate().valid)
		cornersAt(out, 1, function(c)
			assert(c.uv.X > 0 and c.uv.Y > 0)
		end)
	end)
	test("Typed scalar masks reproduce the regular nine-point Catmull Clark stencil", function()
		local m, id = grid(2, 2)
		m = stamp(m)
		local out = S.catmullClark(m, 1, { faceVarying = { ["attribute:stamp"] = "smooth" } })
		cornersAt(out, id(1, 1), function(_, key)
			near(A.get(out, "stamp", key), 3)
		end)
		assert(m.attributes.stamp.values["1:3"] == 2)
	end)
	test("Corner boundary and fully linear modes apply distinct constraints", function()
		local m, id = grid(2, 2)
		m = stamp(m)
		local output = {}
		for _, mode in { "smooth", "corners", "boundaries", "linear" } do
			output[mode] = S.catmullClark(m, 1, { faceVarying = { uv = mode, ["attribute:stamp"] = mode } })
		end
		cornersAt(output.smooth, 1, function(c)
			near(c.uv, Vector2.new(0.125, 0.125))
		end)
		for _, mode in { "corners", "boundaries", "linear" } do
			cornersAt(output[mode], 1, function(c)
				near(c.uv, Vector2.zero)
			end)
		end
		cornersAt(output.corners, id(1, 0), function(_, key)
			near(A.get(output.corners, "stamp", key), 1.25)
		end)
		cornersAt(output.boundaries, id(1, 0), function(_, key)
			near(A.get(output.boundaries, "stamp", key), 1)
		end)
		cornersAt(output.boundaries, id(1, 1), function(_, key)
			near(A.get(output.boundaries, "stamp", key), 3)
		end)
		cornersAt(output.linear, id(1, 1), function(_, key)
			near(A.get(output.linear, "stamp", key), 2)
		end)
	end)
	test("UV discontinuities preserve separate charts while another field stays continuous", function()
		local m, id = grid(2, 2)
		m = stamp(m)
		for fid, face in m.faces do
			if fid >= 3 then
				for _, c in face.corners do
					c.uv += Vector2.new(100, 0)
				end
			end
		end
		local out = S.catmullClark(m, 1, { faceVarying = { uv = "smooth", ["attribute:stamp"] = "smooth" } })
		local left, right = false, false
		cornersAt(out, id(1, 1), function(c, key)
			left = left or c.uv.X < 2
			right = right or c.uv.X > 100
			near(A.get(out, "stamp", key), 3)
		end)
		assert(
			left
				and right
				and uniqueAt(out, id(1, 1), "uv") == 2
				and uniqueAt(out, id(1, 1), "attribute:stamp") == 1
		)
	end)
	test("Explicit seams persist when all face-varying values are coincident", function()
		local m, id = grid(2, 2)
		for _, face in m.faces do
			for _, c in face.corners do
				c.uv = Vector2.zero
			end
		end
		local cuts = { [edge(id(1, 0), id(1, 1))] = true, [edge(id(1, 1), id(1, 2))] = true }
		local first =
			S.catmullClark(m, 1, { faceVarying = { uv = "smooth" }, faceVaryingSeams = { uv = cuts } })
		assert(uniqueAt(first, id(1, 1), "uv") == 2)
		local second = S.catmullClark(first, 1, { faceVarying = { uv = "smooth" } })
		assert(uniqueAt(second, id(1, 1), "uv") == 2)
		for _, face in second.faces do
			for _, c in face.corners do
				assert(c.uv == Vector2.zero)
			end
		end
		assert(not m.attributes[PREFIX .. "uv"])
	end)
	test("Face-varying topology survives JSON and separate refinement calls", function()
		local m, id = grid(2, 2)
		local opts = {
			faceVarying = { uv = "smooth" },
			faceVaryingSeams = {
				uv = { [edge(id(1, 0), id(1, 1))] = true, [edge(id(1, 1), id(1, 2))] = true },
			},
		}
		local all = S.catmullClark(m, 2, opts)
		local first = E.IO.decode(E.IO.encode(S.catmullClark(m, 1, opts)))
		local second = S.catmullClark(first, 1, { faceVarying = { uv = "smooth" } })
		compareData(all, second)
		assert(uniqueAt(second, id(1, 1), "uv") == 2)
	end)
	test("Explicit linear mode matches legacy values while carrying seam topology", function()
		local m, id = grid(2, 2)
		local out = S.catmullClark(m, 2, {
			faceVarying = { uv = "linear", color = "linear", alpha = "linear" },
			faceVaryingSeams = { uv = { [edge(id(1, 0), id(1, 1))] = true } },
		})
		local old = S.catmullClark(m, 2)
		for fid, face in out.faces do
			for i, c in face.corners do
				near(c.uv, old.faces[fid].corners[i].uv)
				near(c.color, old.faces[fid].corners[i].color)
				near(c.alpha, old.faces[fid].corners[i].alpha)
			end
		end
		assert(out.attributes[PREFIX .. "uv"])
	end)
	test("Dart seams smooth in corner mode and pin in concave mode", function()
		local m, id = grid(2, 2)
		local cut = { [edge(id(1, 1), id(1, 2))] = true }
		local a = S.catmullClark(m, 1, { faceVarying = { uv = "corners" }, faceVaryingSeams = { uv = cut } })
		local b = S.catmullClark(m, 1, { faceVarying = { uv = "concave" }, faceVaryingSeams = { uv = cut } })
		cornersAt(a, id(1, 1), function(c)
			near(c.uv, Vector2.new(1, 1.25))
		end)
		cornersAt(b, id(1, 1), function(c)
			near(c.uv, Vector2.one)
		end)
		assert(uniqueAt(a, id(1, 1), "uv") == 1)
	end)
	test("Three-region junctions pin without collapsing distinct chart identities", function()
		local m, id = grid(2, 2)
		for _, face in m.faces do
			for _, c in face.corners do
				c.uv = c.uv * c.uv
			end
		end
		local cuts = {}
		for _, other in { id(0, 1), id(1, 2), id(2, 1) } do
			cuts[edge(id(1, 1), other)] = true
		end
		local a = S.catmullClark(m, 1, { faceVarying = { uv = "corners" }, faceVaryingSeams = { uv = cuts } })
		local b =
			S.catmullClark(m, 1, { faceVarying = { uv = "junctions" }, faceVaryingSeams = { uv = cuts } })
		local moved = false
		cornersAt(a, id(1, 1), function(c)
			moved = moved or (c.uv - Vector2.one).Magnitude > 0.1
		end)
		assert(moved and uniqueAt(b, id(1, 1), "uv") == 3)
		cornersAt(b, id(1, 1), function(c)
			near(c.uv, Vector2.one)
		end)
	end)
	test("Concave chart fans receive the additional corner constraint", function()
		local m, id = grid(2, 2)
		for _, face in m.faces do
			for _, c in face.corners do
				c.uv = c.uv * c.uv
			end
		end
		local cuts = { [edge(id(1, 1), id(1, 2))] = true, [edge(id(1, 1), id(2, 1))] = true }
		local a =
			S.catmullClark(m, 1, { faceVarying = { uv = "junctions" }, faceVaryingSeams = { uv = cuts } })
		local b = S.catmullClark(m, 1, { faceVarying = { uv = "concave" }, faceVaryingSeams = { uv = cuts } })
		local moved = false
		cornersAt(a, id(1, 1), function(c)
			moved = moved or (c.uv - Vector2.one).Magnitude > 0.1
		end)
		assert(moved and uniqueAt(b, id(1, 1), "uv") == 2)
		cornersAt(b, id(1, 1), function(c)
			near(c.uv, Vector2.one)
		end)
	end)
	test("Fractional and Chaikin geometric creases constrain smooth projected data", function()
		local m, id = grid(3, 3)
		m = S.crease(m, {
			[edge(id(1, 0), id(1, 1))] = 0.4,
			[edge(id(1, 1), id(1, 2))] = 1.7,
			[edge(id(1, 2), id(1, 3))] = 2.2,
		}, { [id(1, 1)] = 0.3 })
		for _, creasing in { "uniform", "chaikin" } do
			local out = S.catmullClark(m, 2, { creasing = creasing, faceVarying = { uv = "smooth" } })
			for _, face in out.faces do
				for i, v in face.vertices do
					local p = out.vertices[v]
					near(face.corners[i].uv, Vector2.new(p.X, p.Y), 5e-6)
				end
			end
		end
	end)
	test("Geometric boundary and vertex constraints take precedence over data smoothing", function()
		local m = grid(2, 2)
		for _, boundary in { "edgeAndCorner", "fixed" } do
			local out = S.catmullClark(m, 2, { boundary = boundary, faceVarying = { uv = "smooth" } })
			cornersAt(out, 1, function(c)
				near(c.uv, Vector2.zero)
			end)
			for _, face in out.faces do
				for i, v in face.vertices do
					local p = out.vertices[v]
					near(face.corners[i].uv, Vector2.new(p.X, p.Y), 4e-6)
				end
			end
		end
		m = S.crease(m, nil, { [5] = 10 })
		local out = S.catmullClark(m, 2, { faceVarying = { uv = "smooth" } })
		cornersAt(out, 5, function(c)
			near(c.uv, Vector2.one)
		end)
	end)
	test("Closed extraordinary vertices and vector fields use smooth position masks", function()
		local m = E.Primitives.box(Vector3.one * 2)
		local values = {}
		for fid, face in m.faces do
			for i, v in face.vertices do
				values[fid .. ":" .. i] = m.vertices[v]
			end
		end
		m = A.set(A.create(m, "positionField", "corner", "Vector3", Vector3.zero), "positionField", values)
		local out = S.catmullClark(m, 2, { faceVarying = { ["attribute:positionField"] = "smooth" } })
		for fid, face in out.faces do
			for i, v in face.vertices do
				near(A.get(out, "positionField", fid .. ":" .. i), out.vertices[v], 4e-6)
			end
		end
		assert(out:validate().closed)
	end)
	test("Polygon face points use independent averages for numeric and color data", function()
		local m = E.Mesh.new()
		local ids, corners = {}, {}
		local sum = Vector2.zero
		for i = 1, 5 do
			local a = (i - 1) * 2 * math.pi / 5
			ids[i] = m:addVertex(Vector3.new(math.cos(a), math.sin(a), 0))
			corners[i] = { uv = Vector2.new(i, i * i) }
			sum += corners[i].uv
		end
		m:addFace(ids, corners)
		local out = S.catmullClark(m, 1, { faceVarying = { uv = "smooth" } })
		for _, face in out.faces do
			near(face.corners[3].uv, sum / 5)
		end
		local expected = corners[1].uv * 0.75 + (corners[2].uv + corners[5].uv) * 0.125
		near(out.faces[1].corners[1].uv, expected)
	end)
	test("Color alpha and sparse numeric defaults share independent channel topology", function()
		local m = grid(2, 2)
		m = A.create(m, "sparse", "corner", "number", 7)
		local out = S.catmullClark(
			m,
			2,
			{ faceVarying = { color = "smooth", alpha = "smooth", ["attribute:sparse"] = "smooth" } }
		)
		assert(next(out.attributes.sparse.values) == nil)
		for _, face in out.faces do
			for i, v in face.vertices do
				local p = out.vertices[v]
				near(face.corners[i].color, Color3.new(p.X / 2, p.Y / 2, 0.3))
				near(face.corners[i].alpha, p.X / 2)
			end
		end
	end)
	test("Boolean edge channels can specify seams without altering source masks", function()
		local m, id = grid(2, 2)
		local cut = { [edge(id(1, 0), id(1, 1))] = true, [edge(id(1, 1), id(1, 2))] = true }
		m = A.set(A.create(m, "cut", "edge", "boolean", false, "max"), "cut", cut)
		local before = E.IO.encode(m)
		local out =
			S.catmullClark(m, 2, { faceVarying = { uv = "smooth" }, faceVaryingSeams = { uv = "cut" } })
		assert(uniqueAt(out, id(1, 1), "uv") == 2 and E.IO.encode(m) == before)
	end)
	test("Unrelated attributes skin and groups match ordinary subdivision", function()
		local m = grid(2, 2)
		m.weights[1] = { Bone = 1 }
		m.groups.pick = { [1] = 1, [5] = 0.5 }
		m = A.set(A.create(m, "heat", "vertex", "number", 0), "heat", { [5] = 8 })
		m = A.set(A.create(m, "region", "face", "string", "none"), "region", { [1] = "selected" })
		local ordinary = S.catmullClark(m, 2)
		local out = S.catmullClark(m, 2, { faceVarying = { uv = "smooth" } })
		for id, p in ordinary.vertices do
			near(out.vertices[id], p)
			near(A.get(out, "heat", id), A.get(ordinary, "heat", id))
			near(out.groups.pick[id], ordinary.groups.pick[id])
			near((out.weights[id] or {}).Bone or 0, (ordinary.weights[id] or {}).Bone or 0)
		end
		for fid in ordinary.faces do
			assert(A.get(out, "region", fid) == A.get(ordinary, "region", fid))
		end
	end)
	test("Multires coarse commits retain authored face-varying cuts and masks", function()
		local m, id = grid(2, 2)
		m = stamp(m)
		local opts = {
			faceVarying = { uv = "smooth", ["attribute:stamp"] = "smooth" },
			faceVaryingSeams = {
				uv = { [edge(id(1, 0), id(1, 1))] = true, [edge(id(1, 1), id(1, 2))] = true },
			},
		}
		local stack = S.multires(m, 2, opts)
		local coarse = stack:select(1)
		coarse.vertices[id(1, 1)] += Vector3.new(0, 0, 0.3)
		stack:commit(coarse)
		local fine = stack:select(3)
		local expected = S.catmullClark(coarse, 2, opts)
		compareData(fine, expected)
		assert(uniqueAt(fine, id(1, 1), "uv") == 2)
	end)
	test("Sparse identifiers preserve channel interpolation and independent data copies", function()
		local source, id = grid(2, 2)
		local m = source:clone()
		local positions = {}
		for v, p in m.vertices do
			positions[10 * v + 7] = p
		end
		m.vertices = positions
		local faces = {}
		for fid, face in m.faces do
			for i, v in face.vertices do
				face.vertices[i] = 10 * v + 7
			end
			faces[fid * 20 + 3] = face
		end
		m.faces = faces
		local out = S.catmullClark(m, 2, { faceVarying = { uv = "smooth" } })
		for _, face in out.faces do
			for i, v in face.vertices do
				local p = out.vertices[v]
				near(face.corners[i].uv, Vector2.new(p.X, p.Y), 4e-6)
			end
		end
		assert(out:validate().valid and m.vertices[10 * id(1, 1) + 7] == Vector3.new(1, 1, 0))
		out.faces[1].corners[1].uv = Vector2.new(99, 99)
		assert(m.faces[23].corners[1].uv == Vector2.zero)
	end)
	test("Affine data transforms and rigid geometry changes commute with smooth masks", function()
		local original = stamp(grid(2, 2))
		local moved = original:clone()
		local frame = CFrame.new(40, -20, 7) * CFrame.Angles(0.2, 0.4, -0.3)
		for id, p in moved.vertices do
			moved.vertices[id] = frame:PointToWorldSpace(p)
		end
		for _, face in moved.faces do
			for _, c in face.corners do
				c.uv = c.uv * 3 + Vector2.new(256, -512)
			end
		end
		moved.attributes.stamp.default = 1e12
		for key, value in original.attributes.stamp.values do
			moved.attributes.stamp.values[key] = 1e12 + 1000 * value
		end
		local opts = { faceVarying = { uv = "smooth", ["attribute:stamp"] = "smooth" } }
		local a, b = S.catmullClark(original, 2, opts), S.catmullClark(moved, 2, opts)
		for fid, face in a.faces do
			for i, c in face.corners do
				near(b.faces[fid].corners[i].uv, c.uv * 3 + Vector2.new(256, -512), 0.0002)
				near(
					A.get(b, "stamp", fid .. ":" .. i),
					1e12 + 1000 * A.get(a, "stamp", fid .. ":" .. i),
					0.005
				)
			end
		end
	end)
	test("Cancelled multires commits preserve every stored refinement level", function()
		local cancel = false
		local m = grid(2, 2)
		local stack = S.multires(m, 2, {
			faceVarying = { uv = "smooth" },
			cancelled = function()
				return cancel
			end,
		})
		local before = {}
		for i = 1, 3 do
			before[i] = E.IO.encode(stack:select(i))
		end
		local coarse = stack:select(1)
		coarse.vertices[5] += Vector3.zAxis
		cancel = true
		assert(not pcall(function()
			stack:commit(coarse)
		end))
		for i = 1, 3 do
			assert(E.IO.encode(stack:select(i)) == before[i])
		end
	end)
	test("New mesh corners with default identities form fresh refinable charts", function()
		local m = S.catmullClark(grid(1, 1), 1, { faceVarying = { uv = "smooth" } })
		local e
		for _, entry in m:topology().edges do
			if #entry.faces == 1 then
				e = entry
				break
			end
		end
		local face = m.faces[e.faces[1]]
		local index
		for i, v in face.vertices do
			if edge(v, face.vertices[i % #face.vertices + 1]) == edge(e.a, e.b) then
				index = i
				break
			end
		end
		local nextIndex = index % #face.vertices + 1
		local a, b = face.vertices[index], face.vertices[nextIndex]
		local pa, pb = m.vertices[a], m.vertices[b]
		local delta = pb - pa
		local outward = Vector3.new(delta.Y, -delta.X, 0).Unit * 0.5
		local c, d = m:addVertex(pa + outward), m:addVertex(pb + outward)
		local ua, ub = face.corners[index].uv, face.corners[nextIndex].uv
		local shift = Vector2.new(outward.X, outward.Y)
		local added = m:addFace(
			{ b, a, c, d },
			{ { uv = ub }, { uv = ua }, { uv = ua + shift }, { uv = ub + shift } }
		)
		assert(A.get(m, PREFIX .. "uv", added .. ":1") == 0)
		local out = S.catmullClark(m, 1, { faceVarying = { uv = "smooth" } })
		assert(out:validate().valid and uniqueAt(out, a, "uv") == 2 and uniqueAt(out, b, "uv") == 2)
		for _, value in out.attributes[PREFIX .. "uv"].values do
			assert(value > 0 and value % 1 == 0)
		end
	end)
	test("Malformed fields topology schemas modes and seam selections reject atomically", function()
		local m = grid(2, 2)
		local before = E.IO.encode(m)
		for _, opts in
			{
				{ faceVarying = { uv = "unknown" } },
				{ faceVarying = { normal = "smooth" } },
				{ faceVarying = { ["attribute:missing"] = "smooth" } },
				{ faceVaryingSeams = { uv = { ["1:99"] = true } } },
				{ faceVaryingSeams = { uv = { ["1:2"] = 1 } } },
				{ faceVaryingSeams = { uv = "missing" } },
			}
		do
			assert(not pcall(function()
				S.catmullClark(m, 1, opts)
			end))
		end
		local missing = m:clone()
		missing.faces[1].corners[1].uv = nil
		assert(not pcall(function()
			S.catmullClark(missing, 1, { faceVarying = { uv = "smooth" } })
		end))
		local bad = A.create(m, PREFIX .. "uv", "corner", "number", 1, "nearest")
		assert(not pcall(function()
			S.catmullClark(bad, 1, { faceVarying = { uv = "smooth" } })
		end))
		bad = A.set(
			A.create(m, PREFIX .. "uv", "corner", "number", 0, "nearest"),
			PREFIX .. "uv",
			{ ["1:1"] = -1 }
		)
		assert(not pcall(function()
			S.catmullClark(bad, 1, { faceVarying = { uv = "smooth" } })
		end))
		local categorical = A.create(m, "tag", "corner", "string", "x", "nearest")
		assert(not pcall(function()
			S.catmullClark(categorical, 1, { faceVarying = { ["attribute:tag"] = "smooth" } })
		end))
		assert(E.IO.encode(m) == before)
	end)
	test("Face-varying allocation work and mid-refinement cancellation preserve input", function()
		local m = grid(5, 5)
		local before = E.IO.encode(m)
		for _, opts in
			{
				{ faceVarying = { uv = "smooth" }, maxFaceVaryingValues = 1 },
				{ faceVarying = { uv = "smooth" }, maxFaceVaryingWork = 1 },
				{
					faceVarying = { uv = "smooth" },
					cancelled = function()
						return true
					end,
				},
				{
					faceVarying = { uv = "smooth" },
					faceVaryingCheckpoint = function(p)
						if p.stage == "refine" then
							error("cancel")
						end
					end,
				},
			}
		do
			assert(not pcall(function()
				S.catmullClark(m, 2, opts)
			end))
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Smoothed UV seams survive native conversion with valid geometry and normals", function()
		local m = grid(2, 2)
		for fid, face in m.faces do
			if fid >= 3 then
				for _, c in face.corners do
					c.uv += Vector2.new(100, 0)
				end
			end
		end
		local out =
			S.catmullClark(m, 2, { faceVarying = { uv = "smooth", color = "smooth", alpha = "smooth" } })
		local handle = E.Roblox.toEditable(out)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			local left, right = false, false
			for _, face in restored.faces do
				for _, c in face.corners do
					left = left or c.uv.X < 2
					right = right or c.uv.X > 100
					assert(c.normal and math.abs(c.normal.Magnitude - 1) < 1e-5)
				end
			end
			assert(left and right)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
