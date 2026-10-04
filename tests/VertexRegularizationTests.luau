return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local regularize = require(script.Parent.SourceVertexRegularization)
	local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.VertexClusterFixtures))
	local V = Vector3.new
	local function box(offset)
		local m = E.Primitives.box()
		for id, p in m.vertices do
			m.vertices[id] = p + (offset or Vector3.zero)
		end
		return m
	end
	local function pair(offset)
		return E.Topology.join({ box(), box(offset) })
	end
	local function config(distance)
		return {
			regularization = { distance = distance or 2 ^ -18 },
			tolerance = 1e-7,
			windingPrecision = "exact",
			maxWork = 50000000,
		}
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 1e-8), tostring(a) .. " ~= " .. tostring(b))
	end
	local function check(out, r)
		assert(r.complete, r.reason)
		assert(r.validation.valid and (r.validation.closed or r.empty))
		assert(r.intersections.complete and r.intersections.intersectionFree)
		local s = assert(r.arrangement.regularization)
		assert(
			s.displacementCertified
				and s.sourceSurfaceBoundCertified
				and s.triangleHomotopyOrientationCertified
		)
		assert(not s.globalIsotopyCertified and not s.originalSolidEqualityCertified)
		assert(s.maxDisplacement == s.sourceSurfaceHausdorffBound and s.maxDisplacement <= s.distance)
	end
	test("1728 native-coordinate cluster choices match independent exhaustive Fraction references", function()
		local count = 0
		for _, case in fixtures.cases do
			local mesh = E.Mesh.new()
			for _, p in case.points do
				mesh:addVertex(V(table.unpack(p)))
			end
			for id = 1, #case.points, 3 do
				mesh:addFace({ id, id + 1, id + 2 })
			end
			local out, r = regularize(mesh, { regularization = { distance = case.distance } }, function() end)
			for id, expected in case.representatives do
				assert(r.representatives[id] == expected and out.vertices[id] == mesh.vertices[expected])
				count += 1
			end
			local squared = assert(tonumber(case.maxSquared.n)) / assert(tonumber(case.maxSquared.d))
			assert(
				r.sourceSurfaceHausdorffBound ^ 2 >= squared
					and r.sourceSurfaceHausdorffBound <= case.distance
			)
		end
		assert(count == 1728)
	end)
	local repaired
	test("Source regularization closes a narrow gap and preserves the measured outer boundary", function()
		local source = pair(V(2 + 2 ^ -19, 0, 0))
		local before = E.IO.encode(source)
		local out, r = E.MeshRepair.resolveIntersections(source, config())
		check(out, r)
		near(out:volume(), 16 + 4 * 2 ^ -19)
		assert(r.validation.surfaceComponents == 1 and r.arrangement.regularization.movedVertices == 4)
		assert(r.arrangement.regularization.sourceSurfaceHausdorffBound >= 2 ^ -19)
		assert(E.IO.encode(source) == before)
		repaired = out
	end)
	test("A sub-tolerance overlap follows the same explicit snapped source geometry", function()
		local out, r = E.MeshRepair.resolveIntersections(pair(V(2 - 2 ^ -19, 0, 0)), config())
		check(out, r)
		near(out:volume(), 16 - 4 * 2 ^ -19)
	end)
	test("Nearby duplicate layers follow nonzero positive and odd winding rules", function()
		for _, rule in { "nonzero", "positive", "odd" } do
			local options = config()
			options.windingRule = rule
			local out, r = E.MeshRepair.resolveIntersections(pair(V(2 ^ -19, 0, 0)), options)
			check(out, r)
			near(out:volume(), rule == "odd" and 0 or 8)
			assert(r.arrangement.regularization.movedVertices == 8)
		end
	end)
	test("Oppositely oriented near-duplicate layers cancel after source regularization", function()
		local a, b = box(), box(V(2 ^ -19, 0, 0))
		for _, f in b.faces do
			local vs, cs = {}, {}
			for i = #f.vertices, 1, -1 do
				table.insert(vs, f.vertices[i])
				table.insert(cs, f.corners[i])
			end
			f.vertices, f.corners = vs, cs
		end
		local out, r = E.MeshRepair.resolveIntersections(E.Topology.join({ a, b }), config())
		check(out, r)
		assert(r.empty)
	end)
	test("All arrangement Boolean operations classify the same regularized operand positions", function()
		for _, operation in { "union", "intersect", "subtract" } do
			local options = config()
			options.method = "arrangement"
			local out, r = E.Boolean.apply(box(), box(V(2 ^ -19, 0, 0)), operation, options)
			check(out, r)
			near(out:volume(), operation == "subtract" and 0 or 8)
			assert(r.inputMaps.face and r.windingRules.a == "nonzero")
		end
	end)
	test("Regularization remains optional and a smaller radius preserves the original gap", function()
		local source = pair(V(2 + 2 ^ -19, 0, 0))
		local options = config(2 ^ -21)
		options.tolerance = 0
		local out, r = E.MeshRepair.resolveIntersections(source, options)
		check(out, r)
		near(out:volume(), 16)
		assert(r.validation.surfaceComponents == 2 and r.arrangement.regularization.movedVertices == 0)
		options.regularization = nil
		out, r = E.MeshRepair.resolveIntersections(source, options)
		assert(r.complete and r.validation.surfaceComponents == 2 and not r.arrangement.regularization)
	end)
	test("Cluster representatives do not drift through transitive chains", function()
		local m = E.Mesh.new()
		for i, x in { 0, 0.75, 1.5 } do
			local a = m:addVertex(V(x, 0, 0))
			local b = m:addVertex(V(x, 0, 20 + i))
			local c = m:addVertex(V(x, 2, 20 + i))
			m:addFace({ a, b, c })
		end
		local _, r = regularize(m, { regularization = { distance = 1 } }, function() end)
		assert(r.representatives[1] == 1 and r.representatives[4] == 1 and r.representatives[7] == 7)
	end)
	test("An oblique translated pair regularizes corresponding vertices within the declared bound", function()
		local a, b = E.Topology.triangulate(box()), E.Topology.triangulate(box(V(2 ^ -16, 0, 0)))
		local frame = CFrame.new(4, -8, 2) * CFrame.Angles(0.2, 0.4, 0.3)
		for _, m in { a, b } do
			for id, p in m.vertices do
				m.vertices[id] = frame:PointToWorldSpace(p)
			end
		end
		local options = config(2 ^ -14)
		options.tolerance = 1e-5
		local out, r = E.MeshRepair.resolveIntersections(E.Topology.join({ a, b }), options)
		check(out, r)
		near(out:volume(), a:volume(), 2e-5)
		assert(r.arrangement.regularization.movedVertices == 8)
	end)
	test("Source regularization preserves separate sheet identities during splitting", function()
		local source = pair(V(2 ^ -19, 0, 0))
		local out, r = E.MeshRepair.splitIntersections(source, config())
		assert(
			r.complete
				and r.validation.surfaceComponents == 2
				and r.arrangement.regularization.movedVertices == 8
		)
		near(out:volume(), 16)
	end)
	test("Regularization is idempotent on its declared source triangles", function()
		local source = pair(V(2 ^ -19, 0, 0))
		local a, ra = regularize(source, config(), function() end)
		local b, rb = regularize(a, config(), function() end)
		assert(ra.movedVertices == 8 and rb.movedVertices == 0 and rb.sourceSurfaceHausdorffBound == 0)
		assert(E.IO.encode(a) == E.IO.encode(b))
	end)
	test("Source triangle collapse is rejected transactionally", function()
		local source = box()
		local before = E.IO.encode(source)
		local ok, err = pcall(E.MeshRepair.resolveIntersections, source, config(4))
		assert(not ok and tostring(err):find("collapses or reverses", 1, true))
		assert(E.IO.encode(source) == before)
	end)
	test("Invalid regularization settings reject even on an empty mesh", function()
		for _, value in
			{
				false,
				1,
				{},
				{ distance = 0 },
				{ distance = -1 },
				{ distance = math.huge },
				{ distance = 0 / 0 },
				{ distance = 2 ^ -130 },
				{ distance = 2 ^ 131 },
				{ distance = 1, method = "unknown" },
			}
		do
			local options = config()
			options.regularization = value
			assert(not pcall(E.MeshRepair.resolveIntersections, E.Mesh.new(), options))
		end
		local out, r = E.MeshRepair.resolveIntersections(E.Mesh.new(), config())
		check(out, r)
		assert(r.empty and r.arrangement.regularization.usedVertices == 0)
	end)
	test("BSP does not silently ignore source regularization", function()
		local options = config()
		options.method = "bsp"
		options.tolerance = nil
		options.windingPrecision = nil
		assert(not pcall(E.Boolean.apply, box(), box(), "union", options))
	end)
	test("Regularization shares construction budgets and observes cancellation", function()
		local source = pair(V(2 ^ -19, 0, 0))
		local before = E.IO.encode(source)
		local options = config()
		options.maxWork = 20
		local ok, err = pcall(E.MeshRepair.resolveIntersections, source, options)
		assert(not ok and tostring(err):find("budget", 1, true))
		options = config()
		options.cancelled = function()
			return true
		end
		assert(not pcall(E.MeshRepair.resolveIntersections, source, options))
		local token = {}
		options = config()
		options.checkpoint = function(s)
			if s.stage == "regularize" then
				error(token)
			end
		end
		ok, err = pcall(E.MeshRepair.resolveIntersections, source, options)
		assert(not ok and err == token and E.IO.encode(source) == before)
	end)
	test("Progress callbacks cannot replace snap settings or mutate the in-progress source", function()
		local source = pair(V(2 ^ -19, 0, 0))
		local options = config()
		local fired = false
		options.checkpoint = function(s)
			if s.stage == "regularize" and not fired then
				fired = true
				options.regularization.distance = 4
				source.vertices[1] = V(999, 999, 999)
			end
		end
		local out, r = E.MeshRepair.resolveIntersections(source, options)
		check(out, r)
		near(out:volume(), 8)
		assert(fired and r.arrangement.regularization.distance == 2 ^ -18)
	end)
	test("All typed domains and intrinsic vertex data retain original source correspondence", function()
		local source = pair(V(2 ^ -19, 0, 0))
		local values = { vertex = {}, edge = {}, face = {}, corner = {} }
		for id, p in source.vertices do
			values.vertex[id] = p.X
			source.weights[id] = { Left = 0.25, Right = 0.75 }
			source.groups.test = source.groups.test or {}
			source.groups.test[id] = 0.5
		end
		for fid, f in source.faces do
			values.face[fid] = "face" .. fid
			f.material = values.face[fid]
			for i, id in f.vertices do
				values.corner[fid .. ":" .. i] = source.vertices[id].X
				f.corners[i].uv = Vector2.new(source.vertices[id].X, fid)
			end
		end
		for key in E.Connectivity.index(source).edges do
			values.edge[key] = 7
		end
		for _, domain in { "vertex", "edge", "face", "corner" } do
			local kind = domain == "face" and "string" or "number"
			source = E.Attributes.set(
				E.Attributes.create(source, domain, domain, kind, kind == "string" and "" or 0),
				domain,
				values[domain]
			)
		end
		local out, r = E.MeshRepair.resolveIntersections(source, config())
		check(out, r)
		for id in out.vertices do
			local expected, total = 0, 0
			for _, ref in r.maps.vertex[id] do
				expected += values.vertex[ref[1]] * ref[2]
				total += ref[2]
			end
			expected /= total
			near(E.Attributes.get(out, "vertex", id), expected)
			near(out.weights[id].Left, 0.25)
			near(out.groups.test[id], 0.5)
		end
		for fid, f in out.faces do
			assert(E.Attributes.get(out, "face", fid) == f.material)
			for i in f.vertices do
				local key = fid .. ":" .. i
				local expected, total = 0, 0
				for _, ref in r.maps.corner[key] do
					expected += values.corner[ref[1]] * ref[2]
					total += ref[2]
				end
				expected /= total
				near(E.Attributes.get(out, "corner", key), expected)
				near(f.corners[i].uv.X, expected, 1e-6)
			end
		end
		for key, refs in r.maps.edge do
			if #refs > 0 then
				assert(E.Attributes.get(out, "edge", key) == 7)
			end
		end
	end)
	if not settings or not settings.skipNative then
		test("A source-regularized boundary round-trips through native EditableMesh", function()
			assert(repaired)
			local handle = E.Roblox.toEditable(repaired)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				assert(restored:validate().closed)
				local topology = E.Connectivity.analyze(restored)
				assert(topology.valid and topology.eulerCharacteristic == 2)
				near(restored:volume(), 16 + 4 * 2 ^ -19, 1e-5)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
