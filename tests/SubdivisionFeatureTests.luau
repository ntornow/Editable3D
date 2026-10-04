return function(E, settings)
	local S = E.Subdivision
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		if
			settings
			and settings.skipNative
			and name == "One-sided normals and UVs survive native conversion across a shared crease"
		then
			return
		end
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, epsilon)
		assert((a - b).Magnitude < (epsilon or 1e-5), tostring(a) .. " ~= " .. tostring(b))
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
				m:addVertex(Vector3.new(i, j, field(i, j)))
			end
		end
		for i = 0, nx - 1 do
			for j = 0, ny - 1 do
				m:addFace({ id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) })
			end
		end
		return m, id, fid
	end
	local function edge(a, b)
		return math.min(a, b) .. ":" .. math.max(a, b)
	end
	test("One-sided regular boundaries reproduce independent cubic positions and partials", function()
		local m, _, f = grid(5, 4, function(x, y)
			return x * x + 2 * y * y + 3 * y
		end)
		for _, uv in { { 0, 0 }, { 0.2, 0 }, { 0.7, 0.2 }, { 1, 1 } } do
			local u, v = uv[1], uv[2]
			local x = 2 + u
			local r = S.limit(m, f(2, 0), u, v)
			assert(r.oneSided and r.derivativesAvailable and r.complete and r.method == "bicubicOneSided")
			near(r.position, Vector3.new(x, v, x * x + 1 / 3 + 2 * (v ^ 3 / 3 + v) + 3 * v))
			near(r.derivativeU, Vector3.new(1, 0, 2 * x))
			near(r.derivativeV, Vector3.new(0, 1, 2 * (v * v + 1) + 3))
			near(r.normal, Vector3.new(1, 0, 2 * x):Cross(Vector3.new(0, 1, 2 * (v * v + 1) + 3)).Unit)
		end
	end)
	test("The two sides of an infinite crease share positions and have different analytic normals", function()
		local m, id, f = grid(5, 6, function(x, j)
			local y = j - 3
			return x * x + (y >= 0 and 2 or 5) * y * y + (y >= 0 and 3 or -1) * y
		end)
		local creases = {}
		for i = 0, 4 do
			creases[edge(id(i, 3), id(i + 1, 3))] = 10
		end
		m = S.crease(m, creases)
		local a, b = S.limit(m, f(2, 3), 0.4, 0), S.limit(m, f(2, 2), 0.4, 1)
		near(a.position, b.position)
		near(a.derivativeU, Vector3.new(1, 0, 4.8))
		near(a.derivativeV, Vector3.new(0, 1, 5))
		near(b.derivativeV, Vector3.new(0, 1, -6))
		near(a.normal, Vector3.new(1, 0, 4.8):Cross(Vector3.new(0, 1, 5)).Unit)
		near(b.normal, Vector3.new(1, 0, 4.8):Cross(Vector3.new(0, 1, -6)).Unit)
		assert(a.oneSided and b.oneSided and (a.normal - b.normal).Magnitude > 0.5)
	end)
	test("Fixed nonplanar quad corners and all parameter rotations give exact bilinear jets", function()
		local points =
			{ Vector3.new(0, 0, 0), Vector3.new(2, 0, 0), Vector3.new(2, 1, 1), Vector3.new(0, 1, 0) }
		for offset = 0, 3 do
			local m = E.Mesh.new()
			local p = {}
			for i = 1, 4 do
				p[i] = points[(i + offset - 1) % 4 + 1]
				m:addVertex(p[i])
			end
			m:addFace({ 1, 2, 3, 4 })
			for _, uv in { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { 0.2, 0.7 } } do
				local u, v = uv[1], uv[2]
				local r = S.limit(m, 1, u, v, { boundary = "edgeAndCorner" })
				local du = (p[2] - p[1]) * (1 - v) + (p[3] - p[4]) * v
				local dv = (p[4] - p[1]) * (1 - u) + (p[3] - p[2]) * u
				near(
					r.position,
					p[1] * (1 - u) * (1 - v) + p[2] * u * (1 - v) + p[3] * u * v + p[4] * (1 - u) * v
				)
				near(r.derivativeU, du)
				near(r.derivativeV, dv)
				near(r.normal, du:Cross(dv).Unit)
				assert(r.oneSided and r.derivativesAvailable)
			end
		end
	end)
	test("One-sided jets agree with a full cage subdivision in every quadrant", function()
		local m, _, f = grid(6, 5, function(x, y)
			return math.sin(x * 0.8) + math.cos(y * 0.6) + x * y * 0.13
		end)
		local fine = S.catmullClark(m, 1)
		for _, uv in { { 0.2, 0.3 }, { 0.8, 0.4 }, { 0.7, 0.9 }, { 0.1, 0.8 } } do
			local u, v = uv[1], uv[2]
			local q, x, y, a, b, c, d
			if u <= 0.5 and v <= 0.5 then
				q, x, y, a, b, c, d = 1, 2 * u, 2 * v, 2, 0, 0, 2
			elseif u > 0.5 and v <= 0.5 then
				q, x, y, a, b, c, d = 2, 2 * v, 2 * (1 - u), 0, 2, -2, 0
			elseif u > 0.5 then
				q, x, y, a, b, c, d = 3, 2 * (1 - u), 2 * (1 - v), -2, 0, 0, -2
			else
				q, x, y, a, b, c, d = 4, 2 * (1 - v), 2 * u, 0, -2, 2, 0
			end
			local first = S.limit(m, f(2, 0), u, v)
			local second = S.limit(fine, (f(2, 0) - 1) * 4 + q, x, y)
			near(first.position, second.position)
			near(first.derivativeU, second.derivativeU * a + second.derivativeV * c)
			near(first.derivativeV, second.derivativeU * b + second.derivativeV * d)
			near(first.normal, second.normal)
		end
	end)
	test("Rounded boundary corners have collinear chart partials and a characteristic normal", function()
		local p = { Vector3.new(0, 0, 0), Vector3.new(2, 0, 0), Vector3.new(2, 1, 1), Vector3.new(0, 1, 0) }
		local m = E.Mesh.new()
		for _, point in p do
			m:addVertex(point)
		end
		m:addFace({ 1, 2, 3, 4 })
		for index, uv in { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } } do
			local next, previous = p[index % 4 + 1], p[(index + 2) % 4 + 1]
			local t = (next - previous) * 0.5
			local r = S.limit(m, 1, uv[1], uv[2])
			assert(r.oneSided and r.derivativesAvailable and r.normalMethod == "creaseCharacteristic")
			near(r.position, (4 * p[index] + next + previous) / 6)
			near(r.normal, t:Cross(next + previous - 2 * p[index]).Unit)
			assert(r.derivativeU:Cross(r.derivativeV).Magnitude < 1e-6)
			local du = (index == 1 or index == 2) and t or -t
			local dv = (index == 2 or index == 3) and t or -t
			near(r.derivativeU, du)
			near(r.derivativeV, dv)
		end
	end)
	test("Three-face crease sectors use the full annular proof while retaining divergent partials", function()
		local m = E.Mesh.new()
		local center = m:addVertex(Vector3.zero)
		local es, ds = {}, {}
		for _, p in
			{
				Vector3.new(-1, 0, 0),
				Vector3.new(-0.5, 1, 0.2),
				Vector3.new(0.5, 1, 0.2),
				Vector3.new(1, 0, 0),
			}
		do
			table.insert(es, m:addVertex(p))
		end
		for _, p in { Vector3.new(-1, 1.5, 0.8), Vector3.new(0, 2, -0.3), Vector3.new(1, 1.5, 0.8) } do
			table.insert(ds, m:addVertex(p))
		end
		for i = 1, 3 do
			m:addFace({ center, es[i], ds[i], es[i + 1] })
		end
		local at = S.limit(m, 2, 0, 0)
		assert(
			at.oneSided and at.normalAvailable and not at.derivativesAvailable and at.normalSectorFaces == 3
		)
		assert(at.normalMethod == "creaseThreeSector" and at.normalErrorBound and at.derivativeReason)
		near(at.position, Vector3.zero)
		for _, n in { 4, 6, 8 } do
			local h = 2 ^ -n
			local r = S.limit(m, 2, h, h, { tolerance = 1e-7 })
			assert(r.normalAvailable)
		end
	end)
	test("Exact collinear boundary controls use the surviving diagonal tangent mode", function()
		local m = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.new(1, 0, 0), Vector3.new(0, 1, 1), Vector3.new(-1, 0, 0) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3, 4 })
		local r = S.limit(m, 1, 0, 0)
		assert(r.derivativesAvailable and r.normalAvailable and r.oneSided)
		near(r.normal, Vector3.new(0, -1, 1).Unit)
		near(r.derivativeU, Vector3.xAxis)
		near(r.derivativeV, -Vector3.xAxis)
		local flat = m:clone()
		flat.vertices[3] = Vector3.new(2, 0, 0)
		local q = S.limit(flat, 1, 0, 0)
		assert(q.complete and q.derivativesAvailable and not q.normalAvailable and q.normalReason)
	end)
	test("An adjacent polygon refines once before applying a stationary one-sided vertex stencil", function()
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.zero,
				Vector3.new(1, 0, 0),
				Vector3.new(1, 1, 0),
				Vector3.new(0, 1, 0),
				Vector3.new(-1, 0, 0),
			}
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3, 4 })
		m:addFace({ 1, 4, 5 })
		local coarse = S.limit(m, 1, 0, 0, { maxDepth = 0 })
		assert(coarse.complete and not coarse.normalAvailable)
		local r = S.limit(m, 1, 0, 0)
		assert(r.complete and r.normalAvailable and r.derivativesAvailable and r.depth == 1)
		near(r.normal, Vector3.zAxis)
		near(r.position, coarse.position)
	end)
	test("Rigid transforms and model scales preserve one-sided jets", function()
		local m, _, f = grid(5, 4, function(x, y)
			return x * x + 2 * y * y + 3 * y
		end)
		local base = S.limit(m, f(2, 0), 0.37, 0)
		local frame = CFrame.new(3, -7, 2) * CFrame.Angles(0.2, -0.4, 0.3)
		for _, scale in { 0.01, 100 } do
			local copy = m:clone()
			for id, p in copy.vertices do
				copy.vertices[id] = frame:PointToWorldSpace(p * scale)
			end
			local r = S.limit(copy, f(2, 0), 0.37, 0, { tolerance = 0.001 })
			local epsilon = 3e-5 * math.max(1, scale)
			assert(r.oneSided and r.derivativesAvailable)
			near(r.position, frame:PointToWorldSpace(base.position * scale), epsilon)
			near(r.derivativeU, frame:VectorToWorldSpace(base.derivativeU * scale), epsilon)
			near(r.derivativeV, frame:VectorToWorldSpace(base.derivativeV * scale), epsilon)
			near(r.normal, frame:VectorToWorldSpace(base.normal), 1e-4)
		end
	end)
	test("Finite uniform and Chaikin transitions retain one-sided derivative availability", function()
		local m, id, f = grid(5, 5, function(x, y)
			return math.cos(x) * math.sin(y)
		end)
		m = S.crease(m, { [edge(id(2, 0), id(2, 1))] = 2.2, [edge(id(2, 1), id(2, 2))] = 0.7 })
		for _, creasing in { "uniform", "chaikin" } do
			local r = S.limit(m, f(2, 0), 0.37, 0, { creasing = creasing })
			assert(r.complete and r.derivativesAvailable and r.normalAvailable and r.oneSided)
			local h = 1e-3
			local a = S.limit(m, f(2, 0), 0.37 - h, 0, { creasing = creasing })
			local b = S.limit(m, f(2, 0), 0.37 + h, 0, { creasing = creasing })
			near(r.derivativeU, (b.position - a.position) / (2 * h), 2e-4)
		end
	end)
	test("Fixed two-face boundary normals stay distinct from unsupported higher sectors", function()
		local m, _, f = grid(5, 4, function(x, y)
			return x * x + y * y
		end)
		local r = S.limit(m, f(2, 0), 0, 0, { boundary = "fixed" })
		assert(
			r.complete
				and not r.derivativesAvailable
				and r.normalAvailable
				and r.normalMethod == "fixedCornerJordan"
		)
		near(r.normal, Vector3.new(0, -1, 0))
		local fan = E.Mesh.new()
		local center = fan:addVertex(Vector3.zero)
		local es, ds = {}, {}
		for i = 0, 4 do
			table.insert(
				es,
				fan:addVertex(Vector3.new(math.cos(math.pi * i / 4), math.sin(math.pi * i / 4), 0.1 * i * i))
			)
		end
		for i = 1, 4 do
			table.insert(
				ds,
				fan:addVertex(
					Vector3.new(
						math.cos(math.pi * (i - 0.5) / 4) * 2,
						math.sin(math.pi * (i - 0.5) / 4) * 2,
						0.2 * i
					)
				)
			)
		end
		for i = 1, 4 do
			fan:addFace({ center, es[i], ds[i], es[i + 1] })
		end
		local q = S.limit(fan, 2, 0, 0)
		assert(q.complete and not q.normalAvailable and not q.derivativesAvailable)
	end)
	test("Feature work obeys cancellation, allocation and prepared-query limits", function()
		local m, _, f = grid(5, 4, function(x, y)
			return x * x + y * y
		end)
		for _, options in
			{
				{ maxWork = 1 },
				{ maxVertices = 2 },
				{
					cancelled = function()
						return true
					end,
				},
			}
		do
			assert(not pcall(S.limit, m, f(2, 0), 0.37, 0, options))
		end
		local prepared = S.prepareLimit(m, { maxQueries = 1 })
		local first = prepared:evaluate(f(2, 0), 0.37, 0)
		assert(first.oneSided and first.normalAvailable)
		assert(not pcall(function()
			prepared:evaluate(f(2, 0), 0.4, 0)
		end))
	end)
	test("Feature queries preserve all data and snapshot geometry across callbacks", function()
		local m, _, f = grid(5, 4, function(x, y)
			return x * x + y * y
		end)
		for _, domain in { "vertex", "edge", "face", "corner" } do
			m = E.Attributes.create(m, "stamp_" .. domain, domain, "number", 7)
		end
		m.groups.sample = { [1] = 0.3 }
		m.weights[1] = { Bone = 1 }
		local before = E.IO.encode(m)
		local options = { boundary = "edge", tolerance = 1e-5 }
		local evaluator = S.prepareLimit(m, options)
		local first = evaluator:evaluate(f(2, 0), 0.37, 0)
		assert(E.IO.encode(m) == before)
		options.boundary, options.tolerance = "fixed", 1e-15
		m.vertices[1] = Vector3.new(100, 100, 100)
		local second = evaluator:evaluate(f(2, 0), 0.37, 0)
		near(first.position, second.position)
		near(first.derivativeU, second.derivativeU)
		near(first.derivativeV, second.derivativeV)
		local quad = grid(1, 1, function()
			return 0
		end)
		local expected = S.limit(quad, 1, 0.37, 0)
		local calls = 0
		local actual = S.limit(quad, 1, 0.37, 0, {
			checkpoint = function()
				calls += 1
				quad.vertices[1] = Vector3.new(100, 100, 100)
			end,
		})
		assert(calls > 0 and actual.oneSided)
		near(actual.position, expected.position)
		near(actual.derivativeV, expected.derivativeV)
	end)
	test("Sparse identifiers retain oriented boundary stencils", function()
		local m, _, f = grid(5, 4, function(x, y)
			return x * x + y * y
		end)
		local sparse = E.Mesh.new()
		for id, p in m.vertices do
			sparse.vertices[13 * id + 9] = p
		end
		for fid, face in m.faces do
			local ids = {}
			for i, id in face.vertices do
				ids[i] = 13 * id + 9
			end
			sparse.faces[7 * fid + 11] =
				{ vertices = ids, corners = table.clone(face.corners), material = face.material }
		end
		local a = S.limit(m, f(2, 0), 0.37, 0)
		local b = S.limit(sparse, 7 * f(2, 0) + 11, 0.37, 0)
		near(a.position, b.position)
		near(a.derivativeU, b.derivativeU)
		near(a.derivativeV, b.derivativeV)
		near(a.normal, b.normal)
	end)
	test("Tiny and huge boundary patches avoid native cross underflow and overflow", function()
		for _, scale in { 1e-25, 1e25 } do
			local m = grid(5, 4, function(x, y)
				return x + 2 * y
			end)
			for id, p in m.vertices do
				m.vertices[id] = p * scale
			end
			local r = S.limit(m, 9, 0.37, 0, { tolerance = scale * 1e-5 })
			assert(r.complete and r.oneSided and r.derivativesAvailable and r.normalAvailable)
			near(r.normal, Vector3.new(-1, -2, 1).Unit, 1e-5)
			near(r.derivativeU / scale, Vector3.new(1, 0, 1), 1e-5)
			near(r.derivativeV / scale, Vector3.new(0, 1, 2), 1e-5)
		end
	end)
	test("One-sided normals and UVs survive native conversion across a shared crease", function()
		local result = require(script.Parent.Examples.CreaseLimitPanel)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid and result.queries.queries == 50)
			local seamNormals = {}
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-5)
					if math.abs(corner.uv.Y - 0.5) < 1e-6 then
						table.insert(seamNormals, corner.normal)
					end
				end
			end
			local separated = false
			for _, a in seamNormals do
				for _, b in seamNormals do
					separated = separated or (a - b).Magnitude > 0.5
				end
			end
			assert(separated)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
