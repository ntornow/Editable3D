return function(E)
	local D, P = E.Planar, E.Predicates
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local v = Vector2.new
	local function box(a, b, c, d)
		return { v(a, b), v(c, b), v(c, d), v(a, d) }
	end
	local outer = box(0, 0, 8, 8)
	local function verify(d, boundary, holes)
		assert(d.complete)
		local edges, area = {}, 0
		for _, tri in d.triangles do
			local a, b, c = d.points[tri[1]], d.points[tri[2]], d.points[tri[3]]
			local sign, det = P.orient2D(a, b, c)
			assert(sign > 0)
			area += det / 2
			local center = v((a.X + b.X + c.X) / 3, (a.Y + b.Y + c.Y) / 3)
			assert(P.pointInPolygon2D(center, boundary) == "inside")
			for _, hole in holes or {} do
				assert(P.pointInPolygon2D(center, hole) == "outside")
			end
			for i, x in tri do
				local y = tri[i % 3 + 1]
				edges[math.min(x, y) .. ":" .. math.max(x, y)] = true
			end
		end
		assert(math.abs(area - d.area) < 1e-8)
		for _, path in d.paths do
			for i = 1, #path - 1 do
				local a, b = path[i], path[i + 1]
				assert(edges[math.min(a, b) .. ":" .. math.max(a, b)], "Missing constrained path edge")
			end
		end
		assert(D.toMesh(d):validate().valid)
	end
	test("Constrained triangulation with no paths matches the polygon domain", function()
		local d = D.constrain(outer)
		assert(#d.triangles == 2 and #d.points == 4 and d.area == 64)
		verify(d, outer)
	end)
	test("Two free interior endpoints become a retained dangling edge", function()
		local d = D.constrain(outer, {}, { { v(2, 3), v(6, 5) } })
		assert(#d.points == 6 and #d.triangles == 6 and #d.paths[1] == 2)
		verify(d, outer)
	end)
	test("Crossing paths split once and share one intersection vertex", function()
		local d = D.constrain(outer, {}, { { v(0, 4), v(8, 4) }, { v(4, 0), v(4, 8) } })
		assert(#d.points == 9 and #d.triangles == 8)
		assert(#d.paths[1] == 3 and #d.paths[2] == 3 and d.paths[1][2] == d.paths[2][2])
		assert(d.points[d.paths[1][2]] == v(4, 4) and d.constructionError == 0)
		verify(d, outer)
	end)
	test("Closed interior constraint loops retain both sides of their edges", function()
		local path = box(2, 2, 6, 6)
		table.insert(path, path[1])
		local d = D.constrain(outer, {}, { path })
		assert(#d.points == 8 and #d.triangles == 10 and d.paths[1][1] == d.paths[1][5])
		verify(d, outer)
	end)
	test("Self-crossing paths and T junctions form one conforming arrangement", function()
		local d = D.constrain(outer, {}, {
			{ v(1, 1), v(7, 7), v(1, 7), v(7, 1) },
			{ v(4, 4), v(4, 7) },
		})
		assert(d.paths[1][2] == d.paths[1][6] and d.paths[1][2] == d.paths[2][1])
		verify(d, outer)
	end)
	test("Overlapping reversed and repeated segments merge with complete provenance", function()
		local d = D.constrain(outer, {}, {
			{ v(1, 4), v(7, 4) },
			{ v(6, 4), v(2, 4) },
			{ v(2, 4), v(6, 4), v(2, 4) },
		})
		assert(#d.paths[1] == 4 and #d.paths[2] == 2 and #d.paths[3] == 3)
		local a, b = d.paths[2][1], d.paths[2][2]
		local edge = d.constrainedEdges[math.min(a, b) .. ":" .. math.max(a, b)]
		assert(edge.paths[1] and edge.paths[2] and edge.paths[3] and #edge.sources == 4)
		verify(d, outer)
	end)
	test("Paths may follow a boundary and terminate on inserted boundary points", function()
		local d = D.constrain(outer, {}, { { v(2, 0), v(6, 0), v(4, 4) } })
		assert(#d.boundaryLoops[1] == 6 and #d.triangles == 6)
		verify(d, outer)
	end)
	test("Constraints connect hole and exterior boundaries without filling holes", function()
		local hole = box(3, 3, 5, 5)
		local d = D.constrain(outer, { hole }, {
			{ v(0, 4), v(3, 4) },
			{ v(5, 4), v(8, 4) },
			{ v(4, 0), v(4, 3) },
		})
		assert(d.area == 60 and d.holes == 1)
		verify(d, outer, { hole })
	end)
	test("Paths that leave a concavity or cross a hole reject transactionally", function()
		local concave = { v(0, 0), v(8, 0), v(8, 2), v(2, 2), v(2, 8), v(0, 8) }
		assert(not pcall(D.constrain, concave, {}, { { v(1, 7), v(7, 1) } }))
		assert(not pcall(D.constrain, outer, { box(3, 3, 5, 5) }, { { v(1, 4), v(7, 4) } }))
		assert(not pcall(D.constrain, outer, {}, { { v(-1, 2), v(4, 4) } }))
		assert(#outer == 4 and #concave == 6)
	end)
	test("Constraint recovery preserves long crossing grids and all shared vertices", function()
		local paths = {}
		for i = 1, 7 do
			table.insert(paths, { v(0, i), v(8, i) })
			table.insert(paths, { v(i, 0), v(i, 8) })
		end
		local d = D.constrain(outer, {}, paths)
		assert(#d.points == 81 and #d.triangles == 128)
		for _, path in d.paths do
			assert(#path == 9)
		end
		verify(d, outer)
	end)
	test("Deterministic interior networks recover constraints across input orderings", function()
		for seed = 1, 18 do
			local random, paths = Random.new(seed), {}
			for _ = 1, 6 do
				table.insert(paths, {
					v(random:NextNumber(0.5, 7.5), random:NextNumber(0.5, 7.5)),
					v(random:NextNumber(0.5, 7.5), random:NextNumber(0.5, 7.5)),
				})
			end
			local d = D.constrain(outer, {}, paths)
			verify(d, outer)
			local reversed = {}
			for i = #paths, 1, -1 do
				table.insert(reversed, { paths[i][2], paths[i][1] })
			end
			local other = D.constrain(outer, {}, reversed)
			assert(#other.triangles == #d.triangles and #other.points == #d.points)
			verify(other, outer)
		end
	end)
	test("Constrained topology retains representable thin and translated coordinates", function()
		for _, scale in { 2 ^ -50, 1, 2 ^ 40 } do
			local shape = { v(0, 0), v(8 * scale, 0), v(8 * scale, 8 / scale), v(0, 8 / scale) }
			local d = D.constrain(shape, {}, { { v(2 * scale, 3 / scale), v(6 * scale, 5 / scale) } })
			assert(d.area == 64 and #d.triangles == 6)
		end
		local shape = box(2 ^ 20, 2 ^ 20, 2 ^ 20 + 8, 2 ^ 20 + 8)
		local d = D.constrain(shape, {}, { { v(2 ^ 20 + 2, 2 ^ 20 + 3), v(2 ^ 20 + 6, 2 ^ 20 + 5) } })
		verify(d, shape)
	end)
	test("Construction error measures native intersection rounding and honors its bound", function()
		local paths = { { v(1, 1), v(7, 6) }, { v(2, 7), v(6, 1) } }
		local d = D.constrain(outer, {}, paths)
		assert(d.constructionError > 0 and d.constructionError < 1e-5)
		assert(not pcall(D.constrain, outer, {}, paths, { maxConstructionError = 0 }))
		verify(d, outer)
	end)
	test("Constrained triangulation budgets cancellation and invalid paths fail explicitly", function()
		local paths = { { v(1, 1), v(7, 6) }, { v(2, 7), v(6, 1) } }
		for _, options in
			{
				{ maxVertices = 4 },
				{ maxSegments = 4 },
				{ maxTriangles = 2 },
				{ maxWork = 5 },
				{
					checkpoint = function()
						error("cancel constraint")
					end,
				},
			}
		do
			assert(not pcall(D.constrain, outer, {}, paths, options))
		end
		assert(not pcall(D.constrain, outer, {}, { { v(1, 1), v(1, 1) } }))
		assert(#paths == 2 and #paths[1] == 2 and paths[1][1] == v(1, 1))
	end)
	report.success = report.failed == 0
	return report
end
