return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local V = Vector3.new
	local U = require(script.Parent.Util)
	local R = require(script.Parent.ExactRational)(function() end, 8192)
	local function patch(o, u, v)
		return E.NURBS.surface({ { o, o + v }, { o + u, o + u + v } }, 1, 1)
	end
	local function plane()
		return patch(V(-2, -2, 0), V(4, 0, 0), V(0, 4, 0))
	end
	local function cylinder(degree, intervals)
		local rows = {}
		for _, p in { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) } do
			table.insert(rows, { p - V(0, 0, 1), p + V(0, 0, 1) })
		end
		return E.Cyclic.surface(
			rows,
			degree or 1,
			1,
			{ cyclicU = true, cyclicV = false, intervalsU = intervals }
		)
	end
	local function query(a, b, settings)
		local options = U.copy(settings or {})
		options.method = "exactRuled"
		if options.identifyPeriodicSeams == nil then
			options.identifyPeriodicSeams = true
		end
		return E.SplineQuery.intersectSurfaces(a, b or plane(), options)
	end
	local function check(r, components)
		assert(r.quotientTopologyCertified and r.quotientComplete and r.quotientComponentCount == components)
		local q = r.periodicQuotient
		assert(q.topologyCertified and q.componentsCertified and q.contactsCertified)
		local count = {}
		for _, group in q.components do
			for _, id in group.cellIndices do
				assert(not count[id])
				count[id] = true
			end
		end
		for i in r.cells do
			assert(count[i])
		end
		for i in r.vertices do
			assert(q.vertexMap[i] and q.vertexClasses[q.vertexMap[i]])
		end
	end
	test("A transverse section has one exact point seam identification and a closed cell cycle", function()
		local r = query(cylinder(), nil, { requireQuotient = true })
		check(r, 1)
		local q = r.periodicQuotient
		assert(#r.cells == 9 and #q.joins == 1 and q.joins[1].parameterDimension == 0)
		assert(#q.vertexClasses == 4 and #r.vertices == 5 and q.vertexMap[1] == q.vertexMap[5])
	end)
	test("A seam-contained tangent ruling joins two closed interval representatives", function()
		local r = query(cylinder(), patch(V(1, -2, -2), V(0, 4, 0), V(0, 0, 4)))
		check(r, 1)
		assert(r.componentCount == 2 and #r.cells == 2 and #r.periodicQuotient.vertexClasses == 2)
		local join = r.periodicQuotient.joins[1]
		assert(
			join.parameterDimension == 1
				and R.equal(join.linearRangeExact[1], R.number(0))
				and R.equal(join.linearRangeExact[2], R.number(1))
		)
	end)
	test("A single corner contact joins exact zero-dimensional seam representatives", function()
		local r = query(cylinder(), patch(V(1, 0, 1), V(0, 1, 0), V(0, 0, 1)))
		check(r, 1)
		assert(r.componentCount == 2 and #r.vertices == 2 and #r.periodicQuotient.vertexClasses == 1)
		assert(r.periodicQuotient.joins[1].parameterDimension == 0)
	end)
	test("Coplanar periodic bands identify their complete closed seam fiber", function()
		local a = cylinder()
		for i, row in a.control do
			local p = V(row[1].X, row[1].Y, 0)
			a.control[i] = { p, p * 0.5 }
		end
		local r = query(a)
		check(r, 1)
		assert(
			r.periodicQuotient.components[1].parameterDimension == 2
				and r.periodicQuotient.joins[1].parameterDimension == 1
		)
	end)
	test("Two clipped parameter arcs become one quotient component across the seam", function()
		local r = query(cylinder(), patch(V(0.5, -2, 0), V(1, 0, 0), V(0, 4, 0)))
		check(r, 1)
		assert(r.componentCount == 2 and #r.periodicQuotient.components[1].parameterComponentIndices == 2)
	end)
	test("Unrelated components remain separate after the seam pair is joined", function()
		local r = query(cylinder(), patch(V(-2, -0.25, 0), V(4, 0, 0), V(0, 0.5, 0)))
		check(r, 2)
		assert(r.componentCount == 3 and #r.periodicQuotient.joins == 1)
	end)
	test("Restricted profile ranges preserve the unquotiented parameter complex", function()
		local r = query(
			cylinder(),
			nil,
			{ parameterBox = { { 0, 0.75 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }, requireQuotient = true }
		)
		check(r, r.componentCount)
		assert(not r.periodicQuotient.axes[1].enabled and #r.periodicQuotient.joins == 0)
		assert(#r.periodicQuotient.vertexClasses == #r.vertices)
	end)
	test("Ordinary surfaces return the identity quotient without inferred spatial welding", function()
		local a = E.Cyclic.surfaceToNURBS(cylinder())
		local r = query(a, nil, { requireQuotient = true })
		check(r, r.componentCount)
		assert(#r.periodicQuotient.axes == 0 and #r.periodicQuotient.joins == 0)
		assert(#r.periodicQuotient.vertexClasses == #r.vertices)
	end)
	test("Transposed periodic profiles retain original four-parameter coordinate order", function()
		local a = cylinder()
		local rows, weights = { {}, {} }, { {}, {} }
		for i, row in a.control do
			for j, p in row do
				rows[j][i] = p
				weights[j][i] = a.weights[i][j]
			end
		end
		local source = E.Cyclic.surface(rows, 1, 1, { cyclicU = false, cyclicV = true, weights = weights })
		local r = query(source, nil, { linearAxis = "U" })
		check(r, 1)
		assert(r.periodicQuotient.axes[1].axis == 2 and r.profileAxis == 2)
		for _, class in r.periodicQuotient.vertexClasses do
			if #class.vertexIndices == 2 then
				local first, last = r.vertices[class.vertexIndices[1]], r.vertices[class.vertexIndices[2]]
				assert(
					first.parameters[2] == 0
						and last.parameters[2] == 1
						and first.parameters[1] == last.parameters[1]
				)
			end
		end
	end)
	test("Nonuniform weighted quadratic and uniform cubic profile seams are decided exactly", function()
		for _, degree in { 2, 3 } do
			local a = cylinder(degree, degree == 2 and { 1, 2, 1, 2 } or nil)
			for i, row in a.weights do
				for j in row do
					row[j] = (i + j) % 2 == 0 and 2 or 1
				end
			end
			local r = query(a, nil, { maxWork = 200000000, maxCoefficients = 4000000 })
			check(r, 1)
			assert(r.periodicQuotient.axes[1].identity.equal)
		end
	end)
	test("Unequal exact seams reject native evaluation coincidences with a polynomial witness", function()
		local a = cylinder(2, { 0.1, 0.2, 0.3, 0.4 })
		local ordinary = E.Cyclic.surfaceToNURBS(a)
		assert(E.NURBS.evaluateSurface(ordinary, 0, 0.5) == E.NURBS.evaluateSurface(ordinary, 1, 0.5))
		local r = query(a, nil, { maxWork = 200000000, maxCoefficients = 4000000 })
		assert(r.complete and not r.quotientComplete and not r.quotientTopologyCertified)
		local q = r.periodicQuotient
		assert(q.reason == "seamGeometry" and q.axes[1].identity.certified and not q.axes[1].identity.equal)
		assert(#q.axes[1].identity.difference > 0 and #q.unresolved == 1)
		assert(
			not pcall(
				query,
				a,
				nil,
				{ requireQuotient = true, maxWork = 200000000, maxCoefficients = 4000000 }
			)
		)
	end)
	test("Common weight gauges preserve full seam identifications", function()
		for _, scale in { 2 ^ -80, 2 ^ 80 } do
			local a = cylinder()
			for _, row in a.weights do
				for j in row do
					row[j] = scale
				end
			end
			local r = query(a)
			check(r, 1)
			assert(#r.periodicQuotient.vertexClasses == 4)
		end
	end)
	test("Collapsed spatial rulings allow nonconstant homogeneous seam factors", function()
		local a = cylinder(2, { 0.1, 0.2, 0.3, 0.4 })
		for i, row in a.control do
			for j in row do
				row[j] = V(0.5, 0.5, 0)
				a.weights[i][j] = i + 2 * j
			end
		end
		local r = query(a, nil, { maxWork = 200000000, maxCoefficients = 4000000 })
		check(r, 1)
		assert(
			r.periodicQuotient.axes[1].identity.equal
				and r.periodicQuotient.components[1].parameterDimension == 2
		)
	end)
	test("Empty intersections retain a certified empty periodic contact quotient", function()
		local r = query(cylinder(), patch(V(0, 0, 8), V(1, 0, 0), V(0, 1, 0)))
		check(r, 0)
		assert(#r.cells == 0 and #r.periodicQuotient.joins == 0)
	end)
	test("Native accuracy failure preserves exact gluing while requireQuotient rejects", function()
		local a = cylinder()
		for _, row in a.control do
			row[2] += V(1, 0, 1)
		end
		local r = query(a, nil, { tolerance = 1e-12 })
		assert(r.quotientTopologyCertified and not r.quotientComplete and not r.complete)
		assert(r.periodicQuotient.reason == "approximation" and #r.periodicQuotient.joins == 1)
		assert(not pcall(query, a, nil, { tolerance = 1e-12, requireQuotient = true }))
	end)
	test("Seam callbacks cannot mutate the detached source, requested domain or flags", function()
		local a = cylinder()
		local b = plane()
		local options = {
			method = "exactRuled",
			requireQuotient = true,
			parameterBox = { { 0, 1 }, { 0, 1 }, { 0, 1 }, {
				0,
				1,
			} },
		}
		options.checkpoint = function(state)
			if state.stage == "seamGeometry" then
				a.cyclicU = false
				a.control[1][1] = V(9, 9, 9)
				b.control[1][1] = V(9, 9, 9)
				options.parameterBox[1][1] = 0.5
				options.requireQuotient = false
			end
		end
		local r = E.SplineQuery.intersectSurfaces(a, b, options)
		check(r, 1)
		assert(r.periodicQuotient.axes[1].enabled)
	end)
	test("Seam proof work is charged and cancellation or callback errors propagate", function()
		local a = cylinder()
		local base = query(a, nil, { identifyPeriodicSeams = false })
		assert(not pcall(query, a, nil, { maxWork = base.work }))
		local cancelled = false
		local ok, err = pcall(query, a, nil, {
			cancelled = function()
				return cancelled
			end,
			checkpoint = function(state)
				if state.stage == "seamGeometry" then
					cancelled = true
				end
			end,
		})
		assert(not ok and string.find(tostring(err), "cancelled"))
		local token = {}
		local success, message = pcall(query, a, nil, {
			checkpoint = function(state)
				if state.stage == "seamComponents" then
					error(token)
				end
			end,
		})
		assert(not success and message == token)
		assert(not pcall(query, a, nil, { orderComponents = true }))
		assert(not pcall(query, a, nil, { maxSeamNodes = 0 }))
		assert(not pcall(query, a, nil, { maxSeamPairs = 0 }))
		assert(not pcall(query, a, nil, { maxSeamNodes = -1 }))
	end)
	if not (settings and settings.skipNative) then
		test("A quotient cycle forms a native mesh boundary with both seam UV representatives", function()
			local r = query(cylinder(), nil, { requireQuotient = true })
			check(r, 1)
			local q = r.periodicQuotient
			local mesh = E.Mesh.new()
			local ids = {}
			for i, class in q.vertexClasses do
				ids[i] = mesh:addVertex(r.vertices[class.representative].position)
			end
			local center = mesh:addVertex(V(0, 0, 0))
			for _, cell in r.cells do
				if cell.kind == "graph" then
					local first, last = cell.boundaryVertices[1][1], cell.boundaryVertices[2][1]
					local a, b = r.vertices[first], r.vertices[last]
					mesh:addFace({ center, ids[q.vertexMap[first]], ids[q.vertexMap[last]] }, {
						{ uv = Vector2.new(0.5, 0.5), normal = V(0, 0, 1) },
						{ uv = Vector2.new(a.parameters[1], a.parameters[2]), normal = V(0, 0, 1) },
						{ uv = Vector2.new(b.parameters[1], b.parameters[2]), normal = V(0, 0, 1) },
					})
				end
			end
			local handle = E.Roblox.toEditable(mesh)
			local ok, err = pcall(function()
				local copy = E.Roblox.fromEditable(handle.editable)
				assert(copy:validate().valid)
				local zero, one = false, false
				for _, face in copy.faces do
					for i, c in face.corners do
						local p = copy.vertices[face.vertices[i]] + handle.origin
						if (p - V(1, 0, 0)).Magnitude < 1e-6 then
							assert(c.normal.Z > 0.99)
							zero = zero or c.uv.X == 0
							one = one or c.uv.X == 1
						end
					end
				end
				assert(zero and one)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
