return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local U = require(script.Parent.Util)
	local N, V = E.NURBS, Vector3.new
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function fixture(name)
		return game:GetService("HttpService"):JSONDecode(require(script.Parent[name]))
	end
	local function query(a, b, options)
		options = U.copy(options or {})
		options.method = "exactTensorPair"
		options.parameterOrder = options.parameterOrder or { 3, 4, 1, 2 }
		return E.SplineQuery.intersectSurfaces(a, b, options)
	end
	local function fails(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok and (not pattern or tostring(err):find(pattern, 1, true)), tostring(err))
	end
	local function surfaces(kind)
		local linear, square = { 0, 0.5, 1 }, { 0, 0, 1 }
		local a, b, weights = {}, {}, {}
		for i = 1, 3 do
			a[i], b[i], weights[i] = {}, {}, {}
			for j = 1, 3 do
				a[i][j] = V(linear[i], linear[j], square[i] + square[j])
				local z = square[i] + square[j]
				if kind == "loop" or kind == "tangent" or kind == "empty" then
					local constant = kind == "loop" and 25 / 256 or kind == "tangent" and 41 / 256 or 57 / 256
					z = 0.625 * square[i] + 0.75 * square[j] + 0.25 * linear[j] - constant
				end
				b[i][j] = kind == "overlap" and a[i][j] or V(square[i], linear[j], z)
				weights[i][j] = kind == "overlap" and ({ 4, 2, 1 })[i] or 1
			end
		end
		return N.surface(a, 2, 2), N.surface(b, 2, 2, { weights = weights })
	end
	local function check(r, count, dimension, a, b)
		assert(
			r.algorithm == "exactTensorPair"
				and r.coverageCertified
				and r.rootCoverageComplete
				and r.parameterComponentsCertified
				and r.cellTopologyCertified
				and r.cellDimensionsCertified
		)
		assert(not r.parameterTopologyCertified and not r.componentTopologyCertified)
		assert(r.componentCount == count, "Unexpected contact component count")
		local owned = {}
		for _, c in r.components do
			assert(
				c.certified and c.connected and c.parameterDimension == dimension,
				"Unexpected contact dimension"
			)
			for _, i in c.cellIndices do
				assert(not owned[i] and r.cells[i].component == c.index)
				owned[i] = true
			end
		end
		for i, c in r.cells do
			assert(owned[i] and c.certified and c.complex == 1 and c.dimension == c.parameterDimension)
			assert(r.vertices[c.anchorVertex] and r.parameterVertexMap[c.anchorVertex])
		end
		for _, c in r.connections do
			assert(c.certified and r.proofs[c.proof])
			assert(r.cells[c.firstCell].component == r.cells[c.secondCell].component)
		end
		for _, v in r.vertices do
			assert(v.certified and r.spanPairs[v.spanPair])
			if a and b and v.accurate then
				local pa = N.evaluateSurface(a, v.parameters[1], v.parameters[2])
				local pb = N.evaluateSurface(b, v.parameters[3], v.parameters[4])
				assert((pa - pb).Magnitude < 1e-4 and (pa - v.position).Magnitude < 1e-4)
			end
		end
	end
	test("2304 independent original tensor homogeneous references including shared knots", function()
		local N = E.NURBS
		local V = Vector3.new
		local plane = N.surface({ { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
		local fixtures = fixture("GeneralTensorFixtures")
		local count = 0
		for index, case in fixtures do
			local controls = {}
			for i, row in case.control do
				controls[i] = {}
				for j, p in row do
					controls[i][j] = V(table.unpack(p))
				end
			end
			local surface = N.surface(controls, case.degree, case.degree, {
				weights = case.weights,
				knotsU = case.knots,
				knotsV = case.knots,
				clampedU = case.clamped,
				clampedV = case.clamped,
			})
			local prep = require(script.Parent.GeneralTensorPreparation)(surface, plane, {
				parameterOrder = index % 2 == 0 and { 3, 1, 4, 2 } or { 1, 2, 3, 4 },
				maxWork = 200000000,
				maxCoefficients = 8000000,
			})
			local R, M = prep.data.R, prep.polynomial
			for _, sample in case.samples do
				local u, v = R.number(sample.uv[1]), R.number(sample.uv[2])
				local values = {}
				for i, original in prep.parameterOrder do
					values[i] = original == 1 and u or original == 2 and v or R.number(0.5)
				end
				local owners = 0
				for _, span in prep.spans[1] do
					if
						R.compare(u, span.offset[1]) >= 0
						and R.compare(u, R.add(span.offset[1], span.scale[1])) <= 0
						and R.compare(v, span.offset[2]) >= 0
						and R.compare(v, R.add(span.offset[2], span.scale[2])) <= 0
					then
						owners += 1
						for axis = 1, 4 do
							local expected = sample.h[axis]
							assert(
								R.equal(
									M.evaluate(span.h[axis], values),
									R.fraction(expected.sign, expected.n, expected.d)
								),
								"Independent original span mismatch " .. index .. ":" .. axis
							)
							count += 1
						end
					end
				end
				assert(owners >= 1)
			end
		end
		assert(count == 2304)
	end)
	for _, case in
		{
			{ "twoCurves", 2, 1 },
			{ "loop", 1, 1 },
			{ "tangent", 1, 0 },
			{ "empty", 0, 0 },
			{ "overlap", 1, 2 },
		}
	do
		test("General tensor analytic " .. case[1] .. " has exact components and native anchors", function()
			local a, b = surfaces(case[1])
			local r = query(a, b, { requireComplete = true, requireQuotient = true })
			check(r, case[2], case[3], a, b)
			assert(r.complete and r.quotientComplete and r.quotientComponentCount == case[2])
			assert(#r.periodicQuotient.axes == 0)
		end)
	end
	test("General contacts retain original knot boundaries in both operands", function()
		local a, b = surfaces("twoCurves")
		local function refine(s)
			return N.insertSurfaceKnot(N.insertSurfaceKnot(s, "U", 0.5, 1), "V", 0.5, 1)
		end
		a, b = refine(a), refine(b)
		local r = query(a, b, { requireComplete = true })
		check(r, 2, 1, a, b)
		assert(#r.spanPairs == 16)
	end)
	test("Restricted general contact domains retain an arc and exclude separated curves", function()
		local a, b = surfaces("twoCurves")
		check(query(a, b, { parameterBox = { { 0.125, 0.875 }, { 0, 1 }, { 0, 1 }, { 0, 1 } } }), 0, 0)
		a, b = surfaces("loop")
		local r = query(
			a,
			b,
			{ parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 0.5 }, { 0, 1 } }, requireComplete = true }
		)
		check(r, 1, 1, a, b)
		for _, v in r.vertices do
			assert(v.parameters[3] <= 0.5)
		end
	end)
	test("Collapsed rational fibers retain a three dimensional contact component", function()
		local a = N.surface({ { V(0, 0, 0), V(0, 0, 0) }, { V(1, 0, 0), V(1, 0, 0) } }, 1, 1)
		local b = N.surface(a.control, 1, 1, { weights = { { 1, 1 }, { 2, 2 } } })
		check(query(a, b, { requireComplete = true }), 1, 3, a, b)
	end)
	test("Identical constant surfaces retain a four dimensional parameter component", function()
		local a = N.surface({ { V(1, 2, 3), V(1, 2, 3) }, { V(1, 2, 3), V(1, 2, 3) } }, 1, 1)
		local r = query(a, a, { requireComplete = true })
		check(r, 1, 4, a, a)
		assert(#r.cells == 81)
	end)
	test("Common invertible oblique affine coordinates preserve general tensor contacts", function()
		local a, b = surfaces("twoCurves")
		for _, surface in { a, b } do
			for _, row in surface.control do
				for j, p in row do
					row[j] = V(p.X + 2 * p.Z + 8, 2 * p.X - p.Y - 4, p.Z + p.X + 2)
				end
			end
		end
		check(query(a, b, { requireComplete = true }), 2, 1, a, b)
	end)
	test("Guarded and full projection preserve contacts under parameter reordering", function()
		for _, order in { { 1, 2, 3, 4 }, { 3, 1, 4, 2 }, { 4, 3, 2, 1 } } do
			for _, projection in { "guarded", "full" } do
				local a, b = surfaces("overlap")
				check(
					query(
						a,
						b,
						{ parameterOrder = order, cadProjection = projection, requireComplete = true }
					),
					1,
					2,
					a,
					b
				)
			end
		end
	end)
	test("Native approximation is separate from the exact tensor contact certificate", function()
		local a, b = surfaces("overlap")
		local r = query(
			a,
			b,
			{ tolerance = 1e-12, parameterTolerance = 1e-12, maxIterations = 0, identifyPeriodicSeams = true }
		)
		check(r, 1, 2)
		assert(
			not r.complete and r.reason == "approximation" and #r.unresolved > 0 and not r.quotientComplete
		)
		for _, flag in { "requireComplete", "requireQuotient" } do
			fails(function()
				query(a, b, { tolerance = 1e-12, parameterTolerance = 1e-12, [flag] = true })
			end, "approximation")
		end
	end)
	test("General inputs and nested settings are detached before callbacks", function()
		local a, b = surfaces("twoCurves")
		local options = {
			requireComplete = true,
			parameterOrder = { 3, 4, 1, 2 },
			parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 } },
		}
		local changed = false
		options.checkpoint = function(p)
			p.cells = math.huge
			if not changed then
				changed = true
				a.control[1][1] = V(100, 100, 100)
				b.control[1][1] = V(100, 100, 100)
				options.parameterOrder[1] = 99
				options.parameterBox[1][2] = 0
				options.maxWork = 1
			end
		end
		local r = query(a, b, options)
		check(r, 2, 1)
		assert(changed and r.complete)
	end)
	test("General cancellation and callback errors retain their identity", function()
		for _, stage in { "begin", "work", "finish" } do
			local a, b = surfaces("twoCurves")
			local cancelled = false
			fails(function()
				query(a, b, {
					checkpoint = function(p)
						if p.stage == stage then
							cancelled = true
						end
					end,
					cancelled = function()
						return cancelled
					end,
				})
			end, "cancelled")
			local token = {}
			local ok, err = pcall(query, a, b, {
				checkpoint = function(p)
					if p.stage == stage then
						error(token, 0)
					end
				end,
			})
			assert(not ok and err == token)
		end
	end)
	test("General exact arithmetic decomposition and output budgets fail closed", function()
		for _, option in
			{
				{ maxWork = 1 },
				{ maxCoefficients = 1 },
				{ maxControls = 1 },
				{ maxNodes = 1 },
				{ maxLiftedRoots = 1 },
				{ maxCells = 1 },
				{ maxVertices = 1 },
				{ maxPolynomialDegree = 1 },
				{ maxSnapshotEntries = 1 },
				{ maxGeneralPolynomials = 1 },
				{ maxProjectionPolynomials = 1 },
				{ maxProjectionCandidates = 1 },
				{ maxComponentPairs = 1 },
			}
		do
			local a, b = surfaces("twoCurves")
			fails(function()
				query(a, b, option)
			end, "budget")
		end
		local a, b = surfaces("twoCurves")
		a = N.insertSurfaceKnot(a, "U", 0.5, 1)
		fails(function()
			query(a, b, { maxPieces = 1 })
		end, "budget")
		a, b = surfaces("loop")
		fails(function()
			query(a, b, { maxMatrixEntries = 1 })
		end, "budget")
	end)
	test("Malformed general tensor axes proof limits and ordering reject", function()
		for _, order in { { 1, 2, 3 }, { 1, 1, 3, 4 }, { 1, 2, 3, 5 }, { 1, 2, 3, 0.5 } } do
			local a, b = surfaces("twoCurves")
			fails(function()
				query(a, b, { parameterOrder = order })
			end)
		end
		for _, name in
			{
				"maxGeneralPolynomials",
				"maxProjectionPolynomials",
				"maxProjectionCandidates",
				"maxGcdCache",
				"maxEquationPasses",
				"maxEquationRewrites",
				"maxMatrixEntries",
				"maxLiftedRoots",
				"maxComponentPairs",
			}
		do
			local a, b = surfaces("twoCurves")
			fails(function()
				query(a, b, { [name] = 0.5 })
			end)
		end
		local a, b = surfaces("twoCurves")
		fails(function()
			query(a, b, { cadProjection = "approximate" })
		end, "projection")
		fails(function()
			query(a, b, { requireOrdered = true })
		end, "ordering")
	end)
	test("Private quantifier and closure controls cannot weaken the public certificate", function()
		for _, name in
			{
				"projection",
				"quantifiers",
				"requiredZero",
				"fixedTarget",
				"trace",
				"nullificationFailure",
				"diagnosticErrors",
			}
		do
			local a, b = surfaces("twoCurves")
			fails(function()
				query(a, b, { [name] = true })
			end, "Private CAD option")
		end
	end)

	test(
		"Finite general certificates retain original spans and closure evidence without private objects",
		function()
			local a, b = surfaces("overlap")
			local r = query(a, b)
			local active = {}
			local function inspect(value)
				assert(type(value) ~= "function" and type(value) ~= "thread")
				if type(value) == "number" then
					assert(U.finite(value))
				end
				if type(value) ~= "table" then
					return
				end
				assert(not active[value])
				active[value] = true
				for k, v in value do
					inspect(k)
					inspect(v)
				end
				active[value] = nil
			end
			inspect(r)
			assert(r.decomposition and r.proofs and r.spanPairs and r.sourceSpans)
		end
	)
	if not (settings and settings.skipNative) then
		test("General contact anchors and UV coordinates round trip through EditableMesh", function()
			local a, b = surfaces("overlap")
			local r = query(a, b, { requireComplete = true })
			local mesh, corners = E.Mesh.new(), {}
			for i = 1, 3 do
				local v = r.vertices[i]
				mesh:addVertex(v.position)
				corners[i] = { uv = Vector2.new(v.parameters[1], v.parameters[2]), normal = V(0, 0, 1) }
			end
			mesh:addFace({ 1, 2, 3 }, corners)
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local copy = E.Roblox.fromEditable(handle.editable)
				local count = 0
				for _, f in copy.faces do
					for _, corner in f.corners do
						local found = false
						for _, c in corners do
							if c.uv == corner.uv then
								found = true
							end
						end
						assert(found and corner.normal.Z > 0.99)
						count += 1
					end
				end
				assert(count == 3)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
