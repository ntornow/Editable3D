return function()
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function setup(options)
		options = options or {}
		local ctx = {
			work = 0,
			coefficients = 0,
			maxEvents = options.maxEvents or 1024,
			maxDegree = options.maxPolynomialDegree or 96,
			maxPolynomials = options.maxPolynomials or 64,
		}
		ctx.visit = function(n)
			ctx.work += n or 1
			assert(ctx.work <= (options.maxWork or 200000000), "Planar work budget exceeded")
		end
		ctx.allocate = function(n)
			ctx.coefficients += n
			assert(
				ctx.coefficients <= (options.maxCoefficients or 4000000),
				"Planar coefficient budget exceeded"
			)
		end
		local R = require(script.Parent.ExactRational)(ctx.visit, options.maxExactBits or 8192)
		local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, ctx.maxDegree, ctx.allocate)
		local B = require(script.Parent.ExactPolynomialBounds)(R, P, ctx.visit)
		local T = require(script.Parent.ExactBivariatePolynomial)(R, P, ctx)
		local isolation = {
			tolerance = R.number(options.parameterTolerance or 1e-6),
			maxDepth = options.maxDepth or 256,
			maxNodes = options.maxNodes or 20000,
			nodes = 0,
		}
		local function polynomial(values)
			local p = {}
			for i, x in values do
				p[i] = R.number(x)
			end
			return P.trim(p)
		end
		local function bivariate(values)
			local p = {}
			for i, c in values do
				p[i] = polynomial(c)
			end
			return T.trim(p)
		end
		return R, P, B, T, ctx, isolation, polynomial, bivariate
	end
	local function decompose(source, options)
		local R, P, B, _, ctx, isolation, _, bivariate = setup(options)
		local conditions = {}
		for i, c in source do
			conditions[i] = { p = bivariate(c.p), relation = c.relation }
		end
		return require(script.Parent.ExactPlanarSignCells)(
			conditions,
			{ { R.number(0), R.number(1) }, { R.number(0), R.number(1) } },
			R,
			P,
			B,
			isolation,
			ctx,
			options
		)
	end
	local function equal(a, b, R)
		assert(#a == #b, "Polynomial degree mismatch")
		for i, x in a do
			assert(R.equal(x, b[i]), "Polynomial coefficient mismatch")
		end
	end
	local function same(a, b, R)
		assert(#a == #b, "Bivariate degree mismatch")
		for i, p in a do
			equal(p, b[i], R)
		end
	end
	local function fails(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok and string.find(tostring(err), pattern, 1, true), tostring(err))
	end
	local function fixtures(name)
		return game:GetService("HttpService"):JSONDecode(require(script.Parent[name]))
	end
	test("32 independent full-coefficient Sylvester resultants match fraction-free elimination", function()
		local R, P, _, _, ctx, _, polynomial, bivariate = setup()
		local resultant = require(script.Parent.BivariateResultant)
		for _, row in fixtures("TensorResultantFixtures") do
			equal(
				resultant(bivariate(row.a), bivariate(row.b), R, P, ctx.visit, 4096, ctx.allocate),
				polynomial(row.expected),
				R
			)
		end
	end)
	test("28 independently coprime cofactor pairs recover exact common bivariate factors", function()
		local R, _, _, T, _, _, _, bivariate = setup()
		local count = 0
		for index, row in fixtures("TensorResultantFixtures") do
			if #row.expected == 0 then
				continue
			end
			local a, b = bivariate(row.a), bivariate(row.b)
			local common = index % 2 == 0 and bivariate({ { -2, 1 }, { 1, 1 } })
				or bivariate({ { 0, -1 }, {}, { 1 } })
			local first, second = T.product(a, common), T.product(b, common)
			local g = T.gcd(first, second)
			same(g, common, R)
			same(T.quotient(first, g), a, R)
			same(T.quotient(second, g), b, R)
			count += 1
		end
		assert(count == 28)
	end)
	test(
		"Squarefree pairwise-coprime basis retains polynomial contents and repeated shared factors",
		function()
			local R, _, _, T, _, _, _, bivariate = setup()
			local a, b, c =
				bivariate({ { 0, -1 }, { 1 } }),
				bivariate({ { 0, 1 }, { 1 } }),
				bivariate({ { 1, 0, 1 }, {}, { 1 } })
			local basis, contents = T.basis({
				T.product(T.product(a, a), b),
				T.product(T.product(b, b), c),
				T.product(a, c),
				bivariate({ { 0, 0, 1 } }),
			})
			assert(#basis == 3 and #contents[4] == 3)
			for i, p in basis do
				assert(#T.gcd(p, T.derivative(p)) == 1)
				for j = 1, i - 1 do
					assert(#T.gcd(p, basis[j]) == 1)
				end
			end
			local source = bivariate({ { 2, 4 }, { -6, 2 } })
			local primitive, content = T.primitive(source)
			same(T.product({ content }, primitive), source, R)
		end
	)
	test(
		"Localized algebraic arithmetic handles a reducible defining polynomial and other-conjugate denominator zeros",
		function()
			local R, P, B, _, ctx, isolation, polynomial = setup()
			local defining = P.product(polynomial({ -0.5, 0, 1 }), polynomial({ -2, 1 }))
			local result = P.isolate(defining, R.number(0), R.number(1), isolation)
			local root = result.roots[1]
			root.analysis = result.analysis
			local F = require(script.Parent.ExactAlgebraicValue)(R, P, B, root, isolation)
			local K = require(script.Parent.ExactAlgebraicField)(R, P, F, ctx.allocate)
			local alpha = K.fromPolynomial(polynomial({ 0, 1 }))
			assert(K.equal(K.mul(alpha, alpha), K.number(0.5)))
			assert(K.equal(K.div(K.number(1), alpha), K.mul(K.number(2), alpha)))
			local zero = K.fromPolynomial(polynomial({ -0.5, 0, 1 }))
			assert(zero.sign == 0)
			local denominator = K.fromPolynomial(polynomial({ -2, 1 }))
			assert(denominator.sign < 0 and K.equal(K.mul(K.div(alpha, denominator), denominator), alpha))
			fails(function()
				K.div(alpha, zero)
			end, "division by zero")
			fails(function()
				K.fromFraction(polynomial({ 1 }), polynomial({ -0.5, 0, 1 }))
			end, "zero denominator")
		end
	)
	test("Nested Sturm roots preserve fourth-root enclosures and repeated-root multiplicity", function()
		local R, P, B, _, ctx, isolation, polynomial = setup()
		local isolated = P.isolate(polynomial({ -0.5, 0, 1 }), R.number(0), R.number(1), isolation)
		local root = isolated.roots[1]
		root.analysis = isolated.analysis
		local F = require(script.Parent.ExactAlgebraicValue)(R, P, B, root, isolation)
		local K = require(script.Parent.ExactAlgebraicField)(R, P, F, ctx.allocate)
		local Q = require(script.Parent.ExactPolynomialRoots)(K, ctx.visit, 96, ctx.allocate)
		local alpha = K.fromPolynomial(polynomial({ 0, 1 }))
		local p = { K.neg(alpha), K.number(0), K.number(1) }
		local result = Q.isolate(
			p,
			K.number(-1),
			K.number(1),
			{ tolerance = K.number(1e-7), maxDepth = 128, maxNodes = 20000, nodes = 0 }
		)
		assert(#result.roots == 2)
		for _, r in result.roots do
			local lo, hi = K.toRational(r.low), K.toRational(r.high)
			local a, b = R.mul(R.mul(lo, lo), R.mul(lo, lo)), R.mul(R.mul(hi, hi), R.mul(hi, hi))
			if lo.sign > 0 then
				assert(R.compare(a, R.number(0.5)) < 0 and R.compare(b, R.number(0.5)) > 0)
			else
				assert(R.compare(a, R.number(0.5)) > 0 and R.compare(b, R.number(0.5)) < 0)
			end
		end
		local repeated = Q.product(p, Q.product(p, { K.neg(K.div(alpha, K.number(2))), K.number(1) }))
		local multi = Q.isolate(
			repeated,
			K.number(0),
			K.number(1),
			{ tolerance = K.number(1e-7), maxDepth = 128, maxNodes = 20000, nodes = 0 }
		)
		assert(#multi.roots == 2 and multi.roots[1].multiplicity == 1 and multi.roots[2].multiplicity == 2)
	end)
	local analytic = {
		{ name = "Quarter circle", p = { { -0.5, 0, 1 }, {}, { 1 } }, components = 1, dimension = 1 },
		{ name = "Crossing node", p = { { 0, 1, -1 }, { -1 }, { 1 } }, components = 1, dimension = 1 },
		{
			name = "Isolated tangent point",
			p = { { 0.5, -1, 1 }, { -1 }, { 1 } },
			components = 1,
			dimension = 0,
		},
		{ name = "Closed oval", p = { { 0.4375, -1, 1 }, { -1 }, { 1 } }, components = 1, dimension = 1 },
		{ name = "Hyperbola branches", p = { { 0.1875, -0.5 }, { -0.5, 1 } }, components = 2, dimension = 1 },
		{ name = "Cusp", p = { { 0.375, -0.75, 1.5, -1 }, { -1 }, { 1 } }, components = 1, dimension = 1 },
		{
			name = "Vertical component and incident branch",
			p = { { 0.25, -1, 1 }, { -0.5, 1 } },
			components = 1,
			dimension = 1,
		},
		{
			name = "Two isolated points",
			p = { { 0.28515625, -0.375, 1.375, -2, 1 }, { -1 }, { 1 } },
			components = 2,
			dimension = 0,
		},
		{
			name = "Closed disk",
			p = { { -0.4375, 1, -1 }, { 1 }, { -1 } },
			relation = "ge",
			components = 1,
			dimension = 2,
		},
	}
	for _, case in analytic do
		test("Planar CAD classifies " .. case.name, function()
			local result = decompose({ { p = case.p, relation = case.relation or "eq" } })
			assert(#result.components == case.components)
			for _, c in result.components do
				assert(c.dimension == case.dimension)
			end
			for _, connection in result.connections do
				assert(
					result.cells[connection.cell].component == result.cells[connection.eventCell].component
				)
			end
		end)
	end
	test(
		"40 independent Fraction-clipped line arrangements match complete component counts and dimensions",
		function()
			for index, row in fixtures("TensorLineFixtures") do
				local result = decompose({ { p = row.polynomial, relation = "eq" } })
				local dimensions = {}
				for _, c in result.components do
					table.insert(dimensions, c.dimension)
				end
				table.sort(dimensions)
				assert(#dimensions == #row.dimensions, "Component count mismatch " .. index)
				for i, d in dimensions do
					assert(d == row.dimensions[i], "Component dimension mismatch " .. index)
				end
			end
		end
	)
	test("Disjoint coplanar bands retain all event intervals and both two-dimensional components", function()
		local result =
			decompose({ { p = {}, relation = "eq" }, { p = { { 0.1875 }, { -1 }, { 1 } }, relation = "ge" } })
		assert(#result.components == 2)
		local fibers, bands = 0, 0
		for _, c in result.cells do
			if c.kind == "event" then
				fibers += 1
			else
				bands += 1
			end
		end
		assert(fibers == 4 and bands == 2)
	end)
	test("Nested algebraic boundary corners are ordered in their exact coefficient field", function()
		local result = decompose({
			{ p = { { 0, -1 }, {}, { 1 } }, relation = "eq" },
			{
				p = { { -0.5, 0, 1 } },
				relation = "ge",
			},
		})
		assert(#result.components == 1 and not result.events[2].root.exact)
		local lift = result.events[2].lift
		local root = lift.points[lift.components[1].first].root
		local R = result.R
		local lo, hi = lift.asRational(root.low), lift.asRational(root.high)
		assert(R.compare(R.mul(R.mul(lo, lo), R.mul(lo, lo)), R.number(0.5)) < 0)
		assert(R.compare(R.mul(R.mul(hi, hi), R.mul(hi, hi)), R.number(0.5)) > 0)
	end)
	test("A profile content zero exposes an entire disconnected feasible event fiber", function()
		local result = decompose({
			{ p = { {}, { -0.5, 1 } }, relation = "eq" },
			{
				p = { { 0.1875 }, { -1 }, { 1 } },
				relation = "ge",
			},
		})
		assert(#result.components == 2)
		local dimension = {}
		for _, c in result.components do
			table.insert(dimension, c.dimension)
		end
		assert(dimension[1] == 1 and dimension[2] == 1)
	end)
	test("Even repeated inequalities preserve the full feasible two-dimensional domain", function()
		local result = decompose({ { p = { { 0.25, -1, 1 }, { -1, 2 }, { 1 } }, relation = "ge" } })
		assert(#result.components == 1 and result.components[1].dimension == 2)
	end)
	test("Sub-tolerance endpoint arcs retain both endpoints and nonzero dimension", function()
		local conditions = {
			{ p = { { 0, -1 }, {}, { 1 } }, relation = "eq" },
			{
				p = { { 0, 2 ^ -80, -1 } },
				relation = "ge",
			},
		}
		for _, tolerance in { 1e-3, 1e-7 } do
			local result = decompose(conditions, { parameterTolerance = tolerance })
			assert(#result.components == 1 and result.components[1].dimension == 1)
			assert(#result.cells == 3)
		end
		fails(function()
			decompose(conditions, { maxDepth = 20 })
		end, "depth budget")
	end)
	test("Planar proof resource limits fail explicitly across projection, lifting, and adjacency", function()
		local source = { { p = { { -0.5, 0, 1 }, {}, { 1 } }, relation = "eq" } }
		for _, row in
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
			}
		do
			fails(function()
				decompose(source, row)
			end, "budget")
		end
	end)
	test("Swapping profile and fiber axes preserves singular-set components and dimensions", function()
		for _, case in analytic do
			local swapped = {}
			for i, row in case.p do
				for j, x in row do
					swapped[j] = swapped[j] or {}
					swapped[j][i] = x
				end
			end
			local degree = 0
			for _, row in case.p do
				degree = math.max(degree, #row)
			end
			for i = 1, degree do
				swapped[i] = swapped[i] or {}
				for j = 1, #case.p do
					swapped[i][j] = swapped[i][j] or 0
				end
			end
			local result = decompose({ { p = swapped, relation = case.relation or "eq" } })
			assert(#result.components == case.components, case.name)
			for _, c in result.components do
				assert(c.dimension == case.dimension)
			end
		end
	end)
	report.success = report.failed == 0
	return report
end
