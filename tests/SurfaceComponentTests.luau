return function(E)
	local N, Q = E.NURBS, E.SplineQuery
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function plane(z, size)
		local s = size or 1
		return N.surface({
			{ Vector3.new(-s, -s, z), Vector3.new(-s, s, z) },
			{ Vector3.new(s, -s, z), Vector3.new(s, s, z) },
		}, 1, 1)
	end
	local function linePair(fold)
		local p, h = {}, { 0.1875, -0.3125, 0.1875 }
		local x = fold and { 0.25, -0.25, 0.25 } or { -0.5, 0, 0.5 }
		for i = 1, 3 do
			p[i] = { Vector3.new(x[i], -0.5, h[i]), Vector3.new(x[i], 0.5, h[i]) }
		end
		return N.surface(p, 2, 1), plane(0)
	end
	local function circle()
		local p, h = {}, { 0.25, -0.25, 0.25 }
		for i = 1, 3 do
			p[i] = {}
			for j = 1, 3 do
				p[i][j] = Vector3.new((i - 1) / 2 - 0.5, (j - 1) / 2 - 0.5, h[i] + h[j])
			end
		end
		return N.surface(p, 2, 2), plane(0.125)
	end
	local function check(r, count)
		assert(r.parameterComponentsCertified and r.componentCount == count and #r.components == count)
		assert(r.connectivity.complete and #r.unresolvedConnections == 0)
		local seen = {}
		for index, c in r.components do
			assert(c.connected and c.isolated and c.certified and #c.curveIndices > 0)
			assert(#c.connectionIndices == #c.curveIndices - 1)
			for _, i in c.curveIndices do
				assert(not seen[i] and r.curves[i].component == index)
				seen[i] = true
			end
			for _, i in c.connectionIndices do
				local link = r.connections[i]
				assert(
					link.certified
						and r.curves[link.firstCurve].component == index
						and r.curves[link.secondCurve].component == index
				)
				local target = r.curves[link.targetCurve].isolatingBox
				for axis = 1, 4 do
					assert(
						link.parameterBox[axis][1] >= target[axis][1]
							and link.parameterBox[axis][2] <= target[axis][2]
					)
				end
			end
		end
		for i in r.curves do
			assert(seen[i])
		end
	end
	local circleResult
	test("Closed circular intersection has one certified parameter component", function()
		local a, b = circle()
		circleResult = Q.intersectSurfaces(
			a,
			b,
			{ tolerance = 0.003, maxNodes = 1000, requireComplete = true, requireComponents = true }
		)
		check(circleResult, 1)
		assert(#circleResult.curves > 2 and #circleResult.connections == #circleResult.curves - 1)
		assert(not circleResult.componentTopologyCertified)
	end)
	test("Connection witnesses match independent analytic circle coordinates", function()
		assert(circleResult)
		for _, link in circleResult.connections do
			local axis, t = link.parameterAxis, (link.parameterRange[1] + link.parameterRange[2]) / 2
			local x, y
			if axis == 1 or axis == 3 then
				x = axis == 1 and t - 0.5 or 2 * t - 1
				y = math.sqrt(math.max(0, 0.125 - x * x))
					* (link.parameterBox[2][1] + link.parameterBox[2][2] < 1 and -1 or 1)
			else
				y = axis == 2 and t - 0.5 or 2 * t - 1
				x = math.sqrt(math.max(0, 0.125 - y * y))
					* (link.parameterBox[1][1] + link.parameterBox[1][2] < 1 and -1 or 1)
			end
			for i, p in { x + 0.5, y + 0.5, (x + 1) / 2, (y + 1) / 2 } do
				assert(p >= link.parameterBox[i][1] - 1e-12 and p <= link.parameterBox[i][2] + 1e-12)
			end
		end
	end)
	test("Disconnected lines have two certified components and independent roots", function()
		local a, b = linePair(false)
		local r = Q.intersectSurfaces(a, b, { requireComplete = true, requireComponents = true })
		check(r, 2)
		local found = {}
		for _, c in r.components do
			local first = r.curves[c.curveIndices[1]].samples[1]
			local u = first.parameters[1] < 0.5 and 0.25 or 0.75
			for _, index in c.curveIndices do
				for _, sample in r.curves[index].samples do
					assert(sample.parameterBox[1][1] <= u and sample.parameterBox[1][2] >= u)
				end
			end
			found[u] = true
		end
		assert(found[0.25] and found[0.75])
	end)
	test("Coincident spatial lines with different source parameters stay distinct", function()
		local a, b = linePair(true)
		local r = Q.intersectSurfaces(a, b, { requireComplete = true, requireComponents = true })
		check(r, 2)
		for _, curve in r.curves do
			for _, p in curve.samples do
				assert(math.abs(p.position.X - 0.0625) < 1e-6 and math.abs(p.position.Z) < 1e-6)
			end
		end
	end)
	test("Empty intersection has a certified zero-component partition", function()
		local r = Q.intersectSurfaces(plane(0), plane(1), { requireComponents = true })
		check(r, 0)
		assert(r.complete and r.connectivity.pairs == 0 and #r.connections == 0)
	end)
	test("One graph certifies connectivity independently of chord accuracy", function()
		local p = {}
		for i, h in { 1, -1, 1 } do
			p[i] = { Vector3.new(i - 2, -1, h), Vector3.new(i - 2, 1, h) }
		end
		local a = N.surface(p, 2, 1)
		local b = N.surface({
			{ Vector3.new(-2, 0, -2), Vector3.new(-2, 0, 2) },
			{ Vector3.new(2, 0, -2), Vector3.new(2, 0, 2) },
		}, 1, 1)
		local r = Q.intersectSurfaces(a, b, { maxSegments = 1, tolerance = 1e-7, requireComponents = true })
		check(r, 1)
		assert(not r.complete and r.rootCoverageComplete and not r.curves[1].accurate)
	end)
	test("Pair budget reports an explicit unexamined frontier", function()
		local a, b = linePair(false)
		local r = Q.intersectSurfaces(a, b, { maxConnectionPairs = 0, requireComplete = true })
		assert(r.complete and not r.parameterComponentsCertified and r.componentCount == nil)
		assert(not r.connectivity.complete and r.connectivity.reason == "pairs" and r.connectivity.pairs == 0)
		assert(r.connectivity.frontier.firstCurve == 1 and r.connectivity.frontier.secondCurve == 2)
		for _, c in r.components do
			assert(c.connected and not c.certified and not c.isolated)
		end
		assert(not pcall(Q.intersectSurfaces, a, b, { maxConnectionPairs = 0, requireComponents = true }))
	end)
	test("Missing root coverage prevents a complete-component claim", function()
		local r = Q.intersectSurfaces(plane(0), plane(0), { maxNodes = 8, maxDepth = 2 })
		assert(
			not r.complete
				and not r.rootCoverageComplete
				and not r.parameterComponentsCertified
				and r.componentCount == nil
		)
		assert(#r.unresolved > 0)
		assert(not pcall(Q.intersectSurfaces, plane(0), plane(0), { maxNodes = 1, requireComponents = true }))
	end)
	test("Periodic seam endpoints remain separate in the declared parameter space", function()
		local p = {}
		for _, v in
			{ Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) }
		do
			table.insert(p, { v - Vector3.zAxis, v + Vector3.zAxis })
		end
		local a = E.Cyclic.surface(p, 1, 1, { cyclicU = true, cyclicV = false })
		local b = N.surface({
			{ Vector3.new(0.25, -0.5, 0), Vector3.new(0.25, 0.5, 0) },
			{
				Vector3.new(1.5, -0.5, 0),
				Vector3.new(1.5, 0.5, 0),
			},
		}, 1, 1)
		local r =
			Q.intersectSurfaces(a, b, { tolerance = 0.01, requireComplete = true, requireComponents = true })
		check(r, 2)
		assert(r.componentSpace:find("periodic seams are distinct", 1, true))
		local edges = {}
		for _, c in r.components do
			local box = c.parameterBox[1]
			assert(box[2] < 0.5 or box[1] > 0.5)
			if box[1] == 0 then
				edges[0] = true
			end
			if box[2] == 1 then
				edges[1] = true
			end
		end
		assert(edges[0] and edges[1])
	end)
	test("Connection option validation and cancellation are transactional", function()
		local a, b = linePair(false)
		for _, options in
			{
				{ maxConnectionPairs = -1 },
				{ maxConnectionNodes = -1 },
				{ maxConnectionDepth = 129 },
				{ maxConnectionPairs = 0.5 },
				{ requireComponents = "yes" },
			}
		do
			assert(not pcall(Q.intersectSurfaces, a, b, options))
		end
		local first, seen = a.control[1][1], false
		assert(not pcall(Q.intersectSurfaces, a, b, {
			checkpoint = function(info)
				if info.stage == "connect" then
					seen = true
					error("cancel connections")
				end
			end,
		}))
		assert(seen and a.control[1][1] == first)
	end)
	test("Swapping source order preserves the number of parameter components", function()
		local a, b = linePair(false)
		local r = Q.intersectSurfaces(b, a, { requireComplete = true, requireComponents = true })
		check(r, 2)
		for _, c in r.components do
			local range = c.parameterBox[3]
			assert(range[2] < 0.5 or range[1] > 0.5)
		end
	end)
	test("Restricted source domains select a single analytic component", function()
		local a, b = linePair(false)
		local r = Q.intersectSurfaces(a, b, {
			parameterBox = { { 0.1, 0.4 }, { 0, 1 }, { 0, 1 }, { 0, 1 } },
			requireComplete = true,
			requireComponents = true,
		})
		check(r, 1)
		assert(r.components[1].parameterBox[1][2] < 0.5)
	end)
	test("Nearby branches remain distinct even when closer than chord tolerance", function()
		local e = 1 / 1024
		local p, h = {}, { 0.25 - e * e, -0.25 - e * e, 0.25 - e * e }
		for i = 1, 3 do
			p[i] = { Vector3.new((i - 1) / 2 - 0.5, -0.5, h[i]), Vector3.new((i - 1) / 2 - 0.5, 0.5, h[i]) }
		end
		local r = Q.intersectSurfaces(
			N.surface(p, 2, 1),
			plane(0),
			{ tolerance = 0.1, requireComplete = true, requireComponents = true }
		)
		check(r, 2)
		local signs = {}
		for _, c in r.components do
			local x = r.curves[c.curveIndices[1]].samples[1].position.X
			assert(math.abs(math.abs(x) - e) < 1e-6)
			signs[x < 0 and -1 or 1] = true
		end
		assert(signs[-1] and signs[1])
	end)
	test("Zero refinement budget retains only connections with available certificates", function()
		local a, b = circle()
		local r = Q.intersectSurfaces(
			a,
			b,
			{ tolerance = 0.01, maxConnectionNodes = 0, maxConnectionDepth = 0, requireComplete = true }
		)
		assert(r.connectivity.visited == 0)
		if r.parameterComponentsCertified then
			check(r, 1)
		else
			assert(#r.unresolvedConnections > 0 and r.componentCount == nil)
		end
	end)
	test("Rigid transforms and independent positive weight gauges preserve components", function()
		local frame = CFrame.new(7, -3, 2) * CFrame.Angles(0.2, -0.4, 0.3)
		for _, scale in { 0.01, 100 } do
			local a, b = linePair(false)
			for index, s in { a, b } do
				for i, row in s.control do
					for j, p in row do
						s.control[i][j] = frame:PointToWorldSpace(p * scale)
						s.weights[i][j] = index == 1 and 1e100 or 1e-100
					end
				end
			end
			local r = Q.intersectSurfaces(
				a,
				b,
				{ tolerance = 0.001, requireComplete = true, requireComponents = true }
			)
			check(r, 2)
		end
	end)
	test("Connectivity work participates in the query's hard work budget", function()
		local a, b = linePair(false)
		local entered
		Q.intersectSurfaces(a, b, {
			checkpoint = function(info)
				if info.stage == "connect" and not entered then
					entered = info.work
				end
			end,
		})
		assert(entered)
		assert(not pcall(Q.intersectSurfaces, a, b, { maxWork = entered }))
	end)
	test("Nested exact quartic circles retain both complete components", function()
		local p, q2, q4 = {}, { 3, 0, -1, 0, 3 }, { 1, -1, 1, -1, 1 }
		for i = 1, 5 do
			p[i] = {}
			for j = 1, 5 do
				p[i][j] = Vector3.new(
					(i - 1) / 2 - 1,
					(j - 1) / 2 - 1,
					9 * (q4[i] + q4[j]) + 2 * q2[i] * q2[j] - 39 / 64 * (q2[i] + q2[j]) + 81 / 1024
				)
			end
		end
		-- Exact native coefficients represent 9*(x*x+y*y-1/16)*(x*x+y*y-9/64).
		local r = Q.intersectSurfaces(N.surface(p, 4, 4), plane(0, 2), {
			tolerance = 0.01,
			maxNodes = 2000,
			maxSegments = 4096,
			requireComplete = true,
			requireComponents = true,
		})
		check(r, 2)
		local radii = {}
		for _, c in r.components do
			local first = r.curves[c.curveIndices[1]].samples[1].position
			local radius = math.sqrt(first.X * first.X + first.Y * first.Y) < 0.3 and 0.25 or 0.375
			radii[radius] = true
			for _, index in c.curveIndices do
				for _, sample in r.curves[index].samples do
					local v = sample.position
					assert(math.abs(math.sqrt(v.X * v.X + v.Y * v.Y) - radius) <= sample.errorBound + 1e-12)
				end
			end
			for i = 0, 127 do
				local angle = 2 * math.pi * i / 128
				local x, y = radius * math.cos(angle), radius * math.sin(angle)
				local parameters = { (x + 1) / 2, (y + 1) / 2, (x + 2) / 4, (y + 2) / 4 }
				local covered = false
				for _, index in c.curveIndices do
					local inside = true
					for axis, value in parameters do
						local range = r.curves[index].parameterBox[axis]
						inside = inside and value >= range[1] - 1e-12 and value <= range[2] + 1e-12
					end
					covered = covered or inside
				end
				assert(covered, "Independent analytic circle point lost from its component")
			end
		end
		assert(radii[0.25] and radii[0.375])
	end)
	test("Affine partner reduction certifies interior projection in either source order", function()
		local a, b = linePair(false)
		for _, swapped in { false, true } do
			local r = Q.intersectSurfaces(
				swapped and b or a,
				swapped and a or b,
				{ requireComplete = true, requireComponents = true }
			)
			check(r, 2)
			local proof = r.affinePartner
			assert(proof and proof.certified and proof.surface == (swapped and "A" or "B"))
			assert(proof.fixedAxes[1] == (swapped and 1 or 3))
			for _, range in proof.projectedParameterBox do
				assert(range[1] <= 0.25 and range[2] >= 0.75 and range[1] > 0 and range[2] < 1)
			end
		end
	end)
	test("Affine reduction rejects nonaffine weights, geometry and clipped footprints", function()
		for case = 1, 5 do
			local a, b = linePair(false)
			local options = { maxNodes = 1 }
			if case == 1 then
				b.weights[2][2] = 2
			elseif case == 2 then
				b.control[2][2] += Vector3.new(1 / 1024, 0, 0)
			elseif case == 3 then
				b.control[2][2] += Vector3.new(0, 0, 1 / 1024)
			elseif case == 4 then
				options.parameterBox = { { 0, 1 }, { 0, 1 }, { 0.4, 0.6 }, { 0, 1 } }
			else
				b = plane(0, 0.5)
			end
			assert(Q.intersectSurfaces(a, b, options).affinePartner == nil)
		end
	end)
	return report
end
