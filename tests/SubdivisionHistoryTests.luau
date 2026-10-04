return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local V, S = Vector3.new, E.Subdivision
	local fixture = game:GetService("HttpService")
		:JSONDecode(require(script.Parent.SubdivisionHistoryFixtures))
	local function setup(cap)
		local work = 0
		local function visit(n)
			work += n or 1
			assert(work <= (cap or 100000000), "History test work cap")
		end
		return require(script.Parent.ExactRational)(visit, 8192), visit
	end
	local function rational(R, q)
		return R.div(R.number(tonumber(q[1])), R.number(tonumber(q[2])))
	end
	local function raw(data, uncertainty)
		local m = { vertices = {}, faces = {}, sharp = {}, edges = {} }
		for id, p in data.vertices do
			m.vertices[tonumber(id)] = {
				assert(tonumber(p[1][1])) / assert(tonumber(p[1][2])),
				assert(tonumber(p[2][1])) / assert(tonumber(p[2][2])),
				assert(tonumber(p[3][1])) / assert(tonumber(p[3][2])),
				uncertainty or 0,
			}
		end
		for id, f in data.faces do
			m.faces[tonumber(id)] = table.clone(f)
		end
		for _, name in { "sharp", "edges" } do
			for id, q in data[name] do
				m[name][name == "sharp" and tonumber(id) or id] = assert(tonumber(q[1]))
					/ assert(tonumber(q[2]))
			end
		end
		return m
	end
	local function verify(R, m, data)
		local count = 0
		for id, p in data.vertices do
			for axis, q in p do
				assert(
					R.equal(m.vertices[tonumber(id)][axis], rational(R, q)),
					"Independent coordinate mismatch"
				)
				count += 1
			end
		end
		for id, f in data.faces do
			local actual = m.faces[tonumber(id)]
			assert(#actual == #f)
			for i, v in f do
				assert(actual[i] == v)
			end
		end
		for _, name in { "sharp", "edges" } do
			for id, q in data[name] do
				assert(
					R.equal(m[name][name == "sharp" and tonumber(id) or id], rational(R, q)),
					"Independent sharpness mismatch"
				)
			end
		end
		return count
	end
	local function config(case)
		return { boundary = case.boundary, creasing = case.creasing, maxVertices = 250000, maxFaces = 250000 }
	end
	test(
		"Exact polygon refinement matches 3132 independent Fraction coordinates and propagated sharpness",
		function()
			local R, visit = setup()
			local Q = require(script.Parent.ExactSubdivisionRefinement)(R, visit)
			local count = 0
			for _, case in fixture do
				local m = assert(Q.snapshot(raw(case.source)))
				for _, name in { "first", "second" } do
					m = Q.refine(m, config(case), visit)
					count += verify(R, m, case[name])
				end
			end
			assert(count == 3132)
		end
	)
	test(
		"Exact replay preserves deterministic IDs through repeated refinement and cropped neighborhoods",
		function()
			local R, visit = setup()
			local replay = require(script.Parent.ExactSubdivisionHistory)
			for _, case in fixture do
				local history = { previous = { initial = raw(case.source) } }
				local expected = case.second
				if case.cropFaces then
					local faces = {}
					for _, fid in case.cropFaces do
						faces[fid] = true
					end
					history = { previous = history, faces = faces }
					expected = case.croppedSecond
				end
				history = { previous = history }
				local source = raw(expected, 1e-4)
				source.normalHistory = history
				local actual, reason, steps = replay(R, source, config(case), visit)
				assert(actual and not reason and steps == (case.cropFaces and 3 or 2))
				verify(R, actual, expected)
			end
		end
	)
	test("Rounded controls without original history remain unresolved", function()
		local R, visit = setup()
		local source = raw(fixture[1].source, 1e-20)
		local exact, reason =
			require(script.Parent.ExactSubdivisionHistory)(R, source, config(fixture[1]), visit)
		assert(not exact and reason == "uncertainControls")
	end)
	test("Refinement replay rejects inconsistent topology and enforces coefficient preflight", function()
		local R, visit = setup()
		local replay = require(script.Parent.ExactSubdivisionHistory)
		local case = fixture[1]
		local source = raw(case.first, 1e-4)
		source.normalHistory = { previous = { initial = raw(case.source) } }
		source.faces[1][1] = 9999
		assert(not pcall(replay, R, source, config(case), visit))
		local cfg = config(case)
		local marker = {}
		cfg.normalAllocate = function()
			error(marker)
		end
		local ok, err = pcall(replay, R, raw(case.source), cfg, visit)
		assert(not ok and err == marker)
	end)
	local function fan(polygon, transform)
		transform = transform or function(p)
			return p
		end
		local cycle = { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) }
		local m = E.Mesh.new()
		m:addVertex(transform(Vector3.zero))
		for j = 0, 4 do
			m:addVertex(transform(cycle[j % 4 + 1]))
		end
		for j = 0, 3 do
			local a, b = cycle[j % 4 + 1], cycle[(j + 1) % 4 + 1]
			local d = m:addVertex(transform(a + b))
			if polygon then
				local q = m:addVertex(transform(a * 0.5 + b))
				m:addFace({ 1, j + 2, d, q, j + 3 })
			else
				m:addFace({ 1, j + 2, d, j + 3 })
			end
		end
		return S.crease(m, nil, { [1] = 10 })
	end
	local function options(extra)
		local out = {
			exactConstrainedNormals = true,
			maxWork = 500000000,
			checkpoint = function(s)
				if task and s.stage == "exactNormalWork" then
					task.wait()
				end
			end,
		}
		for k, v in extra or {} do
			out[k] = v
		end
		return out
	end
	test("Rounded stationary masks cannot override exact finite sharpness", function()
		local mesh = fan(false)
		local source = { vertices = {}, faces = {}, edges = {}, sharp = { [1] = 10 } }
		for id, p in mesh.vertices do
			source.vertices[id] = { p.X, p.Y, p.Z, 0 }
		end
		for id, face in mesh.faces do
			source.faces[id] = table.clone(face.vertices)
		end
		local initial =
			{ vertices = source.vertices, faces = source.faces, edges = {}, sharp = { [1] = 0.5 } }
		source.normalHistory = { initial = initial }
		local R, visit = setup()
		local top = require(script.Parent.ExactSubdivisionRefinement)(R, visit).topology(source)
		local sector = require(script.Parent.SubdivisionFeaturePatch).sector(source, top, 1, 1, visit)
		local normal, result = require(script.Parent.ConstrainedNormalCertificate)(
			source,
			top,
			sector,
			1,
			1,
			{ boundary = "edge", creasing = "uniform", maxVertices = 250000, maxFaces = 250000 },
			{},
			visit
		)
		assert(not normal and result.reason == "nonstationaryExactMasks" and not result.normalCertified)
	end)
	local function check(r, expected, steps)
		assert(r.complete and r.normalAvailable and r.normalMethod == "exactConstrainedNormals")
		assert(
			r.constrainedNormalCertificate.normalCertified
				and r.constrainedNormalCertificate.exactHistorySteps == steps
		)
		assert((r.normal - expected).Magnitude <= r.normalErrorBound + 1e-6)
	end
	local nativeResult
	test("Explicit quad corner patches preserve a proved higher-sector normal", function()
		nativeResult = S.limit(fan(false), 1, 0, 0, options({ corner = 1 }))
		check(nativeResult, V(0, 0, 1), 1)
	end)
	test("Pentagonal control faces receive exact constrained-sector normals after quad conversion", function()
		local m = fan(true)
		local r = S.limit(m, 1, 0, 0, options({ corner = 1 }))
		check(r, V(0, 0, -1), 1)
		-- This fixture folds only after more than twenty dyadic levels. A finite
		-- sample before that transition has the opposite orientation.
		local nearby = S.limit(m, 1, 2 ^ -28, 2 ^ -29, { corner = 1, tolerance = 1e-15, maxDepth = 36 })
		assert(nearby.normalAvailable and nearby.normal:Dot(r.normal) > 0.999)
	end)
	test("Finite vertex sharpness can decay through three cropped levels before the normal proof", function()
		local m = S.crease(fan(false), nil, { [1] = 2.25 })
		local r = S.limit(m, 1, 0, 0, options())
		check(r, V(0, 0, 1), 6)
		assert(r.depth == 3)
	end)
	test("Exact histories and caller options are snapshotted before user callbacks", function()
		local m = fan(false, function(p)
			return V(p.Y, p.X, 2 * p.X - p.Y) * 2 ^ -20 + V(1, 2, 3)
		end)
		local o = options({ corner = 1 })
		local prepared = S.prepareLimit(m, o)
		m.vertices[1] = V(99, 99, 99)
		m.attributes.subdivision_vertex_sharpness.values[1] = 0
		o.maxWork = 1
		o.maxExactBits = 1
		local r = prepared:evaluate(1, 0, 0, 1)
		check(r, V(-1, 2, -1).Unit, 1)
	end)
	test("History replay retains cancellation, allocation and callback error contracts", function()
		local m = fan(true)
		local before = E.IO.encode(m)
		local marker = {}
		local ok, err = pcall(
			S.limit,
			m,
			1,
			0,
			0,
			options({
				corner = 1,
				checkpoint = function(s)
					if s.stage == "exactNormalWork" then
						error(marker)
					end
				end,
			})
		)
		assert(not ok and err == marker and E.IO.encode(m) == before)
		for _, bad in { { maxExactCoefficients = 2500 }, { maxWork = 1000 }, { maxExactBits = 8 } } do
			bad.corner = 1
			assert(not pcall(S.limit, m, 1, 0, 0, options(bad)))
		end
		local count = 0
		assert(not pcall(
			S.limit,
			m,
			1,
			0,
			0,
			options({
				corner = 1,
				cancelled = function()
					count += 1
					return count > 15
				end,
			})
		))
		assert(E.IO.encode(m) == before)
	end)
	if not settings or not settings.skipNative then
		test("A normal certified from a refined history survives native normal and UV conversion", function()
			assert(nativeResult)
			local m = E.Mesh.new()
			for _, p in { V(0, 0, 0), V(1, 0, 0), V(0, 1, 0) } do
				m:addVertex(p)
			end
			local f = m:addFace({ 1, 2, 3 })
			for i, c in m.faces[f].corners do
				c.normal = nativeResult.normal
				c.uv = Vector2.new(i, 0)
			end
			local h = E.Roblox.toEditable(m)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(h.editable)
				for _, face in restored.faces do
					for _, c in face.corners do
						assert(c.normal:Dot(nativeResult.normal) > 0.99999 and c.uv.X >= 1 and c.uv.X <= 3)
					end
				end
			end)
			h.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
