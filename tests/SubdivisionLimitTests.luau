return function(E)
	local S = E.Subdivision
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, t)
		local error = typeof(a) == "number" and math.abs(a - b) or (a - b).Magnitude
		assert(error < (t or 5e-6), tostring(a) .. " ~= " .. tostring(b) .. " error " .. error)
	end
	local function rejects(fn)
		assert(not pcall(fn), "Expected rejection")
	end
	local function grid(nx, ny, field)
		local m = E.Mesh.new()
		local function id(i, j)
			return i * (ny + 1) + j + 1
		end
		local function fid(i, j)
			return i * ny + j + 1
		end
		for i = 0, nx do
			for j = 0, ny do
				m:addVertex(Vector3.new(i, j, field and field(i, j) or 0))
			end
		end
		for i = 0, nx - 1 do
			for j = 0, ny - 1 do
				m:addFace({ id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }, {
					{ uv = Vector2.new(i, j) },
					{ uv = Vector2.new(i + 1, j) },
					{ uv = Vector2.new(i + 1, j + 1) },
					{ uv = Vector2.new(i, j + 1) },
				})
			end
		end
		return m, id, fid
	end
	local function edge(a, b)
		return a < b and a .. ":" .. b or b .. ":" .. a
	end
	local function child(fid, corner)
		return (fid - 1) * 4 + corner
	end
	local function mapped(u, v)
		if u <= 0.5 and v <= 0.5 then
			return 1, 2 * u, 2 * v
		elseif u > 0.5 and v <= 0.5 then
			return 2, 2 * v, 2 * (1 - u)
		elseif u > 0.5 then
			return 3, 2 * (1 - u), 2 * (1 - v)
		else
			return 4, 2 * (1 - v), 2 * u
		end
	end
	test("Regular cubic patches reproduce independent polynomial positions and derivatives", function()
		local m, _, f = grid(5, 5, function(x, y)
			return x * x + y * y * y
		end)
		local prepared = S.prepareLimit(m)
		for _, uv in { { 0, 0 }, { 1, 1 }, { 0.17, 0.82 }, { 0.7, 0.23 }, { 0.5, 0.5 } } do
			local u, v = uv[1], uv[2]
			local x, y = 2 + u, 2 + v
			local r = prepared:evaluate(f(2, 2), u, v)
			assert(r.complete and r.method == "bicubic" and r.depth == 0 and r.derivativesAvailable)
			near(r.position, Vector3.new(x, y, x * x + 1 / 3 + y * y * y + y), 8e-6)
			near(r.derivativeU, Vector3.new(1, 0, 2 * x))
			near(r.derivativeV, Vector3.new(0, 1, 3 * y * y + 1))
			near(r.normal, r.derivativeU:Cross(r.derivativeV).Unit)
		end
	end)
	test("Regular subdivision preserves the exact bicubic limit in all four quadrants", function()
		local m, _, f = grid(6, 6, function(x, y)
			return math.sin(x * 0.8) + math.cos(y * 0.6) + x * y * 0.13
		end)
		local fine = S.catmullClark(m, 1)
		for _, uv in { { 0.2, 0.3 }, { 0.8, 0.4 }, { 0.7, 0.9 }, { 0.1, 0.8 } } do
			local q, u, v = mapped(uv[1], uv[2])
			local a = S.limit(m, f(2, 2), uv[1], uv[2])
			local b = S.limit(fine, child(f(2, 2), q), u, v)
			near(a.position, b.position, 2e-6)
		end
	end)
	test("Extraordinary cube corners use the independent stationary limit mask", function()
		local m = E.Primitives.box(Vector3.new(2, 2, 2))
		local fid = 1
		local v = m.faces[fid].vertices[1]
		local p = m.vertices[v]
		local r = S.limit(m, fid, 0, 0)
		assert(r.complete and r.method == "vertexMask" and not r.derivativesAvailable and r.normal)
		near(r.normal, p.Unit)
		near(r.position, p * 0.5)
		local fine = S.catmullClark(m, 5)
		near(fine.vertices[v], r.position, 0.001)
	end)
	test(
		"Noncorner extraordinary queries agree with global refinement and rotated child parameters",
		function()
			local m = E.Primitives.box(Vector3.new(2, 3, 4))
			local fine = S.catmullClark(m, 2)
			for _, uv in
				{
					{ 0.23, 0.31 },
					{ 0.83, 0.27 },
					{ 0.69, 0.91 },
					{ 0.13, 0.87 },
					{ 0.5, 0.5 },
					{ 0.001, 0.002 },
				}
			do
				local fid, u, v = 1, uv[1], uv[2]
				for _ = 1, 2 do
					local q
					q, u, v = mapped(u, v)
					fid = child(fid, q)
				end
				local a = S.limit(m, 1, uv[1], uv[2])
				local b = S.limit(fine, fid, u, v)
				assert(a.complete and b.complete)
				near(a.position, b.position, 3e-6)
			end
		end
	)
	test("Boundary cubic corners and pinned boundary modes have distinct exact limits", function()
		local m = grid(1, 1)
		local a = S.limit(m, 1, 0, 0)
		near(a.position, Vector3.new(1 / 6, 1 / 6, 0))
		for _, boundary in { "fixed", "edgeAndCorner" } do
			near(S.limit(m, 1, 0, 0, { boundary = boundary }).position, Vector3.zero)
		end
	end)
	test("Arbitrary boundary positions reach an exact one-sided cubic patch", function()
		local m = grid(1, 1)
		local r = S.limit(m, 1, 0.37, 0, { tolerance = 2e-5 })
		assert(r.complete and r.method == "bicubicOneSided" and r.derivativesAvailable and r.depth > 0)
		-- The single-face boundary is a closed uniform cubic spline.
		local t = 0.37
		local expected =
			Vector3.new((1 + 3 * t + 3 * t * t - 2 * t * t * t) / 6, (1 - 3 * t + 3 * t * t) / 6, 0)
		assert((r.position - expected).Magnitude <= r.errorBound + 1e-7)
		near(r.derivativeU, Vector3.new(0.5 + t - t * t, t - 0.5, 0))
		near(r.normal, Vector3.zAxis)
	end)
	test("Finite and Chaikin crease limits commute with independent global refinement", function()
		local m, id, f = grid(5, 5, function(x, y)
			return math.cos(x) * math.sin(y)
		end)
		m = S.crease(m, {
			[edge(id(2, 1), id(2, 2))] = 2.2,
			[edge(id(2, 2), id(2, 3))] = 0.7,
			[edge(id(2, 3), id(2, 4))] = 1.3,
		}, { [id(2, 2)] = 0.4 })
		for _, method in { "uniform", "chaikin" } do
			local options = { creasing = method }
			local fine = S.catmullClark(m, 2, options)
			for _, uv in { { 0, 0 }, { 0.23, 0.31 }, { 0.8, 0.6 } } do
				local fid, u, v = f(2, 2), uv[1], uv[2]
				for _ = 1, 2 do
					local q
					q, u, v = mapped(u, v)
					fid = child(fid, q)
				end
				local a = S.limit(m, f(2, 2), uv[1], uv[2], options)
				local b = S.limit(fine, fid, u, v, options)
				assert(a.complete and b.complete)
				near(a.position, b.position, 4e-6)
			end
		end
	end)
	test("Infinite corner and two-edge crease masks retain their analytic positions", function()
		local m = E.Primitives.box(Vector3.new(2, 2, 2))
		local v = m.faces[1].vertices[1]
		local top = m:topology()
		local ns = {}
		for n in top.neighbors[v] do
			table.insert(ns, n)
		end
		table.sort(ns)
		local a = S.crease(m, { [edge(v, ns[1])] = 10, [edge(v, ns[2])] = 10 })
		near(S.limit(a, 1, 0, 0).position, (4 * m.vertices[v] + m.vertices[ns[1]] + m.vertices[ns[2]]) / 6)
		local b = S.crease(a, { [edge(v, ns[3])] = 10 })
		near(S.limit(b, 1, 0, 0).position, m.vertices[v])
		local c = S.crease(m, nil, { [v] = 10 })
		near(S.limit(c, 1, 0, 0).position, m.vertices[v])
	end)
	test("Nonquad corner patches agree with the first globally refined quads", function()
		local m = E.Mesh.new()
		for i = 1, 5 do
			local a = 2 * math.pi * (i - 1) / 5
			m:addVertex(Vector3.new(math.cos(a), math.sin(a), 0.2 * math.cos(2 * a)))
		end
		m:addFace({ 1, 2, 3, 4, 5 })
		local fine = S.catmullClark(m, 1)
		for corner = 1, 5 do
			local a = S.limit(m, 1, 0.34, 0.72, { corner = corner })
			local b = S.limit(fine, corner, 0.34, 0.72)
			assert(a.complete)
			near(a.position, b.position)
		end
		rejects(function()
			S.limit(m, 1, 0.2, 0.3)
		end)
	end)
	test("Prepared queries snapshot source geometry and scalar options", function()
		local m, _, f = grid(4, 4)
		local o = { tolerance = 1e-5, boundary = "edge" }
		local ev = S.prepareLimit(m, o)
		local a = ev:evaluate(f(1, 1), 0.3, 0.2)
		local snapshot = E.IO.encode(m)
		assert(E.IO.encode(m) == snapshot)
		for id, p in m.vertices do
			m.vertices[id] = p + Vector3.new(7, 8, 9)
		end
		o.tolerance = 1e-50
		o.boundary = "fixed"
		local b = ev:evaluate(f(1, 1), 0.3, 0.2)
		assert(b.complete)
		near(a.position, b.position)
		assert(ev:statistics().queries == 2)
	end)
	test("Depth exhaustion and native precision floors report incomplete results", function()
		local m = grid(1, 1)
		local a = S.limit(m, 1, 0.37, 0, { maxDepth = 0, tolerance = 1e-12 })
		assert(not a.complete and a.reason == "maxDepth" and a.errorBound > 0)
		rejects(function()
			S.limit(m, 1, 0.37, 0, { maxDepth = 0, tolerance = 1e-12, requireComplete = true })
		end)
		local b = S.limit(m, 1, 0, 0, { tolerance = 1e-12 })
		assert(not b.complete and b.reason == "precision")
	end)
	test("Work allocation query cancellation and invalid arguments reject explicitly", function()
		local m = grid(4, 4)
		rejects(function()
			S.limit(m, 1, 0.2, 0.3, { maxWork = 1 })
		end)
		rejects(function()
			S.limit(m, 1, 0.2, 0.3, { maxVertices = 2 })
		end)
		rejects(function()
			S.limit(m, 1, 0.2, 0.3, {
				cancelled = function()
					return true
				end,
			})
		end)
		local ev = S.prepareLimit(m, { maxQueries = 1 })
		ev:evaluate(6, 0.2, 0.3)
		rejects(function()
			ev:evaluate(6, 0.2, 0.3)
		end)
		for _, args in { { 0, 0.2, 0.3 }, { 1, -0.1, 0.3 }, { 1, 0.2, 1.1 }, { 1, 0 / 0, 0.3 } } do
			rejects(function()
				S.limit(m, args[1], args[2], args[3])
			end)
		end
		for _, o in { { tolerance = 0 }, { maxDepth = 49 }, { corner = 8 }, { boundary = "other" } } do
			rejects(function()
				S.limit(m, 1, 0.2, 0.3, o)
			end)
		end
	end)
	test("High valence extraordinary masks agree with independent weighted controls", function()
		for _, n in { 3, 5, 7, 12, 31 } do
			local m = E.Mesh.new()
			m:addVertex(Vector3.new(0, 0, 0.8))
			local radial, diagonal = {}, {}
			for i = 1, n do
				local a = 2 * math.pi * (i - 1) / n
				radial[i] = m:addVertex(Vector3.new(math.cos(a), math.sin(a), 0.2 * math.cos(a)))
				diagonal[i] = m:addVertex(
					Vector3.new(
						1.6 * math.cos(a + math.pi / n),
						1.6 * math.sin(a + math.pi / n),
						0.3 * math.sin(3 * a)
					)
				)
			end
			local expected = m.vertices[1] * n * n
			for i = 1, n do
				m:addFace({ 1, radial[i], diagonal[i], radial[i % n + 1] })
				expected += 4 * m.vertices[radial[i]] + m.vertices[diagonal[i]]
			end
			expected /= n * (n + 5)
			local r = S.limit(m, 1, 0, 0)
			assert(r.complete and r.method == "vertexMask")
			near(r.position, expected)
			local q = S.limit(m, 1, 0.0017, 0.0029)
			assert(q.complete and q.method == "bicubic" and q.depth >= 5)
		end
	end)
	test("Local refinement halo matches a much larger globally refined cage", function()
		local m, id, f = grid(18, 18, function(x, y)
			return 0.2 * math.cos(x * 0.7) + 0.1 * math.sin(y * 0.3)
		end)
		local sharp = {}
		for j = 0, 17 do
			sharp[edge(id(9, j), id(9, j + 1))] = 2.7
		end
		m = S.crease(m, sharp)
		local options = { creasing = "chaikin" }
		local fine = S.catmullClark(m, 2, options)
		for _, query in
			{ { 8, 8, 0.98, 0.013 }, { 8, 0, 0.93, 0.001 }, { 0, 8, 0.001, 0.42 }, { 8, 8, 1, 0.37 } }
		do
			local fid = f(query[1], query[2])
			local u, v = query[3], query[4]
			local ff = fid
			for _ = 1, 2 do
				local q
				q, u, v = mapped(u, v)
				ff = child(ff, q)
			end
			local a = S.limit(m, fid, query[3], query[4], options)
			local b = S.limit(fine, ff, u, v, options)
			assert(a.complete and b.complete)
			near(a.position, b.position, 8e-6)
		end
	end)
	test("Refined patch derivatives agree with independent centered differences", function()
		local m = E.Primitives.box(Vector3.new(2, 3, 4))
		local ev = S.prepareLimit(m)
		for _, uv in { { 0.17, 0.29 }, { 0.73, 0.38 }, { 0.79, 0.87 }, { 0.13, 0.81 } } do
			local u, v = uv[1], uv[2]
			local h = 0.001
			local r = ev:evaluate(1, u, v)
			assert(r.derivativesAvailable and r.depth > 0)
			local du = (ev:evaluate(1, u + h, v).position - ev:evaluate(1, u - h, v).position) / (2 * h)
			local dv = (ev:evaluate(1, u, v + h).position - ev:evaluate(1, u, v - h).position) / (2 * h)
			near(du, r.derivativeU, 0.0002)
			near(dv, r.derivativeV, 0.0002)
		end
	end)
	test("Sharp dart limits use shrinking enclosures instead of a smooth corner mask", function()
		local m = E.Primitives.box(Vector3.new(2, 2, 2))
		local f = m.faces[1].vertices
		m = S.crease(m, { [edge(f[1], f[2])] = 10 })
		local r = S.limit(m, 1, 0, 0, { tolerance = 2e-5 })
		assert(r.complete and r.method == "convexHull" and r.depth > 5)
		local fine = S.catmullClark(m, 5)
		local q = S.limit(fine, 1, 0, 0, { tolerance = 1e-5 })
		assert(q.complete)
		assert((r.position - q.position).Magnitude <= r.errorBound + q.errorBound + 2e-6)
	end)
	test("Rigid transforms and uniform scales preserve limits and derivative directions", function()
		local m = E.Primitives.box(Vector3.new(2, 3, 4))
		local frame = CFrame.new(17, -8, 5) * CFrame.Angles(0.3, 0.7, -0.2)
		local a = S.limit(m, 1, 0.17, 0.31)
		for _, scale in { 0.001, 7, 1000 } do
			local n = m:clone()
			for id, p in n.vertices do
				n.vertices[id] = frame:PointToWorldSpace(p * scale)
			end
			local b = S.limit(n, 1, 0.17, 0.31, { tolerance = 0.001 })
			assert(b.complete)
			near(b.position, frame:PointToWorldSpace(a.position * scale), math.max(8e-6, scale * 2e-6))
			near(b.derivativeU, frame:VectorToWorldSpace(a.derivativeU * scale), math.max(8e-6, scale * 3e-6))
		end
	end)
	test("Large and tiny scales return finite unit normals without native cross overflow", function()
		for _, scale in { 1e-20, 1e20 } do
			local m, _, f = grid(4, 4)
			for id, p in m.vertices do
				m.vertices[id] = p * scale
			end
			local r = S.limit(m, f(1, 1), 0.27, 0.63, { tolerance = scale * 1e-5 })
			assert(r.complete and r.normal and r.normalErrorBound)
			near(r.normal, Vector3.zAxis)
		end
	end)
	test("Sparse face and vertex identities preserve all query parameterizations", function()
		local m = E.Primitives.box(Vector3.new(2, 3, 4))
		local n = E.Mesh.new()
		for id, p in m.vertices do
			n.vertices[13 * id + 9] = p
		end
		for fid, f in m.faces do
			local c = table.clone(f.vertices)
			for i, v in c do
				c[i] = 13 * v + 9
			end
			n.faces[7 * fid + 11] = { vertices = c, corners = table.clone(f.corners), material = f.material }
		end
		for _, uv in { { 0, 0 }, { 0.71, 0.28 }, { 0.3, 0.9 } } do
			near(S.limit(m, 1, uv[1], uv[2]).position, S.limit(n, 18, uv[1], uv[2]).position)
		end
	end)
	test("Limit queries preserve every source attribute and do not create scene objects", function()
		local m = grid(3, 3)
		m = E.Attributes.create(m, "stamp", "corner", "number", 7)
		m = S.catmullClark(m, 1, { faceVarying = { uv = "smooth" } })
		m.groups.sample = { [1] = 0.3 }
		m.weights[1] = { Bone = 1 }
		local before = E.IO.encode(m)
		local r = S.limit(m, 1, 0.32, 0.48)
		assert(r.complete and E.IO.encode(m) == before)
	end)
	test("Checkpoint cancellation interrupts local refinement while leaving input unchanged", function()
		local m = grid(1, 1)
		local before = E.IO.encode(m)
		local stop = false
		local calls = 0
		rejects(function()
			S.limit(m, 1, 0.37, 0, {
				cancelled = function()
					return stop
				end,
				checkpoint = function(status)
					calls += 1
					assert(status.depth >= 0 and status.errorBound > 0)
					stop = true
				end,
			})
		end)
		assert(calls == 1 and E.IO.encode(m) == before)
		rejects(function()
			S.limit(m, 1, 0.37, 0, { maxFaces = 2 })
		end)
		rejects(function()
			S.limit(m, 1, 0.37, 0, { maxCorners = 3 })
		end)
	end)
	test("Invalid topology winding positions and crease channels reject before evaluation", function()
		local m = grid(2, 2)
		local bad = m:clone()
		bad.faces[1].vertices[2] = bad.faces[1].vertices[1]
		rejects(function()
			S.prepareLimit(bad)
		end)
		bad = m:clone()
		bad.vertices[1] = Vector3.new(0 / 0, 0, 0)
		rejects(function()
			S.prepareLimit(bad)
		end)
		bad = m:clone()
		local f = bad.faces[1].vertices
		f[1], f[4] = f[4], f[1]
		f[2], f[3] = f[3], f[2]
		rejects(function()
			S.prepareLimit(bad)
		end)
		bad = E.Attributes.create(m, "subdivision_vertex_sharpness", "vertex", "number", 1)
		rejects(function()
			S.prepareLimit(bad)
		end)
	end)
	test("Collapsed regular patches report singular normals without fabricating a direction", function()
		local m, _, f = grid(4, 4)
		for id, p in m.vertices do
			m.vertices[id] = Vector3.new(p.X, 0, 0)
		end
		local r = S.limit(m, f(1, 1), 0.3, 0.7)
		assert(r.complete and r.derivativesAvailable and r.normal == nil)
		near(r.derivativeU, Vector3.xAxis)
		near(r.derivativeV, Vector3.zero)
	end)
	test("Extraordinary characteristic normals match analytic tilted planes and rigid transforms", function()
		local frame = CFrame.Angles(0.2, 0.4, -0.3)
		for _, n in { 3, 5, 8, 17 } do
			local m = E.Mesh.new()
			m:addVertex(Vector3.zero)
			local radial, diagonal = {}, {}
			local function point(a, r)
				local x, y = r * math.cos(a), r * math.sin(a)
				return frame:VectorToWorldSpace(Vector3.new(x, y, 0.2 * x - 0.3 * y))
			end
			for i = 1, n do
				radial[i] = m:addVertex(point(2 * math.pi * (i - 1) / n, 1))
				diagonal[i] = m:addVertex(point(2 * math.pi * (i - 0.5) / n, 1.6))
			end
			for i = 1, n do
				m:addFace({ 1, radial[i], diagonal[i], radial[i % n + 1] })
			end
			local expected = frame:VectorToWorldSpace(Vector3.new(-0.2, 0.3, 1).Unit)
			for fid = 1, n do
				local r = S.limit(m, fid, 0, 0)
				assert(r.normal and r.normalErrorBound)
				near(r.normal, expected, 3e-6)
			end
		end
	end)
	test("Limit sampled patches retain UVs and analytic normals through native conversion", function()
		local result = require(script.Parent.Examples.LimitPanel)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			for _, f in restored.faces do
				for _, c in f.corners do
					assert(
						c.normal
							and math.abs(c.normal.Magnitude - 1) < 1e-5
							and c.uv
							and c.uv.X >= 0
							and c.uv.X <= 1
							and c.uv.Y >= 0
							and c.uv.Y <= 1
					)
				end
			end
			assert(result.queries.queries == 49)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
