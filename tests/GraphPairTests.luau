return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local U = require(script.Parent.Util)
	local N, V = E.NURBS, Vector3.new
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function query(a, b, options)
		options = U.copy(options or {})
		options.method = "exactGraphPair"
		return E.SplineQuery.intersectSurfaces(a, b, options)
	end
	local function fails(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok and (not pattern or tostring(err):find(pattern, 1, true)), tostring(err))
	end
	local function check(r, count, dimension, a, b)
		assert(
			r.algorithm == "exactGraphPair"
				and r.coverageCertified
				and r.rootCoverageComplete
				and r.parameterComponentsCertified
				and r.cellTopologyCertified
				and r.cellDimensionsCertified
		)
		assert(r.componentCount == count, "Unexpected component count")
		local owned = {}
		for _, c in r.components do
			if dimension then
				assert(c.parameterDimension == dimension, "Unexpected contact dimension")
			end
			for _, i in c.cellIndices do
				assert(not owned[i] and r.cells[i].component == c.index)
				owned[i] = true
			end
		end
		for i, c in r.cells do
			assert(owned[i] and c.certified and c.complex == 1)
		end
		for _, c in r.connections do
			assert(r.cells[c.firstCell].component == r.cells[c.secondCell].component)
		end
		for i, v in r.vertices do
			assert(v.certified and r.parameterVertexMap[i] and r.spanPairs[v.spanPair])
			if a and b and v.accurate then
				local pa = N.evaluateSurface(a, v.parameters[1], v.parameters[2])
				local pb = N.evaluateSurface(b, v.parameters[3], v.parameters[4])
				assert((pa - pb).Magnitude < 1e-4)
			end
		end
	end
	local function graph(level, side, swap, weighted)
		local control, weights = {}, {}
		local z = { 0.25, -0.25, 0.25 }
		local w = weighted and (side == 1 and { 1, 2, 3 } or { 3, 2, 1 }) or { 1, 1, 1 }
		local x = weighted and (side == 1 and { 0, 0.25, 1 } or { 0, 0.75, 1 }) or { 0, 0.5, 1 }
		for i = 1, 3 do
			control[i] = {}
			weights[i] = {}
			for j = 1, 3 do
				weights[i][j] = w[i] * w[j]
				local common = weighted and x[i] + x[j] or x[i] * x[j]
				control[i][j] = V(
					swap and x[j] or x[i],
					swap and x[i] or x[j],
					common + side * (weighted and 9 or 1) * (z[i] + z[j] - level) / weights[i][j]
				)
			end
		end
		return N.surface(control, 2, 2, { weights = weights })
	end
	test(
		"752 independent rational values verify graph projection and both weighted parameter maps",
		function()
			local fixtures = game:GetService("HttpService")
				:JSONDecode(require(script.Parent.WeightedGraphFixtures))
			local prepare = require(script.Parent.ExactGraphPreparation)
			local count = 0
			for _, case in fixtures.cases do
				local inputs = {}
				for operand, control in case.control do
					local rows = {}
					for i, row in control do
						rows[i] = {}
						for j, p in row do
							rows[i][j] = V(table.unpack(p))
						end
					end
					inputs[operand] = N.surface(rows, 2, 2, { weights = case.weights[operand] })
				end
				local q = prepare(inputs[1], inputs[2], { graphDirection = V(table.unpack(case.direction)) })
				local R, P = q.data.R, q.data.P
				local function rational(p)
					return R.div(R.number(p[1]), R.number(p[2]))
				end
				local function evaluate(p, x, y)
					local out = R.number(0)
					for i = #p, 1, -1 do
						out = R.add(R.mul(out, y), P.evaluate(p[i], x))
					end
					return out
				end
				for operand, forms in case.projectionForms do
					for i, row in forms do
						for j, x in row do
							assert(R.equal(q.projectionForms[operand][i][j], rational(x)))
						end
					end
				end
				for i, row in case.parameterMap do
					for j, x in row do
						assert(R.equal(q.parameterMap[i][j], rational(x)))
					end
				end
				for _, sample in case.samples do
					local x, y = rational(sample.a[1]), rational(sample.a[2])
					for operand, spans in q.spans do
						local h = spans[1].h
						local w = evaluate(h[4], x, y)
						for axis = 1, 3 do
							assert(
								R.equal(
									R.div(evaluate(h[axis], x, y), w),
									rational(sample.values[operand][axis])
								)
							)
						end
						count += 1
					end
				end
			end
			assert(count == 752)
		end
	)
	for _, level in { 0, 0.0625, 0.125, 0.25, 0.5, 1 } do
		test("Curved graph contacts at analytic level " .. level .. " preserve original knots", function()
			for _, knots in { false, true } do
				local a, b = graph(level, 1), graph(level, -1, true)
				if knots then
					a = N.insertSurfaceKnot(N.insertSurfaceKnot(a, "U", 0.5, 2), "V", 0.5, 2)
					b = N.insertSurfaceKnot(N.insertSurfaceKnot(b, "U", 0.5, 2), "V", 0.5, 2)
				end
				local r = query(a, b, { requireComplete = true })
				check(
					r,
					level > 0.5 and 0 or level == 0.5 and 4 or 1,
					(level == 0 or level == 0.5) and 0 or 1,
					a,
					b
				)
				assert(#r.sourceSpans[1] == (knots and 4 or 1) and #r.spanPairs == (knots and 16 or 1))
			end
		end)
	end
	test("Independent positive weight fields retain analytic tangent loop and corner contacts", function()
		for _, level in { 0, 0.0625, 0.125, 0.25, 0.5, 1 } do
			local a, b = graph(level, 1, false, true), graph(level, -1, true, true)
			check(
				query(a, b, { requireComplete = true }),
				level > 0.5 and 0 or level == 0.5 and 4 or 1,
				(level == 0 or level == 0.5) and 0 or 1,
				a,
				b
			)
		end
	end)
	local function both(control, degree, options)
		local a, b = {}, {}
		for i, row in control do
			a[i] = {}
			b[i] = {}
			for j, p in row do
				a[i][j] = V(p[1], p[2], p[1] * p[2] + p[3])
				b[i][j] = V(p[2], p[1], p[1] * p[2] - p[3])
			end
		end
		return N.surface(a, degree, degree, options), N.surface(b, degree, degree, options)
	end
	for _, case in
		{
			{
				name = "Four singular isolated interior contacts",
				degree = 4,
				z = { 27 / 16, -45 / 16, 59 / 16, -45 / 16, 27 / 16 },
				sum = true,
				count = 4,
				dimension = 0,
			},
			{
				name = "Crossing curves tangent on both branches",
				degree = 2,
				z = { 0.25, -0.25, 0.25 },
				sum = false,
				count = 1,
				dimension = 1,
			},
			{
				name = "Four simple crossing branches",
				degree = 2,
				z = { 3 / 16, -5 / 16, 3 / 16 },
				sum = false,
				count = 1,
				dimension = 1,
			},
		}
	do
		test(case.name, function()
			local controls = {}
			for i, z in case.z do
				controls[i] = {}
				for j, w in case.z do
					controls[i][j] =
						{ (i - 1) / case.degree, (j - 1) / case.degree, case.sum and z + w or z * w }
				end
			end
			local a, b = both(controls, case.degree)
			check(query(a, b, { requireComplete = true }), case.count, case.dimension, a, b)
		end)
	end
	test("Unclamped raw knot domains have one global component ownership across 81 span pairs", function()
		for _, level in { 0, 1, 4.5, 5 } do
			local control = {}
			for i = 1, 5 do
				control[i] = {}
				for j = 1, 5 do
					control[i][j] = { i - 1, j - 1, (i - 3) ^ 2 + (j - 3) ^ 2 - 0.5 - level }
				end
			end
			local knots = { -2, -1, 0, 1, 2, 3, 4, 5 }
			local a, b =
				both(control, 2, { knotsU = knots, knotsV = knots, clampedU = false, clampedV = false })
			local r = query(a, b, { requireComplete = true })
			check(
				r,
				level > 4.5 and 0 or level == 4.5 and 4 or 1,
				(level == 0 or level == 4.5) and 0 or 1,
				a,
				b
			)
			assert(#r.sourceSpans[1] == 9 and #r.spanPairs == 81)
		end
	end)
	test("Restricted curved overlap has dimension two and an ordinary identity quotient", function()
		local a = graph(0.0625, 1)
		local r = query(a, a, {
			requireQuotient = true,
			parameterBox = {
				{ 0.125, 0.875 },
				{ 0.125, 0.875 },
				{ 0.25, 0.75 },
				{
					0.25,
					0.75,
				},
			},
		})
		check(r, 1, 2, a, a)
		assert(r.quotientComplete and #r.periodicQuotient.axes == 0 and r.quotientComponentCount == 1)
	end)
	test("Second-operand parameter limits retain a closed half-loop and its boundary endpoints", function()
		local a, b = graph(0.0625, 1), graph(0.0625, -1, true)
		local r = query(
			a,
			b,
			{ requireComplete = true, parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 }, { 0, 0.5 } } }
		)
		check(r, 1, 1, a, b)
		for _, v in r.vertices do
			assert(v.parameters[1] <= 0.5 and v.parameters[4] <= 0.5)
		end
	end)
	test("Reversed source parameters retain the full geometric loop and original UV pairs", function()
		local a, b = graph(0.125, 1), N.reverseSurface(graph(0.125, -1, true), "U")
		check(query(a, b, { requireComplete = true }), 1, 1, a, b)
	end)
	test("A dyadic oblique projection direction and translated scaled coordinates remain exact", function()
		local a, b = graph(0.0625, 1), graph(0.0625, -1, true)
		local direction = V(1, 2, 4)
		for _, s in { a, b } do
			for _, row in s.control do
				for j, p in row do
					row[j] = V(4, -2, 1) + 8 * (V(p.X, p.Y, 0) + direction * p.Z)
				end
			end
		end
		local r = query(a, b, { graphDirection = direction, requireComplete = true })
		check(r, 1, 1, a, b)
	end)
	test("Merely approximate projected affinities cannot receive an exact certificate", function()
		local a, b = graph(0.125, 1), graph(0.125, -1)
		b.control[2][2] += V(2 ^ -20, 0, 0)
		fails(function()
			query(a, b)
		end, "not affine")
	end)
	test("Rank-deficient and cyclic projected charts reject explicitly", function()
		local a = graph(0.125, 1)
		local b = graph(0.125, -1)
		for _, row in b.control do
			for j, p in row do
				row[j] = V(0, p.Y, p.Z)
			end
		end
		fails(function()
			query(a, b)
		end, "rank two")
		local cyclic = E.Cyclic.surface(a.control, 2, 2)
		fails(function()
			query(a, cyclic)
		end, "Ordinary graph")
	end)
	test("Native anchor accuracy remains separate from the exact contact decomposition", function()
		local a, b = graph(0.125, 1), graph(0.125, -1)
		local r = query(
			a,
			b,
			{ tolerance = 1e-12, parameterTolerance = 1e-12, maxIterations = 0, identifyPeriodicSeams = true }
		)
		check(r, 1, 1)
		assert(
			not r.complete and r.reason == "approximation" and #r.unresolved > 0 and not r.quotientComplete
		)
		fails(function()
			query(a, b, { tolerance = 1e-12, requireComplete = true })
		end, "approximation exceeds tolerance")
	end)
	test("Both graph inputs and nested exact settings are detached before callbacks", function()
		local a, b = graph(0.0625, 1), graph(0.0625, -1)
		local options = { requireComplete = true }
		local changed = false
		options.checkpoint = function(p)
			p.cells = math.huge
			if not changed then
				changed = true
				a.control[1][1] = V(100, 100, 100)
				b.control[1][1] = V(100, 100, 100)
				options.maxWork = 1
			end
		end
		local r = query(a, b, options)
		check(r, 1, 1)
		assert(changed and r.complete)
	end)
	test("Graph cancellation propagates at entry arithmetic and completion", function()
		for _, stage in { "begin", "work", "finish" } do
			local cancelled = false
			fails(function()
				query(graph(0.125, 1), graph(0.125, -1), {
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
		end
	end)
	test("Every graph proof allocation remains bounded by shared exact budgets", function()
		for _, options in
			{
				{ maxWork = 1 },
				{ maxCoefficients = 1 },
				{ maxControls = 1 },
				{ maxEvents = 1 },
				{ maxNodes = 1 },
				{ maxMatrixEntries = 1 },
				{ maxLiftedRoots = 1 },
				{ maxPolynomials = 1 },
				{ maxCells = 1 },
				{ maxVertices = 1 },
				{ maxConnections = 0 },
				{ maxPolynomialDegree = 1 },
				{ maxSnapshotEntries = 1 },
				{ maxGraphPolynomials = 1 },
			}
		do
			fails(function()
				query(graph(0.125, 1), graph(0.125, -1), options)
			end, "budget")
		end
		local a = N.insertSurfaceKnot(graph(0.125, 1), "U", 0.5, 2)
		fails(function()
			query(a, graph(0.125, -1), { maxPieces = 1 })
		end, "budget")
	end)
	test("Malformed graph directions proof limits and unsupported ordering reject", function()
		for _, direction in { false, 1, V(0, 0, 0), V(math.huge, 0, 1) } do
			fails(function()
				query(graph(0.125, 1), graph(0.125, -1), { graphDirection = direction })
			end)
		end
		for _, name in
			{
				"maxGraphPolynomials",
				"maxMatrixEntries",
				"maxLiftedRoots",
				"maxConnections",
				"maxConnectionPairs",
				"maxSeamNodes",
				"maxSeamPairs",
				"maxPolynomials",
			}
		do
			fails(function()
				query(graph(0.125, 1), graph(0.125, -1), { [name] = 0.5 })
			end)
		end
		fails(function()
			query(graph(0.125, 1), graph(0.125, -1), { requireOrdered = true })
		end, "ordering")
	end)
	test("Public graph certificates contain finite witnesses and no private closures or cycles", function()
		local r = query(graph(0.125, 1), graph(0.125, -1), { identifyPeriodicSeams = true })
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
		assert(r.baseComplex.constraints and r.projection.certified and #r.domainGuards == 4)
	end)
	if not (settings and settings.skipNative) then
		test(
			"Graph contact anchors and original UV parameters round-trip through native EditableMesh",
			function()
				local r = query(graph(0.25, 1), graph(0.25, -1, true), { requireComplete = true })
				check(r, 1, 1)
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
			end
		)
	end
	report.success = report.failed == 0
	return report
end
