return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local I = require(script.Parent.DirectedInterval)
	local makeR = require(script.Parent.ExactRational)
	local R = makeR(function() end, 8192)
	local H = game:GetService("HttpService")
	local fixtures = H:JSONDecode(require(script.Parent.AffineContactFixtures))
	local V = Vector3.new
	local function same(a, b)
		if type(a) ~= "table" then
			return a == b
		end
		if type(b) ~= "table" then
			return false
		end
		for k, value in a do
			if not same(value, b[k]) then
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
	local function patch(o, u, v, options)
		return E.NURBS.surface({ { o, o + v }, { o + u, o + u + v } }, 1, 1, options)
	end
	local function fromData(data)
		return patch(V(table.unpack(data[1])), V(table.unpack(data[2])), V(table.unpack(data[3])))
	end
	local function unit()
		return patch(V(0, 0, 0), V(1, 0, 0), V(0, 1, 0))
	end
	local function query(a, b, options)
		options = U.copy(options or {})
		options.method = "exactAffine"
		return E.SplineQuery.intersectSurfaces(a, b, options)
	end
	local function rotated()
		return patch(V(0.5, -0.25, 0), V(0.75, 0.75, 0), V(-0.75, 0.75, 0))
	end
	local function thirds()
		return patch(V(0, 0, -1), V(1, 0, 3), V(0, 1, 0))
	end
	local function verifyVertex(vertex)
		local square = R.number(0)
		for axis, name in { "X", "Y", "Z" } do
			local exact = vertex.positionExact[axis]
			assert(R.compare(R.number(vertex.positionBox[axis][1]), exact) <= 0)
			assert(R.compare(R.number(vertex.positionBox[axis][2]), exact) >= 0)
			local delta = R.sub(exact, R.number(vertex.position[name]))
			square = R.add(square, R.mul(delta, delta))
		end
		local bound = R.number(vertex.errorBound)
		assert(R.compare(square, R.mul(bound, bound)) <= 0, "Native point error underestimated")
		for axis, exact in vertex.parametersExact do
			assert(R.compare(R.number(vertex.parameterBox[axis][1]), exact) <= 0)
			assert(R.compare(R.number(vertex.parameterBox[axis][2]), exact) >= 0)
		end
	end
	test("72 independent Cramer/minor references cover 185 exact affine vertices", function()
		local vertices = 0
		for _, row in fixtures.rows do
			local result = query(fromData(row.a), fromData(row.b), {
				parameterBox = row.bounds,
				tolerance = 2 ^ 100,
				requireComplete = true,
				requireComponents = true,
			})
			assert(
				result.rootCoverageComplete
					and result.cellTopologyCertified
					and result.parameterComponentsCertified
			)
			assert(result.componentCount == (#row.vertices == 0 and 0 or 1))
			local cell = result.cells[1]
			if cell then
				assert(
					cell.parameterDimension == row.dimension and cell.spatialDimension == row.spatialDimension
				)
				assert(#cell.vertices == #row.vertices)
				for _, vertex in cell.vertices do
					local found = false
					for _, expected in row.vertices do
						if same(vertex.parametersExact, expected) then
							found = true
							break
						end
					end
					assert(found, "Exact parameter vertex absent from independent reference")
					verifyVertex(vertex)
					for _, equation in result.affineEquations do
						local lhs = R.number(0)
						for j = 1, 4 do
							lhs = R.add(lhs, R.mul(equation[j], vertex.parametersExact[j]))
						end
						assert(R.equal(lhs, equation[5]))
					end
					vertices += 1
				end
				if cell.spatialDimension == 2 then
					local x, y = table.unpack(cell.spatialProjectionAxes)
					for i, index in cell.spatialBoundary do
						local p = cell.vertices[index].positionExact
						local q =
							cell.vertices[cell.spatialBoundary[i % #cell.spatialBoundary + 1]].positionExact
						for _, vertex in cell.vertices do
							local r = vertex.positionExact
							local cross = R.sub(
								R.mul(R.sub(q[x], p[x]), R.sub(r[y], p[y])),
								R.mul(R.sub(q[y], p[y]), R.sub(r[x], p[x]))
							)
							assert(cross.sign >= 0, "Affine boundary excludes a reference vertex")
						end
					end
				end
			end
		end
		assert(vertices == 185)
	end)
	test("85 rational enclosures remain outward through overflow and FTZ underflow", function()
		local enclose = require(script.Parent.ExactRationalBounds)(R, function() end)
		for _, value in fixtures.enclosures do
			local exact = R.fraction(value.sign, value.n, value.d)
			local before = U.copy(exact)
			local bound = enclose(exact)
			assert(I.leq(bound[1], bound[2]))
			if bound[1] > -math.huge then
				assert(R.compare(R.number(bound[1]), exact) <= 0)
			end
			if bound[2] < math.huge then
				assert(R.compare(R.number(bound[2]), exact) >= 0)
			end
			assert(same(before, exact))
		end
	end)
	test("Corner-only coplanar contact is one exact point", function()
		local r = query(unit(), patch(V(1, 1, 0), V(1, 0, 0), V(0, 1, 0)), { requireComplete = true })
		local c = r.cells[1]
		assert(c.kind == "point" and c.parameterDimension == 0 and #c.vertices == 1)
		assert(c.vertices[1].position == V(1, 1, 0) and #c.vertices[1].activeBounds == 4)
		assert(c.nativeTopologyCertified and c.errorBound == 0)
	end)
	test("Shared boundary edge is retained without interior root padding", function()
		local c = query(unit(), patch(V(1, 0, 0), V(1, 0, 0), V(0, 1, 0))).cells[1]
		assert(c.kind == "segment" and c.parameterDimension == 1 and #c.vertices == 2)
		for _, p in c.vertices do
			assert(p.position.X == 1 and p.position.Z == 0)
		end
	end)
	test("A positive native gap is empty even with a larger approximation tolerance", function()
		local b = patch(V(1 + 2 ^ -23, 0, 0), V(1, 0, 0), V(0, 1, 0))
		local r = query(unit(), b, { tolerance = 10, requireComplete = true })
		assert(r.complete and r.componentCount == 0 and #r.cells == 0 and #r.unresolved == 0)
	end)
	test("Rotated coplanar overlap has an ordered eight-sided boundary and exact area", function()
		local c = query(unit(), rotated(), { requireComplete = true }).cells[1]
		assert(#c.vertices == 8 and #c.spatialBoundary == 8 and #c.parameterBoundary == 8)
		assert(#c.triangles == 6 and c.spatialMapInjective)
		local area = 0
		for _, t in c.triangles do
			local a, b, d = c.vertices[t[1]].position, c.vertices[t[2]].position, c.vertices[t[3]].position
			local cross = (b - a):Cross(d - a)
			assert(cross.Z > 0)
			area += cross.Z * 0.5
		end
		assert(area == 0.875 and c.errorBound == 0)
	end)
	test("Coincident reversed parameterizations preserve every distinct parameter root", function()
		local b = patch(
			V(1, 0, 0),
			V(-1, 0, 0),
			V(0, 1, 0),
			{ weights = { { 2 ^ -500, 2 ^ -500 }, { 2 ^ -500, 2 ^ -500 } } }
		)
		local c = query(unit(), b).cells[1]
		assert(c.parameterDimension == 2 and c.spatialDimension == 2 and #c.vertices == 4)
		for _, p in c.vertices do
			assert(p.parameters[1] + p.parameters[3] == 1 and p.parameters[2] == p.parameters[4])
		end
	end)
	test("Coincident constant patches retain a four-dimensional parameter polytope", function()
		local a = patch(V(0.25, 0.75, 0), V(0, 0, 0), V(0, 0, 0))
		local c = query(a, a).cells[1]
		assert(c.parameterDimension == 4 and c.spatialDimension == 0 and #c.vertices == 16)
		assert(c.parameterBoundary == nil and #c.spatialBoundary == 1 and not c.spatialMapInjective)
		assert(c.surfaceRanks[1] == 0 and c.surfaceRanks[2] == 0)
	end)
	test("A constant patch inside a regular patch has two-dimensional parameter fibers", function()
		local c = query(patch(V(0.25, 0.75, 0), V(0, 0, 0), V(0, 0, 0)), unit()).cells[1]
		assert(c.parameterDimension == 2 and c.spatialDimension == 0 and #c.vertices == 4)
		assert(c.surfaceRanks[1] == 0 and c.surfaceRanks[2] == 2)
	end)
	test("Coincident collapsed ribbons preserve a three-dimensional root relation", function()
		local c =
			query(patch(V(0, 0, 0), V(1, 0, 0), V(2, 0, 0)), patch(V(0, 0, 0), V(2, 0, 0), V(1, 0, 0))).cells[1]
		assert(c.parameterDimension == 3 and c.spatialDimension == 1 and c.parameterBoundary == nil)
		assert(c.surfaceRanks[1] == 1 and c.surfaceRanks[2] == 1 and #c.spatialBoundary == 2)
	end)
	test("Crossing rank-one patches distinguish point geometry from parameter dimension", function()
		local c =
			query(patch(V(0, 0, 0), V(1, 0, 0), V(1, 0, 0)), patch(V(1, -1, 0), V(0, 1, 0), V(0, 1, 0))).cells[1]
		assert(c.kind == "point" and c.parameterDimension == 2 and #c.vertices == 4)
		for _, p in c.vertices do
			assert(p.position == V(1, 0, 0))
		end
	end)
	test("Noncoplanar corner-only contact is certified", function()
		local c = query(unit(), patch(V(1, 1, 0), V(1, 0, 0), V(0, 0, 1))).cells[1]
		assert(c.parameterDimension == 0 and c.spatialDimension == 0 and c.vertices[1].position == V(1, 1, 0))
	end)
	test("Single unclamped spans use the original normalized full domains", function()
		local a = patch(
			V(0, 0, 0),
			V(1, 0, 0),
			V(0, 1, 0),
			{ knotsU = { -5, -2, 3, 9 }, knotsV = { -9, -1, 2, 8 }, clampedU = false, clampedV = false }
		)
		local b = patch(V(0, 0.5, -1), V(1, 0, 0), V(0, 0, 2))
		local c = query(a, b).cells[1]
		assert(
			c.kind == "segment"
				and c.vertices[1].position == V(0, 0.5, 0)
				and c.vertices[2].position == V(1, 0.5, 0)
		)
	end)
	test("Independent closed parameter restrictions clip the exact relation", function()
		local c = query(
			unit(),
			patch(V(0, 0.5, -1), V(1, 0, 0), V(0, 0, 2)),
			{ parameterBox = { { 0.125, 0.875 }, { 0, 1 }, { 0.25, 0.75 }, { 0.1, 0.9 } } }
		).cells[1]
		assert(c.vertices[1].position == V(0.25, 0.5, 0) and c.vertices[2].position == V(0.75, 0.5, 0))
		assert(c.parameterBox[1][1] == 0.25 and c.parameterBox[1][2] == 0.75)
	end)
	test("Rational native error is bounded independently of exact root coverage", function()
		local r = query(unit(), thirds(), { tolerance = 1e-12 })
		local c = r.cells[1]
		assert(
			r.rootCoverageComplete
				and r.cellTopologyCertified
				and not r.complete
				and r.reason == "approximation"
		)
		assert(c.errorBound > 1e-9 and c.errorBound < 1e-7 and not c.nativeTopologyCertified)
		for _, p in c.vertices do
			assert(R.equal(p.positionExact[1], R.div(R.number(1), R.number(3))))
			verifyVertex(p)
		end
		assert(not pcall(query, unit(), thirds(), { tolerance = 1e-12, requireComplete = true }))
	end)
	test("Barycentric images stay within the whole-cell error certificate", function()
		local c = query(unit(), thirds()).cells[1]
		for i = 0, 20 do
			local t = i / 20
			local p = c.vertices[1].position:Lerp(c.vertices[2].position, t)
			-- Client Vector3 interpolation can add rounding; evaluate the real
			-- chord in doubles for the certified geometric correspondence.
			local x = c.vertices[1].position.X * (1 - t) + c.vertices[2].position.X * t
			assert(math.abs(x - 1 / 3) <= c.errorBound)
			assert(math.abs(p.Z) == 0)
		end
	end)
	test("Swapping surfaces swaps parameter coordinates and preserves the spatial cell", function()
		local a, b = query(unit(), thirds()).cells[1], query(thirds(), unit()).cells[1]
		assert(a.kind == b.kind and #a.vertices == #b.vertices)
		for _, p in a.vertices do
			local found = false
			for _, q in b.vertices do
				if
					same(p.parametersExact, {
						q.parametersExact[3],
						q.parametersExact[4],
						q.parametersExact[1],
						q.parametersExact[2],
					})
				then
					assert(same(p.positionExact, q.positionExact))
					found = true
					break
				end
			end
			assert(found)
		end
	end)
	test("Snapshots precede cancellation and checkpoint callbacks", function()
		local a, b = unit(), rotated()
		local options = {
			method = "exactAffine",
			requireComplete = true,
			parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 }, {
				0,
				1,
			} },
		}
		options.checkpoint = function(state)
			if state.stage == "begin" then
				a.control[1][1] = V(100, 100, 100)
				b.weights[1][1] = 17
				options.method = "interval"
				options.parameterBox[1][2] = 0.001
			end
		end
		local r = E.SplineQuery.intersectSurfaces(a, b, options)
		assert(r.complete and r.algorithm == "exactAffine" and #r.cells[1].vertices == 8)
	end)
	test("Success, approximation failure and unsupported inputs leave sources unchanged", function()
		local a, b = unit(), thirds()
		local beforeA, beforeB = U.copy(a), U.copy(b)
		query(a, b)
		assert(not pcall(query, a, b, { requireComplete = true, tolerance = 1e-15 }))
		assert(same(a, beforeA) and same(b, beforeB))
		b.control[2][2] += V(0, 0, 1)
		beforeB = U.copy(b)
		assert(not pcall(query, a, b) and same(b, beforeB))
	end)
	test("Affine work, coefficient, bit and source allocation limits are hard", function()
		for _, options in
			{ { maxWork = 1 }, { maxExactBits = 1 }, { maxCoefficients = 4095 }, { maxControls = 3 } }
		do
			assert(not pcall(query, unit(), rotated(), options))
		end
	end)
	test("Cancellation covers every affine stage and inner arithmetic work", function()
		for _, stage in { "affineIdentity", "affineSolve", "affineBounds", "work", "finish" } do
			local reached = false
			local ok = pcall(query, unit(), rotated(), {
				checkpoint = function(s)
					if s.stage == stage then
						reached = true
					end
				end,
				cancelled = function()
					return reached
				end,
			})
			assert(reached and not ok, stage)
		end
		assert(not pcall(query, unit(), unit(), {
			cancelled = function()
				return true
			end,
		}))
	end)
	test("Nonaffine bilinear, rational and higher-degree patches reject explicitly", function()
		local warped = unit()
		warped.control[2][2] += V(0, 0, 1)
		local weighted = unit()
		weighted.weights[1][1] = 2
		local higher = E.NURBS.surface(
			{ { V(0, 0, 0), V(0, 1, 0) }, { V(0.5, 0, 0), V(0.5, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } },
			2,
			1
		)
		for _, b in { warped, weighted, higher } do
			assert(not pcall(query, unit(), b))
		end
	end)
	test("Method and incompatible arc/quotient requests fail explicitly", function()
		assert(not pcall(E.SplineQuery.intersectSurfaces, unit(), unit(), { method = "guessed" }))
		for _, flag in { "orderComponents", "requireOrdered", "identifyPeriodicSeams", "requireQuotient" } do
			assert(not pcall(query, unit(), unit(), { [flag] = true }))
		end
		local r = query(unit(), unit())
		assert(not r.orderedComplete and not r.parameterTopologyCertified and not r.quotientComplete)
	end)
	test("Exact affine enumeration does not consume interval-search soft limits", function()
		local r =
			query(unit(), rotated(), { maxNodes = 1, maxDepth = 0, maxSegments = 1, requireComplete = true })
		assert(r.complete and r.affineCandidates == 24 and #r.curves == 0 and #r.cells == 1)
	end)
	test("Nearly parallel affine planes retain their exact rank and intersection", function()
		local b = patch(V(0.25, 0, -2 ^ -121), V(1, 0, 2 ^ -120), V(0, 1, 0))
		local r = query(unit(), b, { requireComplete = true })
		assert(r.equalityRank == 3 and r.cells[1].kind == "segment")
		for _, vertex in r.cells[1].vertices do
			assert(vertex.position.X == 0.75 and vertex.position.Z == 0)
		end
	end)
	test("Thin positive overlaps remain two-dimensional across disparate axis scales", function()
		local a = patch(V(0, 0, 0), V(2 ^ 100, 0, 0), V(0, 2 ^ -120, 0))
		local c = query(a, a, { requireComplete = true }).cells[1]
		assert(
			c.parameterDimension == 2
				and c.spatialDimension == 2
				and #c.spatialBoundary == 4
				and c.errorBound == 0
		)
	end)
	if not settings or not settings.skipNative then
		test("An exact overlap polygon round-trips through a native EditableMesh", function()
			local c = query(unit(), rotated(), { requireComplete = true }).cells[1]
			local mesh = E.Mesh.new()
			local ids = {}
			for i, p in c.vertices do
				ids[i] = mesh:addVertex(p.position)
			end
			for _, t in c.triangles do
				mesh:addFace({ ids[t[1]], ids[t[2]], ids[t[3]] })
			end
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				assert(restored:validate().valid)
				local topology = E.Connectivity.analyze(restored)
				assert(topology.valid and topology.eulerCharacteristic == 1 and #topology.boundaryLoops == 1)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
