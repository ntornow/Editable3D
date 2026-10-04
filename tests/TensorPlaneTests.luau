return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local V = Vector3.new
	local function patch(o, u, v)
		return E.NURBS.surface({ { o, o + v }, { o + u, o + u + v } }, 1, 1)
	end
	local function unit()
		return patch(V(0, 0, 0), V(1, 0, 0), V(0, 1, 0))
	end
	local function query(a, b, options)
		options = U.copy(options or {})
		options.method = "exactTensorPlane"
		return E.SplineQuery.intersectSurfaces(a, b or unit(), options)
	end
	local function paraboloid(level)
		local rows, z = {}, { 0.25, -0.25, 0.25 }
		for i = 1, 3 do
			rows[i] = {}
			for j = 1, 3 do
				rows[i][j] = V((i - 1) / 2, (j - 1) / 2, z[i] + z[j] - level)
			end
		end
		return E.NURBS.surface(rows, 2, 2)
	end
	local function check(r, count, dimension)
		assert(
			r.coverageCertified
				and r.rootCoverageComplete
				and r.parameterComponentsCertified
				and r.cellDimensionsCertified
		)
		assert(r.componentCount == count)
		local owned = {}
		for _, component in r.components do
			if dimension then
				assert(component.parameterDimension == dimension)
			end
			for _, i in component.cellIndices do
				assert(not owned[i])
				owned[i] = true
				assert(r.cells[i].component == component.index)
			end
		end
		for i, cell in r.cells do
			assert(owned[i] and cell.certified)
		end
		for _, connection in r.connections do
			assert(r.cells[connection.firstCell].component == r.cells[connection.secondCell].component)
		end
		for i, v in r.vertices do
			assert(v.certified and r.parameterVertexMap[i])
			for axis, value in v.parameters do
				assert(value >= v.parameterBox[axis][1] and value <= v.parameterBox[axis][2])
			end
		end
	end
	local function fails(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok and string.find(tostring(err), pattern, 1, true), tostring(err))
	end
	local function choose(n, k)
		local out = 1
		for i = 1, k do
			out = out * (n - i + 1) / i
		end
		return out
	end
	local function graph(p, weighted)
		local du, dv = 1, math.max(1, #p - 1)
		for _, row in p do
			du = math.max(du, #row - 1)
		end
		local su, sv = 1, 1
		for i = 0, du do
			su *= choose(du, i)
		end
		for i = 0, dv do
			sv *= choose(dv, i)
		end
		local control, weights = {}, {}
		for i = 0, du do
			control[i + 1], weights[i + 1] = {}, {}
			for j = 0, dv do
				local h = 0
				for b = 0, j do
					for a = 0, i do
						h += ((p[b + 1] or {})[a + 1] or 0) * choose(i, a) * choose(j, b) * (su / choose(
							du,
							a
						)) * (sv / choose(dv, b))
					end
				end
				local weight = weighted and 2 ^ ((i + 2 * j) % 3 - 1) or 1
				local point = V(i / du, j / dv, h / weight)
				assert(point.Z == h / weight, "Analytic height controls must store exactly")
				control[i + 1][j + 1], weights[i + 1][j + 1] = point, weight
			end
		end
		return E.NURBS.surface(control, du, dv, { weights = weights })
	end
	test("576 independent tensor de Boor evaluations match exact raw-span homogeneous powers", function()
		local work, allocated = 0, 0
		local function visit(n)
			work += n or 1
			assert(work <= 200000000)
		end
		local function allocate(n)
			allocated += n
			assert(allocated <= 4000000)
		end
		local R = require(script.Parent.ExactRational)(visit, 8192)
		local P = require(script.Parent.ExactPolynomialRoots)(R, visit, 96, allocate)
		local extract = require(script.Parent.ExactSurfacePower)
		local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.TensorPowerFixtures))
		local function value(x)
			return R.fraction(x.sign, x.n, x.d)
		end
		local count = 0
		for index, row in fixtures do
			local control = {}
			for i, points in row.control do
				control[i] = {}
				for j, p in points do
					control[i][j] = V(table.unpack(p))
				end
			end
			local source = E.NURBS.surface(control, row.degreeU, row.degreeV, row)
			local spans = extract(source, R, P, { visit = visit, allocate = allocate, maxPieces = 2048 })
			assert(#spans == #row.spans)
			for i, expected in row.spans do
				local actual = spans[i]
				for axis = 1, 2 do
					assert(actual.knotSpans[axis] == expected.knots[axis])
					assert(R.equal(actual.offset[axis], value(expected.offset[axis])))
					assert(R.equal(actual.scale[axis], value(expected.scale[axis])))
				end
				for _, sample in expected.samples do
					local s, t = R.number(sample.s), R.number(sample.t)
					for axis, p in actual.h do
						local h = R.number(0)
						for power = #p, 1, -1 do
							h = R.add(R.mul(h, t), P.evaluate(p[power], s))
						end
						assert(
							R.equal(h, value(sample.h[axis])),
							"Tensor de Boor mismatch " .. index .. ":" .. i .. ":" .. axis
						)
					end
					count += 1
				end
			end
		end
		assert(count == 576)
	end)
	test("A tensor paraboloid has one isolated interior tangent point", function()
		local r = query(paraboloid(0))
		check(r, 1, 0)
		assert(#r.vertices == 1 and r.vertices[1].parameters[1] == 0.5 and r.vertices[1].parameters[2] == 0.5)
	end)
	test("Circular tensor-plane intersections retain two curved graph branches and exact closure", function()
		for _, level in { 0.0625, 0.125, 0.25 } do
			local r = query(paraboloid(level), nil, { requireComplete = true })
			check(r, 1, 1)
			local graphs = 0
			for _, cell in r.cells do
				if cell.kind == "graph" then
					graphs += 1
					assert(cell.profileOpen and #cell.boundaryVertices == 2)
				end
			end
			assert(graphs >= 2)
			for _, v in r.vertices do
				assert(v.accurate and v.positionBox[3][1] <= 0 and v.positionBox[3][2] >= 0)
			end
		end
	end)
	test("Closed square corners are four isolated contacts rather than a spurious connecting loop", function()
		local r = query(paraboloid(0.5))
		check(r, 4, 0)
		assert(#r.vertices == 4 and #r.cells == 4)
	end)
	test("An excluded tensor patch reports a certified empty contact set", function()
		local r = query(paraboloid(1), nil, { requireComplete = true })
		check(r, 0)
		assert(#r.cells == 0 and #r.vertices == 0 and r.complete)
	end)
	for _, case in
		{
			{
				name = "Crossing branches",
				p = { { 0, 1, -1 }, { -1 }, { 1 } },
				components = 1,
				dimension = 1,
			},
			{
				name = "Cusp branch",
				p = { { 0.375, -0.75, 1.5, -1 }, { -1 }, { 1 } },
				components = 1,
				dimension = 1,
			},
			{
				name = "Two hyperbolic components",
				p = { { 0.1875, -0.5 }, { -0.5, 1 } },
				components = 2,
				dimension = 1,
			},
			{
				name = "Two isolated tangent points",
				p = { { 0.28515625, -0.375, 1.375, -2, 1 }, { -1 }, { 1 } },
				components = 2,
				dimension = 0,
			},
			{
				name = "Vertical contact and incident graph",
				p = { { 0.25, -1, 1 }, { -0.5, 1 } },
				components = 1,
				dimension = 1,
			},
		}
	do
		test("Weighted tensor contacts classify " .. case.name, function()
			local r = query(graph(case.p, true), nil, { requireComponents = true, maxWork = 200000000 })
			check(r, case.components, case.dimension)
		end)
	end
	test("An algebraic clipping corner retains its nested fourth-root parameter", function()
		local rows = {}
		local x, t2 = { 0, 0, 1 }, { 0, 0, 1 }
		for i = 1, 3 do
			rows[i] = {}
			for j = 1, 3 do
				rows[i][j] = V(x[i], (j - 1) / 2, t2[j] - (i - 1) / 2)
			end
		end
		local r = query(
			E.NURBS.surface(rows, 2, 2),
			patch(V(0.5, 0, 0), V(0.5, 0, 0), V(0, 1, 0)),
			{ requireComplete = true }
		)
		check(r, 1, 1)
		local found = false
		for _, event in r.events do
			if not event.profile.exact then
				for _, root in event.roots do
					if root.feasible then
						assert(root.coefficientField == "profileAlgebraic")
						found = true
					end
				end
			end
		end
		assert(found)
	end)
	test("Coplanar curved maps produce two complete disconnected parameter bands", function()
		local rows, x = {}, { 0.25, -0.25, 0.25 }
		for i = 1, 3 do
			rows[i] = {}
			for j = 1, 3 do
				rows[i][j] = V(x[i], (j - 1) / 2, 0)
			end
		end
		local r = query(E.NURBS.surface(rows, 2, 2), patch(V(0.0625, 0, 0), V(0.1875, 0, 0), V(0, 1, 0)))
		check(r, 2, 2)
	end)
	test("A coplanar quadratic map has a curved two-dimensional clipping boundary", function()
		local rows, x = {}, { 0, 0, 1 }
		for i = 1, 3 do
			rows[i] = {}
			for j = 1, 3 do
				rows[i][j] = V(x[i] + x[j], (i - 1) / 2, 0)
			end
		end
		local r = query(E.NURBS.surface(rows, 2, 2), patch(V(0, 0, 0), V(0.5, 0, 0), V(0, 1, 0)))
		check(r, 1, 2)
		local band = false
		for _, cell in r.cells do
			if cell.kind == "band" then
				band = true
			end
		end
		assert(band)
	end)
	test(
		"Both original knot directions glue circles, isolated corner contacts, and the four-tile tangent vertex",
		function()
			for _, level in { 0, 0.0625, 0.125, 0.25, 0.5, 1 } do
				local a = E.NURBS.insertSurfaceKnot(paraboloid(level), "U", 0.5, 2)
				a = E.NURBS.insertSurfaceKnot(a, "V", 0.5, 2)
				local r = query(a, nil, { maxWork = 200000000, requireComplete = true })
				check(r, level > 0.5 and 0 or level == 0.5 and 4 or 1)
				assert(#r.spans == 4 and #r.spanJoins == 4)
				if level == 0 then
					assert(#r.vertices == 4 and #r.parameterVertexClasses == 1)
				end
			end
		end
	)
	test(
		"Restricted source boxes retain original span indices and glue only their active knot edges",
		function()
			local a = E.NURBS.insertSurfaceKnot(paraboloid(0.125), "U", 0.5, 2)
			a = E.NURBS.insertSurfaceKnot(a, "V", 0.5, 2)
			local r = query(
				a,
				nil,
				{ parameterBox = { { 0.5, 1 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }, requireComplete = true }
			)
			check(r, 1, 1)
			assert(not r.spans[1] and not r.spans[2] and r.spans[3] and r.spans[4])
			assert(#r.spanJoins == 1)
		end
	)
	test("Nonclamped raw knot domains preserve exact normalized tensor coordinates", function()
		local rows = {}
		for i = 1, 3 do
			rows[i] = {}
			for j = 1, 3 do
				rows[i][j] = V(i - 1.5, j - 1.5, i + j - 4)
			end
		end
		local a = E.NURBS.surface(rows, 2, 2, {
			clampedU = false,
			clampedV = false,
			knotsU = { -2, -1, 0, 1, 2, 3 },
			knotsV = { -8, -4, 0, 4, 8, 12 },
		})
		local r = query(a, patch(V(-2, -2, 0), V(4, 0, 0), V(0, 4, 0)), { requireComplete = true })
		check(r, 1, 1)
		for _, v in r.vertices do
			assert(math.abs(v.parameters[1] + v.parameters[2] - 1) < 1e-6)
		end
	end)
	test("Common extreme weight and knot scales leave tensor contact topology unchanged", function()
		for _, scale in { 2 ^ -900, 2 ^ 900 } do
			local a = paraboloid(0.0625)
			for i, row in a.weights do
				for j in row do
					a.weights[i][j] = scale
				end
			end
			for i, k in a.knotsU do
				a.knotsU[i] = k * scale
			end
			for i, k in a.knotsV do
				a.knotsV[i] = k * scale
			end
			local r = query(a, nil, { requireComplete = true, maxWork = 200000000 })
			check(r, 1, 1)
		end
	end)
	local function cyclic(du, dv, height)
		local control = {}
		for i = 1, 4 do
			control[i] = {}
			for j = 1, 4 do
				control[i][j] = V(0.5, 0.5, height(i, j))
			end
		end
		return E.Cyclic.surface(control, du, dv)
	end
	local periodicCases = {
		{
			name = "Collapsed periodic sheet",
			du = 2,
			dv = 2,
			height = function()
				return 0
			end,
			parameter = 1,
			quotient = 1,
			classes = 16,
		},
		{
			name = "Four periodic corners",
			du = 1,
			dv = 1,
			height = function(i, j)
				return (i == 1 and 0 or 1) + (j == 1 and 0 or 1)
			end,
			parameter = 4,
			quotient = 1,
			classes = 1,
		},
		{
			name = "Full seam cross",
			du = 1,
			dv = 1,
			height = function(i, j)
				return (i == 1 and 0 or 1) * (j == 1 and 0 or 1)
			end,
			parameter = 1,
			quotient = 1,
		},
		{
			name = "Two periodic loops",
			du = 1,
			dv = 2,
			height = function(i)
				return ({ 0, 1, 0, -1 })[i]
			end,
			parameter = 3,
			quotient = 2,
		},
	}
	for _, case in periodicCases do
		test("Multi-axis tensor quotient identifies " .. case.name, function()
			local r = query(cyclic(case.du, case.dv, case.height), nil, { requireQuotient = true })
			check(r, case.parameter)
			local q = r.periodicQuotient
			assert(
				q.topologyCertified and q.contactsCertified and q.componentsCertified and r.quotientComplete
			)
			assert(r.quotientComponentCount == case.quotient)
			if case.classes then
				assert(#q.vertexClasses == case.classes)
			end
			for i in r.vertices do
				assert(q.vertexMap[i])
			end
			for _, join in q.joins do
				for _, contact in join.contacts do
					assert(contact.certified)
				end
			end
		end)
	end
	test("A weighted quadratic torus has two complete periodic planar sections", function()
		local ring = { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) }
		local tube, weights = {}, {}
		for i, p in ring do
			tube[i], weights[i] = {}, {}
			for j, q in ring do
				tube[i][j] = V((2 + 0.5 * q.X) * p.X, (2 + 0.5 * q.X) * p.Y, 0.5 * q.Y)
				weights[i][j] = (i % 2 == 0 and 2 or 1) * (j % 2 == 0 and 2 or 1)
			end
		end
		local r = query(
			E.Cyclic.surface(tube, 2, 2, { weights = weights }),
			patch(V(-4, -4, 0), V(8, 0, 0), V(0, 8, 0)),
			{ requireComplete = true, requireQuotient = true }
		)
		check(r, 2, 1)
		assert(r.quotientComponentCount == 2 and r.work < 5000000)
	end)
	test(
		"Restricted periodic axes preserve unwrapped parameter components and enabled-axis metadata",
		function()
			local a = cyclic(1, 1, periodicCases[2].height)
			local r = query(
				a,
				nil,
				{ parameterBox = { { 0, 0.75 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }, requireQuotient = true }
			)
			check(r, 2, 0)
			assert(not r.periodicQuotient.axes[1].enabled and r.periodicQuotient.axes[2].enabled)
			assert(r.quotientComponentCount == 1)
		end
	)
	test("False stored periodic boundary equality is rejected even when native samples coincide", function()
		local a = cyclic(2, 2, function()
			return 0
		end)
		for i, row in a.control do
			for j in row do
				a.control[i][j] = V(i, j, 0)
			end
		end
		a.intervalsU = { 0.1, 0.2, 0.3, 0.4 }
		local ordinary = E.Cyclic.surfaceToNURBS(a)
		assert(E.NURBS.evaluateSurface(ordinary, 0, 0.5) == E.NURBS.evaluateSurface(ordinary, 1, 0.5))
		local r = query(a, patch(V(-10, -10, 0), V(20, 0, 0), V(0, 20, 0)), { identifyPeriodicSeams = true })
		assert(not r.quotientTopologyCertified and r.periodicQuotient.reason == "seamGeometry")
		fails(function()
			query(a, patch(V(-10, -10, 0), V(20, 0, 0), V(0, 20, 0)), { requireQuotient = true })
		end, "quotient incomplete")
	end)
	test("Tensor native accuracy is separate from exact topology and periodic identification", function()
		local r = query(
			paraboloid(0.125),
			nil,
			{ tolerance = 1e-12, parameterTolerance = 1e-12, identifyPeriodicSeams = true, maxIterations = 0 }
		)
		check(r, 1, 1)
		assert(
			not r.complete
				and r.reason == "approximation"
				and r.quotientTopologyCertified
				and not r.quotientComplete
		)
		assert(#r.unresolved > 0)
		fails(function()
			query(paraboloid(0.125), nil, { tolerance = 1e-12, requireComplete = true })
		end, "approximation exceeds tolerance")
	end)
	test("Tensor input and option snapshots precede callbacks and detached progress mutation", function()
		local a, b = paraboloid(0.0625), unit()
		local options = { requireComplete = true }
		local changed = false
		options.checkpoint = function(progress)
			progress.cells = math.huge
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
	test("Tensor cancellation propagates at begin, arithmetic, and completion checkpoints", function()
		for _, stage in { "begin", "work", "finish" } do
			local cancelled = false
			fails(function()
				query(paraboloid(0.125), nil, {
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
	test("Tensor and seam proof budgets are global and never return a false certificate", function()
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
			}
		do
			fails(function()
				query(paraboloid(0.125), nil, options)
			end, "budget")
		end
		local a = E.NURBS.insertSurfaceKnot(paraboloid(0.125), "U", 0.5, 2)
		fails(function()
			query(a, nil, { maxPieces = 1 })
		end, "budget")
		fails(function()
			query(a, nil, { maxConnectionPairs = 0 })
		end, "budget")
		for _, options in
			{ { maxSeamNodes = 0, requireQuotient = true }, { maxSeamPairs = 0, requireQuotient = true } }
		do
			fails(function()
				query(cyclic(1, 1, periodicCases[2].height), nil, options)
			end, "budget")
		end
	end)
	test(
		"Invalid affine targets, unsupported ordering, and malformed exact options fail explicitly",
		function()
			local b = unit()
			b.control[2][2] = V(1, 1, 0.25)
			fails(function()
				query(paraboloid(0.125), b)
			end, "parallelogram")
			b = unit()
			b.weights[1][1] = 2
			fails(function()
				query(paraboloid(0.125), b)
			end, "constant weights")
			fails(function()
				query(paraboloid(0.125), nil, { orderComponents = true })
			end, "ordering")
			for _, name in
				{
					"maxMatrixEntries",
					"maxLiftedRoots",
					"maxConnections",
					"maxConnectionPairs",
					"maxSeamNodes",
					"maxSeamPairs",
					"maxPolynomials",
				}
			do
				local ok = pcall(function()
					query(paraboloid(0.125), nil, { [name] = 0.5 })
				end)
				assert(not ok)
			end
		end
	)
	test("Public tensor certificates contain finite data and no private closures or table cycles", function()
		local r = query(paraboloid(0.125), nil, { identifyPeriodicSeams = true })
		local active = {}
		local function inspect(value)
			assert(type(value) ~= "function" and type(value) ~= "thread")
			if type(value) == "number" then
				assert(U.finite(value))
			end
			if type(value) ~= "table" then
				return
			end
			assert(not active[value], "Public certificate has a cycle")
			active[value] = true
			for key, item in value do
				inspect(key)
				inspect(item)
			end
			active[value] = nil
		end
		inspect(r)
	end)
	if not (settings and settings.skipNative) then
		test("Tensor contact anchors and UV parameters survive native EditableMesh conversion", function()
			local r = query(paraboloid(0.25), nil, { requireComplete = true })
			check(r, 1, 1)
			local mesh = E.Mesh.new()
			local corners = {}
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
				for _, face in copy.faces do
					for _, corner in face.corners do
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
