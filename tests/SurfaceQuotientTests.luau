return function(E)
	local N, Q = E.NURBS, E.SplineQuery
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local ring = { Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) }
	local function plane(z)
		return N.surface({
			{ Vector3.new(-2, -2, z), Vector3.new(-2, 2, z) },
			{ Vector3.new(2, -2, z), Vector3.new(2, 2, z) },
		}, 1, 1)
	end
	local function cylinder(degree, options, repeatCount)
		local p = {}
		for i = 1, 4 * (repeatCount or 1) do
			local v = ring[(i - 1) % 4 + 1]
			p[i] = { v - Vector3.zAxis, v + Vector3.zAxis }
		end
		options = options or {}
		options.cyclicU, options.cyclicV = true, false
		return E.Cyclic.surface(p, degree or 1, 1, options)
	end
	local function winding(path)
		local value = 0
		for _, s in path.segments do
			local a, b = path.samples[s.first].position, path.samples[s.last].position
			value += math.atan2(a.X * b.Y - a.Y * b.X, a.X * b.X + a.Y * b.Y)
		end
		return value
	end
	local function check(r, count)
		assert(r.quotientTopologyCertified and r.quotientComplete, r.periodicQuotient.reason)
		assert(r.periodicQuotient.componentCount == count)
		for _, path in r.periodicQuotient.paths do
			assert(path.topologyCertified and path.complete)
			for i, s in path.segments do
				assert(s.certified and s.accurate)
				if i > 1 then
					assert(path.segments[i - 1].last == s.first)
				end
			end
			if path.closed then
				assert(path.segments[#path.segments].last == path.segments[1].first)
				assert(#path.samples == #path.segments)
			else
				assert(#path.samples == #path.segments + 1 and #path.endpoints == 2)
			end
		end
	end
	local square
	test("An exact periodic C0 seam closes one parameter interval with shared sample identity", function()
		square = Q.intersectSurfaces(cylinder(), plane(0), { tolerance = 0.003, requireQuotient = true })
		check(square, 1)
		assert(not square.components[1].ordered.closed and square.periodicQuotient.paths[1].closed)
		assert(square.periodicQuotient.axes[1].reason == "repeatedEndpointControls")
		assert(math.abs(math.abs(winding(square.periodicQuotient.paths[1])) - 2 * math.pi) < 1e-10)
	end)
	test("Seam witnesses preserve both original parameter representatives", function()
		assert(square)
		for _, join in square.periodicQuotient.joins do
			local path = square.components[join.toComponent].ordered
			local chart = path.charts[join.targetChart]
			assert(join.certified and math.abs(join.shift) == 1)
			for axis = 1, 4 do
				assert(
					join.parameterBox[axis][1] >= chart.isolatingBox[axis][1]
						and join.parameterBox[axis][2] <= chart.isolatingBox[axis][2]
				)
			end
		end
		local doubled = 0
		for _, sample in square.periodicQuotient.paths[1].samples do
			if #sample.sources == 2 then
				doubled += 1
				local a, b = sample.sources[1], sample.sources[2]
				local pa = square.components[a.componentIndex].ordered.samples[a.sampleIndex]
				local pb = square.components[b.componentIndex].ordered.samples[b.sampleIndex]
				assert(math.abs(pa.parameters[1] - pb.parameters[1]) == 1)
			end
		end
		assert(doubled == 1)
	end)
	test("Uniform and dyadic nonuniform quadratic seams have exact raw-knot identities", function()
		for _, intervals in { { 1, 1, 1, 1 }, { 1, 2, 1, 2 } } do
			local r = Q.intersectSurfaces(
				cylinder(2, { intervalsU = intervals }),
				plane(0),
				{ tolerance = 0.005, requireQuotient = true }
			)
			check(r, 1)
			assert(r.periodicQuotient.axes[1].reason == "exactKnotTranslation")
			assert(math.abs(math.abs(winding(r.periodicQuotient.paths[1])) - 2 * math.pi) < 1e-10)
		end
	end)
	test("Rounded higher-degree knots do not silently inherit an exact periodic certificate", function()
		local r = Q.intersectSurfaces(
			cylinder(2, { intervalsU = { 0.1, 0.2, 0.3, 0.4 } }),
			plane(0),
			{ tolerance = 0.01, identifyPeriodicSeams = true }
		)
		assert(r.orderedComplete and not r.quotientTopologyCertified)
		assert(
			r.periodicQuotient.reason == "seamGeometry"
				and r.periodicQuotient.axes[1].reason == "storedKnotsNotExactTranslates"
		)
	end)
	test("Degree-one nonuniform intervals close independently of rounded spacing", function()
		local r = Q.intersectSurfaces(
			cylinder(1, { intervalsU = { 0.1, 0.2, 0.3, 0.4 } }),
			plane(0),
			{ tolerance = 0.005, requireQuotient = true }
		)
		check(r, 1)
	end)
	test("A partial periodic parameter range retains its physical boundary endpoints", function()
		local r = Q.intersectSurfaces(cylinder(), plane(0), {
			requireQuotient = true,
			tolerance = 0.005,
			parameterBox = { { 0, 0.75 }, { 0, 1 }, { 0, 1 }, {
				0,
				1,
			} },
		})
		check(r, 1)
		assert(not r.periodicQuotient.axes[1].enabled and #r.periodicQuotient.joins == 0)
		assert(not r.periodicQuotient.paths[1].closed)
	end)
	test("Coincident world-space loops with different surface parameters remain separate", function()
		local p = {}
		for i, v in ring do
			p[i] = {
				v + Vector3.new(0, 0, 0.1875),
				v + Vector3.new(0, 0, -0.3125),
				v + Vector3.new(0, 0, 0.1875),
			}
		end
		local a = E.Cyclic.surface(p, 1, 2, { cyclicU = true, cyclicV = false })
		local r = Q.intersectSurfaces(a, plane(0), { tolerance = 0.005, requireQuotient = true })
		check(r, 2)
		assert(#r.periodicQuotient.joins == 2)
		for _, path in r.periodicQuotient.paths do
			assert(path.closed and math.abs(math.abs(winding(path)) - 2 * math.pi) < 1e-10)
		end
	end)
	test("Two spatial windings remain one full parameter traversal", function()
		local r =
			Q.intersectSurfaces(cylinder(1, nil, 2), plane(0), { tolerance = 0.005, requireQuotient = true })
		check(r, 1)
		assert(math.abs(math.abs(winding(r.periodicQuotient.paths[1])) - 4 * math.pi) < 1e-10)
	end)
	test("Original disconnected arcs join into an open quotient across the periodic seam", function()
		local a = cylinder()
		a.control[3][1] += Vector3.new(0, 0, 2)
		a.control[3][2] += Vector3.new(0, 0, 2)
		local r = Q.intersectSurfaces(a, plane(0), { tolerance = 0.005, requireQuotient = true })
		check(r, 1)
		assert(r.componentCount == 2 and #r.periodicQuotient.paths[1].sections == 2)
		assert(not r.periodicQuotient.paths[1].closed)
	end)
	test(
		"Swapping operands and transposing the cyclic direction changes only parameter provenance",
		function()
			for _, transpose in { false, true } do
				local a = cylinder()
				if transpose then
					a = E.SurfaceEdit.transpose(a)
				end
				local r = Q.intersectSurfaces(plane(0), a, { tolerance = 0.005, requireQuotient = true })
				check(r, 1)
				assert(r.periodicQuotient.axes[1].axis == (transpose and 4 or 3))
			end
		end
	)
	test("Seam resource limits retain original certified coverage and explicit failure", function()
		for _, option in { "maxSeamNodes", "maxSeamPairs" } do
			local options = { identifyPeriodicSeams = true, tolerance = 0.005, [option] = 0 }
			local r = Q.intersectSurfaces(cylinder(), plane(0), options)
			assert(r.orderedComplete and not r.quotientComplete)
			assert(r.periodicQuotient.reason == (option == "maxSeamNodes" and "nodes" or "pairs"))
			options.requireQuotient = true
			assert(not pcall(Q.intersectSurfaces, cylinder(), plane(0), options))
		end
	end)
	test("Topology survives an exhausted ordered approximation budget", function()
		local r = Q.intersectSurfaces(
			cylinder(),
			plane(0),
			{ identifyPeriodicSeams = true, maxOrderedSegments = 0 }
		)
		assert(r.quotientTopologyCertified and not r.quotientComplete)
		assert(
			r.periodicQuotient.paths[1].reason == "sourceApproximation"
				and #r.periodicQuotient.paths[1].sections > 0
		)
	end)
	test("Empty intersections and nonperiodic inputs have an identity quotient", function()
		local r = Q.intersectSurfaces(cylinder(), plane(5), { requireQuotient = true })
		check(r, 0)
		local b = N.surface({
			{ Vector3.new(-1, 0, -1), Vector3.new(-1, 0, 1) },
			{ Vector3.new(1, 0, -1), Vector3.new(1, 0, 1) },
		}, 1, 1)
		local q =
			Q.intersectSurfaces(plane(0), b, { requireQuotient = true, maxSeamNodes = 0, maxSeamPairs = 0 })
		check(q, 1)
		assert(#q.periodicQuotient.axes == 0 and not q.periodicQuotient.paths[1].closed)
	end)
	test("Opt-in flags, depth limits and unresolved parameter coverage are explicit", function()
		local r = Q.intersectSurfaces(cylinder(), plane(0), { requireOrdered = true, tolerance = 0.005 })
		assert(not r.periodicQuotient.requested and not r.quotientComplete)
		for _, options in
			{
				{ identifyPeriodicSeams = 1 },
				{ requireQuotient = "yes" },
				{ maxSeamNodes = -1 },
				{ maxSeamPairs = 0.5 },
				{ maxSeamDepth = 129 },
			}
		do
			assert(not pcall(Q.intersectSurfaces, cylinder(), plane(0), options))
		end
		local q = Q.intersectSurfaces(plane(0), plane(0), { identifyPeriodicSeams = true, maxNodes = 1 })
		assert(not q.quotientTopologyCertified and q.periodicQuotient.reason == "parameterTopology")
	end)
	test("Doubly periodic surfaces preserve two separate quotient loops", function()
		local p = {}
		local radial, heights = { -1, 1, 1, -1 }, { -1, -1, 1, 1 }
		for i, v in ring do
			p[i] = {}
			for j = 1, 4 do
				p[i][j] = v * (3 + radial[j]) + Vector3.new(0, 0, heights[j])
			end
		end
		local a = E.Cyclic.surface(p, 1, 1)
		local b = plane(0)
		for i, row in b.control do
			for j, v in row do
				b.control[i][j] = v * 3
			end
		end
		local started = os.clock()
		local r = Q.intersectSurfaces(a, b, { requireQuotient = true, tolerance = 0.01 })
		check(r, 2)
		assert(#r.periodicQuotient.axes == 2 and #r.periodicQuotient.joins == 2)
		for _, path in r.periodicQuotient.paths do
			assert(path.closed and math.abs(math.abs(winding(path)) - 2 * math.pi) < 1e-10)
		end
		report.benchmark = {
			seconds = os.clock() - started,
			work = r.work,
			curves = #r.curves,
			parameterComponents = r.componentCount,
			quotientComponents = r.periodicQuotient.componentCount,
			seamNodes = r.periodicQuotient.nodes,
			seamPairs = r.periodicQuotient.pairs,
		}
	end)
	test("A seam-contained contact retains its unresolved root cover", function()
		local b = N.surface({
			{ Vector3.new(-2, 0, -2), Vector3.new(-2, 0, 2) },
			{ Vector3.new(2, 0, -2), Vector3.new(2, 0, 2) },
		}, 1, 1)
		local r = Q.intersectSurfaces(cylinder(), b, {
			identifyPeriodicSeams = true,
			maxSeamDepth = 0,
			maxNodes = 128,
		})
		assert(not r.rootCoverageComplete and not r.quotientTopologyCertified and #r.unresolved > 0)
		assert(r.periodicQuotient.reason == "parameterTopology")
	end)
	test("Positive rational repeated-knot seams close a circle with independent chord checks", function()
		local points = {
			Vector3.new(1, 0, 0),
			Vector3.new(1, 1, 0),
			Vector3.new(0, 1, 0),
			Vector3.new(-1, 1, 0),
			Vector3.new(-1, 0, 0),
			Vector3.new(-1, -1, 0),
			Vector3.new(0, -1, 0),
			Vector3.new(1, -1, 0),
		}
		local p, w = {}, {}
		for i, v in points do
			p[i] = { v - Vector3.zAxis, v + Vector3.zAxis }
			local weight = i % 2 == 1 and 1 or math.sqrt(0.5)
			w[i] = { weight, weight }
		end
		local circleSurface = E.Cyclic.surface(
			p,
			2,
			1,
			{ cyclicU = true, cyclicV = false, weights = w, intervalsU = { 1, 0, 1, 0, 1, 0, 1, 0 } }
		)
		local r = Q.intersectSurfaces(circleSurface, plane(0), { requireQuotient = true, tolerance = 0.005 })
		check(r, 1)
		local path = r.periodicQuotient.paths[1]
		assert(path.closed and math.abs(math.abs(winding(path)) - 2 * math.pi) < 1e-10)
		for _, s in path.segments do
			local a, b = path.samples[s.first].position, path.samples[s.last].position
			for i = 0, 8 do
				local t = i / 8
				local x, y = a.X * (1 - t) + b.X * t, a.Y * (1 - t) + b.Y * t
				assert(math.abs(math.sqrt(x * x + y * y) - 1) <= s.errorBound + 1e-12)
			end
		end
	end)
	test("Transforms, scale and independent weight gauges preserve seam identity", function()
		local frame = CFrame.new(7, -3, 2) * CFrame.Angles(0.2, -0.4, 0.3)
		for _, scale in { 0.01, 100 } do
			local a, b = cylinder(), plane(0)
			for operand, s in { a, b } do
				for i, row in s.control do
					for j, p in row do
						s.control[i][j] = frame:PointToWorldSpace(p * scale)
						s.weights[i][j] = operand == 1 and 1e100 or 1e-100
					end
				end
			end
			local r = Q.intersectSurfaces(a, b, { requireQuotient = true, tolerance = 0.003 })
			check(r, 1)
			assert(r.periodicQuotient.paths[1].closed)
		end
	end)
	test("Seam callbacks can cancel every stage without mutating inputs", function()
		for _, stage in { "seamGeometry", "seamContacts", "seamPairs", "seamSample" } do
			local a, b = cylinder(), plane(0)
			local first = a.control[1][1]
			local seen = false
			assert(not pcall(Q.intersectSurfaces, a, b, {
				identifyPeriodicSeams = true,
				tolerance = 0.005,
				checkpoint = function(info)
					if info.stage == stage then
						seen = true
						error("cancel quotient")
					end
				end,
			}))
			assert(seen and a.control[1][1] == first)
		end
	end)
	test("Source and option snapshots precede seam callbacks", function()
		local a, b = cylinder(), plane(0)
		local options = { requireQuotient = true, tolerance = 0.005 }
		options.checkpoint = function(info)
			if info.stage == "seamGeometry" then
				a.cyclicU = false
				a.control[1][1] = Vector3.new(99, 99, 99)
				options.maxSeamNodes = 0
			end
		end
		local r = Q.intersectSurfaces(a, b, options)
		check(r, 1)
		assert(r.periodicQuotient.paths[1].closed)
	end)
	test("The shared hard work budget includes quotient construction", function()
		local entered
		Q.intersectSurfaces(cylinder(), plane(0), {
			requireQuotient = true,
			tolerance = 0.005,
			checkpoint = function(info)
				if info.stage == "seamGeometry" then
					entered = info.work
				end
			end,
		})
		assert(
			entered
				and not pcall(
					Q.intersectSurfaces,
					cylinder(),
					plane(0),
					{ requireQuotient = true, tolerance = 0.005, maxWork = entered }
				)
		)
	end)
	test("A quotient loop forms a native mesh boundary with retained UVs and normals", function()
		assert(square)
		local path = square.periodicQuotient.paths[1]
		local mesh = E.Mesh.new()
		local center = mesh:addVertex(Vector3.zero)
		local ids = {}
		for i, s in path.samples do
			ids[i] = mesh:addVertex(s.position)
		end
		for _, s in path.segments do
			local a, b = path.samples[s.first].position, path.samples[s.last].position
			mesh:addFace({ center, ids[s.first], ids[s.last] }, {
				{ uv = Vector2.new(0.5, 0.5) },
				{ uv = Vector2.new((a.X + 1) / 2, (a.Y + 1) / 2) },
				{ uv = Vector2.new((b.X + 1) / 2, (b.Y + 1) / 2) },
			})
		end
		mesh:recalculateNormals()
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
	return report
end
