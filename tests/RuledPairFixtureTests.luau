return function()
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	test("1024 independent RREF and clipped-rectangle fiber classifications", function()
		local fixtures = game:GetService("HttpService"):JSONDecode(require(script.Parent.RuledFiberFixtures))
		local work, allocated, probes = 0, 0, 0
		local function visit(n)
			work += n or 1
			assert(work <= 500000000, "work")
		end
		local function allocate(n)
			allocated += n
			assert(allocated <= 10000000, "allocation")
		end
		local R = require(script.Parent.ExactRational)(visit, 8192)
		local P = require(script.Parent.ExactPolynomialRoots)(R, visit, 96, allocate)
		local ctx =
			{ visit = visit, allocate = allocate, maxDegree = 96, maxPolynomials = 128, maxEvents = 2048 }
		local T = require(script.Parent.ExactBivariatePolynomial)(R, P, ctx)
		local function poly(values)
			local out = {}
			for i, row in values do
				out[i] = {}
				for j, x in row do
					out[i][j] = R.number(x)
				end
				P.trim(out[i])
			end
			return T.trim(out)
		end
		for index, row in fixtures do
			local equations = {}
			for i, e in row.equations do
				equations[i] = { a = poly(e.a), b = poly(e.b), c = poly(e.c) }
			end
			local projection = require(script.Parent.ExactConvexFiberProjection)(equations, R, P, T, ctx)
			for _, probe in row.probes do
				local s, t = R.number(probe.s), R.number(probe.t)
				local signs = {}
				for i, source in projection.sources do
					local value = R.number(0)
					for j = #source.p, 1, -1 do
						value = R.add(R.mul(value, t), P.evaluate(source.p[j], s))
					end
					signs[i] = value.sign
				end
				local feasible = projection.truth(signs)
				local dimension = feasible and projection.dimension(signs) or -1
				assert(
					dimension == probe.dimension,
					"Reference mismatch "
						.. index
						.. ":"
						.. probe.s
						.. ":"
						.. probe.t
						.. " got "
						.. dimension
						.. " expected "
						.. probe.dimension
				)
				probes += 1
			end
		end
		assert(probes == 1024)
	end)
	test(
		"384 weighted original-knot fibers and 508 exact original-parameter vertices match independent Fraction references",
		function()
			local N = require(script.Parent.NURBS)
			local V = Vector3.new
			local fixtures = game:GetService("HttpService")
				:JSONDecode(require(script.Parent.RuledWeightedFixtures))
			local totals = { fibers = 0, vertices = 0, work = 0 }
			for rowIndex, row in fixtures do
				local sources, bounds = {}, {}
				for operand, surface in row.surfaces do
					local control, weights = {}, {}
					if surface.transpose then
						for side = 1, 2 do
							control[side], weights[side] = {}, {}
							for i, pair in surface.control do
								control[side][i] = V(table.unpack(pair[side]))
								weights[side][i] = surface.weights[i][side]
							end
						end
					else
						for i, pair in surface.control do
							control[i] = { V(table.unpack(pair[1])), V(table.unpack(pair[2])) }
						end
						weights = surface.weights
					end
					local settings = { weights = weights }
					settings[surface.transpose and "knotsV" or "knotsU"] = surface.knots
					settings[surface.transpose and "clampedV" or "clampedU"] = rowIndex % 2 == 1
					sources[operand] = N.surface(
						control,
						surface.transpose and 1 or surface.degree,
						surface.transpose and surface.degree or 1,
						settings
					)
					bounds[(operand - 1) * 2 + 1] = surface.transpose and row.ranges[operand] or { 0, 1 }
					bounds[(operand - 1) * 2 + 2] = surface.transpose and { 0, 1 } or row.ranges[operand]
				end
				local data = require(script.Parent.ExactIntersectionSetup)(
					sources,
					{ parameterBox = bounds, maxWork = 200000000 }
				)
				local R, P, ctx = data.R, data.P, data.ctx
				ctx.maxDegree, ctx.maxPolynomials = 96, 128
				data.enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
				local T = require(script.Parent.ExactBivariatePolynomial)(R, P, ctx)
				local infos = {}
				for i, source in sources do
					infos[i] = require(script.Parent.ExactRuledPairPowers)(
						source,
						row.surfaces[i].transpose and "U" or "V",
						{ data.bounds[(i - 1) * 2 + 1], data.bounds[(i - 1) * 2 + 2] },
						data
					)
				end
				local function integer(s)
					local x = R.number(0)
					local negative = string.sub(s, 1, 1) == "-"
					for j = negative and 2 or 1, #s do
						x = R.add(R.mul(x, R.number(10)), R.number(tonumber(string.sub(s, j, j))))
					end
					return negative and R.neg(x) or x
				end
				local function expected(value)
					return R.div(integer(value[1]), integer(value[2]))
				end
				local function evaluate(p, s, t)
					local v = R.number(0)
					for i = #p, 1, -1 do
						v = R.add(R.mul(v, t), P.evaluate(p[i], s))
					end
					return v
				end
				local cache = {}
				for _, probe in row.probes do
					local originals, localParameters = {}, {}
					local spanIds = {}
					for operand, value in { probe.s, probe.t } do
						value = R.number(value)
						for i, span in infos[operand].spans do
							local t = R.div(R.sub(value, span.offset), span.scale)
							if R.compare(t, R.number(0)) >= 0 and R.compare(t, R.number(1)) <= 0 then
								originals[operand] = span
								localParameters[operand] = t
								spanIds[operand] = i
								break
							end
						end
						assert(originals[operand])
					end
					local key = spanIds[1] .. ":" .. spanIds[2]
					local span = cache[key]
					if not span then
						local equations = require(script.Parent.ExactRuledPairEquations)(
							originals[1],
							originals[2],
							R,
							P,
							T,
							ctx
						)
						span = { sources = originals, equations = equations }
						cache[key] = span
					end
					local s, t = table.unpack(localParameters)
					local equations = {}
					for i, e in span.equations do
						equations[i] = {}
						for _, coordinate in { "a", "b", "c" } do
							equations[i][coordinate] = T.trim({ P.trim({ evaluate(e[coordinate], s, t) }) })
						end
					end
					span.projection =
						require(script.Parent.ExactConvexFiberProjection)(equations, R, P, T, ctx)
					local signs = {}
					for i, source in span.projection.sources do
						signs[i] = evaluate(source.p, s, t).sign
					end
					local feasible = span.projection.truth(signs)
					local dimension = feasible and span.projection.dimension(signs) or -1
					assert(
						dimension == probe.dimension,
						"Dimension mismatch " .. rowIndex .. ":" .. probe.s .. ":" .. probe.t
					)
					if feasible then
						local vertices = span.projection.vertices(signs)
						assert(#vertices == #probe.vertices, "Extreme vertex count differs")
						local matched = {}
						for _, index in vertices do
							local case = span.projection.cases[index]
							local d = evaluate(case.determinant, s, t)
							local alpha, beta =
								R.div(evaluate(case.alpha, s, t), d), R.div(evaluate(case.beta, s, t), d)
							local found
							for i, v in probe.vertices do
								if
									R.equal(alpha, expected(v.affine[1]))
									and R.equal(beta, expected(v.affine[2]))
								then
									found = i
									break
								end
							end
							assert(found and not matched[found], "Extreme affine vertex mismatch")
							matched[found] = true
							local lift = {
								asRational = function(x)
									return x
								end,
							}
							local out = require(script.Parent.ExactRuledPairSample)(
								span,
								{ low = s, high = s, exact = true },
								lift,
								{ low = t, high = t, exact = true },
								case,
								data,
								infos[1],
								infos[2]
							)
							for i, v in probe.vertices[found].parameters do
								assert(
									R.equal(out.parametersExact[i], expected(v)),
									"Original parameter inverse mismatch"
								)
							end
							for i, v in probe.vertices[found].position do
								assert(
									R.equal(out.positionExact[i], expected(v)),
									"Original spatial vertex mismatch"
								)
							end
							assert(out.accurate)
							totals.vertices += 1
						end
					end
					totals.fibers += 1
				end
				totals.work += data.report.work
			end
			assert(totals.fibers == 384 and totals.vertices == 508)
		end
	)
	report.success = report.failed == 0
	return report
end
