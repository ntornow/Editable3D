return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local S, V = E.Subdivision, Vector3.new
	local function near(a, b, e)
		assert((a - b).Magnitude < (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function grid(transform)
		transform = transform or function(p)
			return p
		end
		local m = E.Mesh.new()
		local ids = {}
		for j = -1, 1 do
			for i = -1, 1 do
				ids[i .. ":" .. j] =
					m:addVertex(transform(V(i, j, i * i + 2 * i * j + 3 * j * j + 4 * i - 2 * j)))
			end
		end
		for j = -1, 0 do
			for i = -1, 0 do
				m:addFace({
					ids[i .. ":" .. j],
					ids[(i + 1) .. ":" .. j],
					ids[(i + 1) .. ":" .. (j + 1)],
					ids[i .. ":" .. (j + 1)],
				})
			end
		end
		return m, ids
	end
	local uv = { { 1, 1 }, { 0, 1 }, { 1, 0 }, { 0, 0 } }
	local normal = V(-4, 2, 1).Unit
	test("Quadratic tensor field has exact center slopes on every incident face", function()
		for _, boundary in { "edge", "edgeAndCorner", "fixed" } do
			local m = grid()
			local q = S.prepareLimit(m, { boundary = boundary })
			for f = 1, 4 do
				local r = q:evaluate(f, uv[f][1], uv[f][2])
				assert(r.derivativesAvailable and r.normalAvailable)
				near(r.position, V(0, 0, 4 / 3))
				near(r.derivativeU, V(1, 0, 4))
				near(r.derivativeV, V(0, 1, -2))
				near(r.normal, normal)
			end
		end
	end)
	test("Nearby analytic derivatives approach the regular vertex stencil", function()
		local q = S.prepareLimit(grid(), { maxDepth = 32, maxWork = 100000000, tolerance = 1e-12 })
		local target = q:evaluate(4, 0, 0)
		for _, p in { { 0.75, 0.25 }, { 0.75, 0.75 }, { 0.25, 0.75 } } do
			local early = q:evaluate(4, p[1] * 2 ^ -6, p[2] * 2 ^ -6)
			local later = q:evaluate(4, p[1] * 2 ^ -14, p[2] * 2 ^ -14)
			assert(early.derivativesAvailable and later.derivativesAvailable)
			local a = (early.derivativeU - target.derivativeU).Magnitude
				+ (early.derivativeV - target.derivativeV).Magnitude
			local b = (later.derivativeU - target.derivativeU).Magnitude
				+ (later.derivativeV - target.derivativeV).Magnitude
			assert(b < a and b < 0.005)
		end
	end)
	test("All four rotations preserve parameter derivatives and winding", function()
		local coordinates = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
		local a, b = V(1, 0, 4), V(0, 1, -2)
		local us, vs = { a, -b, -a, b }, { b, a, -b, -a }
		for index = 1, 4 do
			local m = grid()
			local face = m.faces[4]
			local ids, corners = table.clone(face.vertices), table.clone(face.corners)
			for j = 1, 4 do
				local from = (j - index) % 4 + 1
				face.vertices[j] = ids[from]
				face.corners[j] = corners[from]
			end
			local r = S.limit(m, 4, coordinates[index][1], coordinates[index][2])
			near(r.derivativeU, us[index])
			near(r.derivativeV, vs[index])
			near(r.normal, normal)
		end
	end)
	test("Reversed face winding gives reversed limiting normals", function()
		local m = grid()
		for _, face in m.faces do
			face.vertices = { face.vertices[1], face.vertices[4], face.vertices[3], face.vertices[2] }
			face.corners = { face.corners[1], face.corners[4], face.corners[3], face.corners[2] }
		end
		local r = S.limit(m, 4, 0, 0)
		near(r.derivativeU, V(0, 1, -2))
		near(r.derivativeV, V(1, 0, 4))
		near(r.normal, -normal)
	end)
	test("Pins at outer controls leave the center core jet unchanged", function()
		local m, ids = grid()
		local pins = {}
		for _, id in ids do
			if id ~= ids["0:0"] then
				pins[id] = 10
			end
		end
		m = S.crease(m, nil, pins)
		local r = S.limit(m, 4, 0, 0)
		assert(r.normalMethod == "regularVertexJet")
		near(r.derivativeU, V(1, 0, 4))
		near(r.derivativeV, V(0, 1, -2))
	end)
	test("Hard center features do not select the smooth vertex stencil", function()
		local m, ids = grid()
		m = S.crease(m, nil, { [ids["0:0"]] = 10 })
		local r = S.limit(m, 4, 0, 0, { maxDepth = 0 })
		assert(r.normalMethod ~= "regularVertexJet")
	end)
	test("Degenerate regular jets retain derivatives without inventing normals", function()
		for _, rank in { 0, 1 } do
			local m = grid(function(p)
				return V(rank * p.X, 0, 0)
			end)
			local r = S.limit(m, 4, 0, 0)
			assert(r.derivativesAvailable and not r.normalAvailable)
			near(r.derivativeU, V(rank, 0, 0))
			near(r.derivativeV, Vector3.zero)
		end
	end)
	test("Tiny and large affine coordinate scales retain finite unit normals", function()
		for _, scale in { 2 ^ -60, 1, 2 ^ 60 } do
			local function linear(p)
				return V(p.Z, p.X, -p.Y) * scale
			end
			local m = grid(linear)
			local r = S.limit(m, 4, 0, 0, { tolerance = math.max(1e-20, scale * 1e-5) })
			assert(r.derivativesAvailable and r.normalAvailable)
			near(r.derivativeU, linear(V(1, 0, 4)), scale * 1e-5)
			near(r.derivativeV, linear(V(0, 1, -2)), scale * 1e-5)
			near(r.normal, V(-normal.Z, -normal.X, normal.Y))
		end
	end)
	test("Dyadic queries next to fixed boundaries keep smooth-vertex derivatives", function()
		local m = E.Mesh.new()
		m:addVertex(Vector3.zero)
		local cycle = { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) }
		local edges = {}
		for j = 0, 4 do
			local a = cycle[j % 4 + 1]
			edges[j + 1] = m:addVertex(a + V(0, 0, a.Y))
		end
		for j = 0, 3 do
			local a, b = cycle[j % 4 + 1], cycle[(j + 1) % 4 + 1]
			local d = m:addVertex(a + b + V(0, 0, -2 * (a.Y + b.Y)))
			m:addFace({ 1, edges[j + 1], d, edges[j + 2] })
		end
		local r = S.limit(
			m,
			1,
			0.75 * 2 ^ -14,
			0.25 * 2 ^ -14,
			{ boundary = "fixed", maxDepth = 32, tolerance = 1e-14 }
		)
		assert(r.derivativesAvailable and r.normalMethod == "regularVertexJet")
		near(r.derivativeU, V(1, 0, 0), 0.001)
		near(r.derivativeV, V(0, 1, 0), 0.001)
	end)
	test("Prepared smooth-vertex queries retain snapshots and hard limits", function()
		local m, ids = grid()
		local q = S.prepareLimit(m, { maxQueries = 2 })
		local before = E.IO.encode(m)
		local a = q:evaluate(4, 0, 0)
		m.vertices[ids["1:0"]] = V(999, 999, 999)
		local b = q:evaluate(4, 0, 0)
		near(a.derivativeU, b.derivativeU)
		assert(not pcall(function()
			q:evaluate(4, 0, 0)
		end))
		local fresh = grid()
		assert(not pcall(S.limit, fresh, 4, 0, 0, { maxWork = 1 }))
		assert(E.IO.encode(fresh) == before)
	end)
	if not settings or not settings.skipNative then
		test("Regular vertex normals retain native corner normals and UV identities", function()
			local source = grid()
			local mesh = E.Mesh.new()
			for f = 1, 4 do
				local r = S.limit(source, f, uv[f][1], uv[f][2])
				local a = mesh:addVertex(V(f * 3, 0, 0))
				local b = mesh:addVertex(V(f * 3 + 1, 0, 0))
				local c = mesh:addVertex(V(f * 3, 1, 0))
				local id = mesh:addFace({ a, b, c })
				for i, corner in mesh.faces[id].corners do
					corner.normal = r.normal
					corner.uv = Vector2.new(f, i)
				end
			end
			local h = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local out = E.Roblox.fromEditable(h.editable)
				local count = 0
				for _, face in out.faces do
					for _, corner in face.corners do
						near(corner.normal, normal, 1e-6)
						assert(
							corner.uv.X >= 1 and corner.uv.X <= 4 and corner.uv.Y >= 1 and corner.uv.Y <= 3
						)
						count += 1
					end
				end
				assert(count == 12)
			end)
			h.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
