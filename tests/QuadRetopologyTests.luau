return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local A = require(script.Parent.AttributeCore)
	local V = Vector3.new
	local function near(a, b, t)
		assert(math.abs(a - b) <= (t or 1e-6), tostring(a) .. " != " .. tostring(b))
	end
	local function options(extra)
		local out = { checkIntersections = false, coarsen = false, maxDeviation = 10 }
		for k, v in extra or {} do
			out[k] = v
		end
		return out
	end
	local function square(scale, offset)
		scale, offset = scale or 1, offset or Vector3.zero
		local m = E.Mesh.new()
		for _, p in { V(0, 0, 0), V(1, 0, 0), V(1, 1, 0), V(0, 1, 0) } do
			m:addVertex(p * scale + offset)
		end
		m:addFace({ 1, 2, 3, 4 }, {
			{ uv = Vector2.new(0, 0) },
			{ uv = Vector2.new(1, 0) },
			{ uv = Vector2.new(1, 1) },
			{
				uv = Vector2.new(0, 1),
			},
		})
		return m
	end
	local function triangle()
		local m = E.Mesh.new()
		for _, p in { V(0, 0, 0), V(4, 0, 0), V(0, 4, 0) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		return m
	end
	local function same(a, b)
		if type(a) ~= "table" then
			return a == b
		end
		if type(b) ~= "table" then
			return false
		end
		for k, v in a do
			if not same(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil then
				return false
			end
		end
		return true
	end
	local function unchanged(a, b)
		assert(
			same(a.vertices, b.vertices)
				and same(a.faces, b.faces)
				and same(a.attributes, b.attributes)
				and same(a.groups, b.groups)
				and same(a.weights, b.weights)
		)
	end
	local function quads(m)
		assert(m:validate({ minimumFaceArea = 0 }).valid)
		for _, f in m.faces do
			assert(#f.vertices == 4)
		end
	end
	test("Quad patch certificates match 96 independent rational references and 788 positive cells", function()
		local B = require(script.Parent.QuadPatchBound)
		local count = 0
		for _, row in require(script.Parent.QuadPatchFixtures) do
			local positions = {}
			for i, p in row.positions do
				positions[i] = V(p[1], p[2], p[3])
			end
			local function entries(list)
				local out = {}
				for _, ids in list do
					table.insert(out, { ids = ids, uv = { row.uv[ids[1]], row.uv[ids[2]], row.uv[ids[3]] } })
				end
				return out
			end
			local bound, detail = B.check(
				entries(row.source),
				entries(row.target),
				positions,
				row.triangle,
				function() end
			)
			assert(bound and bound >= row.upper and bound <= row.upper * (1 + 1e-12) + 1e-300)
			assert(same(detail.pairs, row.overlaps))
			count += #detail.pairs
		end
		assert(count == 788)
	end)
	test("Planar square produces four exact regular quads and one boundary loop", function()
		local m = square()
		local out, r = E.Remesh.quads(m, nil, options({ maxDeviation = 0 }))
		assert(r.complete and r.applied and r.allQuads and r.finalFaces == 4 and r.finalVertices == 9)
		assert(r.errorBound == 0 and r.stages.pairing.paired == 1)
		near(r.quality.minimumScaledJacobian, 1)
		assert(
			r.outputTopology.components[1].eulerCharacteristic == 1 and #r.outputTopology.boundaryLoops == 1
		)
		quads(out)
	end)
	test("A triangle becomes three conforming quads with a whole-patch bound", function()
		local m = triangle()
		local out, r = E.Remesh.quads(m, nil, options())
		assert(r.complete and r.finalFaces == 3 and r.finalVertices == 7)
		assert(r.errorBound > 0 and r.errorBound < 1e-6)
		quads(out)
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
	end)
	test("Closed crease-delimited cube has 24 exact quads and Euler characteristic two", function()
		local out, r = E.Remesh.quads(E.Primitives.box(V(2, 2, 2)), nil, options({ maxDeviation = 0 }))
		assert(r.complete and r.finalFaces == 24 and r.errorBound == 0 and r.outputTopology.closed)
		assert(r.outputTopology.components[1].eulerCharacteristic == 2)
		quads(out)
	end)
	test("Shared-edge refinement meets a constant upper density target", function()
		local out, r = E.Remesh.quads(triangle(), 0.3, options())
		assert(r.complete and r.stages.density.operations > 0 and r.quality.maximumEdgeRatio <= 4 / 3)
		assert(
			r.outputTopology.components[1].eulerCharacteristic == 1 and #r.outputTopology.boundaryLoops == 1
		)
		quads(out)
	end)
	test("Spatial density fields create more samples in the fine half", function()
		local out, r = E.Remesh.quads(square(4), function(p)
			return p.X < 2 and 0.2 or 0.7
		end, options())
		assert(r.applied and r.stages.density.operations > 0)
		local fine, coarse = 0, 0
		for _, p in out.vertices do
			if p.X < 2 then
				fine += 1
			else
				coarse += 1
			end
		end
		assert(fine > coarse)
		-- Discontinuous fields can prevent the final two-stage layout meeting every target.
		assert(r.complete == r.quality.densityMet)
		quads(out)
	end)
	test("Typed vertices, corners, faces, edge chains and skin/group weights transfer", function()
		local m = square()
		for _, schema in
			{
				{ "v", "vertex", "number", 0 },
				{ "f", "face", "string", "none" },
				{ "c", "corner", "number", 0 },
				{ "e", "edge", "boolean", false },
			}
		do
			m = E.Attributes.create(m, table.unpack(schema))
		end
		m = E.Attributes.set(m, "v", { [1] = 0, [2] = 1, [3] = 2, [4] = 1 })
		m = E.Attributes.set(m, "f", { [1] = "panel" })
		m = E.Attributes.set(m, "c", { ["1:1"] = 0, ["1:2"] = 1, ["1:3"] = 2, ["1:4"] = 1 })
		m = E.Attributes.set(m, "e", { ["1:2"] = true })
		m.groups.test = { [1] = 0, [2] = 1, [3] = 1, [4] = 0 }
		for id in m.vertices do
			m.weights[id] = { Root = 1 }
		end
		local before = m:clone()
		local out, r = E.Remesh.quads(m, nil, options())
		assert(r.complete)
		A.validate(out)
		for id, p in out.vertices do
			near(E.Attributes.get(out, "v", id), p.X + p.Y)
			near(out.groups.test[id] or 0, p.X)
			near(out.weights[id].Root, 1)
		end
		local marked = 0
		for _, value in out.attributes.e.values do
			if value then
				marked += 1
			end
		end
		assert(marked == 2)
		for fid, f in out.faces do
			assert(E.Attributes.get(out, "f", fid) == "panel")
			for i, id in f.vertices do
				near(E.Attributes.get(out, "c", fid .. ":" .. i), out.vertices[id].X + out.vertices[id].Y)
				near(f.corners[i].uv.X, out.vertices[id].X)
			end
		end
		unchanged(m, before)
	end)
	test("Material, UV, typed face and typed diagonal seams delimit pairing", function()
		for _, kind in { "material", "uv", "face", "edge", "handedness" } do
			local m = E.Topology.triangulate(square())
			local ids = U.keys(m.faces)
			local a, b = ids[1], ids[2]
			if kind == "material" then
				m.faces[b].material = 2
			end
			if kind == "uv" then
				for _, c in m.faces[b].corners do
					c.uv += Vector2.new(1, 0)
				end
			end
			if kind == "handedness" then
				for _, c in m.faces[a].corners do
					c.tangentSign = 1
				end
				for _, c in m.faces[b].corners do
					c.tangentSign = -1
				end
			end
			if kind == "face" then
				m = E.Attributes.set(
					E.Attributes.create(m, "region", "face", "boolean", false),
					"region",
					{ [b] = true }
				)
			end
			if kind == "edge" then
				local key
				for k, e in m:topology().edges do
					if #e.faces == 2 then
						key = k
					end
				end
				m = E.Attributes.set(
					E.Attributes.create(m, "feature", "edge", "number", 0),
					"feature",
					{ [key] = 2 }
				)
			end
			local out, r = E.Remesh.quads(m, nil, options())
			assert(r.complete and r.stages.pairing.paired == 0 and r.finalFaces == 6, kind)
			quads(out)
		end
	end)
	test("Generated face normals do not lock smooth triangle pairs", function()
		local m = E.Topology.triangulate(square())
		for fid, f in m.faces do
			for _, c in f.corners do
				c.normal = fid == 1 and Vector3.xAxis or Vector3.yAxis
			end
		end
		local _, r = E.Remesh.quads(m, nil, options())
		assert(r.complete and r.stages.pairing.paired == 1)
	end)
	test("Constrained coarsening reduces dense interiors and keeps all boundary samples", function()
		local m = E.Primitives.grid(5, 5, Vector2.new(4, 4))
		local boundary = {}
		for _, edge in m:topology().edges do
			if #edge.faces == 1 then
				boundary[edge.a] = true
				boundary[edge.b] = true
			end
		end
		local out, r = E.Remesh.quads(m, 0.8, options({ coarsen = true, maxCoarsenIterations = 12 }))
		assert(r.applied and r.stages.coarsening and r.stages.coarsening.collapses > 0)
		for id in boundary do
			assert(out.vertices[id] == m.vertices[id])
		end
		quads(out)
	end)
	test("Exact pins and nondefault edge features survive coarsening and splitting", function()
		local m = E.Primitives.grid(4, 4, Vector2.new(4, 4))
		local key = "12:13"
		m = E.Attributes.set(E.Attributes.create(m, "crease", "edge", "number", 0), "crease", { [key] = 3 })
		local out, r = E.Remesh.quads(m, 0.8, options({ coarsen = true, pins = { [7] = true } }))
		assert(
			r.applied
				and out.vertices[7] == m.vertices[7]
				and out.vertices[12] == m.vertices[12]
				and out.vertices[13] == m.vertices[13]
		)
		local marked = 0
		for _, v in out.attributes.crease.values do
			if v == 3 then
				marked += 1
			end
		end
		assert(marked >= 2)
	end)
	test("Loose vertices and sparse IDs are preserved", function()
		local m = square()
		m.nextVertex = 100
		m.nextFace = 200
		local loose = m:addVertex(V(8, 9, 10))
		local out, r = E.Remesh.quads(m, nil, options())
		assert(r.complete and out.vertices[loose] == m.vertices[loose])
		for fid in out.faces do
			assert(fid >= 200)
		end
	end)
	test("Power-of-two scales and large exact translations retain planar topology", function()
		for _, scale in { 2 ^ -50, 2 ^ -20, 1, 2 ^ 20, 2 ^ 50 } do
			local out, r = E.Remesh.quads(square(scale), nil, options({ maxDeviation = 0 }))
			assert(r.complete and r.errorBound == 0 and r.finalFaces == 4)
			quads(out)
		end
		local _, r =
			E.Remesh.quads(square(16, V(2 ^ 24, -2 ^ 24, 2 ^ 24)), nil, options({ maxDeviation = 0 }))
		assert(r.complete and r.errorBound == 0)
	end)
	test("Native midpoint collapse rolls back the complete source transaction", function()
		local m = square(2, V(2 ^ 24, 2 ^ 24, 0))
		local out, r = E.Remesh.quads(m, nil, options())
		assert(not r.applied and not r.complete and r.errorBound == 0)
		unchanged(out, m)
	end)
	test("Zero deviation refuses rounded triangle center construction", function()
		local m = triangle()
		local out, r = E.Remesh.quads(m, nil, options({ maxDeviation = 0 }))
		assert(not r.complete and not r.applied and r.reason == "quadrangulationBounds")
		unchanged(out, m)
	end)
	test("Shape targets return measured valid partials and requireComplete rejects them", function()
		local m = triangle()
		local out, r = E.Remesh.quads(m, nil, options({ minimumScaledJacobian = 0.95 }))
		assert(r.applied and not r.complete and r.reason == "shapeTarget" and r.quality.badFaces > 0)
		quads(out)
		assert(
			not pcall(
				E.Remesh.quads,
				m,
				nil,
				options({ minimumScaledJacobian = 0.95, requireComplete = true })
			)
		)
	end)
	test("Zero split and depth limits produce explicit density partials", function()
		for _, opt in { { maxSplits = 0 }, { maxDepth = 0 } } do
			local out, r = E.Remesh.quads(triangle(), 0.05, options(opt))
			assert(
				r.applied
					and not r.complete
					and r.reason == "densityTarget"
					and r.stages.density.operations == 0
			)
			quads(out)
		end
	end)
	test("Minimum edge density is measured independently of the upper target", function()
		local out, r = E.Remesh.quads(square(), 10, options({ minimumEdgeRatio = 0.5 }))
		assert(r.applied and not r.complete and r.quality.shortEdges > 0 and r.quality.longEdges == 0)
		quads(out)
	end)
	test("Explicit unattainable coarse targets do not report completion", function()
		local _, r = E.Remesh.quads(
			square(),
			nil,
			options({ coarsen = true, targetTriangles = 0, maxCoarsenIterations = 0 })
		)
		assert(r.applied and not r.complete and not r.coarseningMet and r.reason == "coarseningTarget")
	end)
	test("Source and nested options are detached before checkpoint mutation", function()
		local m = square()
		local opt = options({ pins = { [1] = true } })
		opt.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[1] = V(99, 99, 99)
				opt.pins[1] = false
				opt.maxDeviation = 0
				opt.minimumScaledJacobian = 1
			end
		end
		local out, r = E.Remesh.quads(m, nil, opt)
		assert(r.complete and out.vertices[1] == Vector3.zero)
	end)
	test("Density callbacks observe a snapshot and may not return invalid lengths", function()
		local m = square()
		local out, r = E.Remesh.quads(m, function()
			m.vertices[1] = V(88, 88, 88)
			return 1
		end, options())
		assert(r.complete and out.vertices[1] == Vector3.zero)
		for _, value in { 0, -1, math.huge, 0 / 0, "bad" } do
			assert(not pcall(E.Remesh.quads, square(), function()
				return value
			end, options()))
		end
	end)
	test("Allocation, source data and hard work budgets are enforced", function()
		for _, opt in
			{
				{ maxVertices = 3 },
				{ maxFaces = 1 },
				{ maxCorners = 3 },
				{ maxTriangles = 1 },
				{ maxFaceVertices = 3 },
				{ maxWork = 1 },
				{ maxDataEntries = 1 },
				{ maxVertices = 8 },
			}
		do
			assert(not pcall(E.Remesh.quads, square(), nil, options(opt)))
		end
	end)
	test("Cancellation is enforced at start, density stages and completion", function()
		for _, stage in { "begin", "density", "complete" } do
			local stop = false
			assert(not pcall(
				E.Remesh.quads,
				square(4),
				0.2,
				options({
					cancelled = function()
						return stop
					end,
					checkpoint = function(s)
						if s.stage == stage then
							stop = true
						end
					end,
				})
			))
		end
	end)
	test("Invalid options and nonmanifold inputs are rejected", function()
		for _, opt in
			{
				{ maxDepth = 25 },
				{ maxSplits = -1 },
				{ featureAngle = math.pi },
				{ minimumScaledJacobian = 2 },
				{ maximumAspectRatio = 0 },
				{ minimumEdgeRatio = 2, maximumEdgeRatio = 1 },
				{ pins = { [99] = true } },
				{ intersectionOptions = true },
			}
		do
			assert(not pcall(E.Remesh.quads, square(), nil, options(opt)))
		end
		local m = square()
		m:addFace({ 1, 2, 3, 4 })
		assert(not pcall(E.Remesh.quads, m, nil, options()))
	end)
	test("Endpoint intersection audits accept a cube and reject intersecting source components", function()
		local out, r =
			E.Remesh.quads(E.Primitives.box(V(2, 2, 2)), nil, options({ checkIntersections = true }))
		assert(
			r.complete and r.inputIntersections.intersectionFree and r.outputIntersections.intersectionFree
		)
		quads(out)
		local a, b = square(), square()
		for id, p in b.vertices do
			b.vertices[id] = V(p.X, 0.5, p.Y - 0.5)
		end
		local m = E.Topology.join({ a, b })
		local rejected, s = E.Remesh.quads(m, nil, options({ checkIntersections = true }))
		assert(not s.applied and s.reason == "inputIntersections")
		unchanged(rejected, m)
	end)
	test("Nested audit work limits and cancellation cannot bypass the root transaction", function()
		local m = square()
		local ok, _out, r = pcall(
			E.Remesh.quads,
			m,
			nil,
			options({ checkIntersections = true, intersectionOptions = { maxWork = 1 } })
		)
		assert(not ok or not r.applied and not r.complete)
		assert(not pcall(
			E.Remesh.quads,
			m,
			nil,
			options({
				checkIntersections = true,
				intersectionOptions = {
					cancelled = function()
						return true
					end,
				},
			})
		))
	end)
	test("Empty surfaces preserve loose data without fabricating faces", function()
		local m = E.Mesh.new()
		m:addVertex(V(2, 3, 4))
		local out, r = E.Remesh.quads(m, nil, options())
		assert(r.complete and r.finalFaces == 0 and out.vertices[1] == m.vertices[1])
	end)
	test("A warped square has an analytic one-quarter whole-surface displacement", function()
		local m = square()
		m.vertices[3] = V(1, 1, 1)
		local out, r = E.Remesh.quads(
			m,
			nil,
			options({ featureAngle = 1.5, maxNormalAngle = 1.55, checkIntersections = true })
		)
		assert(r.complete and r.errorBound >= 0.25 and r.errorBound < 0.250000000001)
		near(r.maximumNormalAngle, math.pi / 4, 1e-12)
		quads(out)
	end)
	test("Introduced intersections roll back even after valid certified local patches", function()
		local m = square()
		m.vertices[3] = V(1, 1, 1)
		local a = m:addVertex(V(0.1, 0.25, 0.1))
		local b = m:addVertex(V(0.7, 0.25, 0.1))
		local c = m:addVertex(V(0.1, 0.3, 0.1))
		m:addFace({ a, b, c })
		local out, r = E.Remesh.quads(
			m,
			nil,
			options({ featureAngle = 1.5, maxNormalAngle = 1.55, checkIntersections = true })
		)
		assert(r.inputIntersections.intersectionFree and not r.outputIntersections.intersectionFree)
		assert(not r.applied and not r.complete and r.errorBound == 0 and r.candidateErrorBound > 0)
		unchanged(out, m)
	end)
	test("Default-valued named features still delimit quad pairing", function()
		for _, name in { "sharp_edge", "uv_seam", "subdivision_edge_sharpness", "custom" } do
			local m = E.Topology.triangulate(square())
			m = E.Attributes.create(m, name, "edge", "number", 1)
			-- Normal generation gives sharp_edge its documented boolean schema.
			if name == "sharp_edge" then
				m.attributes[name].dataType = "boolean"
				m.attributes[name].default = true
				m.attributes[name].interpolation = "nearest"
			end
			local _, r =
				E.Remesh.quads(m, nil, options({ seamAttributes = name == "custom" and { name } or nil }))
			assert(r.complete and r.stages.pairing.paired == 0, name)
		end
	end)
	test("Repeated density splits retain affine data and boundary feature chains", function()
		local m = square(4)
		m = E.Attributes.create(m, "height", "vertex", "number", 0)
		m = E.Attributes.create(m, "chart", "corner", "number", 0)
		m = E.Attributes.create(m, "rim", "edge", "number", 0)
		for id, p in m.vertices do
			m.attributes.height.values[id] = p.X + 2 * p.Y
		end
		for i, id in m.faces[1].vertices do
			m.attributes.chart.values["1:" .. i] = m.attributes.height.values[id]
		end
		m.attributes.rim.values["1:2"] = 7
		local out, r = E.Remesh.quads(m, 0.3, options())
		assert(r.applied and r.stages.density.operations > 10)
		for id, p in out.vertices do
			near(E.Attributes.get(out, "height", id), p.X + 2 * p.Y, 2e-6)
		end
		for fid, f in out.faces do
			for i, id in f.vertices do
				local p = out.vertices[id]
				near(E.Attributes.get(out, "chart", fid .. ":" .. i), p.X + 2 * p.Y, 2e-6)
			end
		end
		local total = 0
		for key, edge in out:topology().edges do
			if A.read(out.attributes.rim, key) == 7 then
				total += (out.vertices[edge.a] - out.vertices[edge.b]).Magnitude
			end
		end
		near(total, 4, 1e-6)
	end)
	test("Holed and periodic surfaces retain Euler characteristic and boundary loops", function()
		local panel = E.Primitives.grid(3, 3, Vector2.new(6, 6))
		panel.faces[5] = nil
		for _, m in { panel, E.Primitives.torus(3, 1, 8, 6) } do
			local before = E.Connectivity.analyze(m)
			local out, r = E.Remesh.quads(m, nil, options())
			assert(r.applied and r.outputTopology.eulerCharacteristic == before.eulerCharacteristic)
			assert(#r.outputTopology.boundaryLoops == #before.boundaryLoops)
			quads(out)
		end
	end)
	test("A low hard work limit interrupts refinement without modifying the source", function()
		local m = square(4)
		local before = m:clone()
		assert(not pcall(E.Remesh.quads, m, 0.01, options({ maxWork = 10000, maxSplits = 10000 })))
		unchanged(m, before)
	end)
	test("Density rounding certificates match 64 independent high-precision references", function()
		local D = require(script.Parent.QuadDensity)
		for _, row in require(script.Parent.QuadDensityFixtures) do
			local m = E.Mesh.new()
			for _, p in row.positions do
				m:addVertex(V(p[1], p[2], p[3]))
			end
			m:addFace({ 1, 2, 3 })
			local p = row.point
			local bound = D.pointError(m, 1, row.uv, row.denominator, V(p[1], p[2], p[3]))
			assert(bound >= row.upper and bound <= row.upper * (1 + 1e-12) + 1e-300)
		end
	end)
	test("Exactly tilted planar quads permit a zero normal-change limit", function()
		local m = square(4)
		for id, p in m.vertices do
			m.vertices[id] = V(p.X, p.Y, p.X + 2 * p.Y)
		end
		local out, r = E.Remesh.quads(m, nil, options({ maxDeviation = 0, maxNormalAngle = 0 }))
		assert(r.complete and r.errorBound == 0 and r.maximumNormalAngle < 2 ^ -42)
		quads(out)
	end)
	if not settings or not settings.skipNative then
		test("Native EditableMesh roundtrip retains a retopologized closed cube", function()
			local out, r =
				E.Remesh.quads(E.Primitives.box(V(2, 2, 2)), nil, options({ checkIntersections = true }))
			assert(r.complete)
			local handle = E.Roblox.toEditable(out)
			local ok, err = pcall(function()
				local back = E.Roblox.fromEditable(handle.editable)
				assert(back:validate().closed)
				near(math.abs(back:volume()), 8, 1e-5)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
