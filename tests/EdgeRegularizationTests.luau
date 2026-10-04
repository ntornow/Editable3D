return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local reg = require(script.Parent.SourceFeatureRegularization)
	local V = Vector3.new
	local function near(a, b, tol)
		assert(math.abs(a - b) < (tol or 1e-8), tostring(a) .. " ~= " .. tostring(b))
	end
	local function source(multiple)
		local m = E.Mesh.new()
		local points = multiple
				and {
					V(-2, 0, 0),
					V(2, 0, 0),
					V(-2, -0.5, 0),
					V(0, -2, 1 / 64),
					V(0, 2, 1 / 64),
					V(0.5, -2, 1 / 64),
				}
			or { V(-2, 0, 0), V(2, 0, 0), V(-2, -0.5, -1), V(0, -2, 1 / 64), V(0, 2, 1 / 64), V(0.5, -2, 1) }
		for _, p in points do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 4, 5, 6 })
		return m
	end
	local function config(radius)
		return {
			regularization = { method = "features", distance = radius or 1 / 64, edgePairs = true },
			tolerance = 1e-7,
			maxWork = 50000000,
		}
	end
	local function direct(m, options)
		local work = 0
		return reg(m, options or config(), function(_, n)
			work += n or 1
			assert(work <= 50000000, "Test work budget")
		end)
	end
	test(
		"160 exact closest edge pairs and their reversals match independent orthogonality witnesses",
		function()
			local work = 0
			local function tick(n)
				work += n or 1
				assert(work <= 5000000)
			end
			local R = require(script.Parent.ExactRational)(tick, 8192)
			local G = require(script.Parent.ExactFeatureClosest)(R, tick)
			local fixtures = game:GetService("HttpService")
				:JSONDecode(require(script.Parent.EdgeClosestFixtures))
			local function scalar(p)
				return R.div(R.number(p[1]), R.number(p[2]))
			end
			local function vector(p)
				local v = {}
				for i, x in p do
					v[i] = scalar(x)
				end
				return v
			end
			local function pair(e)
				return { vector(e[1]), vector(e[2]) }
			end
			for _, case in fixtures do
				local result = assert(G.edgePair(pair(case.a), pair(case.b)))
				assert(
					R.equal(result.a, scalar(case.s))
						and R.equal(result.b, scalar(case.t))
						and R.equal(result.squared, scalar(case.squared))
				)
				for i = 1, 3 do
					assert(
						R.equal(result.first[i], scalar(case.first[i]))
							and R.equal(result.second[i], scalar(case.second[i]))
					)
				end
				local swapped = G.edgePair(pair(case.b), pair(case.a))
				assert(R.equal(swapped.a, result.b) and R.equal(swapped.b, result.a))
			end
			assert(#fixtures == 160)
		end
	)
	test("Parallel overlap chooses its exact midpoint and endpoint-only regions remain excluded", function()
		local R = require(script.Parent.ExactRational)(function() end, 8192)
		local G = require(script.Parent.ExactFeatureClosest)(R, function() end)
		local function v(x, y, z)
			return { R.number(x), R.number(y), R.number(z) }
		end
		local a = { v(0, 0, 0), v(1, 0, 0) }
		local p = assert(G.edgePair(a, { v(0, 1, 0), v(1, 1, 0) }))
		assert(
			p.parallel
				and R.equal(p.a, R.number(0.5))
				and R.equal(p.b, R.number(0.5))
				and R.equal(p.squared, R.number(1))
		)
		assert(not G.edgePair(a, { v(2, 1, 0), v(3, 1, 0) }))
		assert(not G.edgePair(a, { v(2, -1, 1), v(2, 1, 1) }))
		assert(not G.edgePair(a, { v(1, -1, 1), v(1, 1, 1) }))
	end)
	test("Edge-interior snapping is explicit and rejects a nonboolean option", function()
		local m = source()
		local options = config()
		options.regularization.edgePairs = nil
		local _, r = direct(m, options)
		assert(#r.snaps == 0 and #r.edgeSnaps == 0 and r.addedVertices == 0)
		local invalid = config()
		invalid.regularization.method = "vertexClusters"
		assert(not pcall(E.MeshRepair.splitIntersections, E.Mesh.new(), invalid))
		for _, v in { 0, 1, "true", {} } do
			options.regularization.edgePairs = v
			assert(not pcall(direct, E.Mesh.new(), options))
		end
	end)
	local refined
	test("One exact-radius crossing refines both sheets without moving original endpoints", function()
		local m = source()
		local before = E.IO.encode(m)
		local out, r = direct(m)
		assert(
			r.displacementCertified
				and r.sourceSurfaceBoundCertified
				and r.triangleHomotopyOrientationCertified
		)
		assert(
			#r.snaps == 0
				and #r.edgeSnaps == 1
				and r.addedVertices == 2
				and r.triangles == 4
				and r.maxDisplacement == 1 / 64
		)
		local s = r.edgeSnaps[1]
		assert(
			s.sourceVertex ~= s.targetVertex
				and out.vertices[s.sourceVertex] == V(0, 0, 0)
				and out.vertices[s.targetVertex] == V(0, 0, 0)
		)
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
		assert(E.IO.encode(m) == before and out:validate().valid)
		refined = out
	end)
	test("Parallel nested edges with interleaved IDs receive a common interior anchor", function()
		local m = E.Mesh.new()
		for _, p in { V(-4, 0, 0), V(-1, 0, 1 / 64), V(1, 0, 1 / 64), V(4, 0, 0), V(-4, -2, -2), V(-1, 2, 2) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 4, 5 })
		m:addFace({ 2, 3, 6 })
		local out, r = direct(m)
		assert(#r.snaps == 0 and #r.edgeSnaps == 1 and r.addedVertices == 2 and out:validate().valid)
		local s = r.edgeSnaps[1]
		assert(out.vertices[s.sourceVertex] == V(0, 0, 0) and out.vertices[s.targetVertex] == V(0, 0, 0))
	end)
	test("An interior pair outside the exact radius remains unchanged", function()
		local _, r = direct(source(), config(1 / 64 - 2 ^ -30))
		assert(#r.edgeSnaps == 0 and r.addedVertices == 0)
	end)
	test("Four interior pairs use distinct sheet anchors and conforming original edge chains", function()
		local m = source(true)
		local out, r = direct(m, config(1 / 32))
		assert(
			#r.snaps == 0
				and #r.edgeSnaps == 4
				and r.addedVertices == 8
				and r.triangles == 10
				and out:validate().valid
		)
		for _, s in r.edgeSnaps do
			assert(out.vertices[s.sourceVertex] == out.vertices[s.targetVertex])
		end
		for id, refs in r.maps.vertex do
			local reference = Vector3.zero
			local total = 0
			for _, ref in refs do
				reference += m.vertices[ref[1]] * ref[2]
				total += ref[2]
			end
			assert((out.vertices[id] - reference / total).Magnitude <= r.sourceSurfaceHausdorffBound + 1e-6)
		end
	end)
	test("Native edge-pair construction outside the original radius rejects transactionally", function()
		local m = source(true)
		local before = E.IO.encode(m)
		local ok, err = pcall(direct, m, config())
		assert(not ok and tostring(err):find("radius", 1, true) and E.IO.encode(m) == before, tostring(err))
	end)
	test("Edge-pair splitIntersections retains separate source sheets and original face maps", function()
		local m = source()
		local out, r = E.MeshRepair.splitIntersections(m, config())
		assert(
			r.complete
				and r.validation.valid
				and r.validation.surfaceComponents == 2
				and r.arrangement.regularization.addedVertices == 2
		)
		for original, ids in r.faceMap do
			assert(m.faces[original])
			for _, id in ids do
				assert(out.faces[id])
			end
		end
		local json = game:GetService("HttpService"):JSONEncode(r)
		assert(#json > 0)
	end)
	test("Original vertex edge face corner UV skin and group values survive paired refinement", function()
		local m = source()
		local values = { vertex = {}, edge = {}, face = {}, corner = {} }
		local uv = {}
		m.groups.test = {}
		for id, p in m.vertices do
			values.vertex[id] = p.X + 3 * p.Z
			m.weights[id] = { Left = id / 8, Right = 1 - id / 8 }
			m.groups.test[id] = id / 10
		end
		for fid, f in m.faces do
			values.face[fid] = "sheet" .. fid
			f.material = values.face[fid]
			for i, id in f.vertices do
				local key = fid .. ":" .. i
				values.corner[key] = m.vertices[id].X + 2 * m.vertices[id].Y
				f.corners[i].uv = Vector2.new(values.corner[key], fid * 16)
				uv[key] = f.corners[i].uv
			end
		end
		for key in E.Connectivity.index(m).edges do
			values.edge[key] = 7
		end
		for _, domain in { "vertex", "edge", "face", "corner" } do
			local kind = domain == "face" and "string" or "number"
			m = E.Attributes.set(
				E.Attributes.create(m, domain, domain, kind, kind == "string" and "" or 0),
				domain,
				values[domain]
			)
		end
		local before = E.IO.encode(m)
		local out, r = E.MeshRepair.splitIntersections(m, config())
		assert(r.complete)
		for id in out.vertices do
			local sum, total, skin, group = 0, 0, 0, 0
			for _, ref in r.maps.vertex[id] do
				sum += values.vertex[ref[1]] * ref[2]
				total += ref[2]
				skin += m.weights[ref[1]].Left * ref[2]
				group += m.groups.test[ref[1]] * ref[2]
			end
			near(E.Attributes.get(out, "vertex", id), sum / total)
			near(out.weights[id].Left, skin / total)
			near(out.groups.test[id], group / total)
		end
		for fid, f in out.faces do
			assert(E.Attributes.get(out, "face", fid) == f.material)
			for i, c in f.corners do
				local key = fid .. ":" .. i
				local total, sum, uvsum = 0, 0, Vector2.zero
				for _, ref in r.maps.corner[key] do
					total += ref[2]
					sum += values.corner[ref[1]] * ref[2]
					uvsum += uv[ref[1]] * ref[2]
				end
				near(E.Attributes.get(out, "corner", key), sum / total)
				assert((c.uv - uvsum / total).Magnitude < 1e-6)
			end
		end
		for key in r.maps.edge do
			assert(E.Attributes.get(out, "edge", key) == 7)
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Exact oblique rotations scales and translations preserve paired contacts", function()
		for _, scale in { 0.5, 4 } do
			local m = source()
			for id, p in m.vertices do
				m.vertices[id] = V(p.X + p.Z + 8, p.Y - 4, p.Z - p.X + 2) * scale
			end
			local out, r = direct(m, config(scale / 32))
			assert(
				#r.edgeSnaps == 1
					and r.addedVertices == 2
					and out:validate().valid
					and r.maxDisplacement <= scale / 32
			)
		end
	end)
	test("An existing paired anchor causes no additional movement on a second pass", function()
		assert(refined)
		local _, r = direct(refined)
		assert(r.addedVertices == 0 and #r.edgeSnaps == 0 and r.maxDisplacement == 0)
	end)
	test("Paired refinement enforces vertex face and exact reference budgets", function()
		local m = source()
		local before = E.IO.encode(m)
		for _, entry in { { "maxVertices", 7 }, { "maxFaces", 3 }, { "maxExactCoefficients", 50 } } do
			local options = config()
			options[entry[1]] = entry[2]
			local ok, err = pcall(E.MeshRepair.splitIntersections, m, options)
			assert(not ok and tostring(err):find("budget", 1, true), tostring(err))
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Edge phase checkpoints retain cancellation and callback error identity", function()
		local m = source()
		local before = E.IO.encode(m)
		local token = {}
		local options = config()
		options.checkpoint = function(s)
			if s.stage == "regularizeEdges" then
				error(token)
			end
		end
		local ok, err = pcall(E.MeshRepair.splitIntersections, m, options)
		assert(not ok and err == token)
		local cancel = false
		options = config()
		options.checkpoint = function(s)
			if s.stage == "regularizeEdges" then
				cancel = true
			end
		end
		options.cancelled = function()
			return cancel
		end
		ok, err = pcall(E.MeshRepair.splitIntersections, m, options)
		assert(not ok and tostring(err):find("cancelled", 1, true) and E.IO.encode(m) == before)
	end)
	test("The edge-pair option and original geometry are snapshotted before callbacks", function()
		local m = source()
		local options = config()
		local fired = false
		options.checkpoint = function(s)
			if s.stage == "regularizeEdges" and not fired then
				fired = true
				options.regularization.edgePairs = false
				options.regularization.distance = 1
				m.vertices[1] = V(999, 999, 999)
			end
		end
		local _, r = E.MeshRepair.splitIntersections(m, options)
		assert(
			fired
				and r.complete
				and #r.arrangement.regularization.edgeSnaps == 1
				and r.arrangement.regularization.distance == 1 / 64
		)
	end)
	if not settings or not settings.skipNative then
		test(
			"Paired anchors remain distinct native vertices at the same position with original UVs",
			function()
				local m, r = direct(source())
				for fid, f in m.faces do
					for _, c in f.corners do
						c.uv = Vector2.new(fid, 3)
					end
				end
				local handle = E.Roblox.toEditable(m)
				local ok, err = pcall(function()
					for _, s in r.edgeSnaps do
						local a, b = handle.vertexIds[s.sourceVertex], handle.vertexIds[s.targetVertex]
						assert(a ~= b and handle.editable:GetPosition(a) == handle.editable:GetPosition(b))
					end
					local restored = E.Roblox.fromEditable(handle.editable)
					assert(restored:validate().valid)
					local count = 0
					for _, f in restored.faces do
						for _, c in f.corners do
							assert(c.uv.Y == 3)
							count += 1
						end
					end
					assert(count == 12)
				end)
				handle.editable:Destroy()
				assert(ok, err)
			end
		)
	end
	report.success = report.failed == 0
	return report
end
