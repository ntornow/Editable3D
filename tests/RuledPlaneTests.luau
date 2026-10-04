return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local R = require(script.Parent.ExactRational)(function() end, 8192)
	local P = require(script.Parent.ExactPolynomialRoots)(R, function() end, 96)
	local V = Vector3.new
	local function patch(o, u, v, options)
		return E.NURBS.surface({ { o, o + v }, { o + u, o + u + v } }, 1, 1, options)
	end
	local function unit()
		return patch(V(0, 0, 0), V(1, 0, 0), V(0, 1, 0))
	end
	local function query(a, b, options)
		options = U.copy(options or {})
		options.method = "exactRuled"
		return E.SplineQuery.intersectSurfaces(a, b or unit(), options)
	end
	local function surface(xs, zs, delta, options)
		local rows = {}
		for i, z in zs do
			rows[i] = { V(xs[i], 0, z), V(xs[i], 1, z + (delta or 0)) }
		end
		return E.NURBS.surface(rows, #rows - 1, 1, options)
	end
	local function saddle(offset)
		offset = offset or 0
		return E.NURBS.surface({
			{ V(0, 0, 0.25 - offset), V(0, 1, -0.25 - offset) },
			{ V(1, 0, -0.25 - offset), V(1, 1, 0.25 - offset) },
		}, 1, 1)
	end
	local function verifyExact(v)
		if not v.positionExact then
			return
		end
		local square = R.number(0)
		for i, name in { "X", "Y", "Z" } do
			assert(
				R.compare(R.number(v.positionBox[i][1]), v.positionExact[i]) <= 0
					and R.compare(R.number(v.positionBox[i][2]), v.positionExact[i]) >= 0
			)
			local d = R.sub(v.positionExact[i], R.number(v.position[name]))
			square = R.add(square, R.mul(d, d))
		end
		assert(R.compare(square, R.mul(R.number(v.errorBound), R.number(v.errorBound))) <= 0)
		for i, x in v.parametersExact do
			assert(
				R.compare(R.number(v.parameterBox[i][1]), x) <= 0
					and R.compare(R.number(v.parameterBox[i][2]), x) >= 0
			)
		end
	end
	local function value(f, x)
		return R.div(P.evaluate(f.n, x), P.evaluate(f.d, x))
	end
	local function compareToEvent(s, event)
		local e = event.profile
		local x = R.div(R.sub(s, e.offset), e.scale)
		if e.exact then
			return R.compare(x, e.low)
		end
		if R.compare(x, e.low) <= 0 then
			return -1
		end
		if R.compare(x, e.high) >= 0 then
			return 1
		end
		if P.evaluate(e.polynomial, x).sign == 0 then
			return 0
		end
		local analysis = P.analyze(e.polynomial)
		return P.count(analysis, e.low, x) == 1 and 1 or -1
	end
	local function fiberAt(r, s)
		local result
		for _, cell in r.cells do
			local found = false
			if cell.kind == "fiber" then
				found = compareToEvent(s, r.events[cell.event]) == 0
			else
				found = compareToEvent(s, r.events[cell.firstEvent]) > 0
					and compareToEvent(s, r.events[cell.lastEvent]) < 0
			end
			if found then
				assert(not result, "Contact cells overlap in their owned profile domain")
				local span = r.spans[cell.span]
				local x = R.div(R.sub(s, span.offset), span.scale)
				result = {
					value(cell.linearBounds[1], x),
					value(cell.linearBounds[2], x),
					dimension = cell.parameterDimension - (cell.kind == "fiber" and 0 or 1),
				}
			end
		end
		return result
	end
	test("576 independent Fraction fibers match 64 weighted ruled-surface contact decompositions", function()
		local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.RuledPlaneFixtures))
		local function exact(x)
			return R.fraction(x.sign, x.n, x.d)
		end
		for index, f in fixtures do
			local points = {}
			for i, row in f.points do
				points[i] = {}
				for j, p in row do
					points[i][j] = V(table.unpack(p))
				end
			end
			local a = E.NURBS.surface(points, f.degree, 1, { weights = f.weights })
			local b =
				patch(V(table.unpack(f.plane[1])), V(table.unpack(f.plane[2])), V(table.unpack(f.plane[3])))
			local r =
				query(a, b, { maxWork = 200000000, maxCoefficients = 4000000, requireComponents = true })
			assert(r.rootCoverageComplete and r.parameterComponentsCertified)
			for _, probe in f.probes do
				local actual = fiberAt(r, R.number(probe.s))
				assert(
					(actual ~= nil) == (probe.fiber ~= nil),
					"Reference fiber feasibility " .. index .. ":" .. probe.s
				)
				if actual then
					assert(
						R.equal(actual[1], exact(probe.fiber.low))
							and R.equal(actual[2], exact(probe.fiber.high))
							and actual.dimension == probe.fiber.dimension,
						"Reference clipped fiber " .. index .. ":" .. probe.s
					)
				end
			end
			for _, v in r.vertices do
				verifyExact(v)
			end
		end
	end)
	test("A saddle crossing retains two graph branches and the complete exceptional ruling", function()
		local r = query(saddle())
		assert(
			r.complete
				and #r.cells == 5
				and #r.vertices == 5
				and #r.connections == 4
				and r.componentCount == 1
		)
		local ruling = 0
		for _, c in r.cells do
			if c.kind == "fiber" and c.parameterDimension == 1 then
				ruling += 1
				assert(c.rulingInPlane)
			end
		end
		assert(ruling == 1 and r.components[1].parameterDimension == 1)
	end)
	test("A parabolic cylinder produces an exact curved graph including both boundary corners", function()
		local r = query(surface({ 0, 0.5, 1 }, { 0, 0, -1 }, 1), nil, { requireComplete = true })
		assert(#r.cells == 3 and r.cells[3].kind == "graph" and #r.vertices == 2)
		for _, x in { 0.125, 0.25, 0.5, 0.75, 0.875 } do
			local f = fiberAt(r, R.number(x))
			assert(R.equal(f[1], R.number(x * x)) and R.equal(f[1], f[2]))
		end
	end)
	test("A tangent parabolic cylinder retains its entire isolated ruling", function()
		local r = query(surface({ 0, 0.5, 1 }, { 0.25, -0.25, 0.25 }))
		assert(
			r.complete
				and #r.cells == 1
				and r.cells[1].kind == "fiber"
				and r.cells[1].parameterDimension == 1
				and r.cells[1].rulingInPlane
		)
		assert(r.componentCount == 1 and #r.connections == 0 and #r.vertices == 2)
	end)
	test("A hyperbola section has two components separated by a pole and excluded fibers", function()
		local r = query(saddle(0.125))
		assert(r.complete and r.componentCount == 2 and #r.cells == 6)
		assert(not fiberAt(r, R.number(0.5)) and fiberAt(r, R.number(0.25)) and fiberAt(r, R.number(0.75)))
	end)
	test(
		"Coplanar nonlinear patches return two-dimensional bands with irrational clipped boundaries",
		function()
			local r = query(
				surface({ 0, 0, 1 }, { 0, 0, 0 }),
				nil,
				{ parameterBox = { { 0, 1 }, { 0, 1 }, { 0.25, 0.75 }, { 0, 1 } }, requireComplete = true }
			)
			assert(
				r.componentCount == 1
					and #r.cells == 3
					and r.cells[3].kind == "band"
					and r.cells[3].parameterDimension == 2
			)
			assert(r.components[1].parameterDimension == 2)
			local irrational = false
			for _, e in r.events do
				if e.feasible and not e.profile.exact then
					irrational = true
				end
			end
			assert(irrational)
		end
	)
	test("Two spatially coincident coplanar bands remain distinct parameter components", function()
		local r = query(
			surface({ 2, -2, 2 }, { 0, 0, 0 }),
			nil,
			{ parameterBox = { { 0, 1 }, { 0, 1 }, { 0.5, 1 }, { 0, 1 } } }
		)
		assert(r.complete and r.componentCount == 2 and #r.cells == 6)
		for _, c in r.components do
			assert(c.parameterDimension == 2)
		end
	end)
	test("A coplanar band closes to one exact point at its apex", function()
		local a = E.NURBS.surface({ { V(0, 1, 0), V(1, 0, 0) }, { V(1, 2, 0), V(2, 1, 0) } }, 1, 1)
		local r = query(a)
		assert(r.complete and r.componentCount == 1 and #r.cells == 3 and #r.vertices == 3)
		local f = fiberAt(r, R.number(0.5))
		assert(f and R.equal(f[1], R.number(0.5)) and R.equal(f[1], f[2]))
	end)
	test("A coplanar graph can attach to a band through a collapsed spatial ruling", function()
		local a = E.NURBS.surface({ { V(0, 0, 0), V(0, -1, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
		local r = query(a)
		assert(
			r.complete and #r.cells == 5 and r.componentCount == 1 and r.components[1].parameterDimension == 2
		)
		assert(fiberAt(r, R.number(0.25)).dimension == 0 and fiberAt(r, R.number(0.75)).dimension == 1)
	end)
	test("A constant spatial surface preserves its full two-dimensional parameter domain", function()
		local a = patch(V(0.5, 0.5, 0), V(0, 0, 0), V(0, 0, 0))
		local r = query(a)
		assert(r.complete and #r.cells == 3 and r.components[1].parameterDimension == 2)
		for _, v in r.vertices do
			assert(v.position == V(0.5, 0.5, 0))
		end
	end)
	test("Closed boundary tangencies can reduce the entire contact set to one corner point", function()
		local a = E.NURBS.surface({ { V(-1, 0, 0), V(-1, -1, 0) }, { V(0, 0, 0), V(0, -1, 0) } }, 1, 1)
		local r = query(a)
		assert(r.complete and #r.cells == 1 and r.cells[1].parameterDimension == 0 and #r.vertices == 1)
		assert(r.vertices[1].parameters[1] == 1 and r.vertices[1].parameters[2] == 0)
	end)
	test("Near-exterior coplanar surfaces are excluded by exact signs, regardless of tolerance", function()
		local a = patch(V(-2 ^ -80, 0, 0), V(0, 1, 0), V(0, 0, 0))
		local r = query(a, nil, { tolerance = 1 })
		assert(r.complete and #r.cells == 0 and r.componentCount == 0)
	end)
	test("Closely separated cylinder rulings remain distinct below parameter tolerance", function()
		local r = query(surface({ 0, 0.5, 1 }, { 2 ^ -79, -3 * 2 ^ -41, 1 }))
		assert(r.complete and #r.cells == 2 and r.componentCount == 2)
		local a, b = r.cells[1].profile, r.cells[2].profile
		assert(R.compare(a.high, b.low) < 0 and R.compare(b.high, R.number(2 ^ -38)) < 0)
	end)
	test("Both ruling directions preserve original uA/vA coordinate order", function()
		local a = saddle()
		local r = query(a, nil, { linearAxis = "U" })
		assert(r.complete and r.linearAxis == 1 and r.profileAxis == 2 and #r.cells == 5)
		for _, v in r.vertices do
			assert(v.position.X == v.parameters[1] and v.position.Y == v.parameters[2])
		end
	end)
	test("Nonclamped raw domains retain exact normalized surface coordinates", function()
		local a = surface({ 0, 0.5, 1 }, { 0, -0.5, -1 }, 1, {
			clampedU = false,
			clampedV = false,
			knotsU = { -2, -1, 0, 1, 2, 3 },
			knotsV = { -5, -3, 7, 10 },
		})
		local r = query(a)
		assert(r.complete and #r.vertices == 2)
		assert(r.vertices[1].parameters[1] == 0 and r.vertices[1].parameters[2] == 0.25)
		assert(r.vertices[2].parameters[1] == 1 and r.vertices[2].parameters[2] == 0.75)
	end)
	test("Repeated profile knots share one exceptional ruling and its crossing vertex", function()
		local rows = {}
		for _, x in { 0, 0.25, 0.5, 0.75, 1 } do
			table.insert(rows, { V(x, 0, -0.5 * (x - 0.5)), V(x, 1, 0.5 * (x - 0.5)) })
		end
		local a = E.NURBS.surface(rows, 2, 1, { knotsU = { 0, 0, 0, 0.5, 0.5, 1, 1, 1 } })
		local r = query(a)
		assert(
			r.complete and #r.cells == 5 and #r.events == 3 and #r.events[2].spans == 2 and #r.vertices == 5
		)
	end)
	test("A coplanar span and noncoplanar neighbor share the closed knot fiber", function()
		local a = E.NURBS.surface(
			{ { V(0, 0, 0), V(0, 1, 0) }, { V(0.5, 0, 0), V(0.5, 1, 0) }, { V(1, 0, 1), V(1, 1, 1) } },
			1,
			1
		)
		local r = query(a)
		assert(
			r.complete and #r.cells == 3 and r.componentCount == 1 and r.components[1].parameterDimension == 2
		)
		assert(#r.events[2].spans == 2)
	end)
	test(
		"Cyclic profile seams retain distinct closed representatives and continuous parameter components",
		function()
			local rows = {}
			for _, p in { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) } do
				table.insert(rows, { p - V(0, 0, 1), p + V(0, 0, 1) })
			end
			local a = E.Cyclic.surface(rows, 1, 1, { cyclicU = true, cyclicV = false })
			local r = query(a, patch(V(-2, -2, 0), V(4, 0, 0), V(0, 4, 0)))
			assert(
				r.complete
					and #r.cells == 9
					and #r.events == 5
					and r.componentCount == 1
					and not r.periodicQuotient.requested
			)
			assert(
				r.vertices[1].position == r.vertices[#r.vertices].position
					and r.vertices[1].parameters[1] ~= r.vertices[#r.vertices].parameters[1]
			)
		end
	)
	test("Restricted profile and ruling ranges retain their closed boundaries", function()
		local r = query(
			surface({ 0, 0.5, 1 }, { 0, 0, -1 }, 1),
			nil,
			{ parameterBox = { { 0.25, 0.75 }, { 0.25, 0.5 }, { 0, 1 }, { 0, 1 } } }
		)
		assert(r.complete and r.componentCount == 1)
		assert(not fiberAt(r, R.number(0.25)) and fiberAt(r, R.number(0.5)))
	end)
	test("Tilted patches and extreme native scales preserve the exact contact complex", function()
		for _, scale in { 2 ^ -70, 2 ^ 70 } do
			local a = saddle()
			local o = V(4, -2, 1) * scale
			local u, v, n = V(1, 2, 0) * scale, V(0, 1, 2) * scale, V(4, -2, 1) * scale
			local rows = {}
			for i, row in a.control do
				rows[i] = {}
				for j, p in row do
					rows[i][j] = o + u * p.X + v * p.Y + n * p.Z
				end
			end
			local r = query(E.NURBS.surface(rows, 1, 1), patch(o, u, v), { tolerance = scale * 1e-4 })
			assert(r.complete and r.componentCount == 1 and r.components[1].parameterDimension == 1)
			for _, x in { 0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1 } do
				local f = fiberAt(r, R.number(x))
				local low, high = x == 0.5 and 0 or 0.5, x == 0.5 and 1 or 0.5
				assert(f and R.equal(f[1], R.number(low)) and R.equal(f[2], R.number(high)))
			end
			for _, vertex in r.vertices do
				verifyExact(vertex)
			end
		end
	end)
	test("Native anchor accuracy remains separate from exact coverage and component certificates", function()
		local a = E.NURBS.surface({ { V(0, 0, 0), V(0, 1, 1) }, { V(1, 0, -3), V(1, 1, -2) } }, 1, 1)
		local r = query(a, nil, { tolerance = 1e-12, requireComponents = true })
		assert(
			r.rootCoverageComplete
				and r.parameterComponentsCertified
				and not r.complete
				and r.reason == "approximation"
		)
		assert(not pcall(query, a, nil, { tolerance = 1e-12, requireComplete = true }))
	end)
	test("Ruled input, plane and nested query settings are detached before callbacks", function()
		local a, b = saddle(), unit()
		local options = { method = "exactRuled", parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 } } }
		options.checkpoint = function()
			a.control[1][1] = V(9, 9, 9)
			b.control[2][2] = V(9, 9, 9)
			options.parameterBox[1][1] = 1
		end
		local r = E.SplineQuery.intersectSurfaces(a, b, options)
		assert(r.complete and #r.cells == 5)
	end)
	test(
		"Unsupported ruling directions and nonaffine or collapsed second patches reject explicitly",
		function()
			local a = saddle()
			local b = unit()
			b.control[2][2] = V(1, 1, 2 ^ -90)
			assert(not pcall(query, a, b))
			b = unit()
			b.weights[1][1] = 2
			assert(not pcall(query, a, b))
			assert(not pcall(query, a, patch(V(0, 0, 0), V(1, 0, 0), V(2, 0, 0))))
			assert(not pcall(query, surface({ 0, 0.5, 1 }, { 0, 0, -1 }, 1), nil, { linearAxis = "U" }))
			assert(not pcall(query, a, nil, { orderComponents = true }))
		end
	)
	test(
		"Event, cell, vertex, snapshot, coefficient, arithmetic and search budgets are hard limits",
		function()
			for name, value in
				{
					maxEvents = 1,
					maxVertices = 1,
					maxSnapshotEntries = 1,
					maxControls = 1,
					maxCoefficients = 1,
					maxExactBits = 1,
					maxWork = 1,
					maxPolynomialDegree = 1,
				}
			do
				assert(
					not pcall(query, surface({ 0, 0.5, 1 }, { 0.25, -0.25, 0.25 }), nil, { [name] = value }),
					"Missing budget " .. name
				)
			end
			assert(not pcall(query, saddle(), nil, { maxCells = 1 }))
			local a = surface({ 0, 0, 1 }, { 0, 0, 0 })
			local ranges = { { 0, 1 }, { 0, 1 }, { 0.25, 0.75 }, { 0, 1 } }
			for name, value in { maxDepth = 0, maxNodes = 1 } do
				assert(not pcall(query, a, nil, { parameterBox = ranges, [name] = value }))
			end
			local multi = E.NURBS.surface(
				{ { V(0, 0, 0), V(0, 1, 0) }, { V(0.5, 0, 0), V(0.5, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } },
				1,
				1
			)
			assert(not pcall(query, multi, nil, { maxPieces = 1 }))
		end
	)
	test(
		"Cancellation, callback errors and cyclic option snapshots cannot produce partial success",
		function()
			local calls = 0
			local ok, err = pcall(query, saddle(), nil, {
				cancelled = function()
					calls += 1
					return calls > 4
				end,
			})
			assert(not ok and string.find(tostring(err), "cancelled") and calls > 4)
			local token = {}
			local passed, message = pcall(query, saddle(), nil, {
				checkpoint = function(state)
					if state.stage == "work" then
						error(token)
					end
				end,
			})
			assert(not passed and message == token)
			local options = { method = "exactRuled" }
			options.self = options
			assert(not pcall(E.SplineQuery.intersectSurfaces, saddle(), unit(), options))
		end
	)
	test("Exact contact anchors and parameter data survive typed mesh serialization", function()
		local r = query(saddle())
		local m = E.Mesh.new()
		local corners = {}
		for _, index in { 1, 2, 3 } do
			local v = r.vertices[index]
			m:addVertex(v.position)
			table.insert(corners, { uv = Vector2.new(v.parameters[1], v.parameters[2]) })
		end
		m:addFace({ 1, 2, 3 }, corners)
		local copy = E.IO.decode(E.IO.encode(m))
		for i = 1, 3 do
			assert(copy.vertices[i] == m.vertices[i] and copy.faces[1].corners[i].uv == corners[i].uv)
		end
	end)
	if not (settings and settings.skipNative) then
		test("Tangent ruling anchors and source parameters survive native EditableMesh conversion", function()
			local r = query(surface({ 0, 0.5, 1 }, { 0.25, -0.25, 0.25 }))
			local m = E.Mesh.new()
			local corners = {}
			for i, v in r.vertices do
				m:addVertex(v.position)
				corners[i] = { uv = Vector2.new(v.parameters[1], v.parameters[2]), normal = V(0, 0, 1) }
			end
			m:addVertex(V(1, 0.5, 0))
			corners[3] = { uv = Vector2.new(1, 0.5), normal = V(0, 0, 1) }
			m:addFace({ 1, 2, 3 }, corners)
			local handle = E.Roblox.toEditable(m)
			local ok, err = pcall(function()
				local copy = E.Roblox.fromEditable(handle.editable)
				local found = 0
				for _, face in copy.faces do
					for _, corner in face.corners do
						if corner.uv == Vector2.new(0.5, 0) or corner.uv == Vector2.new(0.5, 1) then
							found += 1
							assert(corner.normal.Z > 0.99)
						end
					end
				end
				assert(found == 2)
				for _, v in r.vertices do
					local present = false
					for _, p in copy.vertices do
						if (p + handle.origin - v.position).Magnitude < 1e-6 then
							present = true
						end
					end
					assert(present)
				end
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
