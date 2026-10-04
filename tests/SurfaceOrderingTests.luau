return function(E)
	local N, Q = E.NURBS, E.SplineQuery
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function plane(z, s)
		s = s or 1
		return N.surface({
			{ Vector3.new(-s, -s, z), Vector3.new(-s, s, z) },
			{ Vector3.new(s, -s, z), Vector3.new(s, s, z) },
		}, 1, 1)
	end
	local function vertical()
		return N.surface({
			{ Vector3.new(-2, 0, -2), Vector3.new(-2, 0, 2) },
			{ Vector3.new(2, 0, -2), Vector3.new(2, 0, 2) },
		}, 1, 1)
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
	local function pair(fold)
		local p, h = {}, { 0.1875, -0.3125, 0.1875 }
		for i = 1, 3 do
			local x = fold and ({ 0.25, -0.25, 0.25 })[i] or (i - 1) / 2 - 0.5
			p[i] = { Vector3.new(x, -0.5, h[i]), Vector3.new(x, 0.5, h[i]) }
		end
		return N.surface(p, 2, 1), plane(0)
	end
	local function parabola(kink)
		local p = {}
		for i, h in (kink and { 1, 0, 1 } or { 1, -1, 1 }) do
			p[i] = { Vector3.new(i - 2, -1, h), Vector3.new(i - 2, 1, h) }
		end
		return N.surface(p, kink and 1 or 2, 1), vertical()
	end
	local function checkPath(r, path, closed)
		assert(r.parameterTopologyCertified and r.componentTopologyCertified and r.orderedComplete)
		assert(path.topologyCertified and path.complete and path.closed == closed)
		assert(#path.arcs > 0 and #path.segments > 0 and path.errorBound <= 0.01)
		for i, arc in path.arcs do
			assert(arc.certified and #arc.neighborhoods > 0 and path.charts[arc.chartIndex].certified)
			if i > 1 then
				assert(path.arcs[i - 1].lastAnchor == arc.firstAnchor)
			end
		end
		for i, segment in path.segments do
			assert(segment.certified and segment.accurate)
			if i > 1 then
				assert(path.segments[i - 1].last == segment.first)
			end
		end
		if closed then
			assert(path.arcs[#path.arcs].lastAnchor == path.arcs[1].firstAnchor)
			assert(path.segments[#path.segments].last == path.segments[1].first)
			assert(#path.samples == #path.segments)
		else
			assert(#path.samples == #path.segments + 1 and #path.endpoints == 2)
			for _, index in path.endpoints do
				local p = path.anchors[index]
				assert(p.boundary.certified)
				local axis = p.boundary.axis
				assert(
					p.parameterBox[axis][1] == p.boundary.parameter
						and p.parameterBox[axis][2] == p.boundary.parameter
				)
			end
		end
	end
	local function winding(path, radius)
		local sum, sign = 0, nil
		for _, s in path.segments do
			local a, b = path.samples[s.first].position, path.samples[s.last].position
			local angle = math.atan2(a.X * b.Y - a.Y * b.X, a.X * b.X + a.Y * b.Y)
			assert(math.abs(angle) < math.pi / 2)
			if sign then
				assert(sign * angle > 0)
			else
				sign = angle
			end
			sum += angle
			for i = 1, 7 do
				local t = i / 8
				-- Radial projection of the chord gives a point of the exact circle.
				local x, y = a.X * (1 - t) + b.X * t, a.Y * (1 - t) + b.Y * t
				local length = math.sqrt(x * x + y * y)
				assert(math.abs(length - radius) <= s.errorBound + 1e-12)
			end
		end
		assert(math.abs(math.abs(sum) - 2 * math.pi) < 1e-10, "Component traversed more or less than once")
	end
	local circular
	test("Closed graph atlas assembles a single certified traversal", function()
		local a, b = circle()
		circular = Q.intersectSurfaces(a, b, { tolerance = 0.003, requireOrdered = true })
		assert(circular.componentCount == 1 and circular.ordering.addedCharts > 0)
		checkPath(circular, circular.components[1].ordered, true)
	end)
	test("Independent circle winding and between-sample errors verify global order", function()
		assert(circular)
		winding(circular.components[1].ordered, math.sqrt(0.125))
	end)
	test("Every transition and bridge has a shared-root certificate", function()
		assert(circular)
		local p = circular.components[1].ordered
		for _, anchor in p.anchors do
			assert(p.charts[anchor.chartIndex] and anchor.certified and anchor.accurate)
		end
		assert(#p.joins == #p.arcs)
		for _, join in p.joins do
			local anchor = p.anchors[join.anchor]
			local d = join.parameterDerivative
			assert(join.certified and (d[1] > 0 or d[2] < 0))
			assert((d[1] > 0 and 1 or -1) * p.arcs[join.fromArc].direction == p.arcs[join.toArc].direction)
			for _, index in { join.fromChart, join.toChart } do
				local domain = p.charts[index].isolatingBox
				for axis = 1, 4 do
					assert(
						anchor.parameterBox[axis][1] >= domain[axis][1]
							and anchor.parameterBox[axis][2] <= domain[axis][2]
					)
				end
			end
		end
		for _, chart in p.charts do
			if chart.connection then
				assert(p.charts[chart.connection.sourceChart])
				for axis = 1, 4 do
					assert(
						chart.connection.parameterBox[axis][1] >= chart.isolatingBox[axis][1]
							and chart.connection.parameterBox[axis][2] <= chart.isolatingBox[axis][2]
					)
				end
			end
		end
	end)
	test("Straight open intersection has two certified parameter-boundary endpoints", function()
		local r = Q.intersectSurfaces(plane(0), vertical(), { requireOrdered = true })
		local p = r.components[1].ordered
		checkPath(r, p, false)
		assert(p.samples[1].position.X == -1 and p.samples[#p.samples].position.X == 1)
	end)
	test("Parabola and C0 kink assemble ordered open curves with chord bounds", function()
		for _, kink in { false, true } do
			local a, b = parabola(kink)
			local r = Q.intersectSurfaces(a, b, { tolerance = 0.003, requireOrdered = true })
			local path = r.components[1].ordered
			checkPath(r, path, false)
			for _, s in path.segments do
				local p0, p1 = path.samples[s.first].position, path.samples[s.last].position
				assert(p1.X > p0.X)
				for j = 0, 8 do
					local t = j / 8
					local x = p0.X * (1 - t) + p1.X * t
					local z = p0.Z * (1 - t) + p1.Z * t
					assert(math.abs(z - (kink and math.abs(x) or x * x)) <= s.errorBound + 1e-12)
				end
			end
		end
	end)
	test("Rational quarter circle preserves both boundary endpoints", function()
		local a = N.surface({
			{ Vector3.new(1, 0, -1), Vector3.new(1, 0, 1) },
			{ Vector3.new(1, 1, -1), Vector3.new(1, 1, 1) },
			{ Vector3.new(0, 1, -1), Vector3.new(0, 1, 1) },
		}, 2, 1, { weights = { { 1, 1 }, { math.sqrt(0.5), math.sqrt(0.5) }, { 1, 1 } } })
		local r = Q.intersectSurfaces(a, plane(0, 2), { tolerance = 0.003, requireOrdered = true })
		local path = r.components[1].ordered
		checkPath(r, path, false)
		for _, p in path.samples do
			assert(math.abs(p.position.X * p.position.X + p.position.Y * p.position.Y - 1) < 1e-6)
		end
		local first, last = path.samples[1].position, path.samples[#path.samples].position
		assert((first - Vector3.xAxis).Magnitude < 1e-6 and (last - Vector3.yAxis).Magnitude < 1e-6)
	end)
	test("Disconnected and spatially coincident parameter lines remain separate paths", function()
		for _, fold in { false, true } do
			local a, b = pair(fold)
			local r = Q.intersectSurfaces(a, b, { requireOrdered = true })
			assert(r.componentCount == 2)
			for _, c in r.components do
				checkPath(r, c.ordered, false)
				local p = c.ordered.samples
				assert(math.abs(p[1].position.Y + 0.5) < 1e-6 and math.abs(p[#p].position.Y - 0.5) < 1e-6)
			end
		end
	end)
	test("Nested quartic circles each assemble exactly one independent loop", function()
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
		local started = os.clock()
		local r = Q.intersectSurfaces(N.surface(p, 4, 4), plane(0, 2), {
			tolerance = 0.01,
			maxNodes = 2000,
			maxSegments = 4096,
			maxWork = 200000000,
			requireOrdered = true,
		})
		assert(r.componentCount == 2)
		report.benchmark = {
			seconds = os.clock() - started,
			work = r.work,
			visited = r.visited,
			components = r.componentCount,
			curves = #r.curves,
			orderedSegments = r.ordering.segments,
			orderNodes = r.ordering.visited,
			orderSteps = r.ordering.steps,
			addedCharts = r.ordering.addedCharts,
			orderedComplete = r.orderedComplete,
			topologyCertified = r.parameterTopologyCertified,
			tolerance = 0.01,
			paths = {},
		}
		for _, c in r.components do
			local path = c.ordered
			checkPath(r, path, true)
			local v = path.samples[1].position
			local radius = math.sqrt(v.X * v.X + v.Y * v.Y) < 0.3 and 0.25 or 0.375
			winding(path, radius)
			table.insert(report.benchmark.paths, {
				radius = radius,
				closed = path.closed,
				arcs = #path.arcs,
				segments = #path.segments,
				maxErrorBound = path.errorBound,
			})
		end
	end)
	test("Empty root set has a complete empty ordered partition", function()
		local r = Q.intersectSurfaces(plane(0), plane(1), { requireOrdered = true })
		assert(
			r.orderedComplete
				and r.parameterTopologyCertified
				and #r.components == 0
				and r.ordering.steps == 0
		)
	end)
	test("Ordering is opt-in and does not change the local-cover completion contract", function()
		local a, b = parabola(false)
		local r = Q.intersectSurfaces(a, b, { maxSegments = 1, tolerance = 0.003, requireOrdered = true })
		assert(not r.complete and r.orderedComplete and r.rootCoverageComplete)
		checkPath(r, r.components[1].ordered, false)
		local s = Q.intersectSurfaces(a, b, { tolerance = 0.003 })
		assert(not s.ordering.requested and not s.orderedComplete and not s.parameterTopologyCertified)
	end)
	test("Restricted domains terminate at original normalized parameter boundaries", function()
		local r = Q.intersectSurfaces(
			plane(0),
			vertical(),
			{ parameterBox = { { 0.25, 0.75 }, { 0, 1 }, { 0, 1 }, { 0, 1 } }, requireOrdered = true }
		)
		local path = r.components[1].ordered
		checkPath(r, path, false)
		assert(path.samples[1].position.X == -0.5 and path.samples[#path.samples].position.X == 0.5)
	end)
	test("Topology and approximation budgets retain explicit incomplete reports", function()
		for _, options in { { maxOrderNodes = 0 }, { maxOrderSteps = 0 } } do
			options.orderComponents = true
			local r = Q.intersectSurfaces(plane(0), vertical(), options)
			assert(r.complete and not r.orderedComplete and not r.parameterTopologyCertified)
			assert(r.components[1].ordered.reason == "nodes" or r.components[1].ordered.reason == "steps")
			options.requireOrdered = true
			assert(not pcall(Q.intersectSurfaces, plane(0), vertical(), options))
		end
		local r =
			Q.intersectSurfaces(plane(0), vertical(), { maxOrderedSegments = 0, orderComponents = true })
		assert(r.parameterTopologyCertified and not r.orderedComplete and r.ordering.segments == 0)
		assert(r.components[1].ordered.reason == "segments")
		local a, b = parabola(false)
		local q = Q.intersectSurfaces(a, b, { orderComponents = true, maxOrderDepth = 0, tolerance = 1e-5 })
		assert(q.parameterTopologyCertified and not q.orderedComplete)
	end)
	test("Unresolved root coverage or connectivity prevents ordered topology claims", function()
		local r = Q.intersectSurfaces(plane(0), plane(0), { orderComponents = true, maxNodes = 1 })
		assert(
			not r.parameterTopologyCertified and not r.orderedComplete and r.ordering.reason == "components"
		)
		local a, b = pair(false)
		local q = Q.intersectSurfaces(a, b, { orderComponents = true, maxConnectionPairs = 0 })
		assert(q.complete and not q.orderedComplete and q.ordering.reason == "components")
	end)
	test("Ordering option validation and both cancellation stages are transactional", function()
		for _, options in
			{
				{ orderComponents = "yes" },
				{ requireOrdered = 1 },
				{ maxOrderNodes = -1 },
				{ maxOrderSteps = 0.5 },
				{ maxOrderDepth = 129 },
				{ maxOrderedSegments = -1 },
			}
		do
			assert(not pcall(Q.intersectSurfaces, plane(0), vertical(), options))
		end
		for _, stage in { "order", "orderSample" } do
			local a, b = plane(0), vertical()
			local first = a.control[1][1]
			local seen = false
			assert(not pcall(Q.intersectSurfaces, a, b, {
				orderComponents = true,
				checkpoint = function(info)
					if info.stage == stage then
						seen = true
						error("cancel ordering")
					end
				end,
			}))
			assert(seen and a.control[1][1] == first)
		end
	end)
	test("Source and option snapshots precede ordering callbacks", function()
		local a, b = plane(0), vertical()
		local options = { requireOrdered = true, maxOrderNodes = 10000 }
		options.checkpoint = function(info)
			if info.stage == "order" then
				a.control[1][1] = Vector3.new(999, 999, 999)
				b.weights[1][1] = 999
				options.maxOrderNodes = 0
			end
		end
		local r = Q.intersectSurfaces(a, b, options)
		local p = r.components[1].ordered
		checkPath(r, p, false)
		assert(p.samples[1].position.X == -1 and p.samples[#p.samples].position.X == 1)
	end)
	test("Rigid transforms, model scale and weight gauges preserve open traversal", function()
		local frame = CFrame.new(7, -3, 2) * CFrame.Angles(0.2, -0.4, 0.3)
		for _, scale in { 0.01, 100 } do
			local a, b = pair(false)
			for index, s in { a, b } do
				for i, row in s.control do
					for j, p in row do
						s.control[i][j] = frame:PointToWorldSpace(p * scale)
						s.weights[i][j] = index == 1 and 1e100 or 1e-100
					end
				end
			end
			local r = Q.intersectSurfaces(a, b, { tolerance = 0.003, requireOrdered = true })
			assert(r.componentCount == 2)
			for _, c in r.components do
				checkPath(r, c.ordered, false)
			end
		end
	end)
	test("Ordering work obeys the shared hard query budget", function()
		local entered
		Q.intersectSurfaces(plane(0), vertical(), {
			orderComponents = true,
			checkpoint = function(info)
				if info.stage == "order" and not entered then
					entered = info.work
				end
			end,
		})
		assert(
			entered
				and not pcall(
					Q.intersectSurfaces,
					plane(0),
					vertical(),
					{ orderComponents = true, maxWork = entered }
				)
		)
	end)
	test("Periodic seam remains two parameter endpoints even at one spatial point", function()
		local p = {}
		for _, v in
			{ Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) }
		do
			table.insert(p, { v - Vector3.zAxis, v + Vector3.zAxis })
		end
		local a = E.Cyclic.surface(p, 1, 1, { cyclicU = true, cyclicV = false })
		local r = Q.intersectSurfaces(a, plane(0, 2), { tolerance = 0.003, requireOrdered = true })
		assert(r.componentCount == 1)
		local path = r.components[1].ordered
		checkPath(r, path, false)
		assert((path.samples[1].position - path.samples[#path.samples].position).Magnitude < 1e-6)
		assert(path.samples[1].parameters[1] == 0 and path.samples[#path.samples].parameters[1] == 1)
	end)
	test("Nonseparable rational weights retain a monotone ordered centerline", function()
		local p, w = {}, { { 1, 2, 1 }, { 2, 1, 2 }, { 1, 3, 1 } }
		for i = 1, 3 do
			p[i] = {}
			for j = 1, 3 do
				p[i][j] = Vector3.new(i - 2, j - 2, (i - 2) ^ 2)
			end
		end
		local a = N.surface(p, 2, 2, { weights = w })
		local r = Q.intersectSurfaces(a, vertical(), { tolerance = 0.005, requireOrdered = true })
		local path = r.components[1].ordered
		checkPath(r, path, false)
		for _, sample in path.samples do
			local t = sample.parameters[1]
			local b0, b1, b2 = (1 - t) ^ 2, 2 * t * (1 - t), t * t
			local den = 1.5 * b0 + 1.5 * b1 + 2 * b2
			local x, z = (-1.5 * b0 + 2 * b2) / den, (1.5 * b0 + 2 * b2) / den
			assert(math.abs(sample.position.X - x) < 1e-6 and math.abs(sample.position.Z - z) < 1e-6)
		end
	end)
	test("Swapped and transposed surfaces preserve a single closed traversal", function()
		for _, transpose in { false, true } do
			local a, b = circle()
			if transpose then
				a = E.SurfaceEdit.transpose(a)
			end
			local r = Q.intersectSurfaces(b, a, { tolerance = 0.003, requireOrdered = true })
			local path = r.components[1].ordered
			checkPath(r, path, true)
			winding(path, math.sqrt(0.125))
		end
	end)
	test("Ordered loop closes a native mesh boundary without a duplicate seam vertex", function()
		assert(circular)
		local path = circular.components[1].ordered
		local mesh = E.Mesh.new()
		local center = mesh:addVertex(Vector3.new(0, 0, 0.125))
		local ids = {}
		for i, sample in path.samples do
			ids[i] = mesh:addVertex(sample.position)
		end
		for _, segment in path.segments do
			local a, b = path.samples[segment.first].position, path.samples[segment.last].position
			mesh:addFace({ center, ids[segment.first], ids[segment.last] }, {
				{ uv = Vector2.new(0.5, 0.5) },
				{ uv = Vector2.new(a.X + 0.5, a.Y + 0.5) },
				{
					uv = Vector2.new(b.X + 0.5, b.Y + 0.5),
				},
			})
		end
		mesh:recalculateNormals()
		assert(mesh:validate().valid)
		local native = E.Roblox.toEditable(mesh).editable
		local ok, err = pcall(function()
			local copy = E.Roblox.fromEditable(native)
			assert(copy:validate().valid)
			local boundary = 0
			for _, edge in copy:topology().edges do
				if #edge.faces == 1 then
					boundary += 1
				end
			end
			assert(boundary == #path.segments)
			for _, face in copy.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal)
				end
			end
		end)
		native:Destroy()
		assert(ok, err)
	end)
	test("Native precision failure does not invalidate an established parameter topology", function()
		local a, b = plane(0), vertical()
		for _, s in { a, b } do
			for i, row in s.control do
				for j, p in row do
					s.control[i][j] = Vector3.new(1e8 + p.X * 16, p.Y, p.Z)
				end
			end
		end
		local r = Q.intersectSurfaces(a, b, {
			orderComponents = true,
			tolerance = 0.001,
			parameterBox = { { 0.2, 0.8 }, { 0, 1 }, { 0, 1 }, {
				0,
				1,
			} },
		})
		assert(r.parameterTopologyCertified and not r.orderedComplete)
		local path = r.components[1].ordered
		assert(path.topologyCertified and not path.complete and path.reason == "precision")
		assert(path.samples[1].errorBound > 1 and not path.samples[1].accurate)
	end)
	return report
end
