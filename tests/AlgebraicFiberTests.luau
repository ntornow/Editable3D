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
		assert(work < 100000000, "Algebraic fixture work cap")
	end
	local R = require(script.Parent.ExactRational)(visit, 8192)
	local P = require(script.Parent.ExactPolynomialRoots)(R, visit, 96)
	local B = require(script.Parent.ExactPolynomialBounds)(R, P, visit)
	local makeField = require(script.Parent.ExactAlgebraicValue)
	local union = require(script.Parent.ExactRootUnion)
	local function poly(values)
		local p = {}
		for i, x in values do
			p[i] = R.number(x)
		end
		return P.trim(p)
	end
	local function options()
		return { tolerance = R.number(2 ^ -12), maxDepth = 256, maxNodes = 10000, nodes = 0 }
	end
	local function field()
		local settings = options()
		local r = P.isolate(poly({ -1, 0, 2 }), R.number(0), R.number(1), settings)
		r.roots[1].analysis = r.analysis
		return makeField(R, P, B, r.roots[1], settings)
	end
	test(
		"384 independent quadratic-field rational comparisons include exact identity and subnative gaps",
		function()
			local F = field()
			local fixtures = game:GetService("HttpService")
				:JSONDecode(require(script.Parent.AlgebraicValueFixtures))
			local function value(source)
				local out = { n = {}, d = {} }
				for _, name in { "n", "d" } do
					for i, x in source[name] do
						out[name][i] = R.fraction(x.sign, x.n, x.d)
					end
					P.trim(out[name])
				end
				return out
			end
			for i, row in fixtures do
				assert(
					F.compare(value(row.a), value(row.b)) == row.comparison,
					"Quadratic field reference " .. i
				)
			end
		end
	)
	test("Vanishing at a root is localized even for a reducible defining polynomial", function()
		local p = P.product(poly({ -1, 0, 2 }), poly({ -3, 0, 4 }))
		local settings = options()
		local r = P.isolate(p, R.number(0.5), R.number(1), settings)
		assert(#r.roots == 2)
		for _, root in r.roots do
			root.analysis = r.analysis
		end
		local first = makeField(R, P, B, r.roots[1], settings)
		local second = makeField(R, P, B, r.roots[2], settings)
		assert(first.sign(poly({ -1, 0, 2 })) == 0 and first.sign(poly({ -3, 0, 4 })) < 0)
		assert(second.sign(poly({ -3, 0, 4 })) == 0 and second.sign(poly({ -1, 0, 2 })) > 0)
	end)
	test("A zero algebraic denominator is rejected before rational ordering", function()
		local F = field()
		assert(not pcall(F.compare, { n = poly({ 1 }), d = poly({ -1, 0, 2 }) }, F.zero))
	end)
	test("Root unions merge shared irrational roots and retain closed endpoints", function()
		local p = poly({ -1, 0, 2 })
		local q = P.product(p, poly({ -0.25, 1 }))
		local roots = union(
			{ p, q, P.product(p, p) },
			R.number(0),
			R.number(1),
			R,
			P,
			options(),
			{ maxEvents = 100 }
		)
		assert(#roots == 4 and roots[1].exact and roots[2].exact and not roots[3].exact and roots[4].exact)
		assert(R.equal(roots[2].low, R.number(0.25)))
	end)
	test("Distinct algebraic roots below native resolution remain ordered and separate", function()
		local a = poly({ -0.5, 0, 1 })
		local b = table.clone(a)
		b[1] = R.sub(b[1], R.number(2 ^ -80))
		local roots = union({ a, b }, R.number(0), R.number(1), R, P, options(), { maxEvents = 100 })
		assert(#roots == 4 and R.compare(roots[2].high, roots[3].low) < 0)
		assert(P.evaluate(a, roots[2].low).sign < 0 and P.evaluate(a, roots[2].high).sign > 0)
		assert(P.evaluate(b, roots[3].low).sign < 0 and P.evaluate(b, roots[3].high).sign > 0)
	end)
	test("Near-endpoint roots leave strict interior rational slab samples", function()
		local a = poly({ -2 ^ -160, 0, 2 })
		local b = P.add(poly({ 1, -2, 1 }), { R.neg(R.number(2 ^ -160)) })
		local roots = union({ a, b }, R.number(0), R.number(1), R, P, options(), { maxEvents = 100 })
		assert(#roots == 4)
		for i = 1, #roots - 1 do
			assert(R.compare(roots[i].high, roots[i + 1].low) < 0)
		end
	end)
	test("Root-union separation respects event and refinement budgets", function()
		local a = poly({ -0.5, 0, 1 })
		local b = table.clone(a)
		b[1] = R.sub(b[1], R.number(2 ^ -80))
		local limits = options()
		limits.maxDepth = 32
		assert(not pcall(union, { a, b }, R.number(0), R.number(1), R, P, limits, { maxEvents = 100 }))
		assert(not pcall(union, { a, b }, R.number(0), R.number(1), R, P, options(), { maxEvents = 1 }))
	end)
	report.success = report.failed == 0
	return report
end
