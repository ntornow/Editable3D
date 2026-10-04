return function(E)
	local I, report = E.Intersections, { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local v = Vector3.new
	local base = { v(-1, -1, 0), v(1, -1, 0), v(0, 1, 0) }
	local function near(a, b, e)
		assert(math.abs(a - b) <= (e or 1e-8), a .. " ~= " .. b)
	end
	local function checkData(hit)
		for _, point in hit.pointData or {} do
			for _, field in { "barycentricA", "barycentricB" } do
				if point[field] then
					local sum = 0
					for _, w in point[field] do
						assert(w >= -1e-12 and w <= 1 + 1e-12)
						sum += w
					end
					near(sum, 1, 1e-10)
				end
			end
		end
	end
	for _, coplanar in { false, true } do
		test(
			(coplanar and "Coplanar" or "Spatial")
				.. " triangle intersections match independent exact Fraction fixtures",
			function()
				local count = 0
				for index, fixture in require(script.Parent.IntersectionFixtures) do
					if fixture.coplanar == coplanar then
						count += 1
						for _, pair in
							{
								{ fixture.a, fixture.b },
								{
									{ fixture.b[3], fixture.b[2], fixture.b[1] },
									{ fixture.a[2], fixture.a[3], fixture.a[1] },
								},
							}
						do
							local hit = I.triangles(pair[1], pair[2])
							assert(
								hit.dimension == fixture.dimension,
								"Dimension mismatch at exact fixture " .. index
							)
							assert(
								hit.coplanar == fixture.coplanar,
								"Plane mismatch at exact fixture " .. index
							)
							if fixture.dimension >= 0 then
								assert(
									hit.classification == fixture.classification,
									"Classification mismatch at exact fixture " .. index
								)
								checkData(hit)
							end
						end
					end
				end
				assert(count >= 70)
			end
		)
	end
	test("Segment triangle queries distinguish interior crossings edge contacts and misses", function()
		local hit = I.segmentTriangle(v(0, 0, -1), v(0, 0, 1), base)
		assert(hit.kind == "point" and hit.classification == "crossing" and hit.points[1] == Vector3.zero)
		near(hit.pointData[1].barycentricA[1], 0.25)
		near(hit.pointData[1].barycentricA[3], 0.5)
		assert(I.segmentTriangle(v(0, -1, -1), v(0, -1, 1), base).classification == "contact")
		assert(I.segmentTriangle(v(0, 3, -1), v(0, 3, 1), base).kind == "none")
		assert(I.segmentTriangle(v(0, 0, 1), v(0, 0, 2), base).kind == "none")
		assert(I.segmentTriangle(Vector3.zero, Vector3.zero, base).kind == "point")
	end)
	test("Coplanar finite segments clip to exact triangle boundaries", function()
		local r = I.segmentTriangle(v(-2, 0, 0), v(2, 0, 0), base)
		assert(r.kind == "segment" and r.coplanar and r.constructionComplete)
		assert(r.points[1] == v(-0.5, 0, 0) and r.points[2] == v(0.5, 0, 0))
		checkData(r)
		assert(I.segmentTriangle(v(-2, 1, 0), v(2, 1, 0), base).kind == "point")
		assert(I.segmentTriangle(v(-2, 2, 0), v(2, 2, 0), base).kind == "none")
	end)
	test("Homogeneous crossing construction retains offsets lost by rounded segment parameters", function()
		local big = 2 ^ 100
		local tri = { v(1, -1, -1), v(1, 1, -1), v(1, 0, 1) }
		local r = I.segmentTriangle(v(-big, 0, 0), v(big, 0, 0), tri)
		assert(r.kind == "point" and r.points[1] == v(1, 0, 0))
		assert(r.coordinates[1][1] == 1 and r.constructionComplete)
	end)
	test("Crossing dimension survives native endpoint collapse without silent point contact", function()
		local tri = { v(0, 0, -2 ^ -100), v(0, 0, 2 ^ -100), v(0, 1, 2 ^ 100) }
		local r = I.triangles(base, tri)
		assert(r.kind == "segment" and r.classification == "crossing" and not r.constructionComplete)
		assert(r.points[1] == r.points[2] and r.coordinates[2][2] > 0 and r.maxRoundingError > 0)
		near(r.coordinates[2][2] / 2 ^ -200, 1)
	end)
	test("Coplanar overlaps return ordered convex boundaries for reversed and contained triangles", function()
		local a = { v(0, 2, 0), v(-2, -1, 0), v(2, -1, 0) }
		local b = { v(0, -2, 0), v(2, 1, 0), v(-2, 1, 0) }
		local r = I.triangles(a, b)
		assert(r.kind == "polygon" and #r.points == 6 and r.classification == "overlap")
		local loop = {}
		for i, p in r.points do
			loop[i] = Vector2.new(p.X, p.Y)
		end
		assert(E.Predicates.polygonOrientation(loop) > 0 and r.constructionComplete)
		assert(#E.Planar.intersections({ loop }) == 0)
		local copy = I.triangles(base, { base[3], base[2], base[1] })
		assert(copy.dimension == 2 and #copy.points == 3)
		checkData(r)
	end)
	test("Exact signs keep near-parallel disjoint triangles separate without an epsilon", function()
		local b = {}
		for i, p in base do
			b[i] = v(p.X, p.Y, 2 ^ -100)
		end
		assert(I.triangles(base, b).kind == "none")
		local coplanar = { v(1, -1, 0), v(3, -1, 0), v(2, 1, 0) }
		assert(I.triangles(base, coplanar).kind == "point")
	end)
	test("Mesh intersection scans ignore only ordinary shared-edge and shared-vertex contacts", function()
		for _, source in { E.Primitives.box(), E.Primitives.grid(3, 3) } do
			local hits, r = I.mesh(source)
			assert(#hits == 0 and r.complete and r.intersectionFree and r.ordinaryAdjacencies > 0)
			local all = I.mesh(source, { includeAdjacent = true })
			assert(#all > 0)
			for _, hit in all do
				assert(hit.ordinaryAdjacency and hit.classification == "contact")
			end
		end
	end)
	test("Shared vertices do not hide an extended crossing and shared edges do not hide overlap", function()
		local m = E.Mesh.new()
		for _, p in { Vector3.zero, v(2, 0, 0), v(0, 2, 0), v(1, 1, -1), v(1, 1, 1) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 1, 4, 5 })
		local hits, r = I.mesh(m)
		assert(#hits == 1 and r.crossings == 1 and not r.intersectionFree and not hits[1].ordinaryAdjacency)
		m.faces[2].vertices = { 1, 2, 4 }
		m.vertices[4] = v(1, 1, 0)
		hits, r = I.mesh(m)
		assert(#hits == 1 and r.overlaps == 1 and hits[1].dimension == 2)
	end)
	test("Distinct vertex identities retain unwelded point and edge contact diagnostics", function()
		local a = E.Mesh.new()
		for _, p in base do
			a:addVertex(p)
		end
		a:addFace({ 1, 2, 3 })
		local b = E.Mesh.new()
		for _, p in { v(1, -1, 0), v(3, -1, 0), v(2, 1, 0) } do
			b:addVertex(p)
		end
		b:addFace({ 1, 2, 3 })
		local hits, r = I.between(a, b)
		assert(#hits == 1 and r.contacts == 1 and not r.surfaceCrossing and not r.selfQuery)
		hits, r = I.between(a, b, { includeContacts = false })
		assert(#hits == 0 and r.contacts == 1 and not r.intersectionFree)
		hits, r = I.between(a, a)
		assert(#hits == 1 and r.overlaps == 1 and not r.selfQuery)
	end)
	test("BVH traversal matches exhaustive pair classification despite reordered spatial leaves", function()
		local random, mesh, triangles = Random.new(2647), E.Mesh.new(), {}
		for i = 1, 24 do
			local points, ids = {}, {}
			for k = 1, 3 do
				points[k] = v(random:NextNumber(-2, 2), random:NextNumber(-2, 2), random:NextNumber(-2, 2))
				ids[k] = mesh:addVertex(points[k])
			end
			mesh:addFace(ids)
			triangles[i] = points
		end
		local expected = {}
		for i, a in triangles do
			for j = i + 1, #triangles do
				if I.triangles(a, triangles[j]).kind ~= "none" then
					expected[i .. ":" .. j] = true
				end
			end
		end
		local hits, r = I.mesh(mesh)
		assert(r.complete and #hits > 0)
		for _, hit in hits do
			local key = hit.faceA .. ":" .. hit.faceB
			assert(expected[key], "Unexpected or repeated BVH pair")
			expected[key] = nil
		end
		assert(next(expected) == nil, "BVH lost an intersection pair")
	end)
	test("Separate mesh scans detect solid crossings and reject separated boxes with broad bounds", function()
		local source = E.Primitives.box()
		local hits, r = I.between(source, E.Deform.transform(source, CFrame.new(0.7, 0.3, 0.2)))
		assert(#hits > 0 and r.crossings > 0 and r.surfaceCrossing and r.complete)
		for _, h in hits do
			assert(h.faceA and h.faceB and #h.cornersA == 3 and #h.verticesB == 3)
		end
		hits, r = I.between(source, E.Deform.transform(source, CFrame.new(5, 0, 0)))
		assert(#hits == 0 and r.intersectionFree and r.tests == 0)
	end)
	test("Intersection classifications retain rigid transforms scale and native translations", function()
		local b = { v(0, 0, -1), v(0, 0, 1), v(0, 2, 0) }
		for _, scale in { 0.001, 1, 1000 } do
			local frame = CFrame.new(8, -4, 2) * CFrame.Angles(0.3, 0.7, -0.2)
			local a, other = {}, {}
			for i = 1, 3 do
				a[i] = frame:PointToWorldSpace(base[i] * scale)
				other[i] = frame:PointToWorldSpace(b[i] * scale)
			end
			local r = I.triangles(a, other)
			assert(r.dimension == 1 and r.classification == "crossing")
			near((r.points[2] - r.points[1]).Magnitude / scale, 1, 0.001)
		end
	end)
	test("Mesh scan budgets report incompleteness and cancellation preserves source attributes", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		for _, options in
			{ { maxTests = 1 }, { maxWork = 40 }, { maxIntersections = 1, includeAdjacent = true } }
		do
			local _, r = I.mesh(source, options)
			assert(not r.complete and r.reason and not r.intersectionFree)
		end
		assert(not pcall(I.mesh, source, { maxTriangles = 1 }))
		assert(not pcall(I.mesh, source, {
			checkpoint = function()
				error("cancel intersections")
			end,
		}))
		assert(E.IO.encode(source) == before)
		local hits, r = I.mesh(E.Mesh.new())
		assert(#hits == 0 and r.complete and r.intersectionFree)
	end)
	test("Degenerate and nonfinite intersection inputs reject explicitly", function()
		assert(not pcall(I.triangles, base, { Vector3.zero, Vector3.xAxis, Vector3.xAxis * 2 }))
		assert(not pcall(I.segmentTriangle, Vector3.zero, v(math.huge, 0, 0), base))
		assert(not pcall(I.triangles, base, { base[1], base[2] }))
	end)
	test("Native mesh roundtrip retains an intersection-free closed modeled solid", function()
		local source = E.MeshEdit.bevelEdges(E.Primitives.box(), { ["1:2"] = true }, 0.1, { segments = 2 })
		local h = E.Roblox.toEditable(source)
		local ok, err = pcall(function()
			local mesh = E.Roblox.fromEditable(h.editable)
			local hits, r = I.mesh(mesh)
			assert(#hits == 0 and r.complete and r.intersectionFree and mesh:validate().closed)
		end)
		h.editable:Destroy()
		assert(ok, err)
	end)
	test(
		"Boolean intersection validation checks inputs and output while preserving analytic volumes",
		function()
			local a = E.Primitives.box()
			local b = E.Deform.transform(a, CFrame.new(0.5, 0, 0))
			for _, entry in { { "union", 10 }, { "intersect", 6 }, { "subtract", 2 } } do
				local mesh, r = E.Boolean.apply(a, b, entry[1], { checkIntersections = true })
				assert(r.inputIntersections.a.intersectionFree and r.inputIntersections.b.intersectionFree)
				assert(r.intersections.complete and r.intersections.intersectionFree)
				near(mesh:volume(), entry[2], 1e-5)
			end
			local _, empty = E.Boolean.intersect(a, E.Mesh.new(), { checkIntersections = true })
			assert(empty.empty and empty.intersections.intersectionFree)
		end
	)
	test("Strict Boolean diagnostics reject intersecting shells and incomplete validation", function()
		local a = E.Primitives.box()
		local crossing = E.Topology.join({ a, E.Deform.transform(a, CFrame.new(0.7, 0.3, 0.2)) })
		assert(crossing:validate().closed)
		assert(not pcall(E.Boolean.union, crossing, a, { checkIntersections = true }))
		assert(
			not pcall(
				E.Boolean.union,
				a,
				a,
				{ checkIntersections = true, intersectionOptions = { maxTests = 1 } }
			)
		)
	end)
	report.success = report.failed == 0
	return report
end
