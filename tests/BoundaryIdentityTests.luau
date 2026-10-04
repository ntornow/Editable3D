return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local U = require(script.Parent.Util)
	local makeR = require(script.Parent.ExactRational)
	local identity = require(script.Parent.SurfaceBoundaryIdentity)
	local H = game:GetService("HttpService")
	local V = Vector3.new
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
	local function context(settings)
		settings = settings or {}
		local result = { work = 0, maxExactBits = settings.maxExactBits or 8192 }
		result.visit = function(n)
			result.work += n or 1
			assert(result.work <= (settings.maxWork or 100000000), "fixture work limit")
			assert(not settings.cancelled or not settings.cancelled(), "fixture cancelled")
		end
		result.allocate = function(n)
			assert(n <= (settings.maxCoefficients or 1000000), "fixture coefficient limit")
		end
		return result
	end
	local function cylinder(degree, intervals)
		local rows = {}
		for _, p in { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) } do
			table.insert(rows, { p - Vector3.zAxis, p + Vector3.zAxis })
		end
		return E.Cyclic.surface(rows, degree, 1, { intervalsU = intervals, cyclicU = true, cyclicV = false })
	end
	local function plane()
		return E.NURBS.surface({ { V(-2, -2, 0), V(-2, 2, 0) }, { V(2, -2, 0), V(2, 2, 0) } }, 1, 1)
	end
	local function projective()
		return E.NURBS.surface({
			{ V(0, 0, 0), V(0.5, 0, 0), V(1, 0, 0) },
			{ V(0, 1, 0), V(0.5, 1, 0), V(1, 1, 0) },
			{
				V(0, 0, 0),
				V(0.25, 0, 0),
				V(1, 0, 0),
			},
		}, 2, 2, { weights = { { 1, 1, 1 }, { 1, 1, 1 }, { 1, 2, 3 } } })
	end
	test("Exact rationals match 320 independent Fraction operations up to 1024 bits", function()
		local ctx = context()
		local R = makeR(ctx.visit, 8192)
		local data = H:JSONDecode(require(script.Parent.ExactRationalFixtures))
		for _, row in data.rows do
			local a = R.fraction(row.a.sign, row.a.n, row.a.d)
			local b = R.fraction(row.b.sign, row.b.n, row.b.d)
			assert(same(a, row.a) and same(b, row.b))
			for _, name in { "add", "sub", "mul", "div" } do
				if row[name] then
					assert(same(R[name](a, b), row[name]), name)
				end
			end
			assert(R.compare(a, b) == row.comparison)
			assert(R.equal(a, b) == (row.comparison == 0))
		end
	end)
	test("Exact float64 decoding preserves all 96 fixtures including subnormal stored bits", function()
		local R = makeR(context().visit, 8192)
		for _, row in H:JSONDecode(require(script.Parent.ExactRationalFixtures)).values do
			local bytes = buffer.create(8)
			buffer.writeu32(bytes, 0, row.lo)
			buffer.writeu32(bytes, 4, row.hi)
			assert(same(R.number(buffer.readf64(bytes, 0)), row.expected))
		end
	end)
	test("Exact arithmetic enforces bit and work limits and rejects invalid values", function()
		local R = makeR(context().visit, 64)
		assert(not pcall(R.number, 2 ^ 100))
		assert(not pcall(R.mul, R.number(2 ^ 40), R.number(2 ^ 40)))
		for _, x in { math.huge, -math.huge, 0 / 0 } do
			assert(not pcall(R.number, x))
		end
		assert(not pcall(R.div, R.number(1), R.number(0)))
		assert(not pcall(makeR, function() end, 0))
		assert(not pcall(R.fraction, 1, { 1 }, { 0 }))
		assert(not pcall(R.fraction, 1, { 2 ^ 24 }, { 1 }))
		local limited = makeR(context({ maxWork = 1 }).visit, 8192)
		assert(not pcall(limited.number, 2 ^ -1000))
	end)
	test("Exact operations leave their input limbs unchanged and normalize cancellation", function()
		local R = makeR(context().visit)
		local a = R.div(R.number(1), R.number(3))
		local b = R.div(R.number(5), R.number(7))
		local aa, bb = U.copy(a), U.copy(b)
		for _, name in { "add", "sub", "mul", "div", "compare", "equal" } do
			R[name](a, b)
		end
		assert(same(a, aa) and same(b, bb))
		assert(R.equal(R.sub(a, a), R.number(0)))
		assert(R.equal(R.add(a, R.neg(a)), R.number(-0)))
		assert(R.equal(R.div(R.mul(a, b), b), a))
	end)
	test("Boundary coefficients agree with 32 independent pointwise de Boor identities", function()
		local cases = H:JSONDecode(require(script.Parent.BoundaryIdentityFixtures))
		for index, row in cases do
			local points = {}
			for i, list in row.control do
				points[i] = {}
				for j, p in list do
					points[i][j] = V(p[1], p[2], p[3])
				end
			end
			local source = E.NURBS.surface(points, row.degreeU, row.degreeV, {
				weights = row.weights,
				knotsU = row.knotsU,
				knotsV = row.knotsV,
				clampedU = false,
				clampedV = false,
			})
			local ctx = context()
			local equal, proof = identity(source, 1, ctx)
			assert(equal == row.expected and proof.certified and proof.equal == equal, "boundary " .. index)
		end
	end)
	test("Boundary equality recognizes a nonconstant homogeneous weight factor", function()
		local equal, proof = identity(projective(), 1, context())
		assert(equal and proof.checkedSpans == 1)
	end)
	test("Matching boundary endpoints cannot hide a different interior curve", function()
		local source = projective()
		source.control[3][2] = V(0.25, 0.125, 0)
		local equal, proof = identity(source, 1, context())
		assert(not equal and proof.certified and proof.axis == 2)
	end)
	test("Transposed parameter direction has the same exact boundary decision", function()
		local source = projective()
		local transposed = U.copy(source)
		transposed.control, transposed.weights = {}, {}
		for j = 1, #source.control[1] do
			transposed.control[j], transposed.weights[j] = {}, {}
			for i, row in source.control do
				transposed.control[j][i] = row[j]
				transposed.weights[j][i] = source.weights[i][j]
			end
		end
		transposed.degreeU, transposed.degreeV = source.degreeV, source.degreeU
		transposed.knotsU, transposed.knotsV = source.knotsV, source.knotsU
		assert(identity(transposed, 2, context()))
	end)
	test("Power-of-two weight gauges and translated native controls preserve exact identity", function()
		for _, gauge in { 2 ^ -500, 1, 2 ^ 500 } do
			local source = projective()
			for i, row in source.control do
				for j, p in row do
					source.control[i][j] = p * 16 + V(2 ^ 20, -2 ^ 20, 2 ^ 20)
					source.weights[i][j] *= gauge
				end
			end
			assert(identity(source, 1, context()))
		end
	end)
	test("Rounded cyclic knots can give distinct exact seams despite equal native evaluations", function()
		local source = E.Cyclic.surfaceToNURBS(cylinder(2, { 0.1, 0.2, 0.3, 0.4 }))
		local equal, proof = identity(source, 1, context())
		assert(not equal and proof.certified and proof.reason == "differentBoundaryCurves")
		local a = E.NURBS.evaluateSurface(source, 0, 0.5)
		local b = E.NURBS.evaluateSurface(source, 1, 0.5)
		assert(a == b, "The test must distinguish exact model equality from native evaluation coincidence")
	end)
	test("A constant periodic boundary cancels rounded knot discrepancies exactly", function()
		local source = E.Cyclic.surfaceToNURBS(cylinder(3, { 0.1, 0.2, 0.3, 0.4 }))
		for _, row in source.control do
			row[1], row[2] = V(1, 0, -1), V(1, 0, 1)
		end
		assert(identity(source, 1, context()))
	end)
	test("Exact seam identity extends certified periodic paths beyond expansion exponent limits", function()
		for _, scale in { 2 ^ -901, 2 ^ 901 } do
			local result = E.SplineQuery.intersectSurfaces(
				cylinder(2, { scale, scale, scale, scale }),
				plane(),
				{ tolerance = 0.005, requireQuotient = true }
			)
			assert(result.quotientComplete and result.periodicQuotient.componentCount == 1)
			local axis = result.periodicQuotient.axes[1]
			assert(
				axis.reason == "exactBoundaryCurveIdentity"
					and axis.identity.certified
					and axis.identity.equal
			)
			assert(result.periodicQuotient.paths[1].closed)
		end
	end)
	test("Failed periodic geometry retains an exact unequal-coefficient witness", function()
		local result = E.SplineQuery.intersectSurfaces(
			cylinder(2, { 0.1, 0.2, 0.3, 0.4 }),
			plane(),
			{ tolerance = 0.01, identifyPeriodicSeams = true }
		)
		local axis = result.periodicQuotient.axes[1]
		assert(not result.quotientTopologyCertified and result.periodicQuotient.reason == "seamGeometry")
		assert(axis.identity.certified and not axis.identity.equal and axis.identity.coefficient >= 1)
	end)
	test("Exact identity work, coefficient and bit budgets preserve source data", function()
		local source = projective()
		local before = U.copy(source)
		for _, settings in
			{
				{ maxWork = 1 },
				{ maxCoefficients = 1 },
				{ maxExactBits = 1 },
				{
					cancelled = function()
						return true
					end,
				},
			}
		do
			assert(not pcall(identity, source, 1, context(settings)))
		end
		assert(same(source, before))
	end)
	test("Root cancellation and exact-bit caps apply during periodic identity fallback", function()
		local scale = 2 ^ 901
		local a = cylinder(2, { scale, scale, scale, scale })
		assert(
			not pcall(
				E.SplineQuery.intersectSurfaces,
				a,
				plane(),
				{ identifyPeriodicSeams = true, maxExactBits = 64, tolerance = 0.01 }
			)
		)
		local stop = false
		assert(not pcall(E.SplineQuery.intersectSurfaces, a, plane(), {
			identifyPeriodicSeams = true,
			tolerance = 0.01,
			cancelled = function()
				return stop
			end,
			checkpoint = function(status)
				if status.stage == "seamIdentity" then
					stop = true
				end
			end,
		}))
	end)
	test("Periodic exact identity uses detached source and option snapshots", function()
		local scale = 2 ^ 901
		local a = cylinder(2, { scale, scale, scale, scale })
		local options = { tolerance = 0.01, requireQuotient = true, maxExactBits = 8192 }
		options.checkpoint = function(status)
			if status.stage == "begin" then
				a.control[1][1] = V(999, 999, 999)
				options.maxExactBits = 1
			end
		end
		local result = E.SplineQuery.intersectSurfaces(a, plane(), options)
		assert(result.quotientComplete and result.periodicQuotient.axes[1].identity.equal)
	end)
	if not settings or not settings.skipNative then
		test("An exact-fallback periodic boundary survives native EditableMesh conversion", function()
			local scale = 2 ^ 901
			local result = E.SplineQuery.intersectSurfaces(
				cylinder(2, { scale, scale, scale, scale }),
				plane(),
				{ tolerance = 0.005, requireQuotient = true }
			)
			local path = result.periodicQuotient.paths[1]
			local mesh = E.Mesh.new()
			local center = mesh:addVertex(Vector3.zero)
			local ids = {}
			for i, sample in path.samples do
				ids[i] = mesh:addVertex(sample.position)
			end
			for _, segment in path.segments do
				mesh:addFace({ center, ids[segment.first], ids[segment.last] })
			end
			mesh:recalculateNormals()
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local back = E.Roblox.fromEditable(handle.editable)
				assert(back:validate().valid)
				local topology = E.Connectivity.analyze(back)
				assert(topology.eulerCharacteristic == 1 and #topology.boundaryLoops == 1)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
