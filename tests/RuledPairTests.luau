return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local V = Vector3.new
	local function query(a, b, options)
		options = U.copy(options or {})
		options.method = "exactRuledPair"
		return E.SplineQuery.intersectSurfaces(a, b, options)
	end
	local function check(r, count, dimension)
		assert(
			r.coverageCertified
				and r.rootCoverageComplete
				and r.parameterComponentsCertified
				and r.baseCellTopologyCertified
				and r.cellDimensionsCertified
		)
		assert(
			not r.cellTopologyCertified
				and not r.parameterTopologyCertified
				and not r.componentTopologyCertified
		)
		assert(r.componentCount == count, "Unexpected parameter component count")
		local owned = {}
		for _, c in r.components do
			if dimension then
				assert(c.parameterDimension == dimension, "Unexpected full dimension")
			end
			for _, i in c.cellIndices do
				assert(not owned[i] and r.cells[i].component == c.index)
				owned[i] = true
			end
		end
		for i, c in r.cells do
			assert(owned[i] and c.coverageCertified and c.dimensionCertified and not c.cellTopologyCertified)
		end
		for _, c in r.connections do
			assert(r.cells[c.firstCell].component == r.cells[c.secondCell].component)
		end
		for i, v in r.vertices do
			assert(v.certified and r.parameterVertexMap[i])
			for axis, x in v.parameters do
				assert(v.parameterBox[axis][1] <= x and v.parameterBox[axis][2] >= x)
			end
		end
	end
	local function fails(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok and string.find(tostring(err), pattern, 1, true), tostring(err))
	end
	local function saddle(swapped, opposite)
		if swapped then
			return E.NURBS.surface({
				{ V(0, 0, opposite and 0.5 or 0), V(1, 0, opposite and 0.5 or 0) },
				{ V(0, 1, opposite and 0.5 or 0), V(1, 1, opposite and -0.5 or 1) },
			}, 1, 1)
		end
		return E.NURBS.surface({ { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 1) } }, 1, 1)
	end
	local function parabola(positive, constant)
		local rows = {}
		for i, x in { -1, 0, 1 } do
			local z = ({ 1, -1, 1 })[i]
			rows[i] = positive and { V(x, -1, z), V(x, 1, z) }
				or { V(-1, x, constant - z), V(1, x, constant - z) }
		end
		return E.NURBS.surface(rows, 2, 1)
	end
	local function collapsed(height, degree, transpose)
		local rows = {}
		for i = 1, 4 do
			rows[i] = { V(0, 0, height(i)), V(0, 0, height(i)) }
		end
		if transpose then
			rows = {
				{ rows[1][1], rows[2][1], rows[3][1], rows[4][1] },
				{ rows[1][2], rows[2][2], rows[3][2], rows[4][2] },
			}
		end
		return E.Cyclic.surface(
			rows,
			transpose and 1 or degree,
			transpose and degree or 1,
			{ cyclicU = not transpose, cyclicV = transpose == true }
		)
	end
	local function flat()
		return E.NURBS.surface({ { V(0, 0, 0), V(0, 0, 0) }, { V(0, 0, 0), V(0, 0, 0) } }, 1, 1)
	end
	for _, case in
		{
			{ name = "Self-overlapping saddle", swapped = false, dimension = 2 },
			{ name = "Swapped-parameter saddle overlap", swapped = true, dimension = 2 },
			{
				name = "Opposite saddles with a curved contact",
				swapped = true,
				opposite = true,
				dimension = 1,
			},
		}
	do
		test(case.name, function()
			check(
				query(saddle(), saddle(case.swapped, case.opposite), { requireComplete = true }),
				1,
				case.dimension
			)
		end)
	end
	for _, case in
		{
			{ 0.5, 1, 1, "Closed loop" },
			{ 0, 1, 0, "Isolated tangency" },
			{ -1, 0, 0, "Disjoint cylinders" },
			{ 2, 4, 0, "Four corner contacts" },
			{ 3, 0, 0, "Clipped-away curve" },
		}
	do
		test("Two curved quadratic cylinders: " .. case[4], function()
			local r = query(parabola(true, 0), parabola(false, case[1]), { requireComplete = true })
			check(r, case[2], case[3])
		end)
	end
	test("Weighted profile and ruling reparameterizations retain the complete curved loop", function()
		local a, b = parabola(true, 0), parabola(false, 0.5)
		for i = 1, 3 do
			a.weights[i] = { 2 ^ (i - 1), 4 * 2 ^ (i - 1) }
			b.weights[i] = { 2 * 2 ^ -(i - 1), 2 ^ -(i - 1) }
		end
		local r = query(a, b, { requireComplete = true })
		check(r, 1, 1)
		for _, v in r.vertices do
			local pa = E.NURBS.evaluateSurface(a, v.parameters[1], v.parameters[2])
			local pb = E.NURBS.evaluateSurface(b, v.parameters[3], v.parameters[4])
			assert((pa - pb).Magnitude < 1e-4 and (pa - v.position).Magnitude < 1e-4)
		end
	end)
	test("Clipping both ruling intervals preserves an isolated corner", function()
		check(
			query(
				saddle(),
				saddle(true, true),
				{ parameterBox = { { 0, 1 }, { 0, 0.25 }, { 0, 1 }, { 0, 1 } }, requireComplete = true }
			),
			1,
			0
		)
	end)
	test("Original knots in both surface profiles identify complete shared fibers", function()
		local a = E.NURBS.insertSurfaceKnot(saddle(), "U", 0.5, 1)
		local b = E.NURBS.insertSurfaceKnot(saddle(true, true), "U", 0.5, 1)
		local r = query(a, b, { requireComplete = true })
		check(r, 1, 1)
		assert(#r.spans == 4 and #r.spanJoins == 4)
		assert(#r.parameterVertexClasses < #r.vertices)
		for _, v in r.vertices do
			assert(v.positionBox[3][1] <= 0.25 and v.positionBox[3][2] >= 0.25)
		end
	end)
	test("Restricted profile tiles preserve original sparse span indices", function()
		local a = E.NURBS.insertSurfaceKnot(saddle(), "U", 0.5, 1)
		local b = E.NURBS.insertSurfaceKnot(saddle(true, true), "U", 0.5, 1)
		local r = query(a, b, { parameterBox = { { 0.5, 1 }, { 0, 1 }, { 0.5, 1 }, { 0, 1 } } })
		check(r, 1, 0)
		assert(not r.spans[1] and r.spans[4])
	end)
	test("Rank-changing ruling fibers retain their full parameter dimension", function()
		local a = E.NURBS.surface({ { V(0, 0, 0), V(0, 0, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
		local r = query(a, a, { requireComplete = true })
		check(r, 1, 2)
		local square, segment = false, false
		for _, cell in r.cells do
			square = square or cell.fiberDimensionRange[2] == 2
			segment = segment or cell.fiberDimensionRange[1] == 1
		end
		assert(square and segment)
	end)
	test("Spatially collapsed surfaces retain all four parameter dimensions", function()
		check(query(flat(), flat(), { requireComplete = true }), 1, 4)
	end)
	test("Both operand periodic directions identify four corner squares transitively", function()
		local a = collapsed(function(i)
			return i == 1 and 0 or 1
		end, 1)
		local b = collapsed(function(i)
			return i == 1 and 0 or -1
		end, 1, true)
		local r = query(a, b, { requireQuotient = true })
		check(r, 4, 2)
		assert(
			r.quotientComponentCount == 1
				and r.quotientComponentsCertified
				and r.quotientComplete
				and not r.quotientTopologyCertified
		)
		local q = r.periodicQuotient
		assert(
			q.contactsCertified
				and q.componentsCertified
				and not q.topologyCertified
				and #q.vertexClasses == 4
		)
		assert(q.axes[1].parameterAxis == 1 and q.axes[2].parameterAxis == 4)
		for i in r.vertices do
			assert(q.vertexMap[i])
		end
	end)
	test("Restricted periodic operands retain unwrapped components and disabled seam metadata", function()
		local a = collapsed(function(i)
			return i == 1 and 0 or 1
		end, 1)
		local b = collapsed(function(i)
			return i == 1 and 0 or -1
		end, 1, true)
		local r = query(
			a,
			b,
			{ parameterBox = { { 0, 0.75 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }, requireQuotient = true }
		)
		check(r, 2, 2)
		assert(
			r.quotientComponentCount == 1
				and not r.periodicQuotient.axes[1].enabled
				and r.periodicQuotient.axes[2].enabled
		)
	end)
	test("Periodic full-fiber contacts preserve two disconnected three-dimensional components", function()
		local a = collapsed(function(i)
			return ({ 0, 1, 0, -1 })[i]
		end, 1)
		local r = query(a, flat(), { requireQuotient = true })
		check(r, 3, 3)
		assert(r.quotientComponentCount == 2)
	end)
	test("False stored periodic ruling equality cannot receive a quotient certificate", function()
		local a = collapsed(function()
			return 0
		end, 2)
		for i, row in a.control do
			for j in row do
				row[j] = V(i, j, 0)
			end
		end
		a.intervalsU = { 0.1, 0.2, 0.3, 0.4 }
		local b =
			E.NURBS.surface({ { V(-10, -10, 0), V(-10, 10, 0) }, { V(10, -10, 0), V(10, 10, 0) } }, 1, 1)
		local r = query(a, b, { identifyPeriodicSeams = true })
		assert(not r.quotientComponentsCertified and r.periodicQuotient.reason == "seamGeometry")
		fails(function()
			query(a, b, { requireQuotient = true })
		end, "quotient incomplete")
	end)
	test("Native float precision does not change exact coverage or connected components", function()
		local a = E.NURBS.surface({ { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
		local b = E.NURBS.surface({ { V(0, 1, 0), V(1, -2, 0) }, { V(0, 1, 1), V(1, -2, 1) } }, 1, 1)
		local r = query(a, b, { tolerance = 1e-12 })
		check(r, 1, 1)
		assert(not r.complete and #r.unresolved > 0)
		fails(function()
			query(a, b, { tolerance = 1e-12, requireComplete = true })
		end, "approximation exceeds tolerance")
	end)
	test("Common weight and raw-knot scales preserve exact ruled-pair coverage", function()
		for _, scale in { 2 ^ -900, 2 ^ 900 } do
			local a, b = saddle(), saddle(true, true)
			for _, surface in { a, b } do
				for i, row in surface.weights do
					for j in row do
						row[j] = scale
					end
				end
				for _, knots in { surface.knotsU, surface.knotsV } do
					for i, k in knots do
						knots[i] = k * scale
					end
				end
			end
			check(query(a, b, { requireComplete = true }), 1, 1)
		end
	end)
	test("Ruled-pair proof budgets fail explicitly instead of issuing partial certificates", function()
		for _, options in
			{
				{ maxWork = 1 },
				{ maxCoefficients = 1 },
				{ maxEvents = 1 },
				{ maxNodes = 1 },
				{ maxPolynomials = 1 },
				{ maxMatrixEntries = 1 },
				{ maxLiftedRoots = 1 },
				{ maxCells = 1 },
				{ maxConnections = 0 },
				{ maxPolynomialDegree = 1 },
				{ maxFiberPolynomials = 0 },
				{ maxVertices = 1 },
			}
		do
			fails(function()
				query(saddle(), saddle(true, true), options)
			end, "budget")
		end
		local a = collapsed(function(i)
			return i == 1 and 0 or 1
		end, 1)
		for _, options in { { maxSeamNodes = 0 }, { maxSeamPairs = 0 } } do
			options.requireQuotient = true
			fails(function()
				query(a, flat(), options)
			end, "budget")
		end
	end)
	test("Invalid axes, general tensor surfaces, and noninteger caps are rejected", function()
		fails(function()
			query(saddle(), saddle(), { linearAxisA = "Z" })
		end, "axis")
		fails(function()
			query(parabola(true, 0), saddle(), { linearAxisA = "U" })
		end, "degree one")
		fails(function()
			query(saddle(), saddle(), { maxFiberPolynomials = 0.5 })
		end, "integer")
		fails(function()
			query(saddle(), saddle(), { requireOrdered = true })
		end, "ordering")
	end)
	test("Source and option snapshots survive caller mutation at the first checkpoint", function()
		local a, b = saddle(), saddle(true, true)
		local options =
			{ method = "exactRuledPair", linearAxisA = "V", linearAxisB = "V", requireComplete = true }
		local changed = false
		options.checkpoint = function()
			if changed then
				return
			end
			changed = true
			a.control[1][1] = V(100, 100, 100)
			options.linearAxisA = "invalid"
			options.linearAxisB = "invalid"
		end
		check(E.SplineQuery.intersectSurfaces(a, b, options), 1, 1)
	end)
	test("Cancellation and callback failures cannot return a success certificate", function()
		fails(function()
			query(saddle(), saddle(), {
				cancelled = function()
					return true
				end,
			})
		end, "cancelled")
		fails(function()
			query(saddle(), saddle(), {
				checkpoint = function()
					error("callback sentinel")
				end,
			})
		end, "callback sentinel")
		local stop = false
		fails(function()
			query(saddle(), saddle(), {
				cancelled = function()
					return stop
				end,
				checkpoint = function(info)
					if info.stage == "finish" then
						stop = true
					end
				end,
			})
		end, "cancelled")
	end)
	test("Public exact fiber certificates contain finite data and no private executable state", function()
		local r = query(parabola(true, 0), parabola(false, 0.5))
		local active = {}
		local function inspect(value)
			assert(type(value) ~= "function" and type(value) ~= "thread")
			if type(value) ~= "table" then
				return
			end
			assert(not active[value])
			active[value] = true
			for key, item in value do
				inspect(key)
				inspect(item)
			end
			active[value] = nil
		end
		inspect(r)
		for _, span in r.spans do
			assert(#span.fiber.constraints == 7 and #span.fiber.cases > 0)
			for _, case in span.fiber.cases do
				assert(#case.residuals == 7)
			end
		end
	end)
	if not (settings and settings.skipNative) then
		test("Curved ruled-pair anchors preserve their original UVs in EditableMesh", function()
			local r = query(parabola(true, 0), parabola(false, 0.5), { requireComplete = true })
			local mesh = E.Mesh.new()
			local corners = {}
			for i = 1, 3 do
				mesh:addVertex(r.vertices[i].position)
				corners[i] = {
					uv = Vector2.new(r.vertices[i].parameters[1], r.vertices[i].parameters[2]),
					normal = V(0, 0, 1),
				}
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
							found = found or c.uv == corner.uv
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
