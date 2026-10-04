return function(E)
	local S = E.Simplify
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function count(t)
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	local function near(a, b, e)
		assert(math.abs(a - b) < (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function grid(nx, ny, field, omit)
		local m = E.Mesh.new()
		local function id(i, j)
			return i * (ny + 1) + j + 1
		end
		for i = 0, nx do
			for j = 0, ny do
				m:addVertex(Vector3.new(i, j, field and field(i, j) or 0))
			end
		end
		for i = 0, nx - 1 do
			for j = 0, ny - 1 do
				if not omit or not omit(i, j) then
					local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
					local corners = {}
					for k, v in ids do
						local p = m.vertices[v]
						corners[k] =
							{ uv = Vector2.new(p.X, p.Y), color = Color3.new(0.2, 0.4, 0.6), alpha = 0.7 }
					end
					m:addFace(ids, corners)
				end
			end
		end
		return m, id
	end
	local function area(m)
		local a = 0
		for fid in m.faces do
			local _, value = m:faceNormal(fid)
			a += value
		end
		return a
	end
	test("A flat grid dissolves to one polygon while retaining its sampled boundary", function()
		local m = grid(5, 5)
		local before = E.IO.encode(m)
		local out, r = S.planar(m, 0)
		assert(r.complete and r.merges == 24 and r.finalFaces == 1 and r.boundaryRemoved == 0)
		assert(count(out.vertices) == 20 and out:validate().valid and r.outputIntersections.intersectionFree)
		near(area(out), 25)
		for id, p in out.vertices do
			assert(p == m.vertices[id])
		end
		assert(E.IO.encode(m) == before and r.maximumPlaneDeviation == 0)
	end)
	test("Optional boundary dissolving removes an entire collinear grid perimeter", function()
		local m = grid(5, 5)
		local out, r = S.planar(m, 0, { dissolveBoundaries = true })
		assert(r.complete and r.finalFaces == 1 and count(out.vertices) == 4 and r.boundaryRemoved == 16)
		assert(#out:triangles() == 2 and out:validate().valid)
		near(area(out), 25)
		assert(r.maximumBoundaryDeviation == 0)
	end)
	test("A hole retains a disk partition and its independent area", function()
		local m = grid(3, 3, nil, function(i, j)
			return i == 1 and j == 1
		end)
		local out, r = S.planar(m, 0, { dissolveBoundaries = true })
		assert(r.complete and r.finalFaces == 2 and r.blocked.holes and out:validate().valid)
		near(area(out), 8)
		local boundaries = E.Connectivity.boundaries(out)
		assert(#boundaries == 2)
	end)
	test("Concave L-shaped regions keep their exact outline", function()
		local m = grid(2, 2, nil, function(i, j)
			return i == 1 and j == 1
		end)
		local out, r = S.planar(m, 0, { dissolveBoundaries = true })
		assert(r.complete and r.finalFaces == 1 and count(out.vertices) == 6)
		near(area(out), 3)
	end)
	test("Selected faces remain conforming with unselected neighbors", function()
		local m = grid(3, 2)
		local before = E.IO.encode(m)
		local out, r = S.planar(m, 0, { faces = { [1] = true, [2] = true }, dissolveBoundaries = true })
		assert(r.complete and r.merges == 1 and r.finalFaces == 5 and out:validate().valid)
		for fid = 3, 6 do
			assert(table.concat(out.faces[fid].vertices, ",") == table.concat(m.faces[fid].vertices, ","))
			for i, c in out.faces[fid].corners do
				assert(c.uv == m.faces[fid].corners[i].uv)
			end
		end
		assert(E.IO.encode(m) == before)
	end)
	test("UV and material seams delimit edges without locking an entire neighboring region", function()
		local m = grid(4, 2)
		for fid, face in m.faces do
			if fid >= 5 then
				for _, c in face.corners do
					c.uv += Vector2.new(10, 0)
				end
			end
		end
		local out, r = S.planar(m, 0)
		assert(r.complete and r.finalFaces == 2 and r.blocked.seam)
		near(area(out), 8)
		local material = grid(4, 2)
		for fid, face in material.faces do
			if fid >= 5 then
				face.material = 2
			end
		end
		local divided, q = S.planar(material, 0)
		assert(q.finalFaces == 2 and divided.faces[1].material ~= divided.faces[5].material)
	end)
	test("Typed discontinuities and explicit sharp edges survive region unions", function()
		local m, id = grid(4, 2)
		m = E.Attributes.create(m, "panel", "face", "number", 0)
		for fid = 5, 8 do
			m.attributes.panel.values[fid] = 1
		end
		local _, r = S.planar(m, 0)
		assert(r.finalFaces == 2)
		local flat = grid(4, 2)
		flat = E.Attributes.create(flat, "barrier", "edge", "boolean", false)
		for j = 0, 1 do
			flat.attributes.barrier.values[id(2, j) .. ":" .. id(2, j + 1)] = true
		end
		local out, q = S.planar(flat, 0, { seamAttributes = { "barrier" }, dissolveBoundaries = true })
		assert(q.finalFaces == 2 and q.complete)
		local marked = 0
		for _, v in out.attributes.barrier.values do
			if v then
				marked += 1
			end
		end
		assert(marked == 1)
	end)
	test("Original face areas weight merged attributes and retained vertices keep skin and groups", function()
		local m = grid(2, 1)
		for id, p in m.vertices do
			if p.X == 2 then
				m.vertices[id] = Vector3.new(4, p.Y, 0)
			end
		end
		m = E.Attributes.create(m, "density", "face", "number", 0)
		m.attributes.density.values[1], m.attributes.density.values[2] = 1, 5
		m = E.Attributes.create(m, "stamp", "corner", "number", 3)
		m = E.Attributes.create(m, "weight", "vertex", "number", 0.4)
		m.groups.sample = { [1] = 0.6 }
		m.weights[1] = { Bone = 1 }
		local before = E.IO.encode(m)
		local out, r = S.planar(m, 0, { preserveSeams = false, dissolveBoundaries = true })
		assert(r.complete and r.finalFaces == 1)
		near(out.attributes.density.values[1], 4)
		assert(out.groups.sample[1] == 0.6 and out.weights[1].Bone == 1)
		for _, c in out.faces[1].corners do
			assert(c.uv and c.color and c.alpha == 0.7)
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Boundary reduction retains changing edge attributes by default", function()
		local m, id = grid(2, 1)
		m = E.Attributes.create(m, "tag", "edge", "number", 0)
		m.attributes.tag.values[id(0, 0) .. ":" .. id(1, 0)] = 1
		m.attributes.tag.values[id(1, 0) .. ":" .. id(2, 0)] = 3
		local out, r = S.planar(m, 0, { dissolveBoundaries = true })
		assert(r.complete and out.vertices[id(1, 0)])
		local merged, q = S.planar(m, 0, { dissolveBoundaries = true, preserveSeams = false })
		assert(q.complete and not merged.vertices[id(1, 0)])
		near(merged.attributes.tag.values[id(0, 0) .. ":" .. id(2, 0)], 2)
	end)
	test("Angle and plane-deviation constraints prevent cumulative curved-strip drift", function()
		local m = grid(8, 2, function(x)
			return 0.025 * x * x
		end)
		local _, exact = S.planar(m, 0)
		assert(exact.finalFaces == 8)
		local _, limited = S.planar(m, 0.12, { maxPlaneDeviation = 1 })
		assert(limited.complete and limited.finalFaces > 1 and limited.maximumAngle <= 0.12)
		local _, flat = S.planar(m, 0.8, { maxPlaneDeviation = 0.001 })
		assert(flat.finalFaces == 8)
		local reduced, broad = S.planar(m, 0.8, { maxPlaneDeviation = 1 })
		assert(broad.complete and broad.finalFaces == 1 and reduced:validate().valid)
	end)
	test("Boundary distance is measured against the original chain", function()
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.new(0, 0, 0),
				Vector3.new(1, -0.01, 0),
				Vector3.new(2, 0, 0),
				Vector3.new(2, 1, 0),
				Vector3.new(2, 2, 0),
				Vector3.new(1, 2.01, 0),
				Vector3.new(0, 2, 0),
				Vector3.new(0, 1, 0),
			}
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3, 4, 5, 6, 7, 8 })
		local out, r = S.planar(m, 0.1, { dissolveBoundaries = true, maxBoundaryDeviation = 0.02 })
		assert(r.complete and count(out.vertices) == 4)
		near(r.maximumBoundaryDeviation, 0.01, 1e-6)
		near(area(out), 4)
		local tight, q = S.planar(m, 0.1, { dissolveBoundaries = true, maxBoundaryDeviation = 0.001 })
		assert(q.complete and count(tight.vertices) == 6)
	end)
	test("Soft merge and boundary limits return explicit partial meshes", function()
		local m = grid(3, 3)
		local out, r = S.planar(m, 0, { maxMerges = 1 })
		assert(not r.complete and r.reason == "maxMerges" and r.merges == 1 and out:validate().valid)
		assert(not pcall(S.planar, m, 0, { maxMerges = 1, requireComplete = true }))
		local _, b = S.planar(m, 0, { dissolveBoundaries = true, maxBoundaryRemovals = 1 })
		assert(not b.complete and b.reason == "maxBoundaryRemovals" and b.boundaryRemoved == 1)
	end)
	test("Cancellation and resource limits reject without changing the caller", function()
		local m = grid(3, 3)
		local before = E.IO.encode(m)
		for _, options in
			{
				{ maxWork = 1 },
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(s)
						if s.stage == "merge" then
							error("stop")
						end
					end,
				},
			}
		do
			assert(not pcall(S.planar, m, 0, options))
			assert(E.IO.encode(m) == before)
		end
	end)
	test("Input and scalar options are snapshotted before callbacks", function()
		local m = grid(3, 3)
		local options = { dissolveBoundaries = true }
		options.checkpoint = function(s)
			if s.stage == "begin" then
				m.vertices[1] = Vector3.new(100, 100, 100)
				options.dissolveBoundaries = false
			end
		end
		local out, r = S.planar(m, 0, options)
		assert(r.complete and count(out.vertices) == 4)
		near(area(out), 9)
	end)
	test("Transforms and sparse identities retain equivalent planar regions", function()
		local m = grid(3, 3)
		local frame = CFrame.new(100, -20, 30) * CFrame.Angles(0.3, -0.2, 0.1)
		for _, scale in { 0.01, 1000 } do
			local sparse = E.Mesh.new()
			for id, p in m.vertices do
				sparse.vertices[13 * id + 9] = frame:PointToWorldSpace(p * scale)
			end
			for fid, f in m.faces do
				local ids = {}
				for i, id in f.vertices do
					ids[i] = 13 * id + 9
				end
				sparse.faces[7 * fid + 11] =
					{ vertices = ids, corners = table.clone(f.corners), material = f.material }
			end
			local out, r = S.planar(sparse, 0.01, {
				maxPlaneDeviation = math.max(5e-6, 1e-4 * scale),
				dissolveBoundaries = true,
				maxBoundaryDeviation = 1e-3 * scale,
			})
			assert(r.complete and r.finalFaces == 1 and count(out.vertices) == 4)
			near(area(out) / (scale * scale), 9, 0.003)
		end
	end)
	test("Native rounding can retain faces under a strict plane constraint", function()
		local m = grid(3, 3)
		local frame = CFrame.new(100, -20, 30) * CFrame.Angles(0.3, -0.2, 0.1)
		for id, p in m.vertices do
			m.vertices[id] = frame:PointToWorldSpace(p * 0.01)
		end
		local _, r = S.planar(m, 0.01, { maxPlaneDeviation = 1e-7 })
		assert(r.complete and r.finalFaces > 1 and r.blocked.deviation)
		assert(r.maximumPlaneDeviation <= 1e-7)
	end)
	test("Typed corner seams remain present after neighboring reductions", function()
		local m = grid(4, 2)
		m = E.Attributes.create(m, "chart", "corner", "number", 0)
		for fid, face in m.faces do
			if fid >= 5 then
				for i in face.vertices do
					m.attributes.chart.values[fid .. ":" .. i] = 1
				end
			end
		end
		local out, r = S.planar(m, 0, { dissolveBoundaries = true })
		assert(r.complete and r.finalFaces == 2)
		for i in out.faces[5].vertices do
			assert(out.attributes.chart.values["5:" .. i] == 1)
		end
	end)
	test("Invalid flags, selections, limits and intersecting sources reject", function()
		local m = grid(2, 2)
		for _, angle in { -1, math.pi / 2, math.huge, 0 / 0 } do
			assert(not pcall(S.planar, m, angle))
		end
		for _, options in
			{
				{ faces = { [999] = true } },
				{ faces = { [1] = 1 } },
				{ preserveSeams = 1 },
				{ maxPlaneDeviation = -1 },
				{ maxMerges = -1 },
				{ seamAttributes = { "missing" } },
			}
		do
			assert(not pcall(S.planar, m, 0, options))
		end
		local overlap = E.Topology.join({ m, m })
		assert(not pcall(S.planar, overlap, 0))
		local _, unchecked = S.planar(overlap, 0, { checkIntersections = false })
		assert(unchecked.complete and not unchecked.intersectionChecked and not unchecked.outputIntersections)
	end)
	test("A new intersection from near-planar reduction makes the result incomplete", function()
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.new(-1, -1, 0),
				Vector3.new(1, -1, 0),
				Vector3.new(1, 1, 0),
				Vector3.new(-1, 1, 0),
				Vector3.new(0, 0, 0.2),
				Vector3.new(-0.1, 0, -0.02),
				Vector3.new(0.1, 0, -0.02),
				Vector3.new(0, 0, 0.08),
			}
		do
			m:addVertex(p)
		end
		for i = 1, 4 do
			m:addFace({ i, i % 4 + 1, 5 })
		end
		m:addFace({ 6, 7, 8 })
		local out, r = S.planar(m, 0.5, { maxPlaneDeviation = 0.25 })
		assert(r.finalFaces == 2 and out:validate().valid)
		assert(not r.complete and r.reason == "outputIntersections" and r.inputIntersections.intersectionFree)
		assert(r.outputIntersections.complete and not r.outputIntersections.intersectionFree)
		assert(not pcall(S.planar, m, 0.5, { maxPlaneDeviation = 0.25, requireComplete = true }))
	end)
	test("Planar output exports finite UVs and independent flat normals", function()
		local m = grid(3, 3)
		local out, r = S.planar(m, 0, { dissolveBoundaries = true })
		assert(r.complete)
		local handle = E.Roblox.toEditable(out)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid and count(restored.faces) == 2)
			near(area(restored), 9)
			for _, face in restored.faces do
				for _, c in face.corners do
					assert(c.uv and (c.normal - Vector3.zAxis).Magnitude < 1e-6)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
