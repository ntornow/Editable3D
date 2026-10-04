return function(E, settings)
	local S, V = E.Subdivision, Vector3.new
	local Feature = require(script.Parent.SubdivisionFeaturePatch)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, epsilon)
		assert((a - b).Magnitude <= (epsilon or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function fan()
		local m = E.Mesh.new()
		for _, p in { V(0, 0, 0), V(-2, 0, 0), V(0, 1, 2), V(2, 0, 0), V(-1, 2, 3), V(1, 2, 0) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 5, 3 })
		m:addFace({ 1, 3, 6, 4 })
		return m
	end
	local function fixed()
		return S.crease(fan(), nil, { [1] = 10 })
	end
	test("Exact midpoint recognition distinguishes rounded equality and uncertain controls", function()
		local calls = 0
		local function work()
			calls += 1
		end
		assert(Feature.originalMidpoint({ 1, 2, 3, 0 }, { 0, 0, 0, 0 }, { 2, 4, 6, 0 }, work))
		for axis = 1, 3 do
			local p, a, b = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
			p[axis], a[axis], b[axis] = 2 ^ 30, 2 ^ 31, 2 ^ -80
			assert((a[axis] + b[axis]) / 2 == p[axis])
			assert(not Feature.originalMidpoint(p, a, b, work))
		end
		for i = 1, 3 do
			local points = { { 1, 2, 3, 0 }, { 0, 0, 0, 0 }, { 2, 4, 6, 0 } }
			points[i][4] = 1e-30
			assert(not Feature.originalMidpoint(points[1], points[2], points[3], work))
		end
		assert(calls > 0)
	end)
	test("Fixed two-face corners have independently derived finite one-sided partials", function()
		local m = fixed()
		local t, c = V(-2, 0, 0), V(0, 4 / 3, 11 / 6)
		for fid = 1, 2 do
			local r = S.limit(m, fid, 0, 0)
			assert(r.complete and r.derivativesAvailable and r.normalAvailable and r.oneSided)
			assert(r.normalMethod == "fixedMidpointCrease" and r.normalSectorFaces == 2)
			near(r.position, V(0, 0, 0))
			near(r.derivativeU, fid == 1 and t or c)
			near(r.derivativeV, fid == 1 and c or -t)
			near(r.normal, t:Cross(c).Unit)
		end
	end)
	test("Forty-eight independent rational recurrence references match both sector faces", function()
		local refs = require(script.Parent.FixedSectorFixtures)
		local function vector(a)
			return V(a[1], a[2], a[3])
		end
		for _, entry in refs do
			local m = E.Mesh.new()
			for _, p in
				{ entry.p, entry.first, entry.middle, entry.last, entry.diagonals[1], entry.diagonals[2] }
			do
				m:addVertex(vector(p))
			end
			m:addFace({ 1, 2, 5, 3 })
			m:addFace({ 1, 3, 6, 4 })
			m = S.crease(m, nil, { [1] = 10 })
			local t, c = vector(entry.tangent), vector(entry.cross)
			local a, b = S.limit(m, 1, 0, 0, { tolerance = 1e5 }), S.limit(m, 2, 0, 0, { tolerance = 1e5 })
			assert(
				a.derivativesAvailable and b.derivativesAvailable and a.normalMethod == "fixedMidpointCrease"
			)
			near(a.derivativeU, t, math.max(1e-25, t.Magnitude * 1e-6))
			near(a.derivativeV, c, math.max(1e-25, c.Magnitude * 1e-6))
			near(b.derivativeU, c, math.max(1e-25, c.Magnitude * 1e-6))
			near(b.derivativeV, -t, math.max(1e-25, t.Magnitude * 1e-6))
		end
	end)
	test("Nearby analytic patches approach the fixed corner partials and normal", function()
		local m = fixed()
		local target = S.limit(m, 1, 0, 0)
		local last = math.huge
		for power = 3, 8 do
			local h = 0.7 * 2 ^ -power
			local r = S.limit(m, 1, h, 0.8 * h)
			assert(r.method == "bicubic" and r.derivativesAvailable and r.normalAvailable)
			local err = (r.derivativeU - target.derivativeU).Magnitude
				+ (r.derivativeV - target.derivativeV).Magnitude
			assert(err < last)
			last = err
			if power == 8 then
				near(r.normal, target.normal, 0.005)
			end
		end
		assert(last < 0.01)
	end)
	test("All original corner parameter rotations preserve the finite jet", function()
		local uv = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
		local t, c = V(-2, 0, 0), V(0, 4 / 3, 11 / 6)
		for offset = 0, 3 do
			local m = fixed()
			for _, face in m.faces do
				local vertices = table.clone(face.vertices)
				for i = 1, 4 do
					face.vertices[i] = vertices[(i + offset - 1) % 4 + 1]
				end
			end
			local index = (4 - offset) % 4 + 1
			local r = S.limit(m, 1, uv[index][1], uv[index][2])
			local expectedU = ({ t, -c, -t, c })[index]
			local expectedV = ({ c, t, -c, -t })[index]
			assert(r.derivativesAvailable and r.normalAvailable)
			near(r.derivativeU, expectedU)
			near(r.derivativeV, expectedV)
			near(r.normal, t:Cross(c).Unit)
		end
	end)
	test("An explicit fixed boundary rule admits exactly straight two-face corners", function()
		local m = fan()
		local a = S.limit(m, 1, 0, 0, { boundary = "fixed" })
		local b = S.limit(fixed(), 1, 0, 0)
		assert(a.normalMethod == "fixedMidpointCrease")
		near(a.derivativeU, b.derivativeU)
		near(a.derivativeV, b.derivativeV)
		near(a.normal, b.normal)
	end)
	test("A three-crease junction separates midpoint jets from fixed Jordan normals", function()
		local m = E.Mesh.new()
		local center = m:addVertex(V(0, 0, 0))
		local points = { V(-2, 0, 0), V(0, 1, 1), V(2, 0, 0), V(1, -1, 0), V(0, -2, 0), V(-1, -1, 1) }
		local edges, diagonals = {}, {}
		for _, p in points do
			table.insert(edges, m:addVertex(p))
		end
		for i, p in points do
			table.insert(diagonals, m:addVertex(p + points[i % 6 + 1] + V(0, 0, i / 4)))
		end
		for i = 1, 6 do
			m:addFace({ center, edges[i], diagonals[i], edges[i % 6 + 1] })
		end
		local creases = {}
		for _, i in { 1, 3, 5 } do
			creases[center .. ":" .. edges[i]] = 10
		end
		m = S.crease(m, creases)
		local a, b = S.limit(m, 1, 0, 0), S.limit(m, 2, 0, 0)
		assert(a.normalMethod == "fixedMidpointCrease" and a.derivativesAvailable and b.normalAvailable)
		near(a.normal, b.normal)
		for _, fid in { 3, 4, 5, 6 } do
			local r = S.limit(m, fid, 0, 0)
			assert(
				r.normalAvailable
					and not r.derivativesAvailable
					and r.normalSectorFaces == 2
					and r.normalMethod == "fixedCornerJordan"
			)
		end
	end)
	test("A non-midpoint fixed corner never borrows the ordinary crease stencil", function()
		local m = fixed()
		for _, delta in { 2 ^ -20, 0.5 } do
			m.vertices[1] = V(0, delta, 0)
			local r = S.limit(m, 1, 0, 0)
			assert(
				r.complete
					and not r.derivativesAvailable
					and r.normalAvailable
					and r.normalMethod == "fixedCornerJordan"
			)
			near(r.normal, V(0, 0, 1))
		end
	end)
	test("Degenerate jets retain finite partials without asserting a tangent plane", function()
		local m = fixed()
		m.vertices[3], m.vertices[5], m.vertices[6] = V(0, 0, 0), V(-1, 0, 0), V(1, 0, 0)
		local r = S.limit(m, 1, 0, 0)
		assert(r.derivativesAvailable and not r.normalAvailable and r.normalReason)
		near(r.derivativeV, V(0, 0, 0))
	end)
	test("Finite sharpness and uncertain refined controls do not invoke the identity shortcut", function()
		local m = S.crease(fan(), nil, { [1] = 0.5 })
		local r = S.limit(m, 1, 0, 0, { maxDepth = 0 })
		assert(r.normalMethod ~= "fixedMidpointCrease" and not r.derivativesAvailable)
		local calls = 0
		assert(not Feature.originalMidpoint({ 0, 0, 0, 1e-30 }, { -1, 0, 0, 0 }, { 1, 0, 0, 0 }, function()
			calls += 1
		end))
		assert(calls == 0)
	end)
	test("Scale and exact axis transforms preserve the recognized fixed-sector jet", function()
		local a = S.limit(fixed(), 1, 0, 0)
		for _, scale in { 2 ^ -80, 2 ^ -10, 2 ^ 10, 2 ^ 80 } do
			local m = fixed()
			for id, p in m.vertices do
				m.vertices[id] = V(-p.Z, p.X, p.Y) * scale
			end
			local r = S.limit(m, 1, 0, 0, { tolerance = scale * 1e-5 })
			assert(r.complete and r.derivativesAvailable and r.normalAvailable)
			near(r.derivativeU / scale, V(-a.derivativeU.Z, a.derivativeU.X, a.derivativeU.Y))
			near(r.derivativeV / scale, V(-a.derivativeV.Z, a.derivativeV.X, a.derivativeV.Y))
			near(r.normal, V(-a.normal.Z, a.normal.X, a.normal.Y) * -1)
		end
	end)
	test("Prepared fixed-sector queries retain their source snapshot and typed data", function()
		local m = fixed()
		m = E.Attributes.create(m, "label", "vertex", "number", 0)
		m = E.Attributes.set(m, "label", { [1] = 7 })
		local before = E.IO.encode(m)
		local options = { boundary = "edge" }
		local evaluator = S.prepareLimit(m, options)
		local a = evaluator:evaluate(1, 0, 0)
		assert(E.IO.encode(m) == before)
		m.vertices[1], options.boundary = V(0, 1, 0), "fixed"
		local b = evaluator:evaluate(1, 0, 0)
		assert(b.normalMethod == "fixedMidpointCrease")
		near(a.position, b.position)
		near(a.derivativeU, b.derivativeU)
		near(a.normal, b.normal)
	end)
	test("Fixed-sector identity work and queries obey shared hard limits", function()
		local m = fixed()
		local before = E.IO.encode(m)
		assert(not pcall(S.limit, m, 1, 0, 0, { maxWork = 10 }))
		assert(not pcall(S.limit, m, 1, 0, 0, {
			cancelled = function()
				return true
			end,
		}))
		local evaluator = S.prepareLimit(m, { maxQueries = 1 })
		assert(evaluator:evaluate(1, 0, 0).normalAvailable)
		assert(not pcall(evaluator.evaluate, evaluator, 1, 0, 0))
		assert(E.IO.encode(m) == before)
	end)
	test("Whole-cage refinement preserves the recognized jet with the parameter scale", function()
		local m = fixed()
		local expected = S.limit(m, 1, 0, 0)
		for level = 1, 4 do
			m = S.catmullClark(m, 1)
			local r = S.limit(m, 1, 0, 0)
			assert(r.derivativesAvailable and r.normalMethod == "fixedMidpointCrease")
			near(r.derivativeU * 2 ^ level, expected.derivativeU)
			near(r.derivativeV * 2 ^ level, expected.derivativeV)
			near(r.position, expected.position)
			near(r.normal, expected.normal)
		end
	end)
	local panel
	test("The fixed-boundary panel shares seam vertices and retains evaluated normals", function()
		panel = require(script.Parent.Examples.FixedBoundaryPanel)(E)
		local top = E.Connectivity.analyze(panel.mesh)
		assert(top.valid and top.eulerCharacteristic == 1)
		assert(panel.queries.queries == 163 and panel.corner.normalMethod == "fixedMidpointCrease")
		assert(panel.mesh:validate().valid)
	end)
	if not settings or not settings.skipNative then
		test("Fixed-sector normals and UVs round-trip through native EditableMesh", function()
			assert(panel)
			local handle = E.Roblox.toEditable(panel.mesh)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				assert(
					restored:validate().valid and E.Connectivity.analyze(restored).eulerCharacteristic == 1
				)
				local checked = 0
				for _, face in restored.faces do
					for i, id in face.vertices do
						local corner = face.corners[i]
						assert(corner.uv and corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-5)
						if
							(restored.vertices[id] + handle.origin - panel.corner.position).Magnitude < 1e-6
						then
							assert(corner.uv == Vector2.new(0.5, 0))
							near(corner.normal, panel.corner.normal)
							checked += 1
						end
					end
				end
				assert(checked > 0)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
