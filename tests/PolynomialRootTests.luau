return function(_E, _settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local work = 0
	local function visit(n)
		work += n or 1
		assert(work <= 100000000, "Polynomial test work cap")
	end
	local R = require(script.Parent.ExactRational)(visit, 8192)
	local P = require(script.Parent.ExactPolynomialRoots)(R, visit, 96)
	local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.PolynomialRootFixtures))
	local function polynomial(values)
		local p = {}
		for i, v in values do
			p[i] = R.number(v)
		end
		return p
	end
	local function options()
		return { tolerance = R.number(2 ^ -36), maxDepth = 128, maxNodes = 10000 }
	end
	local function rational(value)
		return R.fraction(value.sign, value.n, value.d)
	end
	test("64 independently factored rational polynomials retain roots and multiplicities", function()
		for i, c in fixtures.rational do
			local r = P.isolate(polynomial(c.coefficients), R.number(-1), R.number(1), options())
			assert(r.complete and #r.roots == #c.roots, "Reference root count " .. i)
			for j, expected in c.roots do
				local found = r.roots[j]
				assert(
					found.exact
						and R.equal(found.low, R.number(expected.x))
						and found.multiplicity == expected.multiplicity,
					"Reference root " .. i .. ":" .. j
				)
			end
		end
	end)
	test("64 independent nonsquare quadratic products have certified irrational brackets", function()
		for i, c in fixtures.quadratic do
			local r = P.isolate(polynomial(c.coefficients), R.number(-2), R.number(2), options())
			assert(r.complete and #r.roots == #c.roots, "Quadratic count " .. i)
			for j, expected in c.roots do
				local found = r.roots[j]
				assert(found.multiplicity == expected.multiplicity, "Quadratic multiplicity")
				assert(
					R.compare(found.low, rational(expected.low)) <= 0
						and R.compare(found.high, rational(expected.high)) >= 0,
					"Quadratic enclosure"
				)
			end
		end
	end)
	test("Closed isolation retains both domain endpoints and excludes adjacent exterior roots", function()
		local p = P.product(polynomial({ 0, 1 }), P.product(polynomial({ -1, 1 }), polynomial({ 1, 1 })))
		local r = P.isolate(p, R.number(0), R.number(1), options())
		assert(#r.roots == 2 and r.roots[1].exact and r.roots[2].exact)
		assert(R.equal(r.roots[1].low, R.number(0)) and R.equal(r.roots[2].low, R.number(1)))
	end)
	test("Identity is a continuum while a nonzero constant has no roots", function()
		assert(P.isolate({}, R.number(0), R.number(1), options()).identity)
		local r = P.isolate(polynomial({ 1 }), R.number(0), R.number(1), options())
		assert(not r.identity and #r.roots == 0 and r.complete)
	end)
	test("Algebraic shared roots are exact zero decisions rather than tolerance comparisons", function()
		local a = polynomial({ -2, 0, 1 })
		local b = P.product(a, polynomial({ 1, 1 }))
		local union = P.product(a, b)
		local r = P.isolate(union, R.number(1), R.number(2), options())
		assert(#r.roots == 1)
		local s, m = P.atRoot(P.analyze(b), r.roots[1])
		assert(s == 0 and m == 1)
		assert(P.atRoot(P.analyze(polynomial({ -3, 0, 1 })), r.roots[1]) == -1)
		local width = R.sub(r.roots[1].high, r.roots[1].low)
		P.refine(r.analysis, r.roots[1], options())
		assert(R.compare(R.sub(r.roots[1].high, r.roots[1].low), width) < 0)
	end)
	test("Polynomial degree, coefficient, depth and node limits fail without partial success", function()
		local p = polynomial({ -2, 0, 1 })
		local small = require(script.Parent.ExactPolynomialRoots)(R, visit, 1)
		assert(not pcall(small.isolate, p, R.number(1), R.number(2), options()))
		local capped = require(script.Parent.ExactPolynomialRoots)(R, visit, 96, function(n)
			assert(n < 3, "coefficient cap")
		end)
		assert(not pcall(capped.isolate, p, R.number(1), R.number(2), options()))
		local depth = options()
		depth.maxDepth = 0
		assert(not pcall(P.isolate, p, R.number(1), R.number(2), depth))
		local nodes = options()
		nodes.maxNodes = 1
		assert(not pcall(P.isolate, p, R.number(1), R.number(2), nodes))
	end)
	report.success = report.failed == 0
	return report
end
