return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local A, T = E.Attributes, E.Topology
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b)
		assert(math.abs(a - b) < 1e-6, tostring(a) .. " ~= " .. tostring(b))
	end
	local function edge(a, b)
		return a < b and a .. ":" .. b or b .. ":" .. a
	end
	local function quad()
		local m = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis } do
			m:addVertex(p)
		end
		m:addFace(
			{ 1, 2, 3, 4 },
			{
				{ uv = Vector2.zero, alpha = 0 },
				{ uv = Vector2.xAxis, alpha = 1 },
				{ uv = Vector2.one, alpha = 1 },
				{ uv = Vector2.yAxis, alpha = 0 },
			},
			7
		)
		m.weights[1], m.weights[2] = { A = 1 }, { B = 1 }
		m.groups.pick = { [2] = 1 }
		m = A.set(A.create(m, "heat", "vertex", "number", 0), "heat", { [2] = 10, [3] = 20, [4] = 30 })
		m = A.set(A.create(m, "uv_seam", "edge", "boolean", false, "max"), "uv_seam", { ["1:2"] = true })
		m = A.set(A.create(m, "zone", "face", "string", "unset"), "zone", { [1] = "front" })
		m = A.set(
			A.create(m, "stamp", "corner", "number", 0),
			"stamp",
			{ ["1:1"] = 1, ["1:2"] = 2, ["1:3"] = 3, ["1:4"] = 4 }
		)
		return m
	end
	test("Typed sparse channels distinguish false values from defaults and own their data", function()
		local m = quad()
		local values = { [1] = false }
		local n = A.set(A.create(m, "visible", "vertex", "boolean", true), "visible", values)
		values[1] = true
		assert(A.get(n, "visible", 1) == false and A.get(n, "visible", 2) == true)
		local c = n:clone()
		c.attributes.visible.values[1] = true
		assert(A.get(n, "visible", 1) == false and not m.attributes.visible)
		assert(#A.names(n) == 5 and A.names(n, "edge")[1] == "uv_seam")
		assert(not A.remove(n, "visible").attributes.visible and n.attributes.visible)
	end)
	test("Attribute schemas values and element IDs reject malformed input atomically", function()
		local m = quad()
		local before = E.IO.encode(m)
		for _, fn in
			{
				function()
					A.create(m, "bad", "edge", "number", 0 / 0)
				end,
				function()
					A.create(m, "bad", "edge", "boolean", false, "linear")
				end,
				function()
					A.create(m, "bad", "face", "Vector3", Vector3.zero, "max")
				end,
				function()
					A.create(m, "heat", "vertex", "number", 0)
				end,
				function()
					A.set(m, "heat", { [999] = 1 })
				end,
				function()
					A.set(m, "heat", { [1] = "bad" })
				end,
				function()
					A.set(m, "uv_seam", { ["2:1"] = true })
				end,
				function()
					A.set(m, "stamp", { ["1:5"] = 2 })
				end,
				function()
					A.get(m, "heat", 999)
				end,
			}
		do
			assert(not pcall(fn))
		end
		assert(E.IO.encode(m) == before)
		local corrupt = m:clone()
		corrupt.attributes.heat.values[99] = 10
		assert(not corrupt:validate().valid and #corrupt:validate().errors > 0)
	end)
	test("Explicit weighted transfer supports all interpolation modes with deterministic ties", function()
		local m = quad()
		for _, mode in { "linear", "nearest", "max", "min" } do
			m = A.set(A.create(m, mode, "vertex", "number", 0, mode), mode, { [1] = 2, [2] = 10 })
		end
		m = A.set(A.create(m, "all", "vertex", "boolean", true, "min"), "all", { [1] = false })
		local target = E.Mesh.new()
		target:addVertex(Vector3.zero)
		local out = A.transfer(
			m,
			target,
			{ vertex = { [1] = { { 1, 1 }, { 2, 3 } } }, identity = { vertex = false } }
		)
		near(A.get(out, "linear", 1), 8)
		near(A.get(out, "nearest", 1), 10)
		near(A.get(out, "max", 1), 10)
		near(A.get(out, "min", 1), 2)
		assert(A.get(out, "all", 1) == false and next(target.attributes) == nil)
		out = A.transfer(m, target, { vertex = { [1] = { { 2, 1 }, { 1, 1 } } } })
		near(A.get(out, "nearest", 1), 10)
		for _, mapping in
			{
				{ vertex = { [2] = { { 1, 1 } } } },
				{ vertex = { [1] = { { 99, 1 } } } },
				{ vertex = { [1] = { { 1, -1 } } } },
				{ vertex = { [1] = { { 1, 0 } } } },
			}
		do
			assert(not pcall(A.transfer, m, target, mapping))
		end
	end)
	test("Attribute JSON roundtrip preserves every supported native type and schema", function()
		local m = quad()
		for _, entry in
			{
				{ "uv2", "Vector2", Vector2.zero, Vector2.new(0.2, 0.4) },
				{ "direction", "Vector3", Vector3.zero, Vector3.new(1, 2, 3) },
				{ "tint", "Color3", Color3.new(), Color3.new(0.2, 0.5, 1) },
				{ "enabled", "boolean", true, false },
			}
		do
			m = A.set(A.create(m, entry[1], "vertex", entry[2], entry[3]), entry[1], { [1] = entry[4] })
		end
		m.faces[1].corners[1].tangent = Vector3.xAxis
		m.faces[1].corners[1].tangentSign = -1
		local decoded = E.IO.decode(E.IO.encode(m))
		assert(E.IO.toTable(m).version == 2 and decoded:validate().valid)
		for name, channel in m.attributes do
			assert(decoded.attributes[name].default == channel.default)
			for key, value in channel.values do
				assert(A.get(decoded, name, key) == value)
			end
		end
		assert(
			decoded.faces[1].corners[1].tangentSign == -1
				and decoded.faces[1].corners[1].tangent == Vector3.xAxis
		)
		decoded.attributes.heat.values[2] = 99
		assert(A.get(m, "heat", 2) == 10)
		local old = E.IO.toTable(E.Primitives.box(Vector3.one))
		assert(old.version == 1 and E.IO.fromTable(old):validate().closed)
	end)
	test("Serialized attributes reject duplicate names invalid IDs and nonfinite vectors", function()
		local data = E.IO.toTable(quad())
		table.insert(data.attributes, data.attributes[1])
		assert(not pcall(E.IO.fromTable, data))
		data = E.IO.toTable(quad())
		data.attributes[1].values[1][1] = 999
		assert(not pcall(E.IO.fromTable, data))
		local m = A.create(quad(), "v", "vertex", "Vector3", Vector3.zero)
		data = E.IO.toTable(m)
		for _, entry in data.attributes do
			if entry.name == "v" then
				entry.default = { math.huge, 0, 0 }
			end
		end
		assert(not pcall(E.IO.fromTable, data))
	end)
	test("Triangulation remaps sparse face and corner IDs and leaves new diagonals unmarked", function()
		local m = quad()
		m.nextFace = 90
		local f = m.faces[1]
		m.faces[81] = f
		m.faces[1] = nil
		m.attributes.zone.values = { [81] = "front" }
		m.attributes.stamp.values = { ["81:1"] = 1, ["81:2"] = 2, ["81:3"] = 3, ["81:4"] = 4 }
		local out = T.triangulate(m)
		assert(out:validate().valid and out:validate().faces == 2)
		for fid, face in out.faces do
			assert(A.get(out, "zone", fid) == "front")
			for i, v in face.vertices do
				near(A.get(out, "stamp", fid .. ":" .. i), v)
			end
		end
		for key in out:topology().edges do
			assert(A.get(out, "uv_seam", key) == (key == "1:2"))
		end
	end)
	test("Join remaps all attribute domains without collisions and rejects schema conflicts", function()
		local m = quad()
		local n = A.set(m, "zone", { [1] = "back" })
		n = A.set(n, "heat", { [2] = 100 })
		local out = T.join({ m, n })
		assert(A.get(out, "zone", 1) == "front" and A.get(out, "zone", 2) == "back")
		near(A.get(out, "heat", 2), 10)
		near(A.get(out, "heat", 6), 100)
		assert(A.get(out, "uv_seam", "5:6") and A.get(out, "stamp", "2:4") == 4)
		local bad = n:clone()
		bad.attributes.heat.default = -1
		assert(not pcall(T.join, { m, bad }) and A.get(m, "heat", 2) == 10)
	end)
	test("Extract removeFace and removeUnused prune every deleted attribute element", function()
		local out = T.extract(T.join({ quad(), quad() }), { [2] = true })
		assert(out:validate().valid and out.attributes.zone.values[1] == nil)
		assert(out.attributes.heat.values[2] == nil and out.attributes.uv_seam.values["1:2"] == nil)
		assert(out.attributes.stamp.values["1:1"] == nil and A.get(out, "stamp", "2:1") == 1)
		out:removeFace(2)
		out:removeUnused()
		for _, channel in out.attributes do
			assert(next(channel.values) == nil)
		end
	end)
	test("Reversal reindexes corner channels and reverses tangent handedness", function()
		local m = quad()
		m.faces[1].corners[1].tangentSign = 1
		local out = T.reverse(m)
		for i = 1, 4 do
			near(A.get(out, "stamp", "1:" .. i), 5 - i)
		end
		assert(out.faces[1].corners[4].tangentSign == -1 and A.get(out, "uv_seam", "1:2"))
		assert(E.IO.encode(T.reverse(out)) == E.IO.encode(m))
	end)
	test("Edge split interpolates vertex groups skin weights and corner channels", function()
		local m = quad()
		local out, id = T.splitEdge(m, 1, 2, 0.25)
		near(A.get(out, "heat", id), 2.5)
		near(out.groups.pick[id], 0.25)
		near(out.weights[id].A, 0.75)
		near(out.weights[id].B, 0.25)
		near(A.get(out, "stamp", "1:2"), 1.25)
		near(A.get(out, "stamp", "1:3"), 2)
		assert(A.get(out, "uv_seam", edge(1, id)) and A.get(out, "uv_seam", edge(2, id)))
		assert(out.attributes.uv_seam.values["1:2"] == nil and out:validate().valid)
		local reversed, rid = T.splitEdge(m, 2, 1, 0.75)
		assert(reversed.vertices[rid] == out.vertices[id])
		near(A.get(reversed, "stamp", "1:2"), 1.25)
		local wrap, wid = T.splitEdge(m, 4, 1, 0.5)
		near(A.get(wrap, "stamp", "1:5"), 2.5)
		near(A.get(wrap, "heat", wid), 15)
	end)
	test("Region extrusion copies cap edges material face values and vertex selections", function()
		local m = quad()
		local out, map = T.extrude(m, { [1] = true }, Vector3.zAxis)
		assert(out:validate().valid and out:validate().faces == 5)
		near(out.groups.pick[map[2]], 1)
		near(A.get(out, "heat", map[3]), 20)
		assert(A.get(out, "uv_seam", edge(map[1], map[2])))
		for fid, f in out.faces do
			assert(A.get(out, "zone", fid) == "front" and f.material == 7)
		end
		assert(A.get(out, "stamp", "1:4") == 4 and A.get(m, "heat", 2) == 10)
	end)
	test(
		"Inset interpolates inner geometry UVs weights and channels while retaining boundary values",
		function()
			local m = quad()
			local out = T.insetFaces(m, { [1] = true }, 0.5)
			local id = out.faces[1].vertices[1]
			near(A.get(out, "heat", id), 7.5)
			near(A.get(out, "stamp", "1:1"), 1.75)
			near(out.groups.pick[id], 0.125)
			near(out.weights[id].A, 0.625)
			near(out.weights[id].B, 0.125)
			assert((out.faces[1].corners[1].uv - Vector2.new(0.25, 0.25)).Magnitude < 1e-6)
			near(out.faces[1].corners[1].alpha, 0.25)
			assert(A.get(out, "uv_seam", edge(id, out.faces[1].vertices[2])) and A.get(out, "uv_seam", "1:2"))
			assert(out:validate().valid and A.get(m, "stamp", "1:1") == 1)
		end
	)
	test("Welding merges vertex and edge channels and keeps face corner discontinuities", function()
		local m = E.Mesh.new()
		for _, p in
			{ Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis }
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 4, 5, 6 })
		m = A.set(A.create(m, "heat", "vertex", "number", 0), "heat", { [2] = 2, [4] = 10 })
		m = A.set(A.create(m, "seam", "edge", "boolean", false, "max"), "seam", { ["4:6"] = true })
		m = A.set(A.create(m, "faceUV", "corner", "number", 0), "faceUV", { ["1:2"] = 1, ["2:1"] = 9 })
		local out, map = T.weld(m, 1e-5)
		assert(out:validate().valid and map[4] == 2 and map[6] == 3)
		near(A.get(out, "heat", 2), 6)
		assert(A.get(out, "seam", "2:3"))
		near(A.get(out, "faceUV", "1:2"), 1)
		near(A.get(out, "faceUV", "2:1"), 9)
	end)
	test("Dissolve uses surviving corner provenance and blends face values", function()
		local m = T.triangulate(quad())
		local a, b
		for _, e in m:topology().edges do
			if #e.faces == 2 then
				a, b = e.a, e.b
			end
		end
		local out = T.dissolveEdge(m, a, b)
		assert(out:validate().valid and out:validate().faces == 1)
		for fid, f in out.faces do
			assert(A.get(out, "zone", fid) == "front")
			for i, v in f.vertices do
				near(A.get(out, "stamp", fid .. ":" .. i), v)
			end
		end
	end)
	test("Subdivision preserves edge ancestry face regions and face varying channels", function()
		local m = quad()
		local out = E.Subdivision.catmullClark(m, 1)
		assert(out:validate().valid and out:validate().faces == 4)
		local marked = 0
		for key in out:topology().edges do
			if A.get(out, "uv_seam", key) then
				marked += 1
			end
		end
		assert(marked == 2)
		for fid in out.faces do
			assert(A.get(out, "zone", fid) == "front")
		end
		near(A.get(out, "stamp", "1:1"), 1)
		near(A.get(out, "stamp", "1:2"), 1.5)
		near(A.get(out, "stamp", "1:3"), 2.5)
		near(out.faces[1].corners[3].alpha, 0.5)
		near(A.get(out, "heat", 1), 0)
		near(A.get(out, "heat", 9), 15)
		local twice = E.Subdivision.catmullClark(m, 2)
		marked = 0
		for key in twice:topology().edges do
			if A.get(twice, "uv_seam", key) then
				marked += 1
			end
		end
		assert(marked == 4 and twice:validate().valid)
	end)
	test("Named seam attributes produce the same UV charts as explicit seam selections", function()
		local m = E.Primitives.box(Vector3.one)
		local seams = {}
		for key in m:topology().edges do
			seams[key] = true
		end
		m = A.set(A.create(m, "uv_seam", "edge", "boolean", false, "max"), "uv_seam", seams)
		local a, ar = E.Unwrap.unwrap(m)
		local b, br = E.Unwrap.unwrap(m, seams)
		assert(ar.charts == 6 and br.charts == 6)
		for fid, f in a.faces do
			for i, c in f.corners do
				assert(c.uv == b.faces[fid].corners[i].uv)
			end
		end
		assert(a.attributes.uv_seam and not pcall(E.Unwrap.unwrap, m, {}))
	end)
	report.success = report.failed == 0
	return report
end
