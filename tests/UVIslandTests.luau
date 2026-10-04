return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(
			math.abs(a - b) <= (tolerance or 1e-6) * math.max(1, math.abs(b)),
			tostring(a) .. " differs from " .. tostring(b)
		)
	end
	local function square(mesh, x, worldSize, uvMin, uvMax)
		mesh = mesh or E.Mesh.new()
		worldSize = worldSize or 1
		uvMin, uvMax = uvMin or Vector2.zero, uvMax or Vector2.one
		local vs = {
			mesh:addVertex(Vector3.new(x, 0, 0)),
			mesh:addVertex(Vector3.new(x + worldSize, 0, 0)),
			mesh:addVertex(Vector3.new(x + worldSize, worldSize, 0)),
			mesh:addVertex(Vector3.new(x, worldSize, 0)),
		}
		local fid = mesh:addFace(vs, {
			{ uv = uvMin },
			{ uv = Vector2.new(uvMax.X, uvMin.Y) },
			{ uv = uvMax },
			{
				uv = Vector2.new(uvMin.X, uvMax.Y),
			},
		})
		return mesh, fid
	end
	local function pair()
		local m = square(nil, 0, 1)
		square(m, 3, 2)
		return m
	end
	local function triangle(uv)
		local m = E.Mesh.new()
		m:addVertex(Vector3.zero)
		m:addVertex(Vector3.xAxis)
		m:addVertex(Vector3.yAxis)
		m:addFace({ 1, 2, 3 }, { { uv = uv[1] }, { uv = uv[2] }, { uv = uv[3] } })
		return m
	end
	test("UV islands use shared-edge endpoint continuity and stable minimum face IDs", function()
		local m = E.Topology.triangulate(square(nil, 0, 1))
		local charts, r = E.UV.islands(m)
		assert(#charts == 1 and #charts[1].faces == 2 and charts[1].id == 1 and r.faceToIsland[2] == 1)
		local top = m:topology()
		local shared
		for key, edge in top.edges do
			if #edge.faces == 2 then
				shared = key
			end
		end
		local cut = E.UV.islands(m, { seams = { [shared] = true } })
		assert(#cut == 2)
		m.faces[2].corners[1].uv += Vector2.new(0.125, 0)
		assert(#E.UV.islands(m) == 2)
		assert(#E.UV.islands(pair()) == 2)
	end)
	test("Analytic areas density and singular stretches agree with affine triangles", function()
		local m = triangle({ Vector2.zero, Vector2.new(2, 0), Vector2.new(1, 1) })
		local r = E.UV.analyze(m)
		assert(r.complete and r.consistentOrientation and r.allPositive and r.overlapFree)
		near(r.surfaceArea, 0.5)
		near(r.uvArea, 1)
		near(r.triangles[1].maximumStretch, math.sqrt(3 + math.sqrt(5)))
		near(r.triangles[1].minimumStretch, math.sqrt(3 - math.sqrt(5)))
		near(r.islands[1].density, math.sqrt(2))
		local pixels = E.UV.analyze(
			triangle({ Vector2.zero, Vector2.new(0.5, 0), Vector2.new(0, 0.25) }),
			{ textureSize = Vector2.new(200, 400) }
		)
		near(pixels.triangles[1].maximumStretch, 100)
		near(pixels.triangles[1].minimumStretch, 100)
		near(pixels.islands[1].density, 100)
	end)
	test("UV overlap includes identical and contained charts but excludes edge and point contact", function()
		local m = pair()
		local r = E.UV.analyze(m)
		assert(r.overlapCount == 2 and not r.overlapFree)
		local moved = E.UV.transformIslands(m, { [2] = { translation = Vector2.new(1, 0) } })
		assert(E.UV.analyze(moved).overlapFree)
		local point = E.UV.transformIslands(m, { [2] = { translation = Vector2.new(1, 1) } })
		assert(E.UV.analyze(point).overlapFree)
		local inside = E.UV.transformIslands(m, { [2] = { scale = 0.5 } })
		assert(E.UV.analyze(inside).overlapCount > 0)
		local clipped = E.UV.analyze(m, { maxOverlaps = 0 })
		assert(
			clipped.complete
				and clipped.overlapCount == 2
				and #clipped.overlaps == 0
				and clipped.overlapsTruncated
		)
	end)
	test("Negative folded degenerate and missing UVs have distinct diagnostics", function()
		local negative = triangle({ Vector2.zero, Vector2.yAxis, Vector2.xAxis })
		local r = E.UV.analyze(negative)
		assert(r.negativeTriangles == 1 and not r.allPositive and r.consistentOrientation)
		local flat = triangle({ Vector2.zero, Vector2.xAxis, Vector2.new(2, 0) })
		local q = E.UV.analyze(flat)
		assert(
			q.complete
				and q.degenerateTriangles == 1
				and not q.consistentOrientation
				and q.maximumAnisotropy == math.huge
		)
		negative.faces[1].corners[2].uv = nil
		local absent = E.UV.analyze(negative)
		assert(not absent.complete and absent.missingCorners == 1 and not absent.overlapFree)
		assert(not pcall(E.UV.analyze, negative, { requireComplete = true }))
		local m = E.Topology.triangulate(square(nil, 0, 1))
		local face = m.faces[2]
		for i, id in face.vertices do
			local shared = false
			for _, other in m.faces[1].vertices do
				if id == other then
					shared = true
				end
			end
			if not shared then
				face.corners[i].uv = Vector2.new(0.5, 0.5)
			end
		end
		local folded = E.UV.analyze(m)
		assert(folded.degenerateTriangles == 1 or #folded.mixedOrientationIslands == 1)
	end)
	test("Per-island affine transforms preserve geometry data and clear changed tangents", function()
		local m = pair()
		m = E.Attributes.create(m, "tag", "corner", "number", 7)
		m = E.Attributes.create(m, "weight", "vertex", "number", 0)
		m.attributes.weight.values[1] = 0.8
		m.groups.keep = { [1] = 0.3 }
		for _, face in m.faces do
			for _, corner in face.corners do
				corner.normal = Vector3.zAxis
				corner.tangent = Vector3.xAxis
			end
		end
		local before = E.IO.encode(m)
		local out, r = E.UV.transformIslands(m, {
			[1] = {
				pivot = Vector2.zero,
				rotation = math.pi / 2,
				scale = Vector2.new(2, 3),
				translation = Vector2.new(4, 5),
			},
		})
		assert(r.complete and r.changedCorners == 4 and E.IO.encode(m) == before)
		near(out.faces[1].corners[2].uv.X, 4)
		near(out.faces[1].corners[2].uv.Y, 7)
		near(out.faces[1].corners[4].uv.X, 1)
		near(out.faces[1].corners[4].uv.Y, 5)
		for id, p in out.vertices do
			assert(p == m.vertices[id])
		end
		for _, corner in out.faces[1].corners do
			assert(corner.normal == Vector3.zAxis and corner.tangent == nil)
		end
		for _, corner in out.faces[2].corners do
			assert(corner.tangent == Vector3.xAxis)
		end
		assert(
			out.attributes.tag.default == 7
				and out.attributes.weight.values[1] == 0.8
				and out.groups.keep[1] == 0.3
		)
		local mirror, mr = E.UV.transformIslands(m, { [1] = { scale = Vector2.new(-1, 1) } })
		assert(mr.complete and E.UV.analyze(mirror).negativeTriangles == 2)
	end)
	test("Equal density preserves total selected UV area or uses an explicit texel target", function()
		local m = pair()
		local out, r = E.UV.equalizeDensity(m)
		assert(r.complete)
		local q = E.UV.analyze(out)
		near(q.uvArea, 2)
		near(q.islands[1].density, math.sqrt(2 / 5))
		near(q.islands[2].density, math.sqrt(2 / 5))
		local pinned, p = E.UV.equalizeDensity(
			m,
			{ islands = { [2] = true }, textureSize = Vector2.new(100, 200), density = 50 }
		)
		assert(p.complete and pinned.faces[1].corners[1].uv == m.faces[1].corners[1].uv)
		near(E.UV.analyze(pinned, { textureSize = Vector2.new(100, 200) }).islands[2].density, 50)
	end)
	test("Packing equalizes chart density with explicit margins and native overlap audits", function()
		local m = pair()
		local before = E.IO.encode(m)
		local out, r =
			E.UV.packIslands(m, { normalizeDensity = true, margin = 0.025, requireComplete = true })
		assert(r.complete and r.marginCertified and r.movableIslands == 2 and E.IO.encode(m) == before)
		local q = E.UV.analyze(out)
		assert(q.overlapFree and q.allPositive)
		near(q.islands[1].density, q.islands[2].density)
		near(q.islands[2].uvArea / q.islands[1].uvArea, 4)
		for _, face in out.faces do
			for _, corner in face.corners do
				assert(
					corner.uv.X >= 0.025
						and corner.uv.Y >= 0.025
						and corner.uv.X <= 0.975
						and corner.uv.Y <= 0.975
				)
			end
		end
		local again = E.UV.packIslands(m, { normalizeDensity = true, margin = 0.025 })
		assert(E.IO.encode(out) == E.IO.encode(again))
	end)
	test("Cardinal packing rotates in the requested texture metric", function()
		local m = square(nil, 0, 1, Vector2.zero, Vector2.new(0.4, 1.8))
		local out, r = E.UV.packIslands(
			m,
			{ textureSize = Vector2.new(2, 1), maximum = Vector2.new(1, 1), scale = 1, margin = 0 }
		)
		assert(r.complete and r.placements[1].rotation == math.pi / 2)
		local before = E.UV.analyze(m, { textureSize = Vector2.new(2, 1) })
		local after = E.UV.analyze(out, { textureSize = Vector2.new(2, 1) })
		near(after.islands[1].density, before.islands[1].density)
		near(after.maximumAnisotropy, before.maximumAnisotropy)
		local unchanged, q =
			E.UV.packIslands(m, { textureSize = Vector2.new(2, 1), scale = 1, margin = 0, rotate = false })
		assert(not q.complete and q.reason == "noPlacement" and E.IO.encode(unchanged) == E.IO.encode(m))
	end)
	test("Pinned and unselected charts reserve obstacles without changing their corners", function()
		local m = square(nil, 0, 1, Vector2.new(0.1, 0.1), Vector2.new(0.4, 0.4))
		square(m, 3, 1)
		for _, settings in { { pinnedIslands = { [1] = true } }, { islands = { [2] = true } } } do
			settings.margin = 0.01
			local out, r = E.UV.packIslands(m, settings)
			assert(r.complete and r.fixedIslands == 1 and r.movableIslands == 1)
			for i, corner in m.faces[1].corners do
				assert(out.faces[1].corners[i].uv == corner.uv)
			end
			assert(E.UV.analyze(out).overlapFree)
		end
		local blocked = square(nil, 0, 1)
		square(blocked, 3, 1)
		local unchanged, r = E.UV.packIslands(blocked, { pinnedIslands = { [1] = true } })
		assert(not r.complete and E.IO.encode(unchanged) == E.IO.encode(blocked))
		assert(
			not pcall(E.UV.packIslands, blocked, { pinnedIslands = { [1] = true }, requireComplete = true })
		)
	end)
	test("Seams from islands write real false values over a true channel default", function()
		local m = E.Topology.triangulate(square(nil, 0, 1))
		m = E.Attributes.create(m, "uv_seam", "edge", "boolean", true)
		local out, r = E.UV.seamsFromIslands(m)
		for key, edge in m:topology().edges do
			assert(E.Attributes.get(out, "uv_seam", key) == (#edge.faces == 1))
			assert((r.seams[key] == true) == (#edge.faces == 1))
		end
		assert(m.attributes.uv_seam.default == true and next(m.attributes.uv_seam.values) == nil)
	end)
	test("Native rounding collapse is reported and packing failure remains transactional", function()
		local m = square(nil, 0, 1)
		local _, r = E.UV.transformIslands(m, { [1] = { translation = Vector2.new(2 ^ 30, 2 ^ 30) } })
		assert(not r.complete and r.reason == "nativeOrientation")
		assert(
			not pcall(
				E.UV.transformIslands,
				m,
				{ [1] = { translation = Vector2.new(2 ^ 30, 2 ^ 30) } },
				{ requireComplete = true }
			)
		)
		local unchanged, q = E.UV.packIslands(
			m,
			{ minimum = Vector2.new(2 ^ 30, 2 ^ 30), maximum = Vector2.new(2 ^ 30 + 128, 2 ^ 30 + 128) }
		)
		assert(not q.complete and E.IO.encode(unchanged) == E.IO.encode(m))
	end)
	test("Caller meshes selections transforms and options are snapshotted before callbacks", function()
		local m = pair()
		local transforms = { [1] = { translation = Vector2.new(2, 3) } }
		local options = { islands = { [1] = true } }
		options.checkpoint = function(status)
			if status.stage == "begin" then
				m.faces[1].corners[1].uv = Vector2.new(99, 99)
				transforms[1].translation = Vector2.zero
				options.islands[1] = false
			end
		end
		local out, r = E.UV.transformIslands(m, transforms, options)
		assert(r.complete and out.faces[1].corners[1].uv == Vector2.new(2, 3))
	end)
	test("UV work allocation cancellation and invalid-option failures are bounded", function()
		local m = pair()
		for _, options in
			{
				{ maxWork = 1 },
				{ maxFaces = 1 },
				{ maxVertices = 1 },
				{ maxCorners = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{ textureSize = Vector2.new(1.5, 2) },
				{ islands = { [999] = true } },
				{ seams = { bad = true } },
			}
		do
			assert(not pcall(E.UV.analyze, m, options))
		end
		for _, options in
			{
				{ margin = -1 },
				{ iterations = 65 },
				{ scale = 0 },
				{ pinnedIslands = { [999] = true } },
				{
					maxIslands = 1,
				},
			}
		do
			assert(not pcall(E.UV.packIslands, m, options))
		end
		assert(not pcall(E.UV.equalizeDensity, m, { density = 0 }))
		assert(not pcall(E.UV.transformIslands, m, { [1] = { scale = 0 } }))
	end)
	test("Empty selections and empty meshes have stable identity results", function()
		local m = pair()
		for _, fn in { E.UV.packIslands, E.UV.equalizeDensity } do
			local out, r = fn(m, { islands = {} })
			assert(r.complete and E.IO.encode(out) == E.IO.encode(m))
			local empty, q = fn(E.Mesh.new())
			assert(q.complete and next(empty.faces) == nil)
		end
		local r = E.UV.analyze(E.Mesh.new())
		assert(r.complete and r.overlapFree and #r.islands == 0)
	end)
	test("Independent Fraction clipping confirms 1280 exact native overlap decisions", function()
		local D = require(script.Parent.UVAnalysis)
		for _, fixture in require(script.Parent.UVOverlapFixtures) do
			for _, reverseA in { false, true } do
				for _, swap in { false, true } do
					local a, b = {}, {}
					for i = 1, 3 do
						local p = fixture.a[reverseA and 4 - i or i]
						local q = fixture.b[i]
						a[i], b[i] = Vector2.new(p[1], p[2]), Vector2.new(q[1], q[2])
					end
					local x, y =
						{ uv = a, orientation = E.Predicates.orient2D(table.unpack(a)) },
						{ uv = b, orientation = E.Predicates.orient2D(table.unpack(b)) }
					local result = D.overlap(swap and y or x, swap and x or y, function() end)
					assert(result == fixture.overlap)
				end
			end
		end
	end)
	test("Concave face charts use geometric triangulations and folded islands cannot pack", function()
		local m = E.Mesh.new()
		local points = { { 0, 0 }, { 3, 0 }, { 3, 1 }, { 1, 1 }, { 1, 3 }, { 0, 3 } }
		local ids, corners = {}, {}
		for i, p in points do
			ids[i] = m:addVertex(Vector3.new(p[1], p[2], 0))
			corners[i] = { uv = Vector2.new(p[1], p[2]) }
		end
		m:addFace(ids, corners)
		local r = E.UV.analyze(m)
		near(r.uvArea, 5)
		near(r.surfaceArea, 5)
		assert(r.overlapFree and #r.triangles == 4 and r.allPositive)
		local folded = square(nil, 0, 1)
		folded.faces[1].corners[3].uv, folded.faces[1].corners[4].uv =
			folded.faces[1].corners[4].uv, folded.faces[1].corners[3].uv
		local q = E.UV.analyze(folded)
		assert(#q.mixedOrientationIslands == 1)
		local unchanged, p = E.UV.packIslands(folded)
		assert(
			not p.complete and p.reason == "foldedIsland" and E.IO.encode(unchanged) == E.IO.encode(folded)
		)
	end)
	test("Many rectangular charts pack with independent margins and preserve relative scale", function()
		local m = E.Mesh.new()
		for i = 1, 24 do
			square(m, 4 * i, 1, Vector2.zero, Vector2.new(0.5 + (i % 5) / 4, 0.25 + (i % 7) / 5))
		end
		local initial = E.UV.islands(m)
		local out, r = E.UV.packIslands(
			m,
			{ minimum = Vector2.new(2, 3), maximum = Vector2.new(4, 5), margin = 0.01, iterations = 24 }
		)
		assert(r.complete and r.marginCertified)
		local islands = E.UV.islands(out)
		for i, a in islands do
			near(a.uvArea / initial[i].uvArea, r.scale ^ 2, 3e-5)
			assert(
				a.minimum[1] >= 2.01
					and a.minimum[2] >= 3.01
					and a.maximum[1] <= 3.99
					and a.maximum[2] <= 4.99
			)
			for j = i + 1, #islands do
				local b = islands[j]
				local gap = math.max(
					a.minimum[1] - b.maximum[1],
					b.minimum[1] - a.maximum[1],
					a.minimum[2] - b.maximum[2],
					b.minimum[2] - a.maximum[2]
				)
				assert(gap >= 0.02)
			end
		end
		assert(E.UV.analyze(out).overlapFree)
	end)
	test("Measurements survive rigid geometry frames sparse IDs tiny UVs and common translations", function()
		local source = triangle({ Vector2.zero, Vector2.new(2, 0), Vector2.new(0, 3) })
		for _, size in { 2 ^ -100, 1, 2 ^ 70 } do
			local m = source:clone()
			for _, c in m.faces[1].corners do
				c.uv = Vector2.new(c.uv.X * size, c.uv.Y * size)
			end
			local r = E.UV.analyze(m)
			near(r.maximumAnisotropy, 1.5)
			assert(math.abs(r.islands[1].density / (math.sqrt(6) * size) - 1) < 1e-12)
		end
		local moved = E.Deform.transform(source, CFrame.new(23, -17, 40) * CFrame.Angles(0.3, 0.5, 0.7))
		local r = E.UV.analyze(moved)
		near(r.maximumAnisotropy, 1.5, 1e-5)
		local m = E.Mesh.new()
		for i, p in source.vertices do
			m.vertices[i * 101] = p
		end
		m.faces[777] = {
			vertices = { 101, 202, 303 },
			corners = {
				{ uv = Vector2.new(2 ^ 20, 2 ^ 20) },
				{ uv = Vector2.new(2 ^ 20 + 2, 2 ^ 20) },
				{ uv = Vector2.new(2 ^ 20, 2 ^ 20 + 3) },
			},
		}
		m.nextVertexId, m.nextFaceId = 304, 778
		local q = E.UV.analyze(m)
		assert(q.islands[1].id == 777)
		near(q.uvArea, 3)
		near(q.maximumAnisotropy, 1.5)
	end)
	test("All typed domains material skin and sparse groups survive packing", function()
		local m = pair()
		m = E.Attributes.create(m, "v", "vertex", "number", 2)
		m = E.Attributes.create(m, "e", "edge", "boolean", true)
		m = E.Attributes.create(m, "f", "face", "string", "base")
		m = E.Attributes.create(m, "c", "corner", "Vector2", Vector2.new(2, 3))
		m.attributes.v.values[1] = 10
		m.attributes.e.values["1:2"] = false
		m.attributes.f.values[2] = "panel"
		m.attributes.c.values["1:3"] = Vector2.new(7, 8)
		m.weights[1] = { a = 0.25, b = 0.75 }
		m.groups.mask = { [2] = 0.2, [5] = 0.9 }
		m.faces[2].material = 4
		local out, r = E.UV.packIslands(m)
		assert(
			r.complete
				and out.attributes.v.values[1] == 10
				and out.attributes.e.values["1:2"] == false
				and out.attributes.f.values[2] == "panel"
				and out.attributes.c.values["1:3"] == Vector2.new(7, 8)
		)
		assert(
			out.weights[1].a == 0.25
				and out.weights[1].b == 0.75
				and out.groups.mask[5] == 0.9
				and out.faces[2].material == 4
		)
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
	end)
	test(
		"Late packing cancellation rectangle budgets and nonmanifold inputs reject without mutation",
		function()
			local m = pair()
			local before = E.IO.encode(m)
			assert(not pcall(E.UV.packIslands, m, { maxFreeRectangles = 1 }))
			assert(not pcall(E.UV.packIslands, m, {
				checkpoint = function(status)
					if status.stage == "packedRectangles" then
						error("late cancellation")
					end
				end,
			}))
			assert(E.IO.encode(m) == before)
			local nonmanifold = square(nil, 0, 1)
			nonmanifold:addFace({ 1, 2, 3 })
			assert(not pcall(E.UV.analyze, nonmanifold))
			local missing = square(nil, 0, 1)
			missing.faces[1].corners[1].uv = nil
			local _, r = E.UV.islands(missing)
			local _, q = E.UV.seamsFromIslands(missing)
			assert(not r.complete and not q.complete)
			assert(not pcall(E.UV.islands, missing, { requireComplete = true }))
		end
	)
	test("Packed box atlas survives native UV and normal conversion", function()
		local result = require(script.Parent.Examples.UVAtlas)(E)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid and restored:validate().closed)
			local r = E.UV.analyze(restored, { textureSize = Vector2.new(1024, 512) })
			assert(r.complete and r.overlapFree and r.consistentOrientation and #r.islands == 6)
			for _, face in restored.faces do
				for _, c in face.corners do
					assert(c.uv and c.normal and math.abs(c.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
