return function(E)
	local D, P = E.Planar, E.Predicates
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function box(x0, y0, x1, y1)
		return { Vector2.new(x0, y0), Vector2.new(x1, y0), Vector2.new(x1, y1), Vector2.new(x0, y1) }
	end
	local function inside(domain, outer, holes)
		for _, triangle in domain.triangles do
			local p = Vector2.zero
			for _, id in triangle do
				p += domain.points[id] / 3
			end
			assert(P.pointInPolygon2D(p, outer) == "inside")
			for _, hole in holes or {} do
				assert(P.pointInPolygon2D(p, hole) == "outside")
			end
		end
	end
	test("Exact polygon orientation and winding distinguish interior exterior and boundary", function()
		local outer = box(0, 0, 3, 2)
		local orientation, area = P.polygonOrientation(outer)
		assert(orientation == 1 and area == 6)
		assert(P.pointInPolygon2D(Vector2.one, outer) == "inside")
		assert(P.pointInPolygon2D(Vector2.new(3, 1), outer) == "boundary")
		assert(P.pointInPolygon2D(Vector2.new(4, 1), outer) == "outside")
	end)
	test("Concave polygon triangulation retains area boundary winding and source arrays", function()
		local outer = {
			Vector2.zero,
			Vector2.new(4, 0),
			Vector2.new(4, 1),
			Vector2.new(1, 1),
			Vector2.new(1, 4),
			Vector2.new(0, 4),
		}
		local d = D.triangulate(outer)
		assert(#d.triangles == 4 and math.abs(d.area - 7) < 1e-12 and #outer == 6)
		inside(d, outer)
		local mesh = D.toMesh(d)
		assert(mesh:validate().valid and mesh:validate().boundaryEdges == 6)
	end)
	test("Square hole triangulation excludes the hole and preserves every boundary edge", function()
		local outer, hole = box(0, 0, 5, 5), box(1, 1, 4, 4)
		local d = D.triangulate(outer, { hole })
		assert(#d.triangles == 8 and d.area == 16 and d.holes == 1)
		inside(d, outer, { hole })
		local mesh = D.toMesh(d)
		assert(mesh:validate().valid and mesh:validate().boundaryEdges == 8)
	end)
	test("Several disjoint holes and a concave exterior produce one valid domain", function()
		local outer = {
			Vector2.new(0, 0),
			Vector2.new(10, 0),
			Vector2.new(10, 8),
			Vector2.new(6, 8),
			Vector2.new(6, 5),
			Vector2.new(4, 5),
			Vector2.new(4, 8),
			Vector2.new(0, 8),
		}
		local holes = { box(1, 1, 3, 3), box(7, 1, 9, 3), box(1, 5, 3, 7), box(7, 5, 9, 7) }
		local d = D.triangulate(outer, holes)
		assert(d.holes == 4 and #d.triangles == 30 and d.area == 58)
		inside(d, outer, holes)
		assert(D.toMesh(d):validate().valid)
	end)
	test("Triangulation retains collinear boundary vertices and accepts either input winding", function()
		local outer = {
			Vector2.new(0, 0),
			Vector2.new(0, 1),
			Vector2.new(0, 2),
			Vector2.new(1, 2),
			Vector2.new(2, 2),
			Vector2.new(2, 1),
			Vector2.new(2, 0),
			Vector2.new(1, 0),
			Vector2.new(0, 0),
		}
		local d = D.triangulate(outer)
		assert(#d.points == 8 and #d.triangles == 6 and d.area == 4)
		assert(D.toMesh(d):validate().boundaryEdges == 8 and #outer == 9)
	end)
	test("Intersection diagnostics identify crossing loops and adjacent overlap", function()
		local bow = { Vector2.zero, Vector2.one, Vector2.yAxis, Vector2.xAxis }
		local hits = D.intersections({ bow })
		assert(#hits == 1 and hits[1].intersection.proper)
		local limited, diagnostic = D.intersections({ bow }, { maxIntersections = 1 })
		assert(#limited == 1 and not diagnostic.complete and diagnostic.reason)
		local folded = { Vector2.zero, Vector2.xAxis * 2, Vector2.xAxis, Vector2.yAxis }
		assert(#D.intersections({ folded }) > 0)
		assert(not pcall(function()
			D.triangulate(bow)
		end))
		assert(not pcall(function()
			D.triangulate(box(0, 0, 3, 3), { box(2, 2, 4, 4) })
		end))
	end)
	test("Nested outside and touching holes reject explicitly", function()
		local outer = box(0, 0, 10, 10)
		assert(not pcall(function()
			D.triangulate(outer, { box(2, 2, 8, 8), box(3, 3, 4, 4) })
		end))
		assert(not pcall(function()
			D.triangulate(outer, { box(20, 20, 21, 21) })
		end))
		assert(not pcall(function()
			D.triangulate(outer, { box(0, 1, 2, 3) })
		end))
	end)
	test("Thin representable domains retain topology without epsilon welding", function()
		local tiny = 2 ^ -80
		local outer = box(0, 0, 1, tiny)
		local d = D.triangulate(outer)
		assert(#d.triangles == 2 and d.area == tiny)
		local shifted = {}
		for i, p in outer do
			shifted[i] = Vector2.new(p.X * 2 ^ 80, p.Y)
		end
		local e = D.triangulate(shifted)
		assert(e.area == 1 and #e.triangles == 2)
	end)
	test("Planar work budgets and cancellation preserve caller input", function()
		local outer = {}
		for i = 0, 39 do
			local a = i * 2 * math.pi / 40
			outer[i + 1] = Vector2.new(math.cos(a), math.sin(a))
		end
		assert(not pcall(function()
			D.triangulate(outer, nil, { maxWork = 5 })
		end))
		assert(not pcall(function()
			D.triangulate(outer, nil, { maxVertices = 5 })
		end))
		assert(not pcall(function()
			D.triangulate(outer, nil, {
				checkpoint = function()
					error("cancel")
				end,
			})
		end))
		assert(#outer == 40)
	end)
	test(
		"Concave hole bridges remain valid across deterministic radial domains and input rotations",
		function()
			for seed = 1, 24 do
				local outer, holes = {}, {}
				for i = 0, 19 do
					local a = (i + seed % 7) * 2 * math.pi / 20
					local r = i % 2 == 0 and 5 or 3.8
					outer[i + 1] = Vector2.new(math.cos(a) * r, math.sin(a) * r)
				end
				for h = 1, 2 do
					holes[h] = {}
					for i = 0, 11 do
						local a = (i + seed * 0.17) * 2 * math.pi / 12
						local r = i % 2 == 0 and 0.7 or 0.32
						holes[h][i + 1] =
							Vector2.new((h == 1 and -1.4 or 1.4) + math.cos(a) * r, math.sin(a) * r)
					end
				end
				local d = D.triangulate(outer, holes)
				assert(#d.triangles == 46 and D.toMesh(d):validate().valid)
				inside(d, outer, holes)
				local _, expected = P.polygonOrientation(outer)
				for _, hole in holes do
					local _, area = P.polygonOrientation(hole)
					expected -= math.abs(area)
				end
				assert(math.abs(d.area - expected) < 1e-8)
			end
		end
	)
	report.success = report.failed == 0
	return report
end
