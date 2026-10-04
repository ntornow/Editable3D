return function()
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function fixture(name)
		return game:GetService("HttpService"):JSONDecode(require(script.Parent[name]))
	end
	test("51 independent exact principal subresultant minors", function()
		local fixtures = fixture("PrincipalSubresultantFixtures")
		local work, allocated = 0, 0
		local ctx = {
			maxDegree = 96,
			visit = function(n)
				work += n or 1
				assert(work < 200000000)
			end,
			allocate = function(n)
				allocated += n
				assert(allocated < 20000000)
			end,
		}
		local R = require(script.Parent.ExactRational)(ctx.visit, 8192)
		local M = require(script.Parent.ExactSparsePolynomial)(R, 3, ctx)
		local psc = require(script.Parent.PrincipalSubresultants)
		local function decode(rows)
			local terms = {}
			for _, row in rows do
				table.insert(
					terms,
					{ powers = { row[1], row[2], row[3] }, value = R.div(R.number(row[4]), R.number(row[5])) }
				)
			end
			return M.make(terms)
		end
		local count = 0
		for index, case in fixtures.cases do
			local a, b = decode(case.a), decode(case.b)
			local result = psc(a, b, 3, M, R, ctx, 4096)
			for i, expected in case.psc do
				assert(M.equal(result[i], decode(expected)), `PSC mismatch {index}:{i}`)
				count += 1
			end
			assert(M.equal(M.quotient(M.product(a, b), b), a))
		end
	end)
	test("81 independent multivariate GCD fixtures and squarefree identities", function()
		local work, allocated = 0, 0
		local ctx = {
			maxDegree = 96,
			visit = function(n)
				work += n or 1
				assert(work < 2000000000)
			end,
			allocate = function(n)
				allocated += n
				assert(allocated < 20000000)
			end,
		}
		local R = require(script.Parent.ExactRational)(ctx.visit, 8192)
		local M = require(script.Parent.ExactSparsePolynomial)(R, 3, ctx)
		local function decode(rows)
			local terms = {}
			for _, row in rows do
				table.insert(
					terms,
					{ powers = { row[1], row[2], row[3] }, value = R.div(R.number(row[4]), R.number(row[5])) }
				)
			end
			return M.make(terms)
		end
		local algebra = require(script.Parent.MultivariateBasis)(M, R, 3, ctx, {})
		local one = M.constant(R.number(1))
		local x, y, z = M.variable(1), M.variable(2), M.variable(3)
		for _, pair in
			{
				{ M.product(M.add(x, y), M.add(z, one)), M.product(M.add(x, y), M.sub(z, one)), M.add(x, y) },
				{ M.product(M.product(x, x), y), M.product(x, M.product(y, y)), M.product(x, y) },
				{ M.add(M.product(x, x), y), M.add(M.product(x, x), z), one },
				{
					M.product(x, M.add(y, z)),
					M.product(x, M.add(M.product(y, y), M.product(y, z))),
					M.product(x, M.add(y, z)),
				},
			}
		do
			assert(M.equal(algebra.gcd(pair[1], pair[2]), M.normalize(pair[3])))
		end
		local squared = M.product(M.product(M.add(x, y), M.add(x, y)), M.product(z, z))
		assert(M.equal(algebra.squarefree(squared), M.normalize(M.product(M.add(x, y), z))))

		local gcdFixtures = fixture("MultivariateGcdFixtures")
		for i, case in gcdFixtures do
			local actual = algebra.gcd(decode(case.a), decode(case.b))
			assert(M.equal(actual, M.normalize(decode(case.gcd))), "Independent GCD mismatch " .. i)
		end
	end)
	test("157 independent Sturm Tarski signs without root refinement", function()
		local work, allocated = 0, 0
		local ctx = {
			maxDegree = 96,
			visit = function(n)
				work += n or 1
				assert(work <= 200000000, "Tarski fixture work budget")
			end,
			allocate = function(n)
				allocated += n
				assert(allocated <= 2000000)
			end,
		}
		local R = require(script.Parent.ExactRational)(ctx.visit, 8192)
		local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, 96, ctx.allocate)
		local B = require(script.Parent.ExactPolynomialBounds)(R, P, ctx.visit)
		local function decode(q)
			return R.fraction(q.sign, q.n, q.d)
		end
		local function poly(rows)
			local out = {}
			for _, q in rows do
				out[#out + 1] = decode(q)
			end
			return P.trim(out)
		end
		local fixtures = fixture("SturmTarskiFixtures")
		for i, case in fixtures do
			local p, g = poly(case.f), poly(case.g)
			local root = {
				low = decode(case.low),
				high = decode(case.high),
				exact = false,
				depth = 0,
				analysis = P.analyze(p),
			}
			assert(P.count(root.analysis, root.low, root.high) == 1)
			local actual = require(script.Parent.SturmTarskiSign)(R, P, root, g)
			assert(actual == case.sign, "Tarski fixture mismatch " .. i)
			local F = require(script.Parent.ExactGeneralAlgebraicValue)(
				R,
				P,
				B,
				root,
				{ maxDepth = 0, maxNodes = 0, nodes = 0, tolerance = R.number(1e-7) }
			)
			assert(F.sign(g) == case.sign and root.depth == 0, "Algebraic sign must not refine the root")
		end
	end)
	test("Localized algebraic moduli retain exact inverse identities in a radical tower", function()
		local work, allocated = 0, 0
		local ctx = {
			maxDegree = 96,
			visit = function(n)
				work += n or 1
				assert(work <= 200000000, "Reduced field work budget")
			end,
			allocate = function(n)
				allocated += n
				assert(allocated <= 4000000)
			end,
		}
		local R = require(script.Parent.ExactRational)(ctx.visit, 8192)
		local function extension(base, source, low, high)
			local P = require(script.Parent.ExactPolynomialRoots)(base, ctx.visit, 96, ctx.allocate)
			local B = require(script.Parent.ExactPolynomialBounds)(base, P, ctx.visit)
			local root = { low = low, high = high, exact = false, depth = 0, analysis = P.analyze(source) }
			assert(P.count(root.analysis, low, high) == 1)
			local F = require(script.Parent.ExactGeneralAlgebraicValue)(
				base,
				P,
				B,
				root,
				{ maxDepth = 0, maxNodes = 0, nodes = 0, tolerance = base.number(1e-7) }
			)
			return require(script.Parent.ReducedAlgebraicField)(base, P, F, ctx.allocate), root, P
		end
		local K, root, P = extension(
			R,
			{ R.number(0.375), R.number(0), R.number(-1.25), R.number(0), R.number(1) },
			R.number(0.625),
			R.number(0.75)
		)
		local a = K.fromPolynomial({ R.number(0), R.number(1) })
		assert(K.equal(K.mul(a, a), K.number(0.5)))
		local d = K.sub(K.mul(a, a), K.number(0.75))
		assert(K.equal(K.div(K.number(1), d), K.number(-4)))
		assert(#root.analysis.squarefree == 3 and #root.modulusReductions == 1)
		for _, step in root.modulusReductions do
			assert(#P.quotient(step.before, step.discarded) == #step.after)
		end
		assert(K.equal(K.div(K.number(1), K.add(a, K.number(1))), K.mul(K.number(2), K.sub(K.number(1), a))))
		for i = 1, 40 do
			local b = K.number(i / 64)
			local ratio = K.div(K.add(a, b), K.sub(a, b))
			assert(K.equal(K.mul(ratio, K.div(K.sub(a, b), K.add(a, b))), K.number(1)))
			assert(#ratio.n < #root.analysis.squarefree and #ratio.d == 1)
		end
		local L, bRoot = extension(K, { K.neg(a), K.number(0), K.number(1) }, K.number(0.8), K.number(0.9))
		local b = L.fromPolynomial({ K.number(0), K.number(1) })
		assert(L.equal(L.mul(b, b), L.rational(a)))
		assert(L.equal(L.mul(L.mul(b, b), L.mul(b, b)), L.number(0.5)))
		assert(L.equal(L.div(L.mul(L.mul(b, b), b), b), L.rational(a)))
		assert(root.depth == 0 and bRoot.depth == 0)
	end)
	test(
		"Guarded CAD falls back on nullification and preserves cancellation and universal domains",
		function()
			local work, allocated = 0, 0
			local ctx = {
				maxDegree = 64,
				visit = function(n)
					work += n or 1
					assert(work <= 5000000)
				end,
				allocate = function(n)
					allocated += n
					assert(allocated <= 1000000)
				end,
			}
			local R = require(script.Parent.ExactRational)(ctx.visit, 8192)
			local M = require(script.Parent.ExactSparsePolynomial)(R, 4, ctx)
			local tower = require(script.Parent.GuardedTowerCAD)
			local r = tower(
				{ M.sub(M.product(M.variable(1), M.variable(3)), M.variable(2)) },
				4,
				R,
				ctx,
				{},
				function(s)
					return s[1] == 0
				end
			)
			assert(r.projectionFallback and r.projectionMethod == "collins")
			local count, dimension = 0, 0
			for _, c in r.leaves do
				if c.feasible then
					count += 1
					dimension = math.max(dimension, c.dimension)
				end
			end
			assert(dimension == 3)
			local token = {}
			local visits = 0
			local canceled = {
				maxDegree = 64,
				visit = function(n)
					visits += n or 1
					if visits > 100 then
						error(token, 0)
					end
				end,
				allocate = function() end,
			}
			local ok, err = pcall(tower, { M.variable(1) }, 4, R, canceled, {}, function(s)
				return s[1] == 0
			end)
			assert(not ok and err == token)
			for _, quantifier in { "exists", "forall" } do
				local oneD = require(script.Parent.ExactSparsePolynomial)(R, 1, ctx)
				local result = tower({ oneD.variable(1) }, 1, R, ctx, {
					quantifiers = { quantifier },
					requiredZero = function()
						return { 1 }
					end,
				}, function(s)
					return s[1] == 0
				end)
				assert(result.result == (quantifier == "exists"))
			end
		end
	)
	test("Exact closure rejects a spurious weak-inequality connection", function()
		local work, allocated = 0, 0
		local ctx = {
			maxDegree = 64,
			visit = function(n)
				work += n or 1
				assert(work <= 200000000, "Closure regression work cap")
			end,
			allocate = function(n)
				allocated += n
				assert(allocated <= 8000000)
			end,
		}
		local R = require(script.Parent.ExactRational)(ctx.visit, 8192)
		local M = require(script.Parent.ExactSparsePolynomial)(R, 3, ctx)
		local x, z, y = M.variable(1), M.variable(2), M.variable(3)
		local xx = M.product(x, x)
		local source = {
			x,
			z,
			y,
			M.sub(y, M.constant(R.number(0.5))),
			M.sub(z, xx),
			M.sub(M.scale(xx, R.number(2)), z),
			M.sub(M.product(x, y), z),
		}
		local cad = require(script.Parent.GuardedTowerCAD)(
			source,
			3,
			R,
			ctx,
			{ maxNodes = 100000, maxCells = 100000 },
			function()
				return true
			end
		)
		local C, origin, far
		for _, cell in cad.leaves do
			local s = cell.originalSigns
			if cell.dimension == 0 and s[1] == 0 and s[2] == 0 then
				if s[3] == 0 then
					origin = cell
				elseif s[4] == 0 then
					far = cell
				end
			end
			if cell.dimension == 2 and s[1] == 1 and s[5] == 1 and s[6] == 1 and s[7] == 0 then
				local node = cell
				while node.axis > 1 do
					node = node.parent
				end
				if node.index == 2 then
					C = cell
				end
			end
		end
		assert(C and origin and far)
		local closure = require(script.Parent.CellClosure)
		local bad = closure(C, far, cad, R, ctx, { maxNodes = 100000, maxCells = 100000 })
		assert(not bad)
		local good = closure(C, origin, cad, R, ctx, { maxNodes = 100000, maxCells = 100000 })
		assert(good)
	end)
	report.success = report.failed == 0
	return report
end
