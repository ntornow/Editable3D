return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		report.results[#report.results + 1] =
			{ name = name, passed = ok, error = not ok and tostring(err) or nil }
	end
	local fixture = game:GetService("HttpService"):JSONDecode(require(script.Parent.AnnularNormalFixtures))
	local V, S = Vector3.new, E.Subdivision
	local function pause(s)
		if task and s.stage == "exactNormalWork" then
			task.wait()
		end
	end
	local function options(extra)
		local out = { exactConstrainedNormals = true, checkpoint = pause }
		for k, v in extra or {} do
			out[k] = v
		end
		return out
	end
	local function setup(cap)
		local work = 0
		local function tick(n)
			work += n or 1
			assert(work <= (cap or 100000000), "Test work cap")
		end
		local R = require(script.Parent.ExactRational)(tick, 8192)
		local P = require(script.Parent.ExactPolynomialRoots)(R, tick, 256)
		return R, P, tick
	end
	local function exact(R, q)
		return R.div(R.number(tonumber(q[1])), R.number(tonumber(q[2])))
	end
	local function near(a, b, e)
		assert((a - b).Magnitude <= (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function four()
		local m = E.Mesh.new()
		for _, p in
			{
				V(0, 0.25, 0.125),
				V(-2, 0, 0),
				V(-1, 1, 2),
				V(0, 2, 0.25),
				V(1, 1, -0.5),
				V(2, 0, 0.25),
				V(-3, 2, 1),
				V(-1, 3, 1.5),
				V(1, 3, 2),
				V(3, 2, -1),
			}
		do
			m:addVertex(p)
		end
		for i = 1, 4 do
			m:addFace({ 1, i + 1, i + 6, i + 2 })
		end
		return m
	end
	local cycle = { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) }
	local function affine(n, transform)
		transform = transform or function(p)
			return p
		end
		local m = E.Mesh.new()
		m:addVertex(transform(Vector3.zero))
		for j = 0, n do
			m:addVertex(transform(cycle[j % 4 + 1]))
		end
		for j = 0, n - 1 do
			local d = m:addVertex(transform(cycle[j % 4 + 1] + cycle[(j + 1) % 4 + 1]))
			m:addFace({ 1, j + 2, d, j + 3 })
		end
		return S.crease(m, nil, { [1] = 10 })
	end
	test("Real-spectrum interval counts and highest-root multiplicities match known roots", function()
		local R, P, tick = setup()
		local baseGcd, baseAnalyze, baseCount = P.gcd, P.analyze, P.count
		P = require(script.Parent.RealSpectrumPolynomial)(R, P, tick)
		P.gcd = require(script.Parent.ExactModularPolynomialGCD)(R, P, tick, {})
		local one = R.number(1)
		for _, roots in
			{
				{ -0.75, -0.25, 0.125, 0.5, 0.875 },
				{ 0.125, 0.125, 0.5, 0.5, 0.5, 0.75 },
				{ 0, 0, 0.25, 0.25, 0.5, 0.5, 1 },
				{ 0.125, 0.125, 0.125, 0.125 },
				{ 0, 0, 0 },
				{ -0.75, -0.5, -0.25 },
			}
		do
			local p = { one }
			for _, x in roots do
				p = P.product(p, { R.number(-x), one })
			end
			local expected = baseGcd(p, P.derivative(p))
			local actual = P.gcd(p, P.derivative(p))
			assert(#actual == #expected)
			for i, x in actual do
				assert(R.equal(x, expected[i]))
			end
			local known = baseAnalyze(p)
			P.realSpectrum = true
			local analysis = P.analyze(p)
			for _, range in
				{
					{ -1, 1 },
					{ 0, 1 },
					{ 0.125, 0.5 },
					{ -0.5, 0.25 },
					{ 0.25, 0.5 },
					{ 0.5, 0.75 },
					{
						0.75,
						0.875,
					},
				}
			do
				local a, b = R.number(range[1]), R.number(range[2])
				assert(P.count(analysis, a, b) == baseCount(known, a, b))
			end
			local isolated = P.highestRealRoot(
				p,
				R.number(-1),
				R.number(1),
				{ tolerance = R.number(1 / 1024), maxDepth = 128, maxNodes = 10000 }
			)
			local root = isolated.roots[1]
			local maximum = math.max(table.unpack(roots))
			assert(root.exact and R.equal(root.low, R.number(maximum)))
			local count = 0
			for _, x in roots do
				if x == maximum then
					count += 1
				end
			end
			assert(root.multiplicity == count)
			P.realSpectrum = false
		end
		for _, factors in
			{ { { -0.125, 0, 1 }, { -0.5, 0, 1 } }, { { -0.125, 0, 1 }, { -0.75, 1 }, { -0.875, 1 } } }
		do
			local p = { one }
			for _, numbers in factors do
				local factor = {}
				for i, x in numbers do
					factor[i] = R.number(x)
				end
				p = P.product(p, factor)
			end
			local known = baseAnalyze(p)
			P.realSpectrum = true
			local analysis = P.analyze(p)
			for _, range in { { -1, 1 }, { 0, 1 }, { 0.25, 0.5 }, { 0.5, 0.75 } } do
				local a, b = R.number(range[1]), R.number(range[2])
				assert(P.count(analysis, a, b) == baseCount(known, a, b))
			end
			local isolated = P.highestRealRoot(
				p,
				R.number(0),
				R.number(1),
				{ tolerance = R.number(1 / 1024), maxDepth = 128, maxNodes = 10000 }
			)
			local root = isolated.roots[1]
			assert(baseCount(known, root.low, root.high) == 1 or root.exact)
			P.realSpectrum = false
		end
	end)
	local fourResult
	test("128 independent large-integer normalizations exercise exact quotient paths", function()
		local R = setup()
		for _, case in fixture.arithmetic do
			local a = R.fraction(case.sign, case.n, case.d)
			assert(R.equal(a, { sign = case.sign, n = case.expectedN, d = case.expectedD }))
			assert(R.equal(R.div(a, a), R.number(1)))
			assert(R.equal(R.mul(a, R.number(3)), R.add(a, R.add(a, a))))
		end
	end)
	test("32 independent recurrences verify modular reconstruction including bad primes", function()
		local R, _, tick = setup()
		for _, case in fixture.recurrences do
			local initial = {}
			for _, row in case.source do
				for _, q in row do
					initial[#initial + 1] = exact(R, q)
				end
			end
			local matrix = {}
			for i, row in case.matrix do
				matrix[i] = {}
				for j, q in row do
					matrix[i][j] = exact(R, q)
				end
			end
			local function advance(v)
				local out = table.create(#v, R.number(0))
				for i, row in matrix do
					for j, x in row do
						for axis = 1, 3 do
							local k = (i - 1) * 3 + axis
							out[k] = R.add(out[k], R.mul(x, v[(j - 1) * 3 + axis]))
						end
					end
				end
				return out
			end
			local p = require(script.Parent.ExactModularRecurrence)(
				R,
				initial,
				advance,
				#matrix,
				{ normalRecurrenceScale = 16 },
				tick
			)
			assert(#p == #case.polynomial)
			for i, x in p do
				assert(R.equal(x, exact(R, case.polynomial[i])))
			end
		end
	end)
	test("Modular recurrence degree, prime, allocation and work caps remain hard", function()
		local R, _, tick = setup()
		local advance = function(v)
			return { R.mul(v[1], R.number(0.5)), R.mul(v[2], R.number(0.25)) }
		end
		local certify = require(script.Parent.ExactModularRecurrence)
		local v = { R.div(R.number(1), R.number(16777213)), R.number(1) }
		for _, o in { { maxNormalPrimes = 1 }, { maxNormalKrylovDegree = 1 }, { maxExactCoefficients = 1 } } do
			assert(not pcall(certify, R, v, advance, 2, o, tick))
		end
		local marker = {}
		assert(select(
			2,
			pcall(certify, R, v, advance, 2, {}, function()
				error(marker)
			end)
		) == marker)
	end)
	test("Invariant scalar subspaces preserve all three coordinate evolutions", function()
		local R, _, tick = setup()
		for _, case in
			{
				{
					matrix = { { 0.5, 0, 0 }, { 0, 0.25, 0 }, { 0, 0, 0.125 } },
					initial = { 1, 2, 0, 2, 4, 0, 3, 6, 0 },
					dimension = 3,
				},
				{
					matrix = { { 0.5, 0, 0 }, { 0, 0.5, 0 }, { 0, 0, 0.5 } },
					initial = { 1, 2, 0, 2, 4, 0, 3, 6, 0 },
					dimension = 1,
				},
				{
					matrix = { { 0.5, 1, 0 }, { 0, 0.5, 0 }, { 0, 0, 0.25 } },
					initial = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
					dimension = 3,
				},
				{
					matrix = { { 0, 1, 0 }, { 0, 0, 1 }, { 0, 0, 0 } },
					initial = { 0, 0, 0, 0, 0, 0, 1, 2, 3 },
					dimension = 3,
				},
				{ matrix = { { 0.5, 0 }, { 0, 0.25 } }, initial = { 0, 0, 0, 0, 0, 0 }, dimension = 0 },
			}
		do
			local initial = {}
			for i, x in case.initial do
				initial[i] = R.number(x)
			end
			local function advance(v)
				local out = {}
				for i, row in case.matrix do
					local sum = R.number(0)
					for j, x in row do
						sum = R.add(sum, R.mul(R.number(x), v[j]))
					end
					out[i] = sum
				end
				return out
			end
			local b = require(script.Parent.ExactInvariantSubspace)(R, initial, advance, {}, tick)
			assert(b.dimension == case.dimension)
			local v, full = b.initial, initial
			for _ = 0, 12 do
				local recovered = b.restore(v)
				for i, x in full do
					assert(R.equal(x, recovered[i]))
				end
				v = b.advance(v)
				local out = {}
				for axis = 1, 3 do
					local column = {}
					for i = 1, #full / 3 do
						column[i] = full[(i - 1) * 3 + axis]
					end
					column = advance(column)
					for i, x in column do
						out[(i - 1) * 3 + axis] = x
					end
				end
				full = out
			end
		end
	end)
	test("Cross-product maps match 972 direct bicubic Bernstein coefficients", function()
		local R, P, tick = setup()
		for _, n in { 1, 3, 4 } do
			local masks = require(script.Parent.AnnularControlMasks)(R, n, "corner", false, tick)
			local basis = {}
			for i = 1, 4 do
				basis[i] = { value = {} }
				for j = 1, masks.size do
					basis[i].value[j] = R.number(((i * 17 + j * 13) % 19 - 9) / 8)
				end
			end
			local values = {}
			for i = 1, 12 do
				values[i] = R.number(((i * 7) % 17 - 8) / 4)
			end
			local points = {}
			for j = 1, masks.size do
				points[j] = {}
				for axis = 1, 3 do
					local sum = R.number(0)
					for i, b in basis do
						sum = R.add(sum, R.mul(b.value[j], values[(i - 1) * 3 + axis]))
					end
					points[j][axis] = sum
				end
			end
			local wedge = {}
			for i = 1, 3 do
				for j = i + 1, 4 do
					for _, axes in { { 2, 3 }, { 3, 1 }, { 1, 2 } } do
						wedge[#wedge + 1] = {
							R.sub(
								R.mul(values[(i - 1) * 3 + axes[1]], values[(j - 1) * 3 + axes[2]]),
								R.mul(values[(i - 1) * 3 + axes[2]], values[(j - 1) * 3 + axes[1]])
							),
						}
					end
				end
			end
			local mapped = require(script.Parent.AnnularCrossMap)(R, P, masks, basis, 1, tick)(wedge)
			local direct = require(script.Parent.AnnularJacobianCoefficients)(R, masks, points, 1, tick)
			for i, x in direct do
				assert(#mapped[i] <= 1 and R.equal(x, mapped[i][1] or R.number(0)))
			end
		end
	end)
	local function field(R, P, tick, coefficients)
		local p = {}
		for i, x in coefficients do
			p[i] = R.number(x)
		end
		local settings = { tolerance = R.number(1 / 1024), maxDepth = 128, maxNodes = 10000 }
		local isolated = P.isolate(p, R.number(0), R.number(1), settings)
		local root = isolated.roots[1]
		root.analysis = isolated.analysis
		return require(script.Parent.AnnularAlgebraicValue)(
			R,
			P,
			require(script.Parent.ExactPolynomialBounds)(R, P, tick),
			root,
			settings
		)
	end
	local function liftCase(n, boundary, creasing, offset)
		local R, _, tick = setup()
		local U = require(script.Parent.Util)
		local mesh = E.Mesh.new()
		mesh:addVertex(V(0.25, -0.5, 0.125))
		local edges, diagonals = {}, {}
		local faces = n + (offset ~= nil and 1 or 0)
		for j = 0, faces do
			local p = cycle[j % 4 + 1]
			edges[j + 1] = mesh:addVertex(p + V(0, 0, (j % 3 - 1) * 0.25))
		end
		for j = 0, faces - 1 do
			local a, b = cycle[j % 4 + 1], cycle[(j + 1) % 4 + 1]
			diagonals[j + 1] = mesh:addVertex(a + b + V(0, 0, (j % 3) * 0.5))
			mesh:addFace({ 1, edges[j + 1], diagonals[j + 1], edges[j + 2] })
		end
		local sharp = { [1] = 10, [edges[2]] = 0.375, [diagonals[1]] = 1.75 }
		local marks = { [U.edge(edges[2], diagonals[1])] = 0.75, [U.edge(edges[2], diagonals[2])] = 2.25 }
		if offset ~= nil then
			marks[U.edge(1, offset == 0 and edges[n + 1] or edges[2])] = 10
		end
		mesh = S.crease(mesh, marks, sharp)
		local m = { vertices = {}, faces = {}, edges = marks, sharp = sharp }
		for i, p in mesh.vertices do
			m.vertices[i] = { p.X, p.Y, p.Z, 0 }
		end
		for i, f in mesh.faces do
			m.faces[i] = table.clone(f.vertices)
		end
		local sector = { faces = {}, edges = {}, diagonals = {}, kind = "corner", count = n }
		for i = 1, n do
			sector.faces[i] = i + (offset or 0)
			sector.diagonals[i] = diagonals[i + (offset or 0)]
		end
		for i = 1, n + 1 do
			sector.edges[i] = edges[i + (offset or 0)]
		end
		local fixed = boundary == "fixed"
		if offset ~= nil then
			fixed = { start = offset == 0, finish = offset == 1 }
		end
		local masks = require(script.Parent.AnnularControlMasks)(R, n, "corner", fixed, tick)
		local points = assert(
			require(script.Parent.ExactAnnularNeighborhood)(R, tick)(
				m,
				sector,
				1,
				{ maxFaces = 250000, maxVertices = 250000, boundary = boundary, creasing = creasing },
				masks
			)
		)
		if offset ~= nil then
			local nextPoints = {}
			for i, row in masks.matrix do
				local p = { R.number(0), R.number(0), R.number(0) }
				for j, w in row do
					for axis = 1, 3 do
						p[axis] = R.add(p[axis], R.mul(w, points[j][axis]))
					end
				end
				nextPoints[i] = p
			end
			points = nextPoints
		end
		local actual =
			S.catmullClark(mesh, offset ~= nil and 3 or 2, { boundary = boundary, creasing = creasing })
		local enclose = require(script.Parent.ExactRationalBounds)(R, tick)
		for k = 0, n - 1 do
			local first = (k + (offset or 0)) * (offset ~= nil and 16 or 4) + 1
			local f = {}
			for i = 1, 4 do
				f[i] = actual.faces[(first - 1) * 4 + i].vertices
			end
			for _, entry in
				{
					{ 0, 0, f[1][1] },
					{ 1, 0, f[1][2] },
					{ 1, 1, f[1][3] },
					{ 0, 1, f[1][4] },
					{ 2, 0, f[2][1] },
					{ 2, 1, f[2][2] },
					{ 2, 2, f[3][1] },
					{ 1, 2, f[3][2] },
					{ 0, 2, f[4][1] },
				}
			do
				local point = points[masks.vertex(k, entry[1], entry[2])]
				local expected = actual.vertices[entry[3]]
				local x = { expected.X, expected.Y, expected.Z }
				for axis = 1, 3 do
					local box = enclose(point[axis])
					assert(x[axis] >= box[1] - 1e-6 and x[axis] <= box[2] + 1e-6)
				end
			end
		end
	end
	test("Twelve exact halo lifts match finite sharpness and both creasing rules", function()
		for _, n in { 3, 4, 6 } do
			for _, boundary in { "edge", "fixed" } do
				for _, creasing in { "uniform", "chaikin" } do
					liftCase(n, boundary, creasing)
				end
			end
		end
	end)
	test("Mixed fixed physical boundaries and interior hard rays use separate masks", function()
		for _, offset in { 0, 1 } do
			for _, creasing in { "uniform", "chaikin" } do
				liftCase(3, "fixed", creasing, offset)
			end
		end
	end)
	test("Localized algebraic signs retain the chosen root when factors are discarded", function()
		local R, P, tick = setup()
		local q = { R.number(-0.125), R.number(0), R.number(1) }
		local p = P.product(P.product(q, { R.number(-0.75), R.number(1) }), { R.number(-0.875), R.number(1) })
		local settings = { tolerance = R.number(1 / 1024), maxDepth = 128, maxNodes = 10000 }
		local isolated = P.isolate(p, R.number(0), R.number(1), settings)
		local root = isolated.roots[1]
		root.analysis = isolated.analysis
		local F = require(script.Parent.AnnularAlgebraicValue)(
			R,
			P,
			require(script.Parent.ExactPolynomialBounds)(R, P, tick),
			root,
			settings
		)
		assert(
			F.sign({ R.number(-0.25), R.number(1) }) == 1
				and F.localize({ R.number(-0.75), R.number(1) }) == 3
		)
		assert(F.sign(q) == 0 and F.localize(q) == 2)
		local values =
			{ P.product({ R.number(2), R.number(3) }, q), { R.number(1), R.number(2) }, { R.number(-1) } }
		local denominator = { R.number(-1), R.number(-1) }
		local normalized = require(script.Parent.NormalizeAlgebraicPolynomials)(R, P, F, values, denominator)
		for i, v in normalized do
			assert(
				F.sign(
					P.add(P.product(v, P.scale(denominator, R.number(-1))), P.scale(values[i], R.number(-1)))
				) == 0
			)
		end
		assert(F.sign(normalized[1]) == 0 and F.sign(normalized[2]) == 1 and F.sign(normalized[3]) == -1)
	end)
	test("Directions at different algebraic roots compare exactly", function()
		local R, P, tick = setup()
		local F, G = field(R, P, tick, { -0.125, 0, 1 }), field(R, P, tick, { -0.5, 0, 1 })
		local a = { { R.number(1) }, { R.number(0), R.number(1) }, {} }
		local compare = require(script.Parent.CompareAlgebraicDirections)
		for i, b in
			{
				{ { R.number(2) }, { R.number(0), R.number(1) }, {} },
				{ { R.number(-2) }, { R.number(0), R.number(-1) }, {} },
				{ { R.number(2) }, { R.number(0), R.number(1) }, { R.number(1) } },
				{ { R.number(1) }, { R.number(0), R.number(1) }, {} },
			}
		do
			assert(compare(R, P, F, a, G, b, tick) == (i == 1))
		end
	end)
	test("Bernstein coefficient cones resolve lower Jordan orders and boundary witnesses", function()
		local R, P, tick = setup()
		local zero, one = R.number(0), R.number(1)
		local w = P.product(
			P.product({ R.number(-0.25), one }, { R.number(-0.25), one }),
			{ R.number(-0.125), one }
		)
		local mode = assert(require(script.Parent.ExactDominantMode)(R, P, w, {}, tick))
		for _, case in
			{
				"lowerJordan",
				"lowerRoot",
				"opposedBoundary",
				"tiltedBoundary",
				"tiltedControl",
				"zeroFiltered",
				"zeroUnfiltered",
			}
		do
			local changed = case == "tiltedControl" and 2 or 1
			local rows = {}
			for i = 1, 108 do
				rows[i] = { [i] = one }
			end
			local leading = {}
			for i = 1, 324 do
				leading[i] = {}
			end
			for i = 1, 108 do
				if i ~= changed then
					leading[i * 3] = { one }
				end
			end
			local powers = {}
			for k = 0, #w - 2 do
				local v = table.create(324, zero)
				for i = 1, 108 do
					local x = R.number(k * 0.25 ^ k)
					if i == changed then
						x = R.number((case == "lowerRoot" and 0.125 or 0.25) ^ k)
						if case == "opposedBoundary" then
							x = R.neg(x)
						end
						if case == "tiltedControl" or case == "tiltedBoundary" then
							v[(i - 1) * 3 + 1] = x
						end
						if case == "zeroFiltered" or case == "zeroUnfiltered" then
							x = zero
						end
					end
					v[i * 3] = x
				end
				powers[k + 1] = v
			end
			local direction, r = require(script.Parent.AnnularCoefficientCone)(
				R,
				P,
				mode.value,
				{ {}, {}, { one } },
				leading,
				w,
				powers,
				rows,
				case == "zeroFiltered",
				{},
				tick
			)
			if case == "lowerJordan" or case == "lowerRoot" or case == "zeroUnfiltered" then
				assert(direction and r.normalCertified)
			elseif case == "opposedBoundary" or case == "tiltedBoundary" then
				assert(not direction and r.normalExists == false)
			elseif case == "tiltedControl" then
				assert(not direction and r.normalExists == nil and r.reason == "coefficientConeDirection")
			else
				assert(not direction and r.reason == "coefficientNeedsHalo")
			end
		end
	end)
	test("Four-face source snapshot has a certified normal without finite chart derivatives", function()
		local source = four()
		local o = options()
		local prepared = S.prepareLimit(source, o)
		source.vertices[3] = V(999, 999, 999)
		o.maxWork = 1
		o.maxNormalPrimes = 1
		fourResult = prepared:evaluate(1, 0, 0)
		local r = fourResult
		local c = r.constrainedNormalCertificate
		assert(
			r.complete
				and r.normalAvailable
				and not r.derivativesAvailable
				and r.normalMethod == "exactConstrainedNormals"
		)
		assert(
			c.normalCertified
				and c.coefficientCone
				and c.lowerCoefficients == 6
				and c.dominantMultiplicity == 2
		)
		near(r.normal, V(table.unpack(fixture.fourNormal)), r.normalErrorBound + 1e-7)
		assert(prepared:statistics().work == r.work and c.allocatedCoefficients <= 1000000)
		assert(#game:GetService("HttpService"):JSONEncode(c) > 0)
	end)
	test("Higher fixed affine sectors preserve oriented normals under exact transforms", function()
		for _, n in { 4, 6 } do
			for _, scale in { 2 ^ -30, 1, 2 ^ 30 } do
				local m = affine(n, function(p)
					return V(p.Y, p.X, 2 * p.X - p.Y) * scale
				end)
				local r = S.limit(m, 1, 0, 0, options({ maxWork = 50000000 }))
				assert(r.normalAvailable and r.constrainedNormalCertificate.normalCertified)
				near(r.normal, V(-1, 2, -1).Unit, r.normalErrorBound + 1e-6)
			end
		end
	end)
	test("Fixed three-face sectors report genuinely varying annular directions", function()
		local m = E.Mesh.new()
		for _, p in
			{
				V(0, 0.25, 0.125),
				V(-2, 0, 0),
				V(-1, 1, 2),
				V(1, 1, -0.5),
				V(2, 0, 0.25),
				V(-3, 2, 1),
				V(0, 3, 1.5),
				V(3, 2, -1),
			}
		do
			m:addVertex(p)
		end
		for i = 1, 3 do
			m:addFace({ 1, i + 1, i + 5, i + 2 })
		end
		m = S.crease(m, nil, { [1] = 10 })
		local r = S.limit(m, 1, 0, 0, options())
		assert(r.complete and not r.normalAvailable)
		assert(
			r.constrainedNormalCertificate.normalExists == false
				and r.constrainedNormalCertificate.reason == "varyingAnnularDirection"
		)
	end)
	test("Fixed four-face boundary normals are distinguished from the interior limit", function()
		local r = S.limit(four(), 1, 0, 0, options({ boundary = "fixed" }))
		assert(r.complete and not r.normalAvailable)
		assert(
			r.constrainedNormalCertificate.normalExists == false
				and r.constrainedNormalCertificate.reason == "differentBoundaryNormal"
		)
	end)
	test("A collapsed constrained sector retains a position and no manufactured normal", function()
		local m = affine(4, function()
			return V(3, 2, 1)
		end)
		local r = S.limit(m, 1, 0, 0, options())
		assert(r.complete and not r.normalAvailable and not r.constrainedNormalCertificate.normalCertified)
		near(r.position, V(3, 2, 1))
	end)
	test("Native direction precision stays separate from an exact normal proof", function()
		local r = S.limit(
			affine(4, function(p)
				return V(p.X, p.Y, p.X + p.Y)
			end),
			1,
			0,
			0,
			options({ normalTolerance = 1e-20 })
		)
		assert(
			not r.normalAvailable
				and r.constrainedNormalCertificate.normalCertified
				and r.constrainedNormalCertificate.reason == "normalPrecision"
		)
	end)
	test("Normal options and coefficient, dimension, degree, work and root caps are validated", function()
		for _, bad in
			{
				{ exactConstrainedNormals = 1 },
				{ normalTolerance = 0 },
				{ maxNormalPrimes = 0 },
				{ maxNormalDepth = -1 },
				{ maxRootDepth = 0 },
				{ maxNormalKrylovDegree = 0 },
				{ maxNormalSubspaceDimension = 0 },
				{ maxExactBits = 0 },
			}
		do
			local o = options(bad)
			assert(not pcall(S.prepareLimit, affine(4), o))
		end
		for _, bad in
			{
				{ maxWork = 1 },
				{ maxExactCoefficients = 1 },
				{ maxNormalSubspaceDimension = 1 },
				{ maxNormalKrylovDegree = 1 },
				{ maxExactBits = 1 },
			}
		do
			assert(not pcall(S.limit, affine(4), 1, 0, 0, options(bad)))
		end
	end)
	test("Proof cancellation and checkpoint errors preserve source data and error identity", function()
		local m = affine(4)
		local before = E.IO.encode(m)
		local marker = {}
		local o = options({
			checkpoint = function()
				error(marker)
			end,
		})
		local ok, err = pcall(S.limit, m, 1, 0, 0, o)
		assert(not ok and err == marker and E.IO.encode(m) == before)
		local visits = 0
		o = options({
			cancelled = function()
				visits += 1
				return visits > 12
			end,
		})
		assert(not pcall(S.limit, m, 1, 0, 0, o) and E.IO.encode(m) == before)
	end)
	test("Long exact arithmetic exposes work checkpoints before exhausting the budget", function()
		local m = four()
		local before = E.IO.encode(m)
		local marker = {}
		local observed = false
		local ok, err = pcall(
			S.limit,
			m,
			1,
			0,
			0,
			options({
				maxWork = 1000000,
				checkpoint = function(progress)
					if progress.stage == "exactNormalWork" then
						assert(progress.work >= 262144)
						observed = true
						error(marker)
					end
				end,
			})
		)
		assert(not ok and err == marker and observed and E.IO.encode(m) == before)
	end)
	if not settings or not settings.skipNative then
		test("Certified higher-sector directions survive native corner-normal conversion", function()
			assert(fourResult and fourResult.normalAvailable)
			local mesh = E.Mesh.new()
			for _, p in { V(0, 0, 0), V(1, 0, 0), V(0, 1, 0) } do
				mesh:addVertex(p)
			end
			local id = mesh:addFace({ 1, 2, 3 })
			for i, c in mesh.faces[id].corners do
				c.normal = fourResult.normal
				c.uv = Vector2.new(i, 0)
			end
			local h = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local out = E.Roblox.fromEditable(h.editable)
				local count = 0
				for _, face in out.faces do
					for _, c in face.corners do
						near(c.normal, fourResult.normal, 1e-6)
						assert(c.uv.X >= 1 and c.uv.X <= 3)
						count += 1
					end
				end
				assert(count == 3)
			end)
			h.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
