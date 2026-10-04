return function(E, settings)
	local N, C, V = E.NURBS, E.Cyclic, Vector3.new
	local U = require(script.Parent.Util)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function fails(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok and (not pattern or tostring(err):find(pattern, 1, true)), tostring(err))
	end
	local function query(a, b, options)
		options = U.copy(options or {})
		options.method = "exactTensorPair"
		return E.SplineQuery.intersectSurfaces(a, b, options)
	end
	local function seam(weighted)
		local rows, weights = {}, {}
		for i, p in { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } } do
			rows[i] = { V(p[1], p[2], 0), V(p[1], p[2], 1) }
			weights[i] = weighted and { 2, 1 } or { 1, 1 }
		end
		return C.surface(rows, 1, 1, { cyclicU = true, cyclicV = false, weights = weights }),
			N.surface({ { V(0, 0, 0), V(0, 0, 1) }, { V(1, -1, 0), V(1, -1, 1) } }, 1, 1)
	end
	local function check(r, parameter, quotient, dimension, classes)
		assert(r.coverageCertified and r.parameterComponentsCertified and r.componentCount == parameter)
		assert(
			r.quotientComponentsCertified
				and r.quotientComponentCount == quotient
				and not r.quotientTopologyCertified
		)
		local q = r.periodicQuotient
		assert(q.contactsCertified and q.componentsCertified and not q.topologyCertified)
		for _, c in q.components do
			assert(c.certified and c.connected and c.parameterDimension == dimension)
		end
		if classes then
			assert(#q.vertexClasses == classes, "Unexpected periodic anchor classes")
		end
		local owned = {}
		for _, c in q.vertexClasses do
			for _, i in c.vertexIndices do
				assert(not owned[i] and q.vertexMap[i] == c.index)
				owned[i] = true
			end
		end
		for i in r.vertices do
			assert(owned[i])
		end
		for _, join in q.joins do
			assert(join.connected and join.method == "connectedSeamImage" and #join.proof.signs == 4)
		end
	end
	test("3888 independent weighted Bernstein boundary contact references", function()
		local fixtures = game:GetService("HttpService")
			:JSONDecode(require(script.Parent.TensorBernsteinFixtures))
		local N = require(script.Parent.NURBS)
		local total = 0
		for index, case in fixtures do
			local inputs = {}
			for operand, control in case.control do
				local rows = {}
				for i, row in control do
					rows[i] = {}
					for j, p in row do
						rows[i][j] = Vector3.new(table.unpack(p))
					end
				end
				inputs[operand] =
					N.surface(rows, case.degree, case.degree, { weights = case.weights[operand] })
			end
			local data = require(script.Parent.ExactIntersectionSetup)(inputs, {})
			local R, P = data.R, data.P
			local bernstein = require(script.Parent.GeneralTensorBernstein)(R, data.ctx)
			local spans = {}
			for operand, input in inputs do
				spans[operand] = require(script.Parent.ExactSurfacePower)(input, R, P, data.ctx)[1]
				spans[operand].original = spans[operand].h
			end
			local faces, remaining = bernstein.classify(
				bernstein.prepare(spans[1], case.degree, case.degree),
				bernstein.prepare(spans[2], case.degree, case.degree)
			)
			local function h(span, u, v)
				local out = {}
				for axis, p in span.h do
					local rows = {}
					for i, row in p do
						rows[i] = P.evaluate(row, R.number(u))
					end
					out[axis] = P.evaluate(rows, R.number(v))
				end
				return out
			end
			local count = 0
			for _, u in { 0, 0.5, 1 } do
				for _, v in { 0, 0.5, 1 } do
					for _, s in { 0, 0.5, 1 } do
						for _, t in { 0, 0.5, 1 } do
							count += 1
							local params = { u, v, s, t }
							local found = false
							for _, face in faces do
								local inside = true
								for axis, value in face do
									if params[axis] ~= value then
										inside = false
									end
								end
								found = found or inside
							end
							local ha, hb = h(spans[1], u, v), h(spans[2], s, t)
							for _, axis in remaining do
								if not R.equal(R.mul(ha[axis], hb[4]), R.mul(hb[axis], ha[4])) then
									found = false
								end
							end
							assert(
								found == (case.expected:sub(count, count) == "1"),
								"Bernstein contact truth " .. index .. ":" .. count
							)
						end
					end
				end
			end
			total += count
		end
		assert(total == 3888)
	end)
	test("Nested radical seam anchors compare exactly and reject nearby points", function()
		local work, allocated = 0, 0
		local ctx = {
			maxDegree = 96,
			visit = function(n)
				work += n or 1
				assert(work <= 100000000)
			end,
			allocate = function(n)
				allocated += n
				assert(allocated <= 2000000)
			end,
		}
		local R = require(script.Parent.ExactRational)(ctx.visit, 8192)
		local M = require(script.Parent.ExactSparsePolynomial)(R, 4, ctx)
		local y, z, w = M.variable(2), M.variable(3), M.variable(4)
		local source =
			{ M.sub(M.product(y, y), M.constant(R.number(0.5))), M.sub(M.product(z, z), y), M.sub(w, z) }
		local cad = require(script.Parent.GuardedTowerCAD)(source, 4, R, ctx, {}, function(signs)
			return signs[1] == 0 and signs[2] == 0 and signs[3] < 0
		end)
		local count = 0
		for _, cell in cad.leaves do
			if not cell.feasible or not cell.field.equal(cell.values[1], cell.field.number(0)) then
				continue
			end
			local target, values = require(script.Parent.GeneralSeamTransport)(cad, cell, { [1] = 1 }, ctx)
			local formula = require(script.Parent.GeneralPointFormula)(cad, target, R, ctx)
			for _, condition in formula do
				assert(
					M.evaluate(condition.polynomial, values, cell.field, cell.embed).sign == condition.sign
				)
			end
			if target.kind == "sector" then
				assert(cell.field.equal(cell.field.mul(values[4], cell.field.number(2)), values[3]))
				values[4] = cell.field.add(values[4], cell.field.number(1 / 1024))
				local matched = true
				for _, condition in formula do
					if
						M.evaluate(condition.polynomial, values, cell.field, cell.embed).sign
						~= condition.sign
					then
						matched = false
					end
				end
				assert(not matched, "Nearby distinct algebraic point was merged")
			end
			count += 1
		end
		assert(count >= 2)
	end)
	test("A seam contained contact has one quotient component and exact anchor classes", function()
		local a, b = seam()
		local r = query(a, b, { requireComplete = true, requireQuotient = true })
		check(r, 2, 1, 1, 3)
		assert(r.quotientComplete)
	end)
	test("Seam transport preserves operand order and all parameter axes", function()
		local a, b = seam()
		for _, order in { { 1, 2, 3, 4 }, { 3, 4, 1, 2 }, { 4, 2, 3, 1 } } do
			check(query(b, a, { parameterOrder = order, requireQuotient = true }), 2, 1, 1, 3)
		end
		a, b = E.SurfaceEdit.transpose(a), E.SurfaceEdit.transpose(b)
		check(query(a, b, { requireQuotient = true }), 2, 1, 1, 3)
	end)
	test("Two periodic operand overlaps retain their complete quotient", function()
		local a = seam()
		check(query(a, a, { requireQuotient = true }), 3, 1, 2)
	end)
	test("Four periodic axes retain distinct parameter anchors on a collapsed contact", function()
		local a = C.surface({ { V(1, 2, 3), V(1, 2, 3) }, { V(1, 2, 3), V(1, 2, 3) } }, 1, 1)
		local r = query(a, a, { requireQuotient = true, maxComponentPairs = 250000 })
		check(r, 1, 1, 4, 256)
		assert(#r.cells == 625 and #r.periodicQuotient.axes == 4)
	end)
	test("Sixteen periodic corner contacts have one exact quotient point", function()
		local a, b = {}, {}
		for i = 1, 2 do
			a[i] = {}
			b[i] = {}
			for j = 1, 2 do
				a[i][j] = V(0, 0, i + j - 2)
				b[i][j] = V(0, 0, 2 - i - j)
			end
		end
		local r = query(C.surface(a, 1, 1), C.surface(b, 1, 1), { requireQuotient = true })
		check(r, 16, 1, 0, 1)
		assert(r.work < 10000000, "Boundary sign reduction lost its bounded fast path")
	end)
	test("Quadratic seam tangency identifies a three dimensional contact", function()
		local rows = {}
		for i, z in { 0, 0, 1, 1 } do
			rows[i] = { V(0, 0, z), V(0, 0, z) }
		end
		local flat = N.surface({ { V(0, 0, 0), V(0, 0, 0) }, { V(0, 0, 0), V(0, 0, 0) } }, 1, 1)
		check(
			query(C.surface(rows, 2, 1, { cyclicV = false }), flat, { requireQuotient = true }),
			2,
			1,
			3,
			27
		)
	end)
	test("Biquadratic periodic patches retain a seam curve and a separate curved contact", function()
		local linear, square = { 0, 0.5, 1 }, { 0, 0, 1 }
		local a, b = {}, {}
		for i, p in { { -1, 0 }, { 0, 1 }, { 1, 0 }, { 0, -1 } } do
			a[i] = {}
			for j = 1, 3 do
				a[i][j] = V(p[1] * (1 + square[j]), p[2] * (1 + square[j]), square[j])
			end
		end
		for i = 1, 3 do
			b[i] = {}
			for j = 1, 3 do
				b[i][j] = V(
					-0.5 * (1 + square[j]) + 2 * linear[i],
					0.5 * (1 + square[j]) - 2 * linear[i],
					square[j]
				)
			end
		end
		check(
			query(C.surface(a, 2, 2, { cyclicV = false }), N.surface(b, 2, 2), { requireQuotient = true }),
			3,
			2,
			1
		)
	end)
	test("Restricted periodic domains retain disabled seam metadata", function()
		local a, b = seam()
		local r = query(
			a,
			b,
			{ requireQuotient = true, parameterBox = { { 0, 0.875 }, { 0, 1 }, { 0, 1 }, { 0, 1 } } }
		)
		check(r, 1, 1, 1, 3)
		assert(
			not r.periodicQuotient.axes[1].enabled and r.periodicQuotient.axes[1].reason == "restrictedRange"
		)
	end)
	test("Valid periodic geometry with no contacts has a certified empty quotient", function()
		local a, b = seam()
		for _, row in b.control do
			for j, p in row do
				row[j] = p + V(10, 10, 0)
			end
		end
		check(query(a, b, { requireQuotient = true }), 0, 0, 0, 0)
	end)
	test("Unequal stored seam geometry rejects even an empty contact quotient", function()
		local rows = {}
		for i = 1, 4 do
			rows[i] = {}
			for j = 1, 4 do
				rows[i][j] = V(i, j, 0)
			end
		end
		local a = C.surface(rows, 2, 2, { intervalsU = { 0.1, 0.2, 0.3, 0.4 } })
		local b = N.surface({ { V(0, 0, 100), V(0, 1, 100) }, { V(1, 0, 100), V(1, 1, 100) } }, 1, 1)
		local r = query(a, b, { identifyPeriodicSeams = true, requireComplete = true })
		assert(
			r.componentCount == 0
				and r.complete
				and not r.quotientComplete
				and not r.quotientComponentsCertified
		)
		assert(r.periodicQuotient.reason == "seamGeometry" and #r.periodicQuotient.unresolved > 0)
		fails(function()
			query(a, b, { requireQuotient = true })
		end, "quotient incomplete")
	end)
	test("Native error remains separate from exact periodic component identity", function()
		local a, b = seam(true)
		local r = query(a, b, { tolerance = 1e-12, identifyPeriodicSeams = true })
		check(r, 2, 1, 1)
		assert(not r.complete and not r.quotientComplete and r.periodicQuotient.reason == "approximation")
		fails(function()
			query(a, b, { tolerance = 1e-12, requireQuotient = true })
		end, "quotient incomplete")
	end)
	test("Periodic input and option snapshots precede every callback", function()
		local a, b = seam()
		local options = { requireQuotient = true, parameterOrder = { 1, 2, 3, 4 } }
		local changed = false
		options.checkpoint = function()
			if changed then
				return
			end
			changed = true
			a.control[1][1] = V(100, 100, 100)
			a.intervalsU = { 0.1, 0.2, 0.3, 0.4 }
			b.control[1][1] = V(100, 100, 100)
			options.parameterOrder[1] = 99
			options.maxSeamNodes = 1
		end
		check(query(a, b, options), 2, 1, 1, 3)
		assert(changed)
	end)
	test("Periodic proof budgets and cancellation propagate without certificates", function()
		local a, b = seam()
		for _, name in { "maxSeamNodes", "maxSeamPairs" } do
			fails(function()
				query(a, b, { requireQuotient = true, [name] = 1 })
			end, "budget")
			fails(function()
				query(a, b, { requireQuotient = true, [name] = 0.5 })
			end)
		end
		for _, stage in { "generalSeamGeometry", "generalSeamContacts" } do
			local token = {}
			local ok, err = pcall(query, a, b, {
				requireQuotient = true,
				checkpoint = function(p)
					if p.stage == stage then
						error(token, 0)
					end
				end,
			})
			assert(not ok and err == token)
			local canceled = false
			fails(function()
				query(a, b, {
					requireQuotient = true,
					checkpoint = function(p)
						if p.stage == stage then
							canceled = true
						end
					end,
					cancelled = function()
						return canceled
					end,
				})
			end, "cancelled")
		end
	end)
	test("Periodic transport and Bernstein proof records are finite and retain every anchor", function()
		local a, b = seam(true)
		local r = query(a, b, { requireQuotient = true })
		local active = {}
		local function inspect(value)
			assert(type(value) ~= "function" and type(value) ~= "thread")
			if type(value) == "number" then
				assert(U.finite(value))
			end
			if type(value) ~= "table" then
				return
			end
			assert(not active[value])
			active[value] = true
			for k, v in value do
				inspect(k)
				inspect(v)
			end
			active[value] = nil
		end
		inspect(r)
		assert(r.spanPairs[1].signProof and r.periodicQuotient.vertexProofs)
	end)
	if not (settings and settings.skipNative) then
		test("Periodic tensor anchor UV representatives round trip through EditableMesh", function()
			local a, b = seam(true)
			local r = query(a, b, { requireQuotient = true })
			local mesh, corners = E.Mesh.new(), {}
			for i = 1, 3 do
				local v = r.vertices[i]
				local ids = {
					mesh:addVertex(v.position),
					mesh:addVertex(v.position + V(0.125, 0, 0)),
					mesh:addVertex(v.position + V(0, 0.125, 0)),
				}
				corners[i] = { uv = Vector2.new(v.parameters[1], v.parameters[2]), normal = V(0, 0, 1) }
				mesh:addFace(ids, { corners[i], corners[i], corners[i] })
			end
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local copy = E.Roblox.fromEditable(handle.editable)
				local count = 0
				for _, f in copy.faces do
					for _, corner in f.corners do
						local found = false
						for _, c in corners do
							if corner.uv == c.uv then
								found = true
							end
						end
						assert(found and corner.normal.Z > 0.99)
						count += 1
					end
				end
				assert(count == 9)
				for i = 1, 3 do
					local found = false
					for _, position in copy.vertices do
						if position == r.vertices[i].position - handle.origin then
							found = true
						end
					end
					assert(found, "Native conversion lost a contact anchor")
				end
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
