return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
		if settings and settings.testCheckpoint then
			settings.testCheckpoint({ name = name, passed = ok, error = not ok and tostring(err) or nil })
		end
	end
	local function setup(limit)
		local work, allocated = 0, 0
		local nextYield = 262144
		local function visit(n)
			assert(not task or coroutine.isyieldable(), "Exact normal work callback must permit yielding")
			work += n or 1
			assert(work <= (limit or 500000000), "Normal germ test work cap")
			if task and work >= nextYield then
				nextYield = work + 262144
				task.wait()
			end
		end
		local function allocate(n)
			allocated += n
			assert(allocated <= 20000000, "Normal germ test coefficient cap")
		end
		return require(script.Parent.ExactRational)(visit, 8192),
			{ visit = visit, allocate = allocate, maxDegree = 128 }
	end
	local V, S = Vector3.new, E.Subdivision
	local function grid(fn)
		local m = E.Mesh.new()
		local ids = {}
		for i = -1, 2 do
			ids[i] = {}
			for j = -1, 2 do
				ids[i][j] = m:addVertex(fn(i, j))
			end
		end
		local target
		for i = -1, 1 do
			for j = -1, 1 do
				local f = m:addFace({ ids[i][j], ids[i + 1][j], ids[i + 1][j + 1], ids[i][j + 1] })
				if i == 0 and j == 0 then
					target = f
				end
			end
		end
		return m, target
	end
	local function options(extra)
		local out = {
			exactPolynomialNormals = true,
			maxWork = 500000000,
			maxExactCoefficients = 20000000,
			checkpoint = function(p)
				if task and p.stage == "exactNormalWork" then
					task.wait()
				end
			end,
		}
		for k, v in extra or {} do
			out[k] = v
		end
		if settings and settings.proofCheckpoint then
			out.checkpoint = settings.proofCheckpoint
		end
		return out
	end
	local function cusp(i, j)
		return V(i ^ 3 - i + 3 * i * (j ^ 3 - j), j, -0.5 * (3 * i * i - 1) * (3 * j * j - 1))
	end
	test("Thom roots distinguish infinitesimal sections at both closed endpoints", function()
		local R, ctx = setup()
		local K = require(script.Parent.InfinitesimalField)(R, ctx.visit, ctx.allocate, 128)
		for _, side in { 0, 1 } do
			local polynomial = side == 0 and { K.neg(K.epsilon), K.number(0), K.number(1) }
				or { K.sub(K.number(1), K.epsilon), K.number(-2), K.number(1) }
			local roots = require(script.Parent.ThomRootCells)(
				K,
				{ polynomial },
				ctx,
				{ maxTarskiQueries = 100000 }
			)
			assert(#roots == 3 and roots[1].lowSign == 0 and roots[3].highSign == 0)
			local root = roots[2]
			assert(root.value.sign(polynomial) == 0)
			local F = root.field
			local distance = side == 0 and root.coordinate or F.sub(F.number(1), root.coordinate)
			assert(F.compare(distance, F.rational(K.epsilon)) > 0)
			assert(F.compare(distance, F.rational(K.number(1e-100))) < 0)
		end
	end)
	test("Quantified infinitesimal cells preserve existential and universal scope", function()
		local R, ctx = setup()
		local K = require(script.Parent.InfinitesimalField)(R, ctx.visit, ctx.allocate, 128)
		local M = require(script.Parent.ExactSparsePolynomial)(K, 2, ctx)
		local u, v = M.variable(1), M.variable(2)
		local polynomials = { M.sub(M.product(u, u), M.constant(K.epsilon)), M.sub(v, u) }
		for _, quantifier in { "exists", "forall" } do
			local result = require(script.Parent.ThomCAD)(
				polynomials,
				2,
				K,
				ctx,
				{ quantifiers = { quantifier, "exists" }, maxTarskiQueries = 100000 },
				function(signs)
					if signs[1] ~= nil and signs[1] ~= 0 then
						return false
					end
					if signs[2] ~= nil then
						return signs[1] == 0 and signs[2] == 0
					end
					return nil
				end
			)
			assert(result.result == (quantifier == "exists"))
		end
	end)
	test("Positive exponential germs retain Jordan growth and multiplicative relations", function()
		local R, ctx = setup()
		local G = require(script.Parent.FormalExponentialGermField)(
			R,
			{ R.number(0.5), R.number(0.75), R.number(2) },
			ctx,
			{}
		)
		local T = G.coefficientField
		local function term(base, power)
			return G.fromTerms({ { base = R.number(base), power = power, coefficient = T.number(1) } })
		end
		local a, b = term(0.5, 3), term(0.75, 0)
		assert(G.compare(b, a) > 0 and G.compare(a, G.tolerance) < 0 and a.sign > 0)
		assert(G.equal(G.div(G.mul(a, b), a), b))
		assert(G.compare(G.mul(a, term(2, 0)), G.number(1000000000)) > 0)
		assert(G.sub(G.mul(term(0.5, 0), term(2, 0)), G.number(1)).sign == 0)
	end)
	test("Uniform cone decisions detect shrinking parameter paths", function()
		local R, ctx = setup()
		local G = require(script.Parent.FormalExponentialGermField)(R, { R.number(0.5) }, ctx, {})
		local delta =
			G.fromTerms({ { base = R.number(0.5), power = 3, coefficient = G.coefficientField.number(1) } })
		local M = require(script.Parent.ExactSparsePolynomial)(G, 1, ctx)
		local u = M.variable(1)
		for _, uniform in { true, false } do
			local x = M.scale(u, delta)
			local z = M.add(M.product(u, u), M.constant(uniform and delta or G.mul(delta, delta)))
			local cone = M.sub(M.scale(z, G.tolerance), x)
			local result = require(script.Parent.ThomCAD)(
				{ cone },
				1,
				G,
				ctx,
				{ quantifiers = { "forall" }, maxTarskiQueries = 100000 },
				function(signs)
					if signs[1] ~= nil then
						return signs[1] >= 0
					end
					return nil
				end
			)
			assert(result.result == uniform)
		end
	end)
	test("Full Jordan spectral expansion matches an independent rational recurrence", function()
		local R, ctx = setup()
		local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, 128, ctx.allocate)
		local p = P.product(
			P.product({ R.number(-0.5), R.number(1) }, { R.number(-0.5), R.number(1) }),
			{ R.number(1 / 32), R.number(-0.5), R.number(1) }
		)
		local values = { R.number(1), R.number(2), R.number(-1), R.number(3) }
		for k = 5, 16 do
			local sum = R.number(0)
			for i = 1, #p - 1 do
				sum = R.add(sum, R.mul(p[i], values[k - #p + i]))
			end
			values[k] = R.neg(sum)
		end
		local powers = {}
		for i = 1, #p do
			powers[i] = { values[i] }
		end
		local K, embed, modes, details = require(script.Parent.ExactSpectralModes)(R, p, powers, ctx, {})
		assert(#modes == 3 and details.extensions == 1)
		for k = 0, 15 do
			local sum = K.number(0)
			for _, mode in modes do
				local value, power = K.number(0), K.number(1)
				for _, coefficient in mode.coefficients[1] do
					value = K.add(value, K.mul(coefficient, power))
					power = K.mul(power, K.number(k))
				end
				local growth = K.number(1)
				for _ = 1, k do
					growth = K.mul(growth, mode.base)
				end
				sum = K.add(sum, K.mul(growth, value))
			end
			assert(K.equal(sum, embed(values[k + 1])))
		end
	end)
	test("Common spectral fields exactly pair reciprocal quadratic roots", function()
		local R, ctx = setup()
		local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, 128, ctx.allocate)
		local p = P.product(
			{ R.number(1 / 16), R.number(-11 / 16), R.number(1) },
			{ R.number(1 / 16), R.number(-9 / 16), R.number(1) }
		)
		local K, embed, roots, details = require(script.Parent.SplitRealSpectrum)(R, p, ctx, {})
		assert(#roots == 4 and details.extensions == 2)
		local PK = require(script.Parent.ExactPolynomialRoots)(K, ctx.visit, 128, ctx.allocate)
		local lifted = {}
		for i, x in p do
			lifted[i] = embed(x)
		end
		for _, root in roots do
			assert(PK.evaluate(lifted, root.value).sign == 0)
		end
		assert(K.equal(K.mul(roots[1].value, roots[4].value), K.number(1 / 16)))
		assert(K.equal(K.mul(roots[2].value, roots[3].value), K.number(1 / 16)))
		local normal, error = require(script.Parent.GenericNormalBounds)(
			R,
			K,
			{ K.number(1), roots[1].value, K.mul(roots[1].value, roots[1].value) },
			details.bound,
			details.refine,
			1e-5,
			ctx.visit
		)
		local a = (11 - math.sqrt(57)) / 32
		local expected = V(1, a, a * a).Unit
		assert(normal and (normal - expected).Magnitude <= error + 1e-7)
	end)

	local function annular(raw, n, kind)
		local R, ctx = setup()
		local Q = require(script.Parent.ExactSubdivisionRefinement)(R, ctx.visit)
		local top = Q.topology(raw)
		local sector = require(script.Parent.SubdivisionFeaturePatch).sector(raw, top, 1, 1, ctx.visit)
		assert(sector.kind == kind)
		local masks = require(script.Parent.AnnularControlMasks)(R, n, kind, false, ctx.visit, ctx.allocate)
		local points = require(script.Parent.ExactAnnularNeighborhood)(R, ctx.visit)(
			raw,
			sector,
			1,
			{ boundary = "edge", creasing = "uniform", maxVertices = 250000, maxFaces = 250000 },
			masks
		)
		return require(script.Parent.AnnularGermProof)(
			R,
			masks,
			points,
			assert(table.find(sector.faces, 1)),
			kind,
			{ maxExactCoefficients = 20000000 },
			ctx.visit
		)
	end
	test("The full annular germ pipeline preserves a fixed affine sector normal", function()
		local raw = { vertices = { [1] = { 0, 0, 0, 0 } }, faces = {}, edges = {}, sharp = { [1] = 10 } }
		local cycle = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { -1, 0, 0, 0 }, { 0, -1, 0, 0 } }
		for j = 0, 4 do
			raw.vertices[j + 2] = table.clone(cycle[j % 4 + 1])
		end
		for j = 0, 3 do
			local a, b = cycle[j % 4 + 1], cycle[(j + 1) % 4 + 1]
			raw.vertices[j + 7] = { a[1] + b[1], a[2] + b[2], 0, 0 }
			raw.faces[j + 1] = { 1, j + 2, j + 7, j + 3 }
		end
		local proof = annular(raw, 4, "corner")
		assert(
			proof.normalExists
				and proof.candidate[3].sign > 0
				and proof.candidate[1].sign == 0
				and proof.candidate[2].sign == 0
		)
	end)
	test("The full algebraic spectrum proves varying three-sector annular directions", function()
		local raw = { vertices = {}, faces = {}, edges = {}, sharp = { [1] = 10 } }
		for i, p in
			{
				{ 0, 0.25, 0.125, 0 },
				{ -2, 0, 0, 0 },
				{ -1, 1, 2, 0 },
				{ 1, 1, -0.5, 0 },
				{ 2, 0, 0.25, 0 },
				{
					-3,
					2,
					1,
					0,
				},
				{
					0,
					3,
					1.5,
					0,
				},
				{
					3,
					2,
					-1,
					0,
				},
			}
		do
			raw.vertices[i] = p
		end
		for i = 1, 3 do
			raw.faces[i] = { 1, i + 1, i + 5, i + 2 }
		end
		local proof = annular(raw, 3, "corner")
		assert(proof.normalExists == false and proof.reason == "varyingAnnularDirection")
	end)
	local singular
	test("A singular bicubic corner has a certified uniform normal despite zero first partial", function()
		local m, f = grid(cusp)
		singular = S.limit(m, f, 0, 0, options())
		local r = singular
		assert(r.complete and r.derivativesAvailable and r.derivativeU.Magnitude == 0)
		assert(r.normalAvailable and r.normal.Z > 0.999999 and r.oneSided)
		assert(r.polynomialNormalCertificate.normalExists and r.polynomialNormalCertificate.order == 2)
		assert(r.normalMethod == "exactPolynomialNormals" and r.polynomialNormalCertificate.cells > 0)
		assert(#game:GetService("HttpService"):JSONEncode(r.polynomialNormalCertificate) > 0)
	end)

	test("Singular tensor controls reproduce independent polynomial positions and derivatives", function()
		local m, f = grid(cusp)
		for i = 1, 8 do
			for j = 1, 4 do
				local u, v = i / 16, j / 8
				local r = S.limit(m, f, u, v)
				local p = V(u ^ 3 + 3 * u * v ^ 3, v, -4.5 * u * u * v * v)
				local a = V(3 * u * u + 3 * v ^ 3, 0, -9 * u * v * v)
				local b = V(9 * u * v * v, 1, -9 * u * u * v)
				assert((r.position - p).Magnitude <= r.errorBound + 1e-6)
				assert((r.derivativeU - a).Magnitude <= r.derivativeErrorU + 1e-6)
				assert((r.derivativeV - b).Magnitude <= r.derivativeErrorV + 1e-6)
			end
		end
	end)
	test("Polynomial corner normals replay exact refinement history", function()
		local m, f = grid(cusp)
		local r = S.limit(m, f, 0, 0, options({ corner = 1 }))
		assert(
			r.normalAvailable
				and r.normal.Z > 0.99999
				and r.polynomialNormalCertificate.exactHistorySteps == 1
		)
	end)
	test("Reflected one-sided feature controls retain a collapsed boundary normal", function()
		local m = E.Mesh.new()
		for _, p in { V(0, 0, 0), V(0, 0, 0), V(1, 1, 0), V(0, 1, 0) } do
			m:addVertex(p)
		end
		local f = m:addFace({ 1, 2, 3, 4 })
		local r = S.limit(m, f, 0, 0, options({ boundary = "fixed" }))
		assert(
			r.normalAvailable
				and r.normal.Z > 0.99999
				and r.oneSided
				and r.polynomialNormalCertificate.normalExists
		)
	end)
	test("Interior collapsed tangents retain normals when orientation agrees in all quadrants", function()
		local m, f = grid(function(i, j)
			local x = i - 0.5
			return V(x ^ 3 - x, j, 0)
		end)
		local r = S.limit(m, f, 0.5, 0.5, options())
		assert(r.normalAvailable and r.normal.Z > 0.999999 and not r.oneSided)
		assert(r.polynomialNormalCertificate.quadrants == 4)
	end)
	test("An interior fold proves normal nonexistence while retaining finite derivatives", function()
		local m, f = grid(function(i, j)
			return V(3 * (i - 0.5) ^ 2 - 1, j, 0)
		end)
		local r = S.limit(m, f, 0.5, 0.5, options())
		assert(r.complete and r.derivativesAvailable and not r.normalAvailable)
		assert(
			r.polynomialNormalCertificate.normalExists == false
				and r.polynomialNormalCertificate.decisionCertified
		)
	end)
	test("An edge cusp checks both incident parameter quadrants", function()
		local m, f = grid(function(i, j)
			local x = i - 0.5
			return V(x ^ 3 - x, j, 0)
		end)
		local r = S.limit(m, f, 0.5, 0, options())
		assert(r.normalAvailable and r.oneSided and r.polynomialNormalCertificate.quadrants == 2)
	end)
	test("Identically collapsed patches prove absence of regular points", function()
		local m, f = grid(function(i, j)
			return V(i + j, 0, 0)
		end)
		local r = S.limit(m, f, 0.5, 0.5, options())
		assert(
			not r.normalAvailable
				and r.polynomialNormalCertificate.normalExists == false
				and r.normalReason == "noRegularPoints"
		)
	end)
	test("Normal orientation follows reflected source geometry and native precision is separate", function()
		local m, f = grid(function(i, j)
			local x = i - 0.5
			return V(j, x ^ 3 - x, x ^ 3 - x + j)
		end)
		local r = S.limit(m, f, 0.5, 0.5, options())
		local expected = V(1, 1, -1).Unit
		assert(r.normalAvailable and (r.normal - expected).Magnitude <= r.normalErrorBound + 1e-7)
		local precise = S.limit(m, f, 0.5, 0.5, options({ normalTolerance = 1e-20 }))
		assert(
			not precise.normalAvailable
				and precise.polynomialNormalCertificate.normalExists
				and precise.normalReason == "normalPrecision"
		)
	end)
	test("Prepared polynomial normals retain source and option snapshots", function()
		local m, f = grid(function(i, j)
			local x = i - 0.5
			return V(x ^ 3 - x, j, 0)
		end)
		local o = options()
		local prepared = S.prepareLimit(m, o)
		for id in m.vertices do
			m.vertices[id] = V(999, 999, 999)
		end
		o.maxWork = 1
		o.exactPolynomialNormals = false
		local r = prepared:evaluate(f, 0.5, 0.5)
		assert(r.normalAvailable and r.normal.Z > 0.999999)
	end)
	test("Normal proof option and resource limits fail explicitly", function()
		local m, f = grid(cusp)
		for _, bad in
			{
				{ exactPolynomialNormals = 1 },
				{ maxNormalPolynomialDegree = 0 },
				{ maxNormalPolynomialDegree = 513 },
				{ maxNormalTarskiQueries = 0 },
				{ maxNormalProjectionPolynomials = 0 },
				{ normalTolerance = 0 },
			}
		do
			assert(not pcall(S.prepareLimit, m, options(bad)))
		end
		for _, bad in
			{
				{ maxWork = 1 },
				{ maxExactBits = 1 },
				{ maxExactCoefficients = 1 },
				{ maxNormalPolynomialDegree = 1 },
				{ maxNormalTarskiQueries = 1 },
				{ maxNormalCells = 1 },
				{ maxNormalProjectionPolynomials = 1 },
			}
		do
			assert(not pcall(S.limit, m, f, 0, 0, options(bad)))
		end
	end)
	test("Cancellation and checkpoint errors retain identity and source geometry", function()
		local m, f = grid(cusp)
		local before = E.IO.encode(m)
		local token = {}
		local o = options({
			checkpoint = function()
				error(token)
			end,
		})
		local ok, err = pcall(S.limit, m, f, 0, 0, o)
		assert(not ok and err == token and E.IO.encode(m) == before)
		local calls = 0
		o = options({
			cancelled = function()
				calls += 1
				return calls > 100
			end,
		})
		assert(not pcall(S.limit, m, f, 0, 0, o))
		assert(E.IO.encode(m) == before)
	end)
	if not settings or not settings.skipNative then
		test("Certified singular patch normals survive native UV mesh conversion", function()
			local m = E.Mesh.new()
			local a = m:addVertex(V(0, 0, 0))
			local b = m:addVertex(V(1, 0, 0))
			local c = m:addVertex(V(0, 1, 0))
			local fid = m:addFace({ a, b, c })
			for i, corner in m.faces[fid].corners do
				corner.normal = singular.normal
				corner.uv = Vector2.new(i, 0)
			end
			local handle = E.Roblox.toEditable(m)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				local faceCount = 0
				for _ in restored.faces do
					faceCount += 1
				end
				assert(faceCount == 1)
				for _, face in restored.faces do
					for _, corner in face.corners do
						assert(corner.normal.Z > 0.99999 and corner.uv.X >= 1 and corner.uv.X <= 3)
					end
				end
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
