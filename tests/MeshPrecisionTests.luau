return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function polygon(points)
		local m = E.Mesh.new()
		local ids, corners = {}, {}
		for i, p in points do
			ids[i] = m:addVertex(p)
			corners[i] = { uv = Vector2.new(i, 0) }
		end
		local id = m:addFace(ids, corners, 2)
		return m, id
	end
	test("Scalar normal accumulation retains large and tiny representable triangles", function()
		for _, scale in { 2 ^ -100, 2 ^ 100 } do
			local m, id = polygon({ Vector3.zero, Vector3.new(scale, 0, 0), Vector3.new(0, scale, 0) })
			local normal, area = m:faceNormal(id)
			assert((normal - Vector3.zAxis).Magnitude < 1e-6)
			assert(math.abs(area / (scale * scale * 0.5) - 1) < 1e-12)
			assert(#m:faceTriangles(id) == 1)
		end
	end)
	test("Cancelled face normals fall back to exact projected area signs", function()
		local big = 2 ^ 100
		local m, id =
			polygon({ Vector3.new(-0.5, 0.5, 0), Vector3.new(big, big, 0), Vector3.new(-big, -big, 0) })
		local normal, area = m:faceNormal(id)
		assert((normal + Vector3.zAxis).Magnitude < 1e-6 and area == big)
	end)
	test("Small translated concave faces retain winding and corner correspondence", function()
		local origin = Vector3.new(131072, 65536, 262144)
		local points = {
			Vector3.new(0, 0, 0),
			Vector3.new(0.25, 0, 0),
			Vector3.new(0.25, 0.0625, 0),
			Vector3.new(0.0625, 0.0625, 0),
			Vector3.new(0.0625, 0.25, 0),
			Vector3.new(0, 0.25, 0),
		}
		for i, p in points do
			points[i] = p + origin
		end
		local m, id = polygon(points)
		local triangles = m:faceTriangles(id, { validateSimple = true })
		assert(#triangles == 4)
		local area = 0
		for _, corners in triangles do
			local t, tid = polygon({ points[corners[1]], points[corners[2]], points[corners[3]] })
			local n, a = t:faceNormal(tid)
			assert(n.Z > 0.99)
			area += a
			for _, corner in corners do
				assert(m.faces[id].corners[corner].uv.X == corner)
			end
		end
		local _, original = m:faceNormal(id)
		assert(area == original and area == 0.02734375)
	end)
	test("Closed mesh volume is invariant under large representable world translations", function()
		local box = E.Primitives.box(Vector3.new(2, 4, 8))
		assert(math.abs(box:volume() - 64) < 1e-12)
		for _, offset in { Vector3.new(1000000, -2000000, 3000000), Vector3.new(-65536, 131072, 262144) } do
			local moved = E.Deform.transform(box, CFrame.new(offset))
			assert(math.abs(moved:volume() - 64) < 1e-10)
			assert(moved:validate().closed)
			assert(math.abs(E.Topology.reverse(moved):volume() + 64) < 1e-10)
		end
	end)
	test("Robust ear clipping preserves collinear boundary vertices without zero-area triangles", function()
		local points = {
			Vector3.new(0, 0, 0),
			Vector3.new(1, 0, 0),
			Vector3.new(2, 0, 0),
			Vector3.new(2, 1, 0),
			Vector3.new(2, 2, 0),
			Vector3.new(1, 2, 0),
			Vector3.new(0, 2, 0),
			Vector3.new(0, 1, 0),
		}
		local m, id = polygon(points)
		local triangles = m:faceTriangles(id)
		assert(#triangles == 6)
		for _, triangle in triangles do
			local a, b, c = points[triangle[1]], points[triangle[2]], points[triangle[3]]
			assert(
				E.Predicates.orient2D(Vector2.new(a.X, a.Y), Vector2.new(b.X, b.Y), Vector2.new(c.X, c.Y))
					== 1
			)
		end
	end)
	test("Face triangulation validates optional simplicity and enforces work budgets", function()
		local m, id = polygon({
			Vector3.new(0, 0, 0),
			Vector3.new(3, 2, 0),
			Vector3.new(0, 2, 0),
			Vector3.new(2, 0, 0),
		})
		assert(not pcall(function()
			m:faceTriangles(id, { validateSimple = true })
		end))
		local regular, rid = polygon({ Vector3.zero, Vector3.xAxis, Vector3.one, Vector3.yAxis })
		assert(not pcall(function()
			regular:faceTriangles(rid, { maxVertices = 3 })
		end))
		assert(not pcall(function()
			regular:faceTriangles(rid, { maxWork = 1 })
		end))
	end)
	report.success = report.failed == 0
	return report
end
