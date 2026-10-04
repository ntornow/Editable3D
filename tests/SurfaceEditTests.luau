return function(E)
	local S, N, C = E.SurfaceEdit, E.NURBS, E.Cyclic
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tol)
		assert(math.abs(a - b) < (tol or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function vec(a, b, tol)
		assert((a - b).Magnitude < (tol or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function grid(nu, nv, du, dv, options)
		local p = {}
		for i = 1, nu do
			p[i] = {}
			for j = 1, nv do
				p[i][j] = Vector3.new(i - 1, j - 1, 0)
			end
		end
		return N.surface(p, du or 1, dv or 1, options)
	end
	local function periodic()
		local p, w = {}, {}
		for i = 1, 6 do
			p[i], w[i] = {}, {}
			local angle = (i - 1) * 2 * math.pi / 6
			for j = 1, 4 do
				p[i][j] = Vector3.new(2 * math.cos(angle), j - 1, 2 * math.sin(angle))
				w[i][j] = 1 + 0.1 * i + 0.05 * j
			end
		end
		return C.surface(p, 3, 2, {
			weights = w,
			cyclicV = false,
			intervalsU = { 1, 2, 1, 2, 1, 3 },
			knotsV = { 0, 0, 0, 0.3, 1, 1, 1 },
		})
	end
	local function sameControls(a, b)
		assert(#a.control == #b.control and #a.control[1] == #b.control[1])
		for i, row in a.control do
			for j, p in row do
				assert(p == b.control[i][j] and a.weights[i][j] == b.weights[i][j])
			end
		end
	end
	local function eval(s, u, v)
		return s.kind == "cyclicSurface" and C.evaluateSurface(s, u, v) or N.evaluateSurface(s, u, v)
	end
	local function unchangedKnots(a, b, axis)
		for _, kind in { "knots", "intervals" } do
			local x, y = a[kind .. axis], b[kind .. axis]
			assert((x == nil) == (y == nil))
			if x then
				assert(#x == #y)
				for i, value in x do
					assert(y[i] == value)
				end
			end
		end
		assert(a["degree" .. axis] == b["degree" .. axis] and a["clamped" .. axis] == b["clamped" .. axis])
	end
	test("Control selections combine rectangular ranges predicates and weighted masks", function()
		local a = grid(4, 5)
		local mask = S.select(a, {
			u = Vector2.new(2, 3),
			v = Vector2.new(2, 4),
			predicate = function(_, _, i, j)
				return (i + j) % 2 == 0 and 0.5 or false
			end,
		})
		assert(mask["2:2"] == 0.5 and mask["2:3"] == nil and mask["1:1"] == nil)
		local boundary = S.select(a, { boundary = "all" })
		assert(boundary["1:3"] and boundary["3:5"] and not boundary["2:2"])
		local b, r = S.map(a, function(p, w)
			return p + Vector3.zAxis, w * 2
		end, { mask = mask, strength = 0.5 })
		vec(b.control[2][2], a.control[2][2] + Vector3.zAxis * 0.25)
		near(b.weights[2][2], 1.25)
		assert(b.control[2][3] == a.control[2][3] and r.modifiedControls == 3 and r.modifiedWeights == 3)
	end)
	test("Cyclic selections expose only real open borders", function()
		local a = periodic()
		local mask = S.select(a, { boundary = "all" })
		assert(mask["3:1"] and mask["3:4"] and not mask["1:2"])
		assert(not pcall(S.select, a, { boundary = "U0" }))
		local twice = S.setCyclic(a, "V", true)
		assert(next(S.select(twice, { boundary = "all" })) == nil)
	end)
	test("Affine control transforms commute with independent rational evaluation", function()
		local a = grid(3, 4, 2, 2, {
			weights = { { 1, 2, 1, 3 }, { 2, 1, 4, 1 }, { 1, 3, 2, 1 } },
			knotsV = { 0, 0, 0, 0.3, 1, 1, 1 },
		})
		local frame = CFrame.new(4, -3, 2) * CFrame.Angles(0.3, -0.2, 0.6)
		local scale, pivot = Vector3.new(2, 0.5, -1), Vector3.new(1, 1, 0)
		local b, r = S.transform(a, frame, { scale = scale, pivot = pivot })
		assert(r.complete and not r.regularityChecked)
		for i = 0, 7 do
			for j = 0, 7 do
				local p = N.evaluateSurface(a, i / 7, j / 7)
				vec(
					N.evaluateSurface(b, i / 7, j / 7),
					pivot + frame:VectorToWorldSpace((p - pivot) * scale) + frame.Position,
					2e-5
				)
			end
		end
		unchangedKnots(a, b, "U")
		unchangedKnots(a, b, "V")
	end)
	test("Mapped cyclic controls keep unique seam relationships and skip zero masks", function()
		local a = periodic()
		local original = a.control[1][1]
		local calls = 0
		local b, r = S.map(a, function(p, w)
			calls += 1
			return p + Vector3.xAxis, w * 1.2
		end, { mask = { ["1:1"] = true } })
		assert(calls == 1 and r.modifiedControls == 1 and a.control[1][1] == original)
		vec(C.evaluateSurface(b, 0, 0.4), C.evaluateSurface(b, 1, 0.4), 2e-5)
		unchangedKnots(a, b, "U")
		unchangedKnots(a, b, "V")
		local c = S.map(a, function(p, w)
			return p + Vector3.zAxis, w
		end, { mask = { ["1:1"] = true }, invertMask = true })
		assert(c.control[1][1] == original and c.control[2][2] ~= a.control[2][2])
	end)
	test("Weight edits preserve sparse omissions and common rational scale invariance", function()
		local a = periodic()
		local b, r = S.setWeights(a, { ["2:3"] = 7 })
		assert(r.modifiedWeights == 1 and b.weights[2][3] == 7 and b.weights[1][1] == a.weights[1][1])
		local scaled = S.setWeights(a, 1e80, { mode = "multiply" })
		for i = 0, 8 do
			vec(eval(a, i / 8, 0.37), eval(scaled, i / 8, 0.37), 1e-5)
		end
		local reset = S.setWeights(scaled, 1)
		assert(reset.weights[1][1] == 1)
		local callback = S.setWeights(a, function(w, i, j)
			return w + i + j
		end)
		near(callback.weights[3][2], a.weights[3][2] + 5)
	end)
	test("Simultaneous smoothing preserves pinned borders and has analytic interior averages", function()
		local a = grid(3, 3, 2, 2)
		a.control[2][2] += Vector3.zAxis * 4
		a.weights[2][2] = 9
		local b, r = S.smooth(a, 1, { factor = 1, smoothWeights = true })
		assert(r.modifiedControls == 1 and r.modifiedWeights == 1)
		vec(b.control[2][2], Vector3.new(1, 1, 0))
		near(b.weights[2][2], 1)
		for i = 1, 3 do
			assert(b.control[1][i] == a.control[1][i] and b.control[i][1] == a.control[i][1])
		end
		local copy = S.smooth(a, 0)
		sameControls(a, copy)
		copy.control[1][1] += Vector3.one
		assert(a.control[1][1] == Vector3.zero)
	end)
	test("Cyclic smoothing wraps neighbors without counting a two-row neighbor twice", function()
		local a = grid(2, 3, 1, 1)
		a = S.setCyclic(a, "U", true)
		local b = S.smooth(a, 1, { factor = 1, pinBoundary = false, mask = { ["1:2"] = 1 } })
		local expected = (a.control[2][2] + a.control[1][1] + a.control[1][3]) / 3
		vec(b.control[1][2], expected)
		assert(b.control[2][2] == a.control[2][2])
	end)
	test("Existing mesh deformations compose with control masks and rational weights", function()
		local a = grid(3, 4, 2, 2)
		a.weights[2][3] = 2.5
		local b, r = S.deform(a, function(mesh, map)
			assert(map["2:3"] and mesh.attributes.surface_weight.values[map["2:3"]] == 2.5)
			return E.Deform.shear(mesh, 0.4, { axis = "X", direction = "Y" })
		end, { mask = { ["2:3"] = 0.5 } })
		assert(r.operator.complete and r.modifiedControls == 1 and b.weights[2][3] == 2.5)
		vec(b.control[2][3], Vector3.new(1.4, 2, 0))
		assert(b.control[1][4] == a.control[1][4])
	end)
	test("Control-mesh adapters reject changed IDs schemas topology and incomplete operators", function()
		local a = grid(2, 2)
		for _, operation in
			{
				function(m)
					m:addVertex(Vector3.one)
					return m
				end,
				function(m)
					m:addFace({ 1, 2, 3 })
					return m
				end,
				function(m)
					m.attributes = {}
					return m
				end,
				function(m)
					m.vertices[9] = m.vertices[1]
					m.vertices[1] = nil
					m.attributes.surface_weight.values[9] = 1
					m.attributes.surface_weight.values[1] = nil
					return m
				end,
				function(m)
					return m, { complete = false }
				end,
				function(m)
					m.attributes.surface_weight.values[1] = -1
					return m
				end,
			}
		do
			assert(not pcall(S.deform, a, operation, { mask = {} }))
		end
		sameControls(a, grid(2, 2))
	end)
	test("Every border extrusion preserves old controls and copies new rows in order", function()
		local a = grid(3, 4, 2, 2)
		for _, boundary in { "U0", "U1", "V0", "V1" } do
			local b, r = S.extrude(a, boundary, 2, Vector3.zAxis)
			local along = boundary:sub(1, 1) == "U"
			local low = boundary:sub(2) == "0"
			assert(
				r.createdControls == 2 * (along and 4 or 3)
					and #b.control == (along and 5 or 3)
					and #b.control[1] == (along and 4 or 6)
			)
			for i, row in b.control do
				for j, p in row do
					local oldI, oldJ = r.sourceRefs[i .. ":" .. j]:match("^(%d+):(%d+)$")
					local q = along and i or j
					local k = low and math.max(0, 3 - q) or math.max(0, q - (along and 3 or 4))
					vec(p, a.control[tonumber(oldI)][tonumber(oldJ)] + Vector3.zAxis * k)
				end
			end
			unchangedKnots(a, b, along and "V" or "U")
		end
	end)
	test("Extrusion callbacks can change section weights and zero steps retain the basis", function()
		local a = grid(3, 4, 2, 2, { knotsV = { 0, 0, 0, 0.3, 1, 1, 1 } })
		local b, r = S.extrude(a, "U1", 2, function(p, w, k, index)
			return p + Vector3.new(1, 0, k / 10), w * (1 + index / 10)
		end)
		near(b.weights[5][3], 1.3 ^ 2)
		vec(b.control[5][3], a.control[3][3] + Vector3.new(2, 0, 0.3))
		assert(r.created["4:3"] and r.created["5:3"] and not r.created["3:3"])
		local copy, zero = S.extrude(a, "V0", 0)
		sameControls(a, copy)
		unchangedKnots(a, copy, "V")
		assert(not zero.basisChanged)
	end)
	test("Unclamped extrusion retains its boundary convention and explicit knot option", function()
		local a = grid(4, 3, 2, 2, { clampedU = false })
		local b = S.extrude(a, "U1", 1, Vector3.xAxis)
		assert(not b.clampedU and #b.knotsU == 8)
		local c =
			S.extrude(a, "U0", 1, Vector3.xAxis, { knots = { 0, 0, 0, 0.2, 0.6, 1, 1, 1 }, clamped = true })
		assert(c.clampedU and c.knotsU[4] == 0.2)
	end)
	test("Rectangular duplication retains whole directions and changes only selected bases", function()
		local a = periodic()
		local b, r = S.duplicate(a, nil, Vector2.new(2, 4))
		assert(b.cyclicU and not b.cyclicV and r.basisChanged)
		unchangedKnots(a, b, "U")
		for i, row in b.control do
			for j, p in row do
				assert(p == a.control[i][j + 1] and b.weights[i][j] == a.weights[i][j + 1])
			end
		end
		b.control[1][1] += Vector3.one
		assert(b.control[1][1] ~= a.control[1][2])
		local small = S.duplicate(a, Vector2.new(2, 3), Vector2.new(2, 3), { reduceDegree = true })
		assert(small.kind == "surface" and small.degreeU == 1 and small.degreeV == 1)
		assert(not pcall(S.duplicate, a, Vector2.new(2, 3), Vector2.new(2, 3)))
	end)
	test("Transposing swaps exact parameter directions and derivative orientation", function()
		for _, a in { grid(3, 4, 2, 2), periodic() } do
			local b, r = S.transpose(a)
			assert(r.parametersSwapped and not r.basisChanged)
			for i = 0, 7 do
				for j = 0, 7 do
					vec(eval(a, i / 7, j / 7), eval(b, j / 7, i / 7), 1e-5)
				end
			end
			assert(b.degreeU == a.degreeV and b.degreeV == a.degreeU)
			if a.kind == "cyclicSurface" then
				assert(b.cyclicV and not b.cyclicU)
			end
			local restored = S.transpose(b)
			sameControls(a, restored)
		end
	end)
	test("Cyclic toggling changes the basis without deleting or duplicating controls", function()
		local a = grid(6, 4, 3, 2)
		local b, r = S.setCyclic(a, "U", true, { intervals = { 1, 2, 1, 2, 1, 3 } })
		assert(r.basisChanged and b.kind == "cyclicSurface" and b.cyclicU and not b.cyclicV)
		sameControls(a, b)
		vec(eval(b, 0, 0.4), eval(b, 1, 0.4))
		vec(C.surfaceDerivatives(b, 0, 0.4).du, C.surfaceDerivatives(b, 1, 0.4).du, 1e-4)
		local copy, noop = S.setCyclic(b, "U", true)
		assert(not noop.basisChanged)
		unchangedKnots(b, copy, "U")
		local opened = S.setCyclic(b, "U", false, { clamped = false })
		assert(opened.kind == "surface" and not opened.clampedU)
		sameControls(a, opened)
	end)
	test("Control-row deletion bridges retained rows with explicit correspondence", function()
		local a = grid(6, 4, 2, 2, { knotsV = { 0, 0, 0, 0.3, 1, 1, 1 } })
		local b, r = S.deleteRows(a, "U", { 2, 4 })
		assert(#b.control == 4 and r.deletedControls == 8 and r.basisChanged)
		for i, old in { 1, 3, 5, 6 } do
			for j = 1, 4 do
				assert(
					b.control[i][j] == a.control[old][j] and r.sourceRefs[i .. ":" .. j] == old .. ":" .. j
				)
			end
		end
		unchangedKnots(a, b, "V")
		local copy, empty = S.deleteRows(a, "V", {})
		sameControls(a, copy)
		assert(not empty.basisChanged)
	end)
	test("Periodic row deletion retains unique cyclic relationships", function()
		local a = periodic()
		local b, r = S.deleteRows(a, "U", { 2, 4 }, { reduceDegree = true })
		assert(b.cyclicU and #b.control == 4 and b.degreeU == 3 and r.deletedControls == 8)
		for _, interval in b.intervalsU do
			assert(interval == 1)
		end
		vec(eval(b, 0, 0.2), eval(b, 1, 0.2))
		unchangedKnots(a, b, "V")
	end)
	test("Open control-grid split duplicates the shared row independently", function()
		local a = grid(6, 4, 1, 2)
		local pieces, r = S.split(a, "U", 3)
		assert(#pieces == 2 and #pieces[1].control == 3 and #pieces[2].control == 4 and r.sharedRows[1] == 3)
		for j = 1, 4 do
			assert(pieces[1].control[3][j] == pieces[2].control[1][j])
		end
		pieces[1].control[3][1] += Vector3.one
		assert(pieces[2].control[1][1] == a.control[3][1])
	end)
	test("Cyclic splitting opens two arcs with both shared control rows", function()
		local a = periodic()
		local pieces, r = S.split(a, "U", 3, { reduceDegree = true })
		assert(#pieces == 2 and pieces[1].kind == "surface" and pieces[2].kind == "surface")
		assert(#pieces[1].control == 3 and #pieces[2].control == 5 and r.sharedRows[1] == 1)
		for j = 1, 4 do
			assert(pieces[2].control[5][j] == a.control[1][j])
		end
		unchangedKnots(a, pieces[1], "V")
		unchangedKnots(a, pieces[2], "V")
	end)
	test("Splitting at the last unique cyclic row opens both pieces", function()
		local a = periodic()
		local pieces = S.split(a, "U", #a.control, { reduceDegree = true })
		assert(#pieces == 2 and pieces[1].kind == "surface" and pieces[2].kind == "surface")
		assert(#pieces[1].control == 6 and #pieces[2].control == 2)
		assert(pieces[1].degreeU == 3 and pieces[2].degreeU == 1)
		for j = 1, 4 do
			assert(pieces[1].control[1][j] == pieces[2].control[2][j])
			assert(pieces[1].control[6][j] == pieces[2].control[1][j])
		end
		vec(eval(pieces[1], 0, 0.3), eval(pieces[2], 1, 0.3))
		vec(eval(pieces[1], 1, 0.3), eval(pieces[2], 0, 0.3))
	end)
	test("Segment deletion creates separate strips or one opened cyclic arc", function()
		local a = grid(6, 4, 1, 2)
		local pieces, r = S.deleteSegments(a, "U", 2, 5)
		assert(
			#pieces == 2 and #pieces[1].control == 2 and #pieces[2].control == 2 and r.deletedControls == 8
		)
		assert(pieces[2].control[1][1] == a.control[5][1])
		local cyclic = periodic()
		local arcs, cut = S.deleteSegments(cyclic, "U", 2, 5)
		assert(
			#arcs == 1 and #arcs[1].control == 4 and arcs[1].kind == "surface" and cut.removedSegments == 3
		)
		for i, old in { 5, 6, 1, 2 } do
			assert(arcs[1].control[i][1] == cyclic.control[old][1])
		end
	end)
	test("Boundary curves preserve rational weights knots and periodic profiles", function()
		local a = grid(3, 4, 2, 2, {
			weights = { { 1, 2, 1, 2 }, { 2, 1, 2, 1 }, { 1, 3, 2, 1 } },
			knotsV = { 0, 0, 0, 0.3, 1, 1, 1 },
		})
		for _, boundary in { "U0", "U1", "V0", "V1" } do
			local curve = S.boundaryCurve(a, boundary)
			local along = boundary:sub(1, 1) == "U"
			local fixed = boundary:sub(2) == "0" and 0 or 1
			for i = 0, 10 do
				vec(
					N.evaluate(curve, i / 10),
					N.evaluateSurface(a, along and fixed or i / 10, along and i / 10 or fixed)
				)
			end
		end
		local p = S.boundaryCurve(periodic(), "V0")
		assert(p.kind == "cyclicCurve" and #p.points == 6)
		vec(C.evaluate(p, 0), C.evaluate(p, 1))
	end)
	test("Full and partial boundary spins have independent circular geometry", function()
		local a = S.transform(grid(2, 3, 1, 2), CFrame.identity, { scale = Vector3.new(3, 1, 1) })
		local full, r = S.spin(a, "U1", Vector3.zero, Vector3.yAxis, 2 * math.pi)
		assert(r.closedRevolution and full.cyclicV and not full.cyclicU and #full.control[1] == 8)
		for i = 0, 8 do
			local p = eval(full, 0.3, i / 8)
			near(p.Y, 0.6)
			near(math.sqrt(p.X ^ 2 + p.Z ^ 2), 3)
			vec(p, Vector3.new(3 * math.cos(i * math.pi / 4), 0.6, -3 * math.sin(i * math.pi / 4)), 2e-5)
		end
		local partial = S.spin(a, "U1", Vector3.zero, Vector3.yAxis, -math.pi / 2, { startAngle = 0.2 })
		assert(partial.kind == "surface")
		for _, t in { 0, 1 } do
			local angle = 0.2 - t * math.pi / 2
			vec(eval(partial, 0.3, t), Vector3.new(3 * math.cos(angle), 0.6, -3 * math.sin(angle)), 2e-5)
		end
	end)
	test("Edited periodic spin surfaces retain native topology and both UV seams", function()
		local p = {}
		for i = 1, 2 do
			p[i] = {}
			for j = 1, 6 do
				local a = (j - 1) * 2 * math.pi / 6
				p[i][j] = Vector3.new(3 + math.cos(a), math.sin(a), i - 1)
			end
		end
		local source = C.surface(p, 1, 2, { cyclicU = false, cyclicV = true })
		local spun = S.spin(source, "U0", Vector3.zero, Vector3.yAxis, 2 * math.pi)
		assert(spun.cyclicU and spun.cyclicV)
		local edited = S.map(spun, function(point, w, i, j)
			return point, w * (1 + 0.01 * i * j)
		end)
		local mesh = N.tessellate(C.surfaceToNURBS(edited), 16, 16, { closedU = true, closedV = true })
		assert(mesh:validate().closed)
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), mesh:volume(), 0.0001)
			local u0, u1, v0, v1 = false, false, false, false
			for _, f in restored.faces do
				for _, c in f.corners do
					u0 = u0 or c.uv.X == 0
					u1 = u1 or c.uv.X == 1
					v0 = v0 or c.uv.Y == 0
					v1 = v1 or c.uv.Y == 1
				end
			end
			assert(u0 and u1 and v0 and v1)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Invalid control edits ranges budgets and cancellation leave sources unchanged", function()
		local a = grid(4, 4, 2, 2)
		for _, options in
			{
				{ maxControls = 1 },
				{ maxWork = 1 },
				{ mask = { ["99:1"] = 1 } },
				{ mask = { ["01:1"] = 1 } },
				{ mask = { ["1:1"] = -1 } },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function()
						error("cancel")
					end,
				},
			}
		do
			assert(not pcall(S.transform, a, CFrame.identity, options))
		end
		assert(not pcall(S.map, a, function(p)
			return p, 0
		end))
		assert(not pcall(S.setWeights, a, { ["1:1"] = -1 }))
		assert(not pcall(S.duplicate, a, Vector2.new(0, 2)))
		assert(not pcall(S.deleteRows, a, "U", { 1, 1 }))
		assert(not pcall(S.deleteRows, a, "U", { 1, 2, 3 }))
		assert(not pcall(S.deleteSegments, a, "U", 1, 4))
		assert(not pcall(S.extrude, a, "U0", 2, Vector3.one, { maxSteps = 1 }))
		assert(not pcall(S.extrude, a, "U0", 2, Vector3.one, { maxControls = 20 }))
		assert(not pcall(S.extrude, periodic(), "U0", 1, Vector3.one))
		assert(not pcall(S.smooth, a, 2, { maxIterations = 1 }))
		assert(not pcall(S.smooth, a, 1, { strength = -1 }))
		sameControls(a, grid(4, 4, 2, 2))
	end)
	report.success = report.failed == 0
	return report
end
