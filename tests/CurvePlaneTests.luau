return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local R = require(script.Parent.ExactRational)(function() end, 8192)
	local V = Vector3.new
	local function patch(o, u, v, options)
		return E.NURBS.surface({ { o, o + v }, { o + u, o + u + v } }, 1, 1, options)
	end
	local function unit()
		return patch(V(0, 0, 0), V(1, 0, 0), V(0, 1, 0))
	end
	local function curve(points, degree, options)
		return E.NURBS.curve(points, degree or #points - 1, options)
	end
	local function query(c, s, options)
		options = U.copy(options or {})
		options.method = "exactPlane"
		return E.SplineQuery.intersectCurveSurface(c, s or unit(), options)
	end
	local function rationalInside(box, x)
		assert(
			R.compare(R.number(box[1]), x) <= 0 and R.compare(R.number(box[2]), x) >= 0,
			"Rational escaped native enclosure"
		)
	end
	local function verifyExact(vertex)
		assert(vertex.certified and vertex.unique)
		if not vertex.positionExact then
			return
		end
		local square = R.number(0)
		for i, name in { "X", "Y", "Z" } do
			rationalInside(vertex.positionBox[i], vertex.positionExact[i])
			rationalInside(vertex.parameterBox[i], vertex.parametersExact[i])
			local d = R.sub(vertex.positionExact[i], R.number(vertex.position[name]))
			square = R.add(square, R.mul(d, d))
		end
		assert(
			R.compare(square, R.mul(R.number(vertex.errorBound), R.number(vertex.errorBound))) <= 0,
			"Underestimated native position error"
		)
	end
	test("320 independent raw-knot de Boor values equal exact homogeneous span powers", function()
		local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.CurvePowerFixtures))
		local P = require(script.Parent.ExactPolynomialRoots)(R, function() end, 96)
		local extract = require(script.Parent.ExactCurvePower)
		local function exact(x)
			return R.fraction(x.sign, x.n, x.d)
		end
		for _, fixture in fixtures do
			local points = {}
			for i, p in fixture.points do
				points[i] = V(table.unpack(p))
			end
			local c = curve(
				points,
				fixture.degree,
				{ weights = fixture.weights, knots = fixture.knots, clamped = fixture.clamped }
			)
			local spans =
				extract(c, R, P, { visit = function() end, allocate = function() end, maxPieces = 100 })
			assert(#spans == #fixture.spans)
			for i, expected in fixture.spans do
				local span = spans[i]
				assert(
					span.index == expected.index
						and R.equal(span.offset, exact(expected.offset))
						and R.equal(span.scale, exact(expected.scale))
				)
				for _, sample in expected.samples do
					for axis = 1, 4 do
						assert(R.equal(P.evaluate(span.h[axis], R.number(sample.x)), exact(sample.h[axis])))
					end
				end
			end
		end
	end)
	test("64 independent weighted Bernstein references retain closed contacts and orders", function()
		local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.CurvePlaneFixtures))
		for index, fixture in fixtures do
			local points = {}
			for i, p in fixture.points do
				points[i] = V(table.unpack(p))
			end
			local c = curve(points, fixture.degree, { weights = fixture.weights, knots = fixture.knots })
			local plane = patch(
				V(table.unpack(fixture.plane[1])),
				V(table.unpack(fixture.plane[2])),
				V(table.unpack(fixture.plane[3]))
			)
			local r = query(c, plane, { maxWork = 200000000, requireComplete = true })
			assert(#r.roots == #fixture.roots and #r.overlaps == 0, "Reference curve root count " .. index)
			for i, expected in fixture.roots do
				local vertex = r.roots[i]
				assert(
					vertex.parameter.t == expected.t and vertex.contacts[1].order == expected.order,
					"Reference curve root/order " .. index
				)
				assert(vertex.parameter.u == fixture.u and vertex.parameter.v == fixture.v)
				assert(vertex.position == V(table.unpack(expected.position)))
				verifyExact(vertex)
			end
		end
	end)
	test("Transverse curve/plane contact is unique with exact stored-bit parameter", function()
		local r = query(curve({ V(0.5, 0.5, -1), V(0.5, 0.5, 1) }))
		assert(r.complete and r.rootCoverageComplete and #r.roots == 1 and #r.overlaps == 0)
		assert(r.roots[1].contacts[1].order == 1 and r.roots[1].parameter.t == 0.5)
		verifyExact(r.roots[1])
	end)
	test("Even tangency and odd stationary crossing retain their analytic contact orders", function()
		for _, case in { { 1, -1, 1 }, { -1, 1, -1, 1 }, { 1, -1, 1, -1, 1 } } do
			local points = {}
			for _, z in case do
				table.insert(points, V(0.5, 0.5, z))
			end
			local r = query(curve(points))
			assert(r.complete and #r.roots == 1 and r.roots[1].contacts[1].order == #case - 1)
			assert(r.roots[1].parameter.t == 0.5)
			verifyExact(r.roots[1])
		end
	end)
	test("All four exact corners and four edges retain closed patch contacts", function()
		for _, xy in
			{ { 0, 0 }, { 0, 1 }, { 1, 0 }, { 1, 1 }, { 0, 0.5 }, { 1, 0.5 }, { 0.5, 0 }, { 0.5, 1 } }
		do
			local r = query(curve({ V(xy[1], xy[2], 1), V(xy[1], xy[2], -1), V(xy[1], xy[2], 1) }))
			assert(
				r.complete
					and #r.roots == 1
					and #r.roots[1].activeBounds == ((xy[1] == 0.5 or xy[2] == 0.5) and 1 or 2)
			)
			verifyExact(r.roots[1])
		end
	end)
	test("Roots outside the patch remain excluded regardless of proximity tolerance", function()
		local r = query(curve({ V(-2 ^ -100, 0.5, -1), V(-2 ^ -100, 0.5, 1) }), nil, { tolerance = 1 })
		assert(r.complete and #r.roots == 0 and #r.vertices == 0)
	end)
	test("Closed t-domain endpoints and a clipped t/u/v corner are retained", function()
		local c = curve({ V(0, 0.5, 0), V(0.5, 0.5, 1), V(1, 0.5, 0) })
		local r = query(c)
		assert(#r.roots == 2 and r.roots[1].parameter.t == 0 and r.roots[2].parameter.t == 1)
		local a = query(
			curve({ V(0, 0.5, -1), V(1, 0.5, 1) }),
			nil,
			{ parameterBox = { { 0.5, 1 }, { 0.5, 1 }, { 0.5, 1 } } }
		)
		assert(#a.roots == 1 and a.roots[1].parameter.t == 0.5 and #a.roots[1].activeBounds == 2)
	end)
	test(
		"Sub-tolerance overlaps at either closed domain endpoint retain their full parameter interval",
		function()
			local delta = R.number(2 ^ -80)
			local denominator = R.add(R.number(1), delta)
			for _, reverse in { false, true } do
				local points = { V(2 ^ -80, 0.5, 0), V(-1, 0.5, 0) }
				if reverse then
					points = { points[2], points[1] }
				end
				local expected = R.div(reverse and R.number(1) or delta, denominator)
				for _, parameterTolerance in { 1e-3, 1e-7 } do
					local r = query(
						curve(points),
						nil,
						{ parameterTolerance = parameterTolerance, maxIterations = 0, requireComplete = true }
					)
					assert(#r.vertices == 2 and #r.overlaps == 1 and #r.roots == 0 and r.componentCount == 1)
					assert(r.components[1].parameterDimension == 1 and r.parameterTopologyCertified)
					local endpoint = r.vertices[reverse and 2 or 1]
					local boundary = r.vertices[reverse and 1 or 2]
					assert(R.equal(endpoint.parametersExact[1], R.number(reverse and 1 or 0)))
					local isolated = boundary.algebraic
					assert(R.compare(isolated.low, expected) <= 0 and R.compare(isolated.high, expected) >= 0)
					assert(
						R.compare(isolated.low, R.number(0)) > 0 and R.compare(isolated.high, R.number(1)) < 0
					)
					assert(r.overlaps[1].first == 1 and r.overlaps[1].last == 2)
				end
			end
		end
	)
	test("Endpoint-gap proof limits reject instead of collapsing a short overlap to one point", function()
		for _, points in { { V(2 ^ -80, 0.5, 0), V(-1, 0.5, 0) }, { V(-1, 0.5, 0), V(2 ^ -80, 0.5, 0) } } do
			for name, value in { maxDepth = 32, maxNodes = 32 } do
				assert(not pcall(query, curve(points), nil, { parameterTolerance = 1e-3, [name] = value }))
			end
		end
	end)
	test("An irrational plane root shared with a boundary is certified by exact algebra", function()
		local c = curve(
			{ V(-1, 0.5, -1), V(-0.5, 0.5, -0.5), V(0.25, 0.5, 0.25) },
			2,
			{ weights = { 1, 2, 4 } }
		)
		local r = query(c, nil, { requireComplete = true })
		assert(#r.roots == 1 and not r.roots[1].algebraic.exact and r.roots[1].activeBounds[1] == "uMin")
		assert(r.roots[1].parameterBox[2][1] == 0 and r.roots[1].parameterBox[2][2] == 0)
		assert(r.roots[1].parameterBox[1][1] ^ 2 < 0.5 and r.roots[1].parameterBox[1][2] ^ 2 > 0.5)
	end)
	test("Near shared irrational constraints distinguish inside and outside exactly", function()
		for _, offset in { -2 ^ -23, 2 ^ -23 } do
			local r = query(
				curve({ V(-1 + offset, 0.5, -1), V(-1 + offset, 0.5, -1), V(1 + offset, 0.5, 1) }),
				nil,
				{ parameterTolerance = 1e-3 }
			)
			assert(r.complete and #r.roots == (offset > 0 and 1 or 0))
		end
	end)
	test("A coincident line clips to an exact rational arc with algebraic endpoints", function()
		local r = query(curve({ V(-1, 0.5, 0), V(2, 0.5, 0) }))
		assert(
			r.complete and #r.roots == 0 and #r.vertices == 2 and #r.overlaps == 1 and r.componentCount == 1
		)
		assert(r.components[1].parameterDimension == 1 and r.parameterTopologyCertified)
		for i, v in r.vertices do
			rationalInside(v.parameterBox[1], R.div(R.number(i), R.number(3)))
		end
		assert(r.overlaps[1].parameterDimension == 1 and r.overlaps[1].homogeneousExact)
	end)
	test("Coplanar quadratic clips at two distinct irrational patch boundaries", function()
		local r = query(curve({ V(-1, 0.5, 0), V(-1, 0.5, 0), V(2, 0.5, 0) }))
		assert(r.complete and #r.overlaps == 1 and #r.roots == 0 and #r.vertices == 2)
		for i, v in r.vertices do
			assert(
				not v.algebraic.exact
					and v.parameterBox[1][1] ^ 2 < i / 3
					and v.parameterBox[1][2] ^ 2 > i / 3
			)
		end
	end)
	test("A coplanar exterior double boundary touch is an isolated point", function()
		local r = query(curve({ V(-1, 0.5, 0), V(1, 0.5, 0), V(-1, 0.5, 0) }))
		assert(r.complete and #r.roots == 1 and #r.overlaps == 0 and r.roots[1].parameter.t == 0.5)
		assert(r.roots[1].contacts[1].planeIdentity and r.roots[1].contacts[1].order == 0)
	end)
	test("A coplanar exterior irrational repeated boundary touch is retained", function()
		local r = query(curve({ V(-6, 0.5, 0), V(-6, 0.5, 0), V(-2, 0.5, 0), V(6, 0.5, 0), V(-6, 0.5, 0) }))
		assert(r.complete and #r.roots == 1 and #r.overlaps == 0 and not r.roots[1].algebraic.exact)
	end)
	test("A coplanar interior boundary touch joins both incident rational arcs", function()
		local r = query(
			curve({ V(3, 0.5, 0), V(3, 0.5, 0), V(1, 0.5, 0), V(-3, 0.5, 0), V(3, 0.5, 0) }),
			patch(V(0, 0, 0), V(3, 0, 0), V(0, 1, 0))
		)
		assert(
			r.complete and #r.roots == 0 and #r.overlaps == 2 and #r.vertices == 3 and r.componentCount == 1
		)
		assert(#r.vertices[2].edgeIndices == 2 and r.vertices[2].activeBounds[1] == "uMin")
	end)
	test("A constant coplanar curve remains a one-dimensional parameter component", function()
		local r =
			query(curve({ V(0.5, 0.5, 0), V(0.5, 0.5, 0), V(0.5, 0.5, 0) }, 2, { weights = { 1, 2, 4 } }))
		assert(r.complete and #r.overlaps == 1 and r.components[1].parameterDimension == 1)
		assert(r.vertices[1].position == r.vertices[2].position and #r.roots == 0)
	end)
	test("Shared B-spline knot contacts are deduplicated with per-span orders", function()
		local r = query(
			curve({ V(0.5, 0.5, 1), V(0.5, 0.5, 0), V(0.5, 0.5, -1) }, 1, { knots = { -3, -3, 1, 5, 5 } })
		)
		assert(r.complete and #r.roots == 1 and #r.roots[1].contacts == 2 and r.roots[1].parameter.t == 0.5)
		local repeated = query(
			curve(
				{ V(0.5, 0.5, 1), V(0.5, 0.5, 0), V(0.5, 0.5, 0), V(0.5, 0.5, 0), V(0.5, 0.5, 1) },
				2,
				{ knots = { 0, 0, 0, 0.5, 0.5, 1, 1, 1 } }
			)
		)
		assert(repeated.complete and #repeated.roots == 1 and #repeated.roots[1].contacts == 2)
		for _, contact in repeated.roots[1].contacts do
			assert(contact.order == 2)
		end
	end)
	test("Coincident spans join across knots and absorb an adjacent isolated plane endpoint", function()
		local r =
			query(curve({ V(0, 0.5, -1), V(0.25, 0.5, 0), V(0.5, 0.5, 0), V(0.75, 0.5, 0), V(1, 0.5, 1) }, 1))
		assert(
			r.complete and #r.roots == 0 and #r.overlaps == 2 and #r.vertices == 3 and r.componentCount == 1
		)
		assert(#r.vertices[1].contacts == 2 and #r.vertices[3].contacts == 2)
	end)
	test("Disconnected overlap portions remain separate parameter components", function()
		local r = query(curve({ V(0.5, 0.5, 0), V(2, 0.5, 0), V(0.5, 0.5, 0) }, 1))
		assert(r.complete and #r.overlaps == 2 and r.componentCount == 2 and #r.roots == 0)
	end)
	test("Nonclamped raw knot domains preserve normalized affine and curve parameters", function()
		local c = curve(
			{ V(0.5, 0.5, -1), V(0.5, 0.5, 1) },
			1,
			{ clamped = false, knots = { -7, -3, 5, 11 } }
		)
		local s = patch(
			V(0, 0, 0),
			V(1, 0, 0),
			V(0, 1, 0),
			{ clampedU = false, clampedV = false, knotsU = { -2, -1, 3, 4 }, knotsV = { -5, -3, 7, 13 } }
		)
		local r = query(c, s)
		assert(
			r.complete and #r.roots == 1 and r.roots[1].parameter.t == 0.5 and r.roots[1].parameter.u == 0.5
		)
	end)
	test("Cyclic curves keep the two closed seam parameter endpoints distinct", function()
		local c = E.Cyclic.curve({ V(0, 0, 0), V(1, 0, 0), V(1, 1, 0), V(0, 1, 0) }, 1)
		local r = query(c)
		assert(
			r.complete and #r.roots == 0 and r.componentCount == 1 and #r.overlaps == 4 and #r.vertices == 5
		)
		assert(
			r.vertices[1].position == r.vertices[#r.vertices].position and not r.periodicQuotient.requested
		)
	end)
	test("Oblique and reflected rank-two patches preserve exact contact parameters", function()
		for _, axes in
			{ { { 1, 2, 0 }, { 0, 1, 2 } }, { { 0, 2, 0 }, { 0, 0, -3 } }, { { 2, 0, 1 }, { 0, -2, 1 } } }
		do
			local o = V(3, -2, 1)
			local a, b = V(table.unpack(axes[1])), V(table.unpack(axes[2]))
			local p = o + a * 0.25 + b * 0.75
			local n = a:Cross(b)
			local r = query(curve({ p - n, p + n }), patch(o, a, b))
			assert(
				r.complete
					and #r.roots == 1
					and r.roots[1].parameter.u == 0.25
					and r.roots[1].parameter.v == 0.75
			)
			verifyExact(r.roots[1])
		end
	end)
	test("Exact curve-plane decisions survive small and large native coordinate scales", function()
		for _, scale in { 2 ^ -80, 2 ^ 80 } do
			local r = query(
				curve({
					V(scale / 2, scale / 2, scale),
					V(scale / 2, scale / 2, -scale),
					V(scale / 2, scale / 2, scale),
				}),
				patch(V(0, 0, 0), V(scale, 0, 0), V(0, scale, 0)),
				{ tolerance = scale * 1e-5 }
			)
			assert(r.complete and #r.roots == 1 and r.roots[1].contacts[1].order == 2)
			verifyExact(r.roots[1])
		end
	end)
	test("Topology coverage remains explicit when a native endpoint misses requested accuracy", function()
		local c = curve({ V(0, 0.5, -1), V(1, 0.5, 2) })
		local r = query(c, nil, { tolerance = 1e-12 })
		assert(
			r.rootCoverageComplete
				and r.parameterTopologyCertified
				and not r.complete
				and r.reason == "approximation"
				and #r.roots == 1
		)
		assert(not pcall(query, c, nil, { tolerance = 1e-12, requireComplete = true }))
	end)
	test("Callbacks observe detached curve, patch and nested option snapshots", function()
		local c = curve({ V(0.5, 0.5, -1), V(0.5, 0.5, 1) })
		local s = unit()
		local options = { parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 } } }
		options.method = "exactPlane"
		options.checkpoint = function()
			c.points[1] = V(9, 9, 9)
			s.control[1][1] = V(9, 9, 9)
			options.parameterBox[1][1] = 1
		end
		local r = E.SplineQuery.intersectCurveSurface(c, s, options)
		assert(r.complete and #r.roots == 1 and r.roots[1].parameter.t == 0.5)
	end)
	test("Unsupported nonaffine, varying-weight and collapsed patches are rejected", function()
		local c = curve({ V(0.5, 0.5, -1), V(0.5, 0.5, 1) })
		local s = unit()
		s.control[2][2] = V(1, 1, 2 ^ -100)
		assert(not pcall(query, c, s))
		s = unit()
		s.weights[2][2] = 2
		assert(not pcall(query, c, s))
		assert(not pcall(query, c, patch(V(0, 0, 0), V(1, 0, 0), V(2, 0, 0))))
		assert(not pcall(E.SplineQuery.intersectCurveSurface, c, unit(), { method = "misspelled" }))
	end)
	test(
		"Snapshots, controls, spans, roots, degree, coefficients, exact bits and work are bounded",
		function()
			local c = curve({ V(-1, 0.5, 0), V(-1, 0.5, 0), V(2, 0.5, 0) })
			for name, value in
				{
					maxSnapshotEntries = 1,
					maxControls = 2,
					maxRoots = 1,
					maxPolynomialDegree = 1,
					maxCoefficients = 1,
					maxExactBits = 1,
					maxWork = 1,
					maxDepth = 0,
					maxNodes = 1,
				}
			do
				assert(not pcall(query, c, nil, { [name] = value }), "Missing hard cap " .. name)
			end
			local multi = curve({ V(0.5, 0.5, -1), V(0.5, 0.5, 0), V(0.5, 0.5, 1) }, 1)
			assert(not pcall(query, multi, nil, { maxPieces = 1 }))
			local settingsCycle = {}
			settingsCycle.self = settingsCycle
			settingsCycle.method = "exactPlane"
			assert(not pcall(E.SplineQuery.intersectCurveSurface, c, unit(), settingsCycle))
		end
	)
	test("Cancellation and callback errors propagate during exact arithmetic", function()
		local c = curve({ V(-1, 0.5, 0), V(-1, 0.5, 0), V(2, 0.5, 0) })
		local calls = 0
		local ok, err = pcall(query, c, nil, {
			cancelled = function()
				calls += 1
				return calls > 5
			end,
		})
		assert(not ok and string.find(tostring(err), "cancelled") and calls > 5)
		local token = {}
		local passed, message = pcall(query, c, nil, {
			checkpoint = function(state)
				if state.stage == "work" then
					error(token)
				end
			end,
		})
		assert(not passed and message == token)
	end)
	test("Contact positions and parameters survive mesh typed data roundtrip", function()
		local r = query(curve({ V(0, 0.5, 0), V(0.5, 0.5, 1), V(1, 0.5, 0) }))
		local mesh = E.Mesh.new()
		local corners = {}
		for i, root in r.roots do
			mesh:addVertex(root.position)
			corners[i] = { uv = Vector2.new(root.parameter.t, root.parameter.u) }
		end
		mesh:addVertex(V(0.5, 1, 0))
		corners[3] = { uv = Vector2.new(0.5, 0.5) }
		mesh:addFace({ 1, 2, 3 }, corners)
		local restored = E.IO.decode(E.IO.encode(mesh))
		for i = 1, 2 do
			assert(
				restored.vertices[i] == r.roots[i].position
					and restored.faces[1].corners[i].uv == corners[i].uv
			)
		end
	end)
	if not (settings and settings.skipNative) then
		test("Certified contact vertices survive native EditableMesh conversion", function()
			local r = query(curve({ V(0, 0.5, 0), V(0.5, 0.5, 1), V(1, 0.5, 0) }))
			local m = E.Mesh.new()
			for _, root in r.roots do
				m:addVertex(root.position)
			end
			m:addVertex(V(0.5, 1, 0))
			m:addFace({ 1, 2, 3 })
			local handle = E.Roblox.toEditable(m)
			local restored = E.Roblox.fromEditable(handle.editable)
			local count = 0
			for _, p in restored.vertices do
				if
					(p + handle.origin - V(0, 0.5, 0)).Magnitude < 1e-6
					or (p + handle.origin - V(1, 0.5, 0)).Magnitude < 1e-6
				then
					count += 1
				end
			end
			handle.editable:Destroy()
			assert(count == 2)
		end)
	end
	report.success = report.failed == 0
	return report
end
