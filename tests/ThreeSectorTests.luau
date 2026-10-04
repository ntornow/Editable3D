return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local S, V = E.Subdivision, Vector3.new
	local fixture = game:GetService("HttpService"):JSONDecode(require(script.Parent.ThreeSectorFixtures))
	local function scalar(q)
		return assert(tonumber(q[1])) / assert(tonumber(q[2]))
	end
	local function near(a, b, e)
		assert((a - b).Magnitude < (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function fan(midpoint)
		local m = E.Mesh.new()
		local points = {
			V(0, 0.25, 0.125),
			V(-2, 0, 0),
			V(-1, 1, 2),
			V(1, 1, -0.5),
			V(2, 0, 0.25),
			V(-3, 2, 1),
			V(0, 3, 1.5),
			V(3, 2, -1),
		}
		if midpoint then
			points[1] = (points[2] + points[5]) / 2
		end
		for _, p in points do
			m:addVertex(p)
		end
		for i = 1, 3 do
			m:addFace({ 1, i + 1, i + 5, i + 2 })
		end
		return m
	end
	local function reference(m)
		local p, e, d = m.vertices[1], {}, {}
		for i = 1, 4 do
			e[i] = m.vertices[i + 1]
		end
		for i = 1, 3 do
			d[i] = m.vertices[i + 5]
		end
		local lambda = (11 + math.sqrt(57)) / 32
		local function combination(weights)
			local points = { p, e[1], e[2], e[3], e[4], d[1], d[2], d[3] }
			local x, y, z = 0, 0, 0
			for i, q in points do
				x += q.X * weights[i]
				y += q.Y * weights[i]
				z += q.Z * weights[i]
			end
			return V(x / 114, y / 114, z / 114)
		end
		local transverse = combination({
			-16 - 64 * lambda,
			18 - 80 * lambda,
			12 + 48 * lambda,
			12 + 48 * lambda,
			18 - 80 * lambda,
			-11 + 32 * lambda,
			-22 + 64 * lambda,
			-11 + 32 * lambda,
		})
		return ((e[1] - e[4]) / 2):Cross(transverse).Unit
	end
	test("882 full-halo operator entries match actual crease and fixed-center subdivision masks", function()
		local U = require(script.Parent.Util)
		local function key(v)
			return table.concat(v, ":")
		end
		local function node(k, i, j)
			if i == 0 and j == 0 then
				return "c"
			elseif j == 0 then
				return "r:" .. k .. ":" .. i
			elseif i == 0 then
				return "r:" .. (k + 1) .. ":" .. j
			else
				return "f:" .. k .. ":" .. i .. ":" .. j
			end
		end
		for _, kind in { "crease", "corner" } do
			local matrix = kind == "crease" and fixture.matrix or fixture.cornerMatrix
			for column in fixture.vertices do
				local m = E.Mesh.new()
				local ids, faces = {}, {}
				local rays = { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) }
				for i, v in fixture.vertices do
					local p = Vector3.zero
					if v[1] == "r" then
						p = rays[v[2] + 1] * v[3]
					elseif v[1] == "f" then
						p = rays[v[2] + 1] * v[3] + rays[v[2] + 2] * v[4]
					end
					ids[key(v)] = m:addVertex(p + V(0, 0, i == column and 1 or 0))
				end
				for k = 0, 2 do
					for j = 0, 1 do
						for i = 0, 1 do
							faces[k .. ":" .. i .. ":" .. j] = m:addFace({
								ids[node(k, i, j)],
								ids[node(k, i + 1, j)],
								ids[node(k, i + 1, j + 1)],
								ids[node(k, i, j + 1)],
							})
						end
					end
				end
				local edgeKeys = U.keys(m:topology().edges)
				local edgeIds = {}
				for i, k in edgeKeys do
					edgeIds[k] = #fixture.vertices + i
				end
				if kind == "corner" then
					m = S.crease(m, nil, { [ids.c] = 10 })
				end
				local out = S.catmullClark(m, 1)
				for row, v in fixture.vertices do
					local k, i, j = 0, 0, 0
					if v[1] == "r" then
						k = v[2]
						i = v[3]
						if k == 3 then
							k = 2
							j = i
							i = 0
						end
					elseif v[1] == "f" then
						k, i, j = v[2], v[3], v[4]
					end
					local a = ids[node(k, math.floor(i / 2), math.floor(j / 2))]
					local id
					if i % 2 == 1 and j % 2 == 1 then
						id = #fixture.vertices
							+ #edgeKeys
							+ faces[k .. ":" .. math.floor(i / 2) .. ":" .. math.floor(j / 2)]
					elseif i % 2 == 1 then
						id = edgeIds[U.edge(a, ids[node(k, math.floor(i / 2) + 1, math.floor(j / 2))])]
					elseif j % 2 == 1 then
						id = edgeIds[U.edge(a, ids[node(k, math.floor(i / 2), math.floor(j / 2) + 1)])]
					else
						id = a
					end
					assert(
						out.vertices[id].Z == scalar(matrix[row][column]),
						kind .. " mask " .. row .. ":" .. column
					)
				end
			end
		end
	end)
	test("Exact quadratic-field eigenvectors and all324 annular Jacobian signs verify", function()
		local work = 0
		local function tick(n)
			work += n or 1
			assert(work < 30000000)
		end
		local R = require(script.Parent.ExactRational)(tick, 8192)
		local function r(p)
			return R.div(R.number(tonumber(p[1])), R.number(tonumber(p[2])))
		end
		local function q(p)
			return { r(p[1]), r(p[2]) }
		end
		local zero = { R.number(0), R.number(0) }
		local function add(a, b)
			return { R.add(a[1], b[1]), R.add(a[2], b[2]) }
		end
		local function scale(a, b)
			return { R.mul(a[1], b), R.mul(a[2], b) }
		end
		local function mul(a, b)
			local bb = R.mul(a[2], b[2])
			return {
				R.sub(R.mul(a[1], b[1]), R.div(bb, R.number(16))),
				R.add(
					R.add(R.mul(a[1], b[2]), R.mul(a[2], b[1])),
					R.mul(bb, R.div(R.number(11), R.number(16)))
				),
			}
		end
		local function equal(a, b)
			return R.equal(a[1], b[1]) and R.equal(a[2], b[2])
		end
		for _, mode in
			{
				{ "rightX", "leftX", { R.number(0.5), R.number(0) } },
				{
					"rightY",
					"leftY",
					{ R.number(0), R.number(1) },
				},
			}
		do
			local right, left = {}, {}
			for i, p in fixture[mode[1]] do
				right[i] = q(p)
				left[i] = q(fixture[mode[2]][i])
			end
			for i, row in fixture.matrix do
				local value, transpose = zero, zero
				for j, c in row do
					value = add(value, scale(right[j], r(c)))
					transpose = add(transpose, scale(left[j], r(fixture.matrix[j][i])))
				end
				assert(equal(value, mul(mode[3], right[i])) and equal(transpose, mul(mode[3], left[i])))
			end
			local total = zero
			for i, a in left do
				total = add(total, mul(a, right[i]))
			end
			assert(equal(total, { R.number(1), R.number(0) }))
		end
		local count = 0
		for _, patch in fixture.patches do
			for _, row in patch.jacobian do
				for _, encoded in row do
					local value = q(encoded)
					local a = R.add(R.mul(R.number(32), value[1]), R.mul(R.number(11), value[2]))
					local b = value[2]
					local sign
					if a.sign == 0 then
						sign = b.sign
					elseif b.sign == 0 or a.sign == b.sign then
						sign = a.sign
					else
						sign = a.sign * R.compare(R.mul(a, a), R.mul(R.number(57), R.mul(b, b)))
					end
					assert(sign == 1)
					count += 1
				end
			end
		end
		assert(count == 324)
	end)
	test(
		"Three-face ordinary crease normals agree across the sector with an independent modal reference",
		function()
			local m = fan()
			local expected = reference(m)
			for face = 1, 3 do
				local r = S.limit(m, face, 0, 0)
				assert(
					r.complete
						and r.normalAvailable
						and not r.derivativesAvailable
						and r.normalMethod == "creaseThreeSector"
						and r.normalSectorFaces == 3
						and r.oneSided
				)
				near(r.normal, expected, 1e-6)
				assert(r.normalErrorBound < 1e-5)
			end
		end
	)
	test("Analytic annular normals converge on all nine patches and both hard boundaries", function()
		local m = fan()
		local evaluator = S.prepareLimit(m, { maxDepth = 32, maxWork = 100000000, tolerance = 1e-14 })
		local expected = evaluator:evaluate(1, 0, 0).normal
		for face = 1, 3 do
			for _, uv in { { 0.75, 0.25 }, { 0.75, 0.75 }, { 0.25, 0.75 }, { 0.75, 0 }, { 0, 0.75 } } do
				local early = evaluator:evaluate(face, uv[1] * 2 ^ -8, uv[2] * 2 ^ -8)
				local later = evaluator:evaluate(face, uv[1] * 2 ^ -16, uv[2] * 2 ^ -16)
				assert(early.derivativesAvailable and later.derivativesAvailable)
				assert(
					(later.normal - expected).Magnitude < (early.normal - expected).Magnitude
						and (later.normal - expected).Magnitude < 0.04
				)
			end
		end
	end)
	test("Fixed exact-midpoint three-face sectors inherit the proved crease normal", function()
		local m = S.crease(fan(true), nil, { [1] = 10 })
		local expected = reference(m)
		for _, boundary in { "edge", "fixed" } do
			for face = 1, 3 do
				local r = S.limit(m, face, 0, 0, { boundary = boundary })
				assert(
					r.normalAvailable
						and not r.derivativesAvailable
						and r.normalMethod == "fixedMidpointThreeSector"
				)
				near(r.normal, expected, 1e-6)
			end
		end
	end)
	test("A three-face sector at a hard-edge junction retains the exact midpoint normal", function()
		local m = fan(true)
		local expected = reference(m)
		local a = m:addVertex(V(1, -1, 0))
		local b = m:addVertex(V(-1, -1, 0))
		local d = m:addVertex(V(3, -2, 0))
		local e = m:addVertex(V(0, -3, 0))
		local f = m:addVertex(V(-3, -2, 0))
		m:addFace({ 1, 5, d, a })
		m:addFace({ 1, a, e, b })
		m:addFace({ 1, b, f, 2 })
		local U = require(script.Parent.Util)
		m = S.crease(m, { [U.edge(1, 2)] = 10, [U.edge(1, 5)] = 10, [U.edge(1, a)] = 10 })
		for face = 1, 3 do
			local r = S.limit(m, face, 0, 0)
			assert(r.normalAvailable and r.normalMethod == "fixedMidpointThreeSector")
			near(r.normal, expected, 1e-6)
		end
	end)
	test("A higher fixed corner without the exact midpoint keeps its unresolved contract", function()
		local m = S.crease(fan(), nil, { [1] = 10 })
		local r = S.limit(m, 1, 0, 0)
		assert(r.complete and not r.normalAvailable and not r.derivativesAvailable)
	end)
	local function zeroMode()
		local m = E.Mesh.new()
		for _, p in
			{
				V(0, 0, 0),
				V(-2, 0, 0),
				V(-1, 1, 1),
				V(1, -1, -1),
				V(2, 0, 0),
				V(-3, 2, 3),
				V(0, 1, -1),
				V(3, -4, -1),
			}
		do
			m:addVertex(p)
		end
		for i = 1, 3 do
			m:addFace({ 1, i + 1, i + 5, i + 2 })
		end
		return m
	end
	test("Exact transverse-mode annihilation supplies finite rank-one face-chart partials", function()
		local m = zeroMode()
		local tangent = V(-2, 0, 0)
		for face, slopes in { { 1, 1 }, { 1, -1 }, { -1, -1 } } do
			local r = S.limit(m, face, 0, 0)
			assert(r.derivativesAvailable and not r.normalAvailable)
			near(r.derivativeU, tangent * slopes[1])
			near(r.derivativeV, tangent * slopes[2])
		end
	end)
	test("Mode-free analytic annuli converge to the finite rank-one jets", function()
		local m = zeroMode()
		local evaluator = S.prepareLimit(m, { maxDepth = 32, maxWork = 100000000, tolerance = 1e-14 })
		for face = 1, 3 do
			local exact = evaluator:evaluate(face, 0, 0)
			local early = evaluator:evaluate(face, 0.75 * 2 ^ -8, 0.5 * 2 ^ -8)
			local later = evaluator:evaluate(face, 0.75 * 2 ^ -16, 0.5 * 2 ^ -16)
			assert(later.derivativesAvailable and early.derivativesAvailable)
			local old = (early.derivativeU - exact.derivativeU).Magnitude
				+ (early.derivativeV - exact.derivativeV).Magnitude
			local new = (later.derivativeU - exact.derivativeU).Magnitude
				+ (later.derivativeV - exact.derivativeV).Magnitude
			assert(new < old and new < 0.3, tostring(new) .. " vs " .. tostring(old))
		end
	end)
	test("A native perturbation of the annihilation identity retains unavailable finite partials", function()
		local m = zeroMode()
		m.vertices[6] += V(0, 0, 2 ^ -20)
		local r = S.limit(m, 1, 0, 0)
		assert(not r.derivativesAvailable and r.normalAvailable)
	end)
	test("All parameter-corner rotations map finite three-sector derivatives correctly", function()
		local m = zeroMode()
		local base = S.limit(m, 1, 0, 0)
		local uv = { { 0, 0 }, { 0, 1 }, { 1, 1 }, { 1, 0 } }
		for rotation = 0, 3 do
			local copy = m:clone()
			for _, face in copy.faces do
				local ids, cs = {}, {}
				for i = 1, 4 do
					ids[i] = face.vertices[(i + rotation - 1) % 4 + 1]
					cs[i] = face.corners[(i + rotation - 1) % 4 + 1]
				end
				face.vertices, face.corners = ids, cs
			end
			local r = S.limit(copy, 1, uv[rotation + 1][1], uv[rotation + 1][2])
			assert(r.derivativesAvailable)
			local a, b = base.derivativeU, base.derivativeV
			if rotation == 1 then
				a, b = b, -a
			elseif rotation == 2 then
				a, b = -a, -b
			elseif rotation == 3 then
				a, b = -b, a
			end
			near(r.derivativeU, a)
			near(r.derivativeV, b)
		end
	end)
	test("Reflected source winding reverses the limiting normal consistently", function()
		local m = fan()
		local base = S.limit(m, 1, 0, 0).normal
		for _, face in m.faces do
			face.vertices = { face.vertices[1], face.vertices[4], face.vertices[3], face.vertices[2] }
			face.corners = { face.corners[1], face.corners[4], face.corners[3], face.corners[2] }
		end
		for face = 1, 3 do
			near(S.limit(m, face, 0, 0).normal, -base, 1e-6)
		end
	end)
	test("Three-sector normals respect scale translation and exact oblique rotation", function()
		local m = fan()
		local expected = S.limit(m, 1, 0, 0).normal
		for _, scale in { 0.01, 1000 } do
			local copy = m:clone()
			for id, p in copy.vertices do
				copy.vertices[id] = V(p.X + p.Z, p.Y, p.Z - p.X) * scale + V(16, -8, 4)
			end
			local r = S.limit(copy, 1, 0, 0, { tolerance = 0.01 })
			assert(r.normalAvailable)
			-- Transform normal by inverse transpose of the exact diagonal-scaled rotation.
			local transformed =
				V((expected.X + expected.Z) / 2, expected.Y, (expected.Z - expected.X) / 2).Unit
			near(r.normal, transformed, 2e-4)
		end
	end)
	test("Prepared queries detach source positions and enforce work and query budgets", function()
		local m = fan()
		local before = E.IO.encode(m)
		local prepared = S.prepareLimit(m, { maxQueries = 2 })
		local first = prepared:evaluate(1, 0, 0)
		m.vertices[1] = V(99, 99, 99)
		local second = prepared:evaluate(1, 0, 0)
		near(first.normal, second.normal)
		assert(not pcall(function()
			prepared:evaluate(1, 0, 0)
		end))
		local fresh = fan()
		assert(not pcall(S.limit, fresh, 1, 0, 0, { maxWork = 1 }))
		assert(E.IO.encode(fresh) == before)
		local token = {}
		local ok, err = pcall(S.limit, fresh, 1, 0, 0, {
			cancelled = function()
				error(token)
			end,
		})
		assert(not ok and err == token)
	end)
	if not settings or not settings.skipNative then
		test("Three-sector limit normals and corner UVs survive native EditableMesh conversion", function()
			local source = fan()
			local mesh = E.Mesh.new()
			local results = {}
			for face = 1, 3 do
				local limit = S.limit(source, face, 0, 0)
				local p = limit.position
				local a = mesh:addVertex(p)
				local b = mesh:addVertex(p + V(1, 0, 0))
				local c = mesh:addVertex(p + V(0, 1, 0))
				local fid = mesh:addFace({ a, b, c })
				for i, corner in mesh.faces[fid].corners do
					corner.normal = limit.normal
					corner.uv = Vector2.new(face, i)
				end
				results[fid] = limit.normal
			end
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				local count = 0
				for _, face in restored.faces do
					for _, corner in face.corners do
						near(corner.normal, results[corner.uv.X], 1e-6)
						assert(corner.uv.Y >= 1 and corner.uv.Y <= 3)
						count += 1
					end
				end
				assert(count == 9)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
