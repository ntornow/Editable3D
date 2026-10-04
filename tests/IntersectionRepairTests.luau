return function(E)
	local R, A = E.MeshRepair, E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function count(values)
		local n = 0
		for _ in values do
			n += 1
		end
		return n
	end
	local function box(offset, size)
		local m = E.Primitives.box(size)
		for id, p in m.vertices do
			m.vertices[id] = p + (offset or Vector3.zero)
		end
		return m
	end
	local function pair(offset)
		return E.Topology.join({ box(), box(offset or Vector3.new(0.5, 0.25, 0)) })
	end
	local function reverse(mesh)
		local out = mesh:clone()
		for _, face in out.faces do
			local vertices, corners = {}, {}
			for i = #face.vertices, 1, -1 do
				table.insert(vertices, face.vertices[i])
				table.insert(corners, face.corners[i])
			end
			face.vertices, face.corners = vertices, corners
		end
		return out
	end
	local function check(m, r)
		assert(r.complete, r.reason)
		assert(r.validation.valid and (r.empty or r.validation.closed))
		assert(r.intersections.complete and r.intersections.intersectionFree)
		assert(m:validate().valid)
	end
	local function area(m)
		local sum = 0
		for fid in m.faces do
			local _, a = m:faceNormal(fid)
			sum += a
		end
		return sum
	end
	local function sheets(coplanar)
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.new(-2, -2, 0),
				Vector3.new(2, -2, 0),
				Vector3.new(0, 2, 0),
				Vector3.new(0, -1, -1),
				Vector3.new(0, 1, -1),
				Vector3.new(0, 0, 1),
			}
		do
			m:addVertex(coplanar and Vector3.new(p.X + p.Z, p.Y, 0) or p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 4, 5, 6 })
		return m
	end
	test("Intersection splitting retains separate closed sheets and their oriented volume", function()
		local source = pair()
		local before = E.IO.encode(source)
		local m, r = R.splitIntersections(source)
		assert(r.complete and r.mode == "separate_sheets" and r.validation.closed)
		assert(r.validation.surfaceComponents == 2 and r.faces > 24)
		near(m:volume(), 16)
		local duplicated = 0
		for _, ids in r.nodeMap do
			if #ids > 1 then
				duplicated += 1
			end
		end
		assert(duplicated > 4 and E.IO.encode(source) == before)
	end)
	test("Open transverse and coplanar sheet splits preserve area and source components", function()
		for _, coplanar in { false, true } do
			local source = sheets(coplanar)
			local m, r = R.splitIntersections(source)
			assert(r.validation.valid and not r.validation.closed and r.validation.surfaceComponents == 2)
			assert(r.arrangement.inputIntersections.reported > 0 and r.faces > 2)
			near(area(m), area(source))
		end
	end)
	test("Point contacts split source boundaries without welding independent sheet identities", function()
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.zero,
				Vector3.new(2, 0, 0),
				Vector3.new(0, 2, 0),
				Vector3.new(0.5, 0.5, 0),
				Vector3.new(0.5, 0.5, 1),
				Vector3.new(1, 0.5, 1),
			}
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 4, 5, 6 })
		local split, r = R.splitIntersections(m)
		assert(r.validation.valid and r.validation.surfaceComponents == 2)
		near(area(split), area(m))
		local copies = 0
		for _, p in split.vertices do
			if p == m.vertices[4] then
				copies += 1
			end
		end
		assert(copies == 2)
	end)
	test("Coplanar overlap repair matches an analytic box union and clears every intersection", function()
		local m, r = R.resolveIntersections(pair())
		check(m, r)
		near(m:volume(), 16 - 1.5 * 1.75 * 2)
		assert(r.classification.discarded > 0 and r.classification.duplicateFragments > 0)
	end)
	test("Spatial overlap repair preserves the analytic noncoplanar union volume", function()
		local m, r = R.resolveIntersections(pair(Vector3.new(0.7, 0.3, 0.2)))
		check(m, r)
		near(m:volume(), 16 - 1.3 * 1.7 * 1.8)
	end)
	test("Triple overlaps synchronize retained coplanar boundaries and match inclusion exclusion", function()
		local m, r = R.resolveIntersections(
			E.Topology.join({ box(), box(Vector3.new(0.5, 0.25, 0)), box(Vector3.new(0.2, -0.3, 0.7)) })
		)
		check(m, r)
		near(m:volume(), 24 - 1.5 * 1.75 * 2 - 1.8 * 1.7 * 1.3 - 1.7 * 1.45 * 1.3 + 1.5 * 1.45 * 1.3)
		assert(r.conformity.edgeSplits > 0 and r.arrangement.sliverEdgeFlips > 0)
	end)
	test("Rotated overlapping boxes match the independent clipped square area formula", function()
		local b = box()
		local frame = CFrame.Angles(0, 0, math.pi / 4)
		for id, p in b.vertices do
			b.vertices[id] = frame:PointToWorldSpace(p)
		end
		local m, r = R.resolveIntersections(E.Topology.join({ box(), b }))
		check(m, r)
		near(m:volume(), 16 - 16 * (math.sqrt(2) - 1))
	end)
	test("Oblique intersections remove native rounding slivers and retain a valid boundary", function()
		local b = box()
		local frame = CFrame.new(0.5, 0.25, 0.125) * CFrame.Angles(0.2, 0.3, 0.1)
		for id, p in b.vertices do
			b.vertices[id] = frame:PointToWorldSpace(p)
		end
		local m, r = R.resolveIntersections(E.Topology.join({ box(), b }))
		check(m, r)
		assert(
			r.arrangement.sliverEdgeFlips > 0 and r.arrangement.sliverDisplacement <= r.arrangement.tolerance
		)
		assert(m:volume() > 8 and m:volume() < 16)
	end)
	test("Disjoint components and face touching solids retain correct topology and volume", function()
		for _, offset in { Vector3.new(3, 0, 0), Vector3.new(2, 0, 0) } do
			local m, r = R.resolveIntersections(pair(offset))
			check(m, r)
			near(m:volume(), 16)
			assert(r.validation.surfaceComponents == (offset.X == 3 and 2 or 1))
		end
	end)
	test("Coincident sheets obey nonzero odd and opposite winding rules", function()
		local source = pair(Vector3.zero)
		local m, r = R.resolveIntersections(source)
		check(m, r)
		near(m:volume(), 8)
		m, r = R.resolveIntersections(source, { windingRule = "odd" })
		check(m, r)
		assert(r.empty)
		m, r = R.resolveIntersections(E.Topology.join({ box(), reverse(box()) }))
		check(m, r)
		assert(r.empty)
	end)
	test("Nested shells and cavity orientation follow the requested winding region", function()
		local outer, inner = box(), box(nil, Vector3.one)
		local m, r = R.resolveIntersections(E.Topology.join({ outer, inner }))
		check(m, r)
		near(m:volume(), 8)
		m, r = R.resolveIntersections(E.Topology.join({ outer, inner }), { windingRule = "odd" })
		check(m, r)
		near(m:volume(), 7)
		m, r = R.resolveIntersections(E.Topology.join({ outer, reverse(inner) }))
		check(m, r)
		near(m:volume(), 7)
	end)
	test(
		"Inward source components reverse for nonzero occupancy and disappear for positive occupancy",
		function()
			local source = reverse(box())
			local m, r = R.resolveIntersections(source)
			check(m, r)
			near(m:volume(), 8)
			assert(r.classification.reversed == 12)
			m, r = R.resolveIntersections(source, { windingRule = "positive" })
			check(m, r)
			assert(r.empty)
		end
	)
	test("A single self intersecting component repairs its positive winding region", function()
		local source = E.Primitives.sphere(1, 8, 4)
		local top, high = nil, -math.huge
		for id, p in source.vertices do
			if p.Y > high then
				top, high = id, p.Y
			end
		end
		source.vertices[top] = Vector3.new(0.15, -1.5, 0.1)
		local m, r = R.resolveIntersections(source, { windingRule = "positive" })
		check(m, r)
		assert(r.arrangement.inputIntersections.crossings > 0 and r.validation.surfaceComponents == 1)
		assert(r.validation.eulerCharacteristic == 0 and m:volume() > 0)
		local _, nonzero = R.resolveIntersections(source)
		assert(not nonzero.complete and nonzero.reason == "invalid_topology")
	end)
	test("Nonmanifold edge and vertex tangencies are returned as unresolved candidates", function()
		for _, delta in { Vector3.new(2, 2, 0), Vector3.new(2, 2, 2) } do
			local _, r = R.resolveIntersections(pair(delta))
			assert(not r.complete and r.reason == "invalid_topology" and not r.validation.valid)
		end
	end)
	test("Repair preserves volume under scale translation and oblique rigid transforms", function()
		for _, scale in { 0.001, 1, 1000 } do
			local source = pair(Vector3.new(0.7, 0.3, 0.2))
			local frame = scale == 1 and CFrame.new(16, -8, 32) * CFrame.Angles(0.2, 0.4, 0.3)
				or CFrame.identity
			for id, p in source.vertices do
				source.vertices[id] = frame:PointToWorldSpace(p * scale)
			end
			local m, r = R.resolveIntersections(source)
			check(m, r)
			near(m:volume() / scale ^ 3, 12.022, 5e-5)
		end
	end)
	test(
		"Repair transfers all attribute domains UV seams skin and groups through source correspondence",
		function()
			local source = pair()
			local xv, xc, labels, edges = {}, {}, {}, {}
			for id, p in source.vertices do
				xv[id] = p.X
				local w = (p.X + 1) / 4
				source.groups.test = source.groups.test or {}
				source.groups.test[id] = w
				source.weights[id] = { Left = 1 - w, Right = w }
			end
			for fid, f in source.faces do
				labels[fid] = "face" .. fid
				f.material = labels[fid]
				for i, id in f.vertices do
					xc[fid .. ":" .. i] = source.vertices[id].X
					f.corners[i].uv = Vector2.new(source.vertices[id].X, fid)
				end
			end
			for key in E.Connectivity.index(source).edges do
				edges[key] = 7
			end
			for _, schema in
				{
					{ "x", "vertex", "number", xv },
					{ "xc", "corner", "number", xc },
					{ "label", "face", "string", labels },
					{ "rim", "edge", "number", edges },
				}
			do
				source = A.set(
					A.create(source, schema[1], schema[2], schema[3], schema[3] == "string" and "" or 0),
					schema[1],
					schema[4]
				)
			end
			local before = E.IO.encode(source)
			for _, operation in { R.splitIntersections, R.resolveIntersections } do
				local m, r = operation(source)
				assert(r.complete and r.validation.valid)
				for id, p in m.vertices do
					near(A.get(m, "x", id), p.X)
					near(m.groups.test[id] or 0, (p.X + 1) / 4)
					near(m.weights[id].Right or 0, (p.X + 1) / 4)
				end
				for fid, f in m.faces do
					local original = r.maps.face[fid][1][1]
					assert(f.material == "face" .. original and A.get(m, "label", fid) == f.material)
					for i, id in f.vertices do
						near(A.get(m, "xc", fid .. ":" .. i), m.vertices[id].X)
						near(f.corners[i].uv.X, m.vertices[id].X)
						near(f.corners[i].uv.Y, original)
					end
				end
				assert(next(r.maps.edge))
				for key in r.maps.edge do
					near(A.get(m, "rim", key), 7)
				end
			end
			assert(E.IO.encode(source) == before)
		end
	)
	test("Welded vertex channel blending offers deterministic first and averaged contributors", function()
		local source = pair()
		local values = {}
		for id in source.vertices do
			values[id] = id <= 8 and 10 or 30
		end
		source = A.set(A.create(source, "source", "vertex", "number", 0), "source", values)
		local first, rf = R.resolveIntersections(source, { vertexBlend = "first" })
		local average, ra = R.resolveIntersections(source)
		check(first, rf)
		check(average, ra)
		local mixed = 0
		for id in average.vertices do
			local sum, total = 0, 0
			for _, ref in ra.maps.vertex[id] do
				sum += values[ref[1]] * ref[2]
				total += ref[2]
			end
			near(A.get(average, "source", id), sum / total)
			if sum / total > 10.01 and sum / total < 29.99 then
				mixed += 1
			end
			local value = A.get(first, "source", id)
			assert(value == 10 or value == 30)
		end
		assert(mixed > 0)
	end)
	test("Repairing an already repaired mesh retains topology coordinates and volume", function()
		local first = R.resolveIntersections(pair())
		local second, r = R.resolveIntersections(first)
		check(second, r)
		assert(count(first.faces) == count(second.faces) and count(first.vertices) == count(second.vertices))
		for id, p in first.vertices do
			assert(second.vertices[id] == p)
		end
		near(first:volume(), second:volume())
	end)
	test("Empty intersection repair and splitting return independent empty meshes", function()
		local source = E.Mesh.new()
		local m, r = R.resolveIntersections(source)
		check(m, r)
		assert(r.empty and m ~= source)
		m, r = R.splitIntersections(source)
		assert(r.complete and r.validation.valid and not next(m.faces))
	end)
	test(
		"Invalid repair settings open sheets and collapsed source features reject transactionally",
		function()
			local source = pair()
			local before = E.IO.encode(source)
			for _, options in
				{
					{ windingRule = "unknown" },
					{ vertexBlend = "unknown" },
					{ classificationOffset = 0 },
					{ maxRayDirections = 1 },
					{ tolerance = -1 },
					{ tolerance = 10 },
				}
			do
				assert(not pcall(R.resolveIntersections, source, options))
			end
			assert(not pcall(R.resolveIntersections, sheets(false)))
			assert(E.IO.encode(source) == before)
		end
	)
	test("Intersection repair allocation traversal and cancellation limits preserve the source", function()
		local source = pair()
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxVertices = 8 },
				{ maxFaces = 1 },
				{ maxWork = 8 },
				{ maxFacePoints = 3 },
				{ intersectionOptions = { maxTests = 1 } },
				{ intersectionOptions = { maxIntersections = 1 } },
				{
					checkpoint = function(state)
						if state.stage == "classify" then
							error("cancel classification")
						end
					end,
				},
			}
		do
			assert(not pcall(R.resolveIntersections, source, options))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("An incomplete final audit cannot report a completed repair", function()
		local source = pair()
		local _, input = E.Intersections.mesh(source)
		local _, r = R.resolveIntersections(source, { intersectionOptions = { maxTests = input.tests + 1 } })
		assert(not r.complete and r.reason == "incomplete_audit" and not r.intersections.complete)
	end)
	test("Unresolvable near coincident transformed sheets reject instead of claiming repair", function()
		local source = pair()
		local frame = CFrame.new(16, -8, 32) * CFrame.Angles(0.2, 0.4, 0.3)
		for id, p in source.vertices do
			source.vertices[id] = frame:PointToWorldSpace(p)
		end
		local ok, result = pcall(function()
			local _, r = R.resolveIntersections(source)
			return r
		end)
		assert(not ok or not result.complete)
	end)
	test("Repaired native EditableMesh roundtrips preserve closed geometry and corner UVs", function()
		local m, r = R.resolveIntersections(pair(Vector3.new(0.7, 0.3, 0.2)))
		check(m, r)
		local handle = E.Roblox.toEditable(m)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), 12.022)
			local _, audit = E.Intersections.mesh(restored)
			assert(audit.complete and audit.intersectionFree)
			for _, f in restored.faces do
				for _, c in f.corners do
					assert(typeof(c.uv) == "Vector2")
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
