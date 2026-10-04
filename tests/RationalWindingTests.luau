return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local makeR = require(script.Parent.ExactRational)
	local prepare = require(script.Parent.RationalWinding)
	local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.RationalWindingFixtures))
	local V = Vector3.new
	local R = makeR(function() end, 8192)
	local function same(a, b)
		if type(a) ~= "table" then
			return a == b
		end
		if type(b) ~= "table" then
			return false
		end
		for key, value in a do
			if not same(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	end
	local function rational(x)
		return R.fraction(x.sign, x.n, x.d)
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function box(offset, size)
		local mesh = E.Primitives.box(size or V(2, 2, 2))
		for id, p in mesh.vertices do
			mesh.vertices[id] = p + (offset or Vector3.zero)
		end
		return mesh
	end
	local function gap()
		return E.Topology.join({ box(), box(V(2 + 2 ^ -22, 0, 0)) })
	end
	local function oblique()
		local source = E.Topology.join({ box(), box(V(0.5, 0.25, 0)) })
		local frame = CFrame.new(16, -8, 32) * CFrame.Angles(0.2, 0.4, 0.3)
		for id, p in source.vertices do
			source.vertices[id] = frame:PointToWorldSpace(p)
		end
		return source
	end
	local function context(scene, attempts)
		local triangles = {}
		for i, tri in scene.triangles do
			triangles[i] = {}
			for j, p in tri do
				triangles[i][j] = V(table.unpack(p))
			end
		end
		return prepare(triangles, R, function() end, scene.groups, nil, attempts)
	end
	local repaired, repairReport
	test("Exact winding matches 54 independent Cramer ray references across eight scenes", function()
		local count = 0
		for _, scene in fixtures.scenes do
			local C = context(scene)
			for _, row in scene.rows do
				local point = {}
				for i, x in row.point do
					point[i] = rational(x)
				end
				assert(same(C.winding(point), row.winding))
				count += 1
			end
		end
		assert(count == 54)
	end)
	test("64 homogeneous integer vectors match independent common-denominator references", function()
		for _, row in fixtures.homogeneous do
			local values = {}
			for i, x in row.values do
				values[i] = rational(x)
			end
			local before = U.copy(values)
			local integers, denominator = R.homogeneous(values)
			assert(same(integers, row.integers) and same(denominator, row.denominator))
			for i, x in values do
				assert(R.equal(R.div(integers[i], denominator), x))
			end
			assert(same(before, values))
		end
	end)
	test("Homogeneous integer construction obeys caps and preserves zero signs", function()
		local small = makeR(function() end, 8)
		local a, b =
			small.div(small.number(1), small.number(127)), small.div(small.number(1), small.number(131))
		assert(not pcall(small.homogeneous, { a, b }))
		local integers, denominator =
			R.homogeneous({ R.number(0), R.number(-2), R.div(R.number(3), R.number(7)) })
		assert(integers[1].sign == 0 and integers[2].sign == -1 and R.equal(denominator, R.number(7)))
	end)
	test("Exact offsets classify both sides when the positive native sample collapses", function()
		local C = context(fixtures.scenes[2])
		local enclose = require(script.Parent.ExactRationalBounds)(R, function() end)
		local found = 0
		for i, c in C.contexts do
			if
				R.equal(c.points[1][1], R.number(1))
				and R.equal(c.points[2][1], R.number(1))
				and R.equal(c.points[3][1], R.number(1))
			then
				local minus, plus = C.samples(i, { R.number(1), R.number(1), R.number(1) }, 1e-4)
				local interval = enclose(plus[1])
				assert(V(interval[1] * 0.5 + interval[2] * 0.5, 0, 0).X == 1)
				assert(R.compare(plus[1], R.number(1)) > 0)
				assert(same(C.winding(minus), { 1, 0 }) and same(C.winding(plus), { 0, 0 }))
				found += 1
			end
		end
		assert(found == 2)
	end)
	test("Exact rays retry a vertex hit and honor the ray-direction limit", function()
		local p = { R.number(1 - 26 / 64), R.number(1 - 14 / 64), R.number(1 - 6 / 64) }
		local C = context(fixtures.scenes[1])
		assert(C.winding(p)[1] == 1 and C.report.ambiguous >= 1)
		local limited = context(fixtures.scenes[1], 2)
		assert(not pcall(limited.winding, p))
	end)
	test("Samples on a source face cannot receive a fabricated winding label", function()
		local C = context(fixtures.scenes[1])
		assert(not pcall(C.winding, { R.number(1), R.number(0), R.number(0) }))
	end)
	test("Clearance includes a sampling line contained in another triangle's plane", function()
		local triangles = { { V(0, 0, 0), V(1, 0, 0), V(0, 1, 0) }, { V(0, 0, 1), V(1, 1, 1), V(0, 0, 2) } }
		local C = prepare(triangles, R, function() end)
		local minus, plus, delta = C.samples(1, { R.number(1), R.number(1), R.number(1) }, 10)
		assert(
			R.equal(delta, R.number(0.25))
				and R.equal(plus[3], R.number(0.25))
				and R.equal(minus[3], R.number(-0.25))
		)
		triangles[2] = { V(0, 0, -1), V(1, 1, -1), V(0, 0, 1) }
		C = prepare(triangles, R, function() end)
		assert(not pcall(C.samples, 1, { R.number(1), R.number(1), R.number(1) }, 10))
	end)
	test("Native precision failure automatically repairs a resolvable narrow gap", function()
		local source = gap()
		local before = E.IO.encode(source)
		local out, r = E.MeshRepair.resolveIntersections(source, { tolerance = 0 })
		assert(r.complete and r.validation.surfaceComponents == 2 and r.intersections.intersectionFree)
		assert(r.classification.nativeFailure == "nativeOffset" and r.classification.exactSamples)
		assert(r.classification.exactWork > 0 and r.classification.exactWork <= r.work)
		assert(r.classification.offsetRangeCertified and r.classification.minOffset > 0)
		near(out:volume(), 16)
		assert(E.IO.encode(source) == before)
	end)
	test("Explicit native mode rejects the same unrepresentable side samples", function()
		assert(
			not pcall(
				E.MeshRepair.resolveIntersections,
				gap(),
				{ tolerance = 0, windingPrecision = "native" }
			)
		)
	end)
	test("Ordinary repairs retain the native fast path", function()
		local out, r = E.MeshRepair.resolveIntersections(box())
		assert(r.complete and r.classification.sampleMethod == "native" and r.classification.exactWork == 0)
		near(out:volume(), 8)
	end)
	test("Transformed nearly coincident layers repair with exact source-plane samples", function()
		local source = oblique()
		local before = E.IO.encode(source)
		repaired, repairReport = E.MeshRepair.resolveIntersections(source, { maxWork = 50000000 })
		assert(repairReport.complete and repairReport.classification.exactSamples)
		assert(repairReport.intersections.intersectionFree and repairReport.validation.closed)
		near(repaired:volume(), 10.75, 1e-4)
		assert(E.IO.encode(source) == before)
	end)
	test("Exact winding preserves independent Boolean operand occupancy", function()
		local a, b = box(), box(V(0.5, 0.25, 0))
		for operation, volume in { union = 10.75, intersect = 5.25, subtract = 2.75 } do
			local out, r = E.Boolean.apply(
				a,
				b,
				operation,
				{ method = "arrangement", windingPrecision = "exact", maxWork = 50000000 }
			)
			assert(r.complete and r.classification.exactSamples)
			near(out:volume(), volume)
		end
	end)
	test("Exact Boolean classification retains missing operand groups as zero", function()
		for _, emptyFirst in { false, true } do
			local a, b = emptyFirst and E.Mesh.new() or box(), emptyFirst and box() or E.Mesh.new()
			local out, r = E.Boolean.union(a, b, { method = "arrangement", windingPrecision = "exact" })
			assert(r.complete and r.classification.exactSamples)
			near(out:volume(), 8)
		end
	end)
	test("Exact signed winding respects nested positive, nonzero, odd and reversed sheets", function()
		for _, reverse in { false, true } do
			local inner = box(nil, V(1, 1, 1))
			if reverse then
				inner = E.Topology.reverse(inner)
			end
			local source = E.Topology.join({ box(), inner })
			for _, rule in { "positive", "nonzero", "odd" } do
				local out, r = E.MeshRepair.resolveIntersections(
					source,
					{ windingPrecision = "exact", windingRule = rule }
				)
				assert(r.complete)
				near(out:volume(), reverse and 7 or rule == "odd" and 7 or 8)
			end
		end
	end)
	test("Excessive proximity welding still cannot claim valid repaired topology", function()
		local ok, r = pcall(function()
			local _, result =
				E.MeshRepair.resolveIntersections(gap(), { windingPrecision = "exact", tolerance = 1e-5 })
			return result
		end)
		assert(not ok or not r.complete)
	end)
	test("Typed channels, materials, corner fields, skin and groups survive exact classification", function()
		local source = gap()
		local vertex, corner, face, edge = {}, {}, {}, {}
		for id, p in source.vertices do
			vertex[id] = p.X
			source.weights[id] = { Left = 0.25, Right = 0.75 }
			source.groups.test = source.groups.test or {}
			source.groups.test[id] = 0.5
		end
		for fid, f in source.faces do
			face[fid] = "face" .. fid
			f.material = face[fid]
			for i, id in f.vertices do
				corner[fid .. ":" .. i] = source.vertices[id].X
				f.corners[i].uv = Vector2.new(source.vertices[id].X, fid)
			end
		end
		for key in E.Connectivity.index(source).edges do
			edge[key] = 7
		end
		for _, schema in
			{
				{ "x", "vertex", "number", vertex },
				{ "xc", "corner", "number", corner },
				{ "label", "face", "string", face },
				{ "rim", "edge", "number", edge },
			}
		do
			source = E.Attributes.set(
				E.Attributes.create(
					source,
					schema[1],
					schema[2],
					schema[3],
					schema[3] == "string" and "" or 0
				),
				schema[1],
				schema[4]
			)
		end
		local out, r =
			E.MeshRepair.resolveIntersections(source, { tolerance = 0, windingPrecision = "exact" })
		assert(r.complete)
		for id, p in out.vertices do
			near(E.Attributes.get(out, "x", id), p.X)
			near(out.weights[id].Left, 0.25)
			near(out.groups.test[id], 0.5)
		end
		for fid, f in out.faces do
			assert(E.Attributes.get(out, "label", fid) == f.material)
			for i, id in f.vertices do
				near(E.Attributes.get(out, "xc", fid .. ":" .. i), out.vertices[id].X)
				near(f.corners[i].uv.X, out.vertices[id].X)
			end
		end
		for key, refs in r.maps.edge do
			if #refs > 0 then
				assert(E.Attributes.get(out, "rim", key) == 7)
			end
		end
	end)
	test("Repair snapshots geometry and options before progress callbacks", function()
		local source = gap()
		local options = { tolerance = 0, windingPrecision = "exact" }
		local called = false
		options.checkpoint = function(state)
			if state.stage == "begin" and not called then
				called = true
				for id in source.vertices do
					source.vertices[id] = V(0, 0, 0)
				end
				options.windingPrecision = "native"
				options.maxWork = 1
			end
		end
		local out, r = E.MeshRepair.resolveIntersections(source, options)
		assert(called and r.complete and r.classification.exactSamples)
		near(out:volume(), 16)
	end)
	test("Arrangement Boolean snapshots both operands before input-audit callbacks", function()
		local a, b = box(), box(V(0.5, 0.25, 0))
		local called = false
		local options = {
			method = "arrangement",
			windingPrecision = "exact",
			checkIntersections = true,
			maxWork = 50000000,
		}
		options.intersectionOptions = {
			checkpoint = function()
				if not called then
					called = true
					for id in a.vertices do
						a.vertices[id] = V(0, 0, 0)
					end
					for id in b.vertices do
						b.vertices[id] = V(0, 0, 0)
					end
					options.windingPrecision = "native"
				end
			end,
		}
		local out, r = E.Boolean.union(a, b, options)
		assert(called and r.complete and r.classification.exactSamples)
		near(out:volume(), 10.75)
	end)
	test("Snapshot caps and cyclic custom data reject before invoking callbacks", function()
		local called = false
		local source = box()
		local options = {
			maxSnapshotEntries = 1,
			checkpoint = function()
				called = true
			end,
		}
		assert(not pcall(E.MeshRepair.resolveIntersections, source, options) and not called)
		source.extra = {}
		source.extra.self = source.extra
		assert(not pcall(E.MeshRepair.resolveIntersections, source, {
			checkpoint = function()
				called = true
			end,
		}) and not called)
		assert(source.extra.self == source.extra)
	end)
	test("Exact arithmetic caps and shared work exhaustion remain hard failures", function()
		local source = gap()
		local before = E.IO.encode(source)
		for _, options in
			{
				{ windingPrecision = "exact", maxExactBits = 1 },
				{ windingPrecision = "exact", maxExactCoefficients = 200 },
				{ windingPrecision = "exact", maxWork = 1000 },
				{ maxExactBits = 0 },
				{ maxExactCoefficients = 0 },
			}
		do
			assert(not pcall(E.MeshRepair.resolveIntersections, source, options))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Cancellation during exact work preserves the detached transaction", function()
		local source = gap()
		local before = E.IO.encode(source)
		local reached = false
		assert(not pcall(E.MeshRepair.resolveIntersections, source, {
			tolerance = 0,
			windingPrecision = "exact",
			checkpoint = function(s)
				if s.stage == "classifyExact" then
					reached = true
				end
			end,
			cancelled = function()
				return reached
			end,
		}))
		assert(reached and E.IO.encode(source) == before)
	end)
	test("Callback errors resembling precision failures are never swallowed by auto fallback", function()
		local exact = false
		local token = { reason = "nativeOffset" }
		local ok, err = pcall(E.MeshRepair.resolveIntersections, box(), {
			checkpoint = function(s)
				if s.stage == "classifyExact" then
					exact = true
				end
				if s.stage == "classify" then
					error(token, 0)
				end
			end,
		})
		assert(not ok and err == token and not exact)
	end)
	test("Precision option validation is explicit and scoped to arrangement operations", function()
		assert(not pcall(E.MeshRepair.resolveIntersections, box(), { windingPrecision = "approximate" }))
		for _, name in { "windingPrecision", "maxExactBits", "maxExactCoefficients" } do
			assert(
				not pcall(
					E.Boolean.union,
					box(),
					box(),
					{ [name] = name == "windingPrecision" and "exact" or 8192 }
				)
			)
		end
	end)
	test("An incomplete final audit remains incomplete after exact classification", function()
		local source = E.Topology.join({ box(), box(V(0.5, 0.25, 0)) })
		local _, input = E.Intersections.mesh(source)
		local _, r = E.MeshRepair.resolveIntersections(
			source,
			{ windingPrecision = "exact", intersectionOptions = { maxTests = input.tests + 1 } }
		)
		assert(not r.complete and not r.intersections.complete)
	end)
	test("Empty exact winding repairs retain an empty certified classification", function()
		local out, r = E.MeshRepair.resolveIntersections(E.Mesh.new(), { windingPrecision = "exact" })
		assert(
			r.complete
				and not next(out.faces)
				and r.classification.exactFragments == 0
				and r.classification.exactSamples
		)
	end)
	if not settings or not settings.skipNative then
		test("The repaired oblique boundary round-trips through a native EditableMesh", function()
			assert(repaired and repairReport.complete)
			local handle = E.Roblox.toEditable(repaired)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				assert(restored:validate().closed)
				local topology = E.Connectivity.analyze(restored)
				assert(topology.valid and topology.eulerCharacteristic == 2)
				near(restored:volume(), 10.75, 1e-4)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
