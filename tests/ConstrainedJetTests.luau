return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local S, V = E.Subdivision, Vector3.new
	local fixture = game:GetService("HttpService"):JSONDecode(require(script.Parent.ConstrainedJetFixtures))
	local function scalar(q)
		return assert(tonumber(q[1])) / assert(tonumber(q[2]))
	end
	local function near(a, b, e)
		assert((a - b).Magnitude < (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function tickFactory()
		local work = 0
		return function(n)
			work += n or 1
			assert(work <= 100000000, "Test work cap")
		end
	end
	local function rational(R, s)
		local sign = s:sub(1, 1) == "-" and -1 or 1
		local x = R.number(0)
		for digit in s:gmatch("%d") do
			x = R.add(R.mul(x, R.number(10)), R.number(tonumber(digit)))
		end
		return sign < 0 and R.neg(x) or x
	end
	local function exact(R, q)
		return R.div(rational(R, q[1]), rational(R, q[2]))
	end
	local function decoded(R, q)
		return R.fraction(q.sign, q.numerator, q.denominator)
	end
	local cycle = { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) }
	local function fan(n, kind, transform, flat)
		transform = transform or function(p)
			return p
		end
		local mesh = E.Mesh.new()
		mesh:addVertex(transform(Vector3.zero))
		local edges = {}
		for j = 0, n do
			local a = cycle[j % 4 + 1]
			edges[j + 1] = mesh:addVertex(transform(a + V(0, 0, flat and 0 or a.Y)))
		end
		for j = 0, n - 1 do
			local a, b = cycle[j % 4 + 1], cycle[(j + 1) % 4 + 1]
			local d = mesh:addVertex(transform(a + b + V(0, 0, flat and 0 or -2 * (a.Y + b.Y))))
			mesh:addFace({ 1, edges[j + 1], d, edges[j + 2] })
		end
		return kind == "corner" and S.crease(mesh, nil, { [1] = 10 }) or mesh
	end
	test("96 known real and complex root polynomials verify strict Schur decisions", function()
		local tick = tickFactory()
		local R = require(script.Parent.ExactRational)(tick, 8192)
		local schur = require(script.Parent.ExactSchurStability)
		for _, case in fixture.schur do
			local p = {}
			for i, q in case.polynomial do
				p[i] = exact(R, q)
			end
			local stable = schur(R, p, tick)
			assert(stable == case.stable)
		end
	end)
	test("25 independent vector recurrences and exact stationary jets match", function()
		local tick = tickFactory()
		local R = require(script.Parent.ExactRational)(tick, 8192)
		local certify = require(script.Parent.ConstrainedJetCertificate)
		for _, case in fixture.jets do
			local points = {}
			for i, p in case.raw do
				points[i] = { p[1], p[2], p[3], 0 }
			end
			local edges, diagonals = {}, {}
			for j = 1, case.sectors + 1 do
				edges[j] = points[j + 1]
			end
			for j = 1, case.sectors do
				diagonals[j] = points[case.sectors + 2 + j]
			end
			local jets, r = certify(points[1], edges, diagonals, case.kind, {}, tick)
			assert(#r.polynomial == #case.polynomial)
			for i, p in r.polynomial do
				assert(R.equal(decoded(R, p), exact(R, case.polynomial[i])))
			end
			assert(r.finiteCertified == (case.limit ~= nil))
			if case.limit then
				assert(jets and #r.scaledLimit == #case.limit)
				for i, p in r.scaledLimit do
					assert(R.equal(decoded(R, p), exact(R, case.limit[i])))
				end
			else
				assert(not jets and r.reason == case.reason)
			end
			assert(#game:GetService("HttpService"):JSONEncode(r) > 0)
		end
	end)
	test("4500 full-halo operator entries match production masks at four and six sectors", function()
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
		for _, fixture in fixture.operators do
			local kind, n, matrix = fixture.kind, fixture.sectors, fixture.matrix
			for column in fixture.vertices do
				local m = E.Mesh.new()
				local ids, faces = {}, {}
				local rays = {}
				for j = 0, n do
					rays[j + 1] = cycle[j % 4 + 1]
				end
				for i, v in fixture.vertices do
					local p = Vector3.zero
					if v[1] == "r" then
						p = rays[v[2] + 1] * v[3]
					elseif v[1] == "f" then
						p = rays[v[2] + 1] * v[3] + rays[v[2] + 2] * v[4]
					end
					ids[key(v)] = m:addVertex(p + V(0, 0, i == column and 1 or 0))
				end
				for k = 0, n - 1 do
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
						if k == n then
							k = n - 1
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

	test("Four through fourteen fixed sectors return nondegenerate finite jets", function()
		for _, n in { 4, 6, 8, 10, 14 } do
			local m = fan(n, "corner")
			local q = S.prepareLimit(m, { exactConstrainedJets = true })
			for f = 1, n do
				local r = q:evaluate(f, 0, 0)
				assert(
					r.derivativesAvailable
						and r.normalAvailable
						and r.normalMethod == "exactConstrainedJets"
						and r.constrainedJetCertificate.finiteCertified
				)
				near(r.derivativeU, cycle[(f - 1) % 4 + 1])
				near(r.derivativeV, cycle[f % 4 + 1])
				near(r.normal, V(0, 0, 1))
			end
		end
	end)
	test("Six, ten and fourteen ordinary crease sectors admit exact finite jets", function()
		for _, n in { 6, 10, 14 } do
			local m = fan(n, "crease")
			local q = S.prepareLimit(m, { exactConstrainedJets = true })
			for f = 1, n do
				local r = q:evaluate(f, 0, 0)
				assert(r.derivativesAvailable and r.normalAvailable)
				near(r.derivativeU, cycle[(f - 1) % 4 + 1])
				near(r.derivativeV, cycle[f % 4 + 1])
			end
		end
	end)
	test("Odd fixed sectors retain affine jets without an opposite-ray requirement", function()
		for _, n in { 3, 5, 7 } do
			local m = fan(n, "corner", nil, true)
			local r = S.limit(m, 1, 0, 0, { exactConstrainedJets = true })
			assert(r.constrainedJetCertificate and r.derivativesAvailable)
			near(r.derivativeU, V(1, 0, 0))
			near(r.derivativeV, V(0, 1, 0))
		end
	end)
	test("Analytic interior and hard-boundary derivatives converge to certified jets", function()
		for _, kind in { "corner", "crease" } do
			local n = kind == "corner" and 4 or 6
			local m = fan(n, kind)
			local q = S.prepareLimit(
				m,
				{ exactConstrainedJets = true, maxDepth = 32, maxWork = 100000000, tolerance = 1e-12 }
			)
			for _, f in { 1, n } do
				local target = q:evaluate(f, 0, 0)
				for _, uv in { { 0.75, 0.25 }, { 0.75, 0.75 }, { 0.25, 0.75 }, { 0.75, 0 }, { 0, 0.75 } } do
					local early = q:evaluate(f, uv[1] * 2 ^ -6, uv[2] * 2 ^ -6)
					local later = q:evaluate(f, uv[1] * 2 ^ -14, uv[2] * 2 ^ -14)
					assert(early.derivativesAvailable and later.derivativesAvailable)
					local a = (early.derivativeU - target.derivativeU).Magnitude
						+ (early.derivativeV - target.derivativeV).Magnitude
					local b = (later.derivativeU - target.derivativeU).Magnitude
						+ (later.derivativeV - target.derivativeV).Magnitude
					assert(
						(a < 1e-12 and b < 1e-12 or b < a) and b < 0.001,
						tostring(a) .. " -> " .. tostring(b)
					)
					near(later.normal, target.normal, 0.001)
				end
			end
		end
	end)
	test("All parameter-corner rotations map the certified derivatives", function()
		local uv = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
		local du = { V(1, 0, 0), V(0, -1, 0), V(-1, 0, 0), V(0, 1, 0) }
		local dv = { V(0, 1, 0), V(1, 0, 0), V(0, -1, 0), V(-1, 0, 0) }
		for index = 1, 4 do
			local m = fan(4, "corner")
			local face = m.faces[1]
			local original = table.clone(face.vertices)
			local corners = table.clone(face.corners)
			for j = 1, 4 do
				local from = (j - index) % 4 + 1
				face.vertices[j] = original[from]
				face.corners[j] = corners[from]
			end
			local r = S.limit(m, 1, uv[index][1], uv[index][2], { exactConstrainedJets = true })
			near(r.derivativeU, du[index])
			near(r.derivativeV, dv[index])
			near(r.normal, V(0, 0, 1))
		end
	end)
	test("Reversing all faces reverses the certified normal", function()
		local m = fan(6, "crease")
		for _, face in m.faces do
			face.vertices = { face.vertices[1], face.vertices[4], face.vertices[3], face.vertices[2] }
			face.corners = { face.corners[1], face.corners[4], face.corners[3], face.corners[2] }
		end
		local r = S.limit(m, 1, 0, 0, { exactConstrainedJets = true })
		near(r.derivativeU, V(0, 1, 0))
		near(r.derivativeV, V(1, 0, 0))
		near(r.normal, V(0, 0, -1))
	end)
	test("Dyadic affine transforms preserve exact cancellation and geometric jets", function()
		for _, scale in { 0.0009765625, 1, 1024 } do
			local function linear(p)
				return V(2 * p.X + p.Y / 2, p.Z - p.X / 4, p.Y + p.Z / 2) * scale
			end
			local shift = V(16, -32, 8) * scale
			local m = fan(6, "crease", function(p)
				return linear(p) + shift
			end)
			local r = S.limit(m, 1, 0, 0, { exactConstrainedJets = true, tolerance = 0.1 })
			local a, b = linear(V(1, 0, 0)), linear(V(0, 1, 0))
			assert(r.derivativesAvailable)
			near(r.derivativeU, a, scale * 1e-5)
			near(r.derivativeV, b, scale * 1e-5)
			near(r.normal, a:Cross(b).Unit)
		end
	end)
	test("A stored-bit perturbation activates a noncontracting mode", function()
		local m = fan(6, "crease")
		local id = m.faces[1].vertices[3]
		m.vertices[id] += V(0, 0, 2 ^ -20)
		local r = S.limit(m, 1, 0, 0, { exactConstrainedJets = true, maxWork = 100000000 })
		assert(
			not r.derivativesAvailable
				and not r.constrainedJetCertificate.finiteCertified
				and r.constrainedJetCertificate.reason == "noncontractingModes"
		)
	end)
	test("Opt-in failure preserves an existing three-sector characteristic normal", function()
		local m = E.Mesh.new()
		for _, p in
			{
				V(0, 0, 0),
				V(-2, 0, 0),
				V(-1, 1, 2),
				V(1, 1, -0.5),
				V(2, 0, 0),
				V(-3, 2, 1),
				V(0, 3, 1.5),
				V(3, 2, -1),
			}
		do
			m:addVertex(p)
		end
		for i = 1, 3 do
			m:addFace({ 1, i + 1, i + 5, i + 2 })
		end
		local a = S.limit(m, 1, 0, 0)
		local b = S.limit(m, 1, 0, 0, { exactConstrainedJets = true })
		assert(
			a.normalAvailable
				and b.normalAvailable
				and not b.derivativesAvailable
				and b.constrainedJetCertificate.reason == "noncontractingModes"
		)
		near(a.normal, b.normal)
	end)
	test("Unit Jordan growth is reported without discarding a proved corner normal", function()
		local m = E.Mesh.new()
		for _, p in { V(0, 0, 0), V(2, 0, 0), V(1, 1, 1), V(0, 2, 0), V(2, 2, 1), V(-1, 2, 1) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 5, 3 })
		m:addFace({ 1, 3, 6, 4 })
		m = S.crease(m, nil, { [1] = 10 })
		local r = S.limit(m, 1, 0, 0, { exactConstrainedJets = true })
		assert(
			r.normalAvailable
				and not r.derivativesAvailable
				and r.constrainedJetCertificate.reason == "unitJordanMode"
		)
	end)
	test("Zero and rank-one exact jets do not invent a tangent plane", function()
		for _, rank in { 0, 1 } do
			local m = fan(4, "corner", function(p)
				return V(p.X * rank, 0, 0)
			end, true)
			local r = S.limit(m, 1, 0, 0, { exactConstrainedJets = true })
			assert(
				r.derivativesAvailable
					and not r.normalAvailable
					and r.constrainedJetCertificate.finiteCertified
			)
			near(r.derivativeU, V(rank, 0, 0))
			near(r.derivativeV, Vector3.zero)
		end
	end)
	test("Uncertain intermediate controls cannot satisfy an exact source certificate", function()
		local p = { 0, 0, 0, 1e-30 }
		local edges, diagonals = {}, {}
		for i = 1, 5 do
			edges[i] = { 1, 0, 0, 0 }
		end
		for i = 1, 4 do
			diagonals[i] = { 0, 1, 0, 0 }
		end
		local jets, r =
			require(script.Parent.ConstrainedJetCertificate)(p, edges, diagonals, "corner", {}, tickFactory())
		assert(not jets and r.reason == "uncertainControls" and not r.finiteCertified)
	end)
	test("Prepared queries snapshot controls and options before proof checkpoints", function()
		local m = fan(6, "crease")
		local options = { exactConstrainedJets = true }
		local seen = 0
		options.checkpoint = function(state)
			if state.stage == "constrainedJet" then
				seen += 1
				m.vertices[1] = V(100, 100, 100)
				options.exactConstrainedJets = false
				options.maxExactBits = 1
			end
		end
		local q = S.prepareLimit(m, options)
		local r = q:evaluate(1, 0, 0)
		assert(seen > 0 and r.derivativesAvailable)
		near(r.derivativeU, V(1, 0, 0))
		near(q:evaluate(1, 0, 0).derivativeV, V(0, 1, 0))
	end)
	test("Proof budgets and invalid options fail transactionally", function()
		local m = fan(6, "crease")
		local before = E.IO.encode(m)
		for _, setting in
			{
				{ maxWork = 1 },
				{ maxKrylovDegree = 2 },
				{ maxExactCoefficients = 100 },
				{ maxExactBits = 3 },
				{ maxExactBits = 0 },
				{ maxKrylovDegree = 0.5 },
				{ maxExactCoefficients = math.huge },
				{ exactConstrainedJets = "yes" },
			}
		do
			local options = { exactConstrainedJets = true }
			for k, v in setting do
				options[k] = v
			end
			assert(not pcall(S.limit, m, 1, 0, 0, options))
			assert(E.IO.encode(m) == before)
		end
	end)
	test("Cancellation and checkpoint errors retain identity through exact work", function()
		local m = fan(6, "crease")
		local before = E.IO.encode(m)
		local token = {}
		local ok, err = pcall(S.limit, m, 1, 0, 0, {
			exactConstrainedJets = true,
			checkpoint = function(s)
				if s.stage == "constrainedJet" then
					error(token)
				end
			end,
		})
		assert(not ok and err == token)
		local cancel = false
		ok, err = pcall(S.limit, m, 1, 0, 0, {
			exactConstrainedJets = true,
			checkpoint = function(s)
				if s.stage == "constrainedJet" then
					cancel = true
				end
			end,
			cancelled = function()
				if cancel then
					error(token)
				end
				return false
			end,
		})
		assert(not ok and err == token and E.IO.encode(m) == before)
	end)
	test("Optional proof leaves default query behavior and source attributes intact", function()
		local m = fan(6, "crease")
		local before = E.IO.encode(m)
		local plain = S.limit(m, 1, 0, 0)
		local proved = S.limit(m, 1, 0, 0, { exactConstrainedJets = true })
		assert(
			not plain.derivativesAvailable
				and not plain.constrainedJetCertificate
				and proved.derivativesAvailable
				and E.IO.encode(m) == before
		)
	end)
	if not settings or not settings.skipNative then
		test("Certified higher-sector normals and UVs survive native EditableMesh conversion", function()
			local source = fan(6, "crease")
			local mesh = E.Mesh.new()
			local expected = {}
			for f = 1, 6 do
				local r = S.limit(source, f, 0, 0, { exactConstrainedJets = true })
				local a = mesh:addVertex(V(f * 3, 0, 0))
				local b = mesh:addVertex(V(f * 3 + 1, 0, 0))
				local c = mesh:addVertex(V(f * 3, 1, 0))
				local id = mesh:addFace({ a, b, c })
				expected[f] = r.normal
				for i, corner in mesh.faces[id].corners do
					corner.normal = r.normal
					corner.uv = Vector2.new(f, i)
				end
			end
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				local count = 0
				for _, face in restored.faces do
					for _, corner in face.corners do
						near(corner.normal, expected[corner.uv.X], 1e-6)
						assert(corner.uv.Y >= 1 and corner.uv.Y <= 3)
						count += 1
					end
				end
				assert(count == 18)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
