return function(E)
	local M, A, R = E.MeshEdit, E.Attributes, E.MeshRepair
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
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function all(mesh)
		local s = {}
		for fid in mesh.faces do
			s[fid] = true
		end
		return s
	end
	local function annotated()
		local mesh = E.Primitives.grid(2, 3, Vector2.new(2, 3))
		local heat, stamp, zone = {}, {}, {}
		for id, p in mesh.vertices do
			heat[id] = p.X + 2
			mesh.weights[id] = { A = (p.X + 1) / 2, B = (1 - p.X) / 2 }
		end
		mesh.groups.pick = {}
		for id, p in mesh.vertices do
			mesh.groups.pick[id] = (p.X + 1) / 2
		end
		for fid, f in mesh.faces do
			zone[fid] = fid
			for i, c in f.corners do
				stamp[fid .. ":" .. i] = fid
				if fid == 3 then
					c.uv += Vector2.new(5, 0)
				end
			end
		end
		mesh = A.set(A.create(mesh, "heat", "vertex", "number", 0), "heat", heat)
		mesh = A.set(A.create(mesh, "stamp", "corner", "number", 0), "stamp", stamp)
		mesh = A.set(A.create(mesh, "zone", "face", "number", 0), "zone", zone)
		mesh = A.set(A.create(mesh, "marked", "edge", "boolean", false, "max"), "marked", { ["1:2"] = true })
		return mesh
	end
	test("Loop cuts preserve grid area Euler characteristic and conforming quad strips", function()
		local source = E.Primitives.grid(2, 3, Vector2.new(2, 3))
		local mesh, r = M.loopCut(source, "1:2", { 0.25, 0.75 })
		assert(mesh:validate().valid and count(mesh.vertices) == 20 and count(mesh.faces) == 12)
		assert(mesh:validate().eulerCharacteristic == 1 and #r.ring.faces == 3 and #r.loops == 2)
		for j, loop in r.loops do
			for _, id in loop do
				near(mesh.vertices[id].X, j == 1 and -0.75 or -0.25)
			end
		end
		local area = 0
		for fid in mesh.faces do
			local _, a = mesh:faceNormal(fid)
			area += a
		end
		near(area, 6)
		assert(count(source.vertices) == 12 and count(source.faces) == 6)
	end)
	test("Loop cuts interpolate vertex skin group and typed values while retaining corner seams", function()
		local source = annotated()
		local mesh, r = M.loopCut(source, "1:2", { 0.25, 0.75 })
		for _, id in r.addedVertices do
			near(A.get(mesh, "heat", id), mesh.vertices[id].X + 2)
			near(mesh.weights[id].A, (mesh.vertices[id].X + 1) / 2)
			near(mesh.groups.pick[id], mesh.weights[id].A)
		end
		for fid, descendants in r.faceMap do
			for _, nf in descendants do
				near(A.get(mesh, "zone", nf), fid)
				for i, c in mesh.faces[nf].corners do
					near(A.get(mesh, "stamp", nf .. ":" .. i), fid)
					if fid == 3 then
						assert(c.uv.X >= 5)
					else
						assert(c.uv.X <= 1)
					end
				end
			end
		end
		local marked = 0
		for _, v in mesh.attributes.marked.values do
			if v then
				marked += 1
			end
		end
		assert(marked == 3 and not mesh:topology().edges["1:2"])
	end)
	test("Closed loop cuts retain watertight box volume and ordered closed cut loops", function()
		local source = E.Primitives.box()
		local mesh, r = M.loopCut(source, "1:2", 3)
		assert(mesh:validate().closed and r.ring.closed and #r.ring.edges == 4)
		near(mesh:volume(), source:volume())
		for _, loop in r.loops do
			assert(#loop == 4)
			for i, id in loop do
				local other = loop[i % #loop + 1]
				local key = id < other and id .. ":" .. other or other .. ":" .. id
				assert(mesh:topology().edges[key])
			end
		end
	end)
	test("Loop cuts split terminal non-quad boundaries without creating T junctions", function()
		local source = E.Primitives.grid(1, 1, Vector2.new(2, 2))
		local id = source:addVertex(Vector3.new(0, 0, 3))
		source:addFace({ 3, id, 4 })
		local mesh, r = M.loopCut(source, "1:2", 2)
		assert(mesh:validate().valid and not r.ring.closed and #mesh.faces[2].vertices == 5)
		assert(mesh:validate().eulerCharacteristic == 1 and #mesh:faceTriangles(2) == 3)
	end)
	test("Loop cut counts order limits and cancellation are atomic", function()
		local source = annotated()
		local before = E.IO.encode(source)
		for _, fn in
			{
				function()
					M.loopCut(source, "1:99", 1)
				end,
				function()
					M.loopCut(source, "1:2", { 0.8, 0.2 })
				end,
				function()
					M.loopCut(source, "1:2", { 0, 0.5 })
				end,
				function()
					M.loopCut(source, "1:2", 129)
				end,
				function()
					M.loopCut(source, "1:2", 2, { maxVertices = 13 })
				end,
				function()
					M.loopCut(source, "1:2", 2, { maxFaces = 6 })
				end,
				function()
					M.loopCut(source, "1:2", 1, { maxSteps = 1 })
				end,
				function()
					M.loopCut(source, "1:2", 1, {
						checkpoint = function()
							error("cancelled")
						end,
					})
				end,
			}
		do
			assert(not pcall(fn))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Individual extrusion gives separate face tops and predictable added solid volume", function()
		local source = E.Primitives.box()
		local mesh, r = M.extrudeFaces(source, { [5] = true }, 0.5)
		assert(mesh:validate().closed and #r.addedVertices == 4 and #r.sides[5] == 4)
		near(mesh:volume(), 10)
		for _, id in r.tops[5] do
			near(mesh.vertices[id].Y, 1.5)
		end
		near(source:volume(), 8)
	end)
	test("Adjacent individual extrusions retain distinct vertices and inherited face metadata", function()
		local source = annotated()
		local mesh, r = M.extrudeFaces(source, { [1] = true, [2] = true }, 0.4)
		assert(mesh:validate().valid and #r.addedVertices == 8)
		local ids = {}
		for _, top in r.tops do
			for _, id in top do
				assert(not ids[id])
				ids[id] = true
			end
		end
		for fid, sides in r.sides do
			for _, side in sides do
				near(A.get(mesh, "zone", side), fid)
				for i in mesh.faces[side].corners do
					near(A.get(mesh, "stamp", side .. ":" .. i), fid)
				end
			end
		end
	end)
	test("Extrusion preserves copied skin groups attributes and selected face IDs", function()
		local source = annotated()
		local mesh, r = M.extrudeFaces(source, { [1] = 1, [2] = 0 }, -0.25)
		assert(mesh.faces[1] and not r.tops[2])
		for i, id in r.tops[1] do
			local old = source.faces[1].vertices[i]
			near(A.get(mesh, "heat", id), A.get(source, "heat", old))
			near(mesh.groups.pick[id], source.groups.pick[old])
			near(mesh.weights[id].A, source.weights[old].A)
		end
		assert(not pcall(M.extrudeFaces, source, { [1] = true }, 0))
	end)
	test("Poke preserves planar area and closed volume with an independent pyramid offset", function()
		local source = E.Primitives.box()
		local flat, r = M.poke(source, { [5] = true })
		assert(flat:validate().closed and #r.faceMap[5] == 4)
		near(flat:volume(), 8)
		local raised = M.poke(source, { [5] = true }, { offset = 1 })
		near(raised:volume(), 8 + 4 / 3)
	end)
	test("Poke center interpolation retains typed corners skin weights groups and material", function()
		local source = annotated()
		local mesh, r = M.poke(source, { [3] = true }, { center = "area" })
		local id = r.centers[3]
		near(A.get(mesh, "heat", id), 1.5)
		near(mesh.weights[id].A, 0.25)
		near(mesh.groups.pick[id], 0.25)
		for _, fid in r.faceMap[3] do
			near(A.get(mesh, "zone", fid), 3)
			for i, c in mesh.faces[fid].corners do
				near(A.get(mesh, "stamp", fid .. ":" .. i), 3)
				assert(c.uv.X >= 5)
			end
		end
	end)
	test("Poke rejects a centroid outside a concave polygon's strict kernel", function()
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.new(0, 0, 0),
				Vector3.new(3, 0, 0),
				Vector3.new(3, 1, 0),
				Vector3.new(1, 1, 0),
				Vector3.new(1, 3, 0),
				Vector3.new(0, 3, 0),
			}
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3, 4, 5, 6 })
		assert(not pcall(M.poke, m, { [1] = true }))
		assert(count(m.vertices) == 6 and count(m.faces) == 1)
	end)
	test("Vertex slides evaluate simultaneously and retain attached data", function()
		local source = annotated()
		local mesh = M.slideVertices(source, { [2] = 3, [5] = 6, [8] = 9, [11] = 12 }, 0.25)
		for _, id in { 2, 5, 8, 11 } do
			near(mesh.vertices[id].X, 0.25)
			near(A.get(mesh, "heat", id), A.get(source, "heat", id))
		end
		assert(mesh:validate().valid and E.IO.encode(source) ~= E.IO.encode(mesh))
		assert(not pcall(M.slideVertices, source, { [1] = 12 }, 0.5))
		assert(not pcall(M.slideVertices, source, { [1] = 2 }, 1))
		assert(not pcall(M.slideVertices, E.Primitives.grid(1, 1), { [1] = 2, [2] = 1 }, 0.75))
	end)
	test("Triangle pairing reconstructs a planar quad grid with stable surviving face IDs", function()
		local source = E.Primitives.grid(3, 2)
		local triangles = E.Topology.triangulate(source)
		local quads, r = M.trianglesToQuads(triangles, all(triangles))
		assert(#r.pairs == 6 and count(quads.faces) == 6 and quads:validate().valid)
		for _, face in quads.faces do
			assert(#face.vertices == 4)
		end
		for _, pair in r.pairs do
			assert(pair.result == math.min(pair.faces[1], pair.faces[2]))
		end
	end)
	test("Triangle pairing preserves explicit edge face material and corner delimiters", function()
		local base = E.Topology.triangulate(E.Primitives.grid(1, 1))
		local shared
		for key, e in base:topology().edges do
			if #e.faces == 2 then
				shared = key
			end
		end
		local marked = A.set(A.create(base, "crease", "edge", "number", 0), "crease", { [shared] = 1 })
		local _, r = M.trianglesToQuads(marked, all(marked))
		assert(#r.pairs == 0 and r.rejected.attributes)
		local faces =
			A.set(A.create(base, "region", "face", "string", ""), "region", { [1] = "A", [2] = "B" })
		_, r = M.trianglesToQuads(faces, all(faces))
		assert(#r.pairs == 0)
		local seam = base:clone()
		seam.faces[2].corners[1].uv += Vector2.one
		_, r = M.trianglesToQuads(seam, all(seam))
		assert(#r.pairs == 0)
		local materials = base:clone()
		materials.faces[2].material = 3
		_, r = M.trianglesToQuads(materials, all(materials))
		assert(#r.pairs == 0 and r.rejected.material)
	end)
	test("Explicit triangle attribute merging uses area weights and preserves sparse schemas", function()
		local source = E.Topology.triangulate(E.Primitives.grid(1, 1))
		source = A.set(A.create(source, "region", "face", "number", 0), "region", { [1] = 2, [2] = 6 })
		local mesh, r = M.trianglesToQuads(source, all(source), { delimitAttributes = false })
		assert(#r.pairs == 1)
		near(A.get(mesh, "region", r.pairs[1].result), 4)
		assert(mesh:validate().valid)
	end)
	test("Triangle pairing rejects concave joins and keeps sharp folds separate", function()
		local m = E.Mesh.new()
		for _, p in
			{ Vector3.new(0, 0, 0), Vector3.new(2, 0, 0), Vector3.new(0.3, 0.3, 0), Vector3.new(0, 2, 0) }
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 1, 3, 4 })
		local _, r = M.trianglesToQuads(m, all(m))
		assert(#r.pairs == 0 and r.rejected.shape)
		local box = E.Topology.triangulate(E.Primitives.box())
		local mesh, joined = M.trianglesToQuads(box, all(box))
		assert(#joined.pairs == 6 and mesh:validate().closed)
		near(mesh:volume(), 8)
	end)
	test("Winding repair restores independently flipped closed faces and their corner attributes", function()
		local source = E.Primitives.box()
		local values = {}
		for fid, f in source.faces do
			for i, v in f.vertices do
				values[fid .. ":" .. i] = v
			end
		end
		source = A.set(A.create(source, "vertexLabel", "corner", "number", 0), "vertexLabel", values)
		local f = source.faces[3]
		local v, c = {}, {}
		for i = 4, 1, -1 do
			table.insert(v, f.vertices[i])
			table.insert(c, f.corners[i])
		end
		f.vertices, f.corners = v, c
		for i, id in v do
			source.attributes.vertexLabel.values["3:" .. i] = id
		end
		assert(not source:validate().valid)
		local mesh, r = R.orient(source)
		assert(r.complete and mesh:validate().closed and r.flipped[3])
		near(mesh:volume(), 8)
		for fid, face in mesh.faces do
			for i, id in face.vertices do
				near(A.get(mesh, "vertexLabel", fid .. ":" .. i), id)
			end
		end
	end)
	test("Winding repair handles disconnected inward shells and consistent open boundaries", function()
		local a = E.Topology.reverse(E.Primitives.box())
		local b = E.Deform.transform(E.Primitives.box(), CFrame.new(1000, 0, 0))
		local mesh, r = R.orient(E.Topology.join({ a, b }))
		assert(r.complete and #r.components == 2)
		near(mesh:volume(), 16)
		local open = E.Primitives.grid(2, 1)
		local f = open.faces[2]
		local vs, cs = {}, {}
		for i = 4, 1, -1 do
			table.insert(vs, f.vertices[i])
			table.insert(cs, f.corners[i])
		end
		f.vertices, f.corners = vs, cs
		local fixed, rr = R.orient(open)
		assert(rr.complete and not fixed:validate().closed)
		for fid in fixed.faces do
			assert(fixed:faceNormal(fid).Y > 0.99)
		end
	end)
	test("Winding repair rejects nonorientable strips nonmanifold edges and exhausted work", function()
		local m = E.Mesh.new()
		for i = 0, 4 do
			m:addVertex(Vector3.new(i, 0, 0))
			m:addVertex(Vector3.new(i, 1, 0))
		end
		for i = 0, 3 do
			m:addFace({ i * 2 + 1, i * 2 + 2, i * 2 + 4, i * 2 + 3 })
		end
		m:addFace({ 9, 10, 1, 2 })
		assert(not pcall(R.orient, m))
		assert(not pcall(R.orient, E.Primitives.box(), { maxWork = 1 }))
		local b = E.Primitives.box()
		b:addFace({ 1, 2, 3 })
		assert(not pcall(R.orient, b))
	end)
	test("Cleanup removes malformed duplicate degenerate and loose elements with a report", function()
		local m = E.Primitives.grid(1, 1)
		local original = m.faces[1]
		m:addFace({ 2, 4, 3, 1 })
		local a = m:addVertex(Vector3.new(5, 0, 0))
		local b = m:addVertex(Vector3.new(6, 0, 0))
		local c = m:addVertex(Vector3.new(7, 0, 0))
		m:addFace({ a, b, c })
		m:addFace({ 1, a, b })
		m.faces[4].vertices[3] = 999
		m:addVertex(Vector3.new(8, 8, 8))
		m.weights[999] = { Ghost = 1 }
		m.groups.stale = { [999] = 1 }
		local clean, r = R.clean(m)
		assert(r.complete and count(clean.faces) == 1 and count(clean.vertices) == 4)
		assert(not clean.weights[999] and not clean.groups.stale[999])
		assert(
			r.removedFaces[2] == "duplicate"
				and r.removedFaces[3] == "zero_area"
				and r.removedFaces[4] == "invalid_vertex"
		)
		assert(#original.vertices == 4 and count(m.faces) == 4)
	end)
	test("Cleanup preserves retained channels and reports unresolved touching surface fans", function()
		local m = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.xAxis, Vector3.yAxis, -Vector3.xAxis, -Vector3.yAxis } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 1, 4, 5 })
		m = A.set(A.create(m, "label", "face", "string", "empty"), "label", { [1] = "A", [2] = "B" })
		local clean, r = R.clean(m)
		assert(not r.complete and r.validation.nonmanifoldVertices == 1)
		assert(A.get(clean, "label", 1) == "A" and A.get(clean, "label", 2) == "B")
	end)
	test("Modeled cut poke and extrusion compose through native EditableMesh conversion", function()
		local mesh = M.loopCut(E.Primitives.box(), "1:2", 2)
		mesh = M.poke(mesh, { [5] = true }, { offset = 0.2 })
		mesh = M.extrudeFaces(mesh, { [1] = true }, 0.15)
		assert(mesh:validate().closed)
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), mesh:volume(), 1e-4)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Region inset shrinks a connected patch as one region and preserves total area", function()
		local source = E.Primitives.grid(2, 2, Vector2.new(4, 4))
		local mesh, r = M.insetRegion(source, all(source), 0.2)
		assert(r.planarChecks and count(r.insetVertices) == 8 and #r.sides == 8)
		assert(count(mesh.vertices) == 17 and count(mesh.faces) == 12 and mesh:validate().valid)
		local inner, area = 0, 0
		for fid in mesh.faces do
			local _, a = mesh:faceNormal(fid)
			area += a
			if source.faces[fid] then
				inner += a
			end
		end
		near(inner, 3.6 ^ 2)
		near(area, 16)
		assert(mesh.vertices[5] == source.vertices[5])
	end)
	test("Region inset preserves holes and offset direction on both boundary orientations", function()
		local source = E.Primitives.grid(3, 3, Vector2.new(3, 3))
		source:removeFace(5)
		local mesh, r = M.insetRegion(source, all(source), 0.1)
		assert(#r.boundaryLoops == 2 and #r.sides == 16 and r.planarChecks)
		assert(mesh:validate().valid and mesh:validate().eulerCharacteristic == 0)
		local inner = 0
		for fid in source.faces do
			local _, a = mesh:faceNormal(fid)
			inner += a
		end
		near(inner, 2.8 ^ 2 - 1.2 ^ 2)
	end)
	test("Region inset depth produces the independent square frustum volume", function()
		local source = E.Primitives.box()
		local mesh, r = M.insetRegion(source, { [5] = true }, 0.2, { depth = 0.3 })
		assert(mesh:validate().closed and r.planarChecks)
		near(mesh:volume(), 8 + 0.3 * (4 + 2.56 + 3.2) / 3)
		local frame = CFrame.new(8, 9, 10) * CFrame.Angles(0.3, 0.7, 0.2)
		local tilted = E.Deform.transform(source, frame)
		local moved = M.insetRegion(tilted, { [5] = true }, 0.2, { depth = 0.3 })
		near(moved:volume(), mesh:volume(), 0.0001)
	end)
	test("Region inset retains typed inherited boundary data skin and UV discontinuities", function()
		local source = annotated()
		local mesh, r = M.insetRegion(source, { [1] = true, [3] = true, [5] = true }, 0.1)
		for old, new in r.insetVertices do
			near(A.get(mesh, "heat", new), A.get(source, "heat", old))
			near(mesh.weights[new].A, source.weights[old].A)
			near(mesh.groups.pick[new], source.groups.pick[old])
		end
		for i, c in mesh.faces[3].corners do
			assert(c.uv.X >= 5)
			near(A.get(mesh, "stamp", "3:" .. i), 3)
		end
		assert(mesh:validate().valid)
	end)
	test("Region inset supports nonplanar connected surface patches with explicit diagnostics", function()
		local mesh, r = M.insetRegion(E.Primitives.box(), { [4] = true, [5] = true }, 0.1)
		assert(mesh:validate().closed and not r.planarChecks and #r.boundaryLoops == 1)
	end)
	test("Inset rejects crossing collapsed or ambiguous boundaries and bounded work", function()
		local source = E.Primitives.grid(2, 2, Vector2.new(4, 4))
		local before = E.IO.encode(source)
		for _, fn in
			{
				function()
					M.insetRegion(source, all(source), 3)
				end,
				function()
					M.insetRegion(source, { [1] = true, [4] = true }, 0.1)
				end,
				function()
					M.insetRegion(source, all(source), 0.1, { miterLimit = 1 })
				end,
				function()
					M.insetRegion(source, all(source), 0.1, { maxBoundaryVertices = 4 })
				end,
				function()
					M.insetRegion(source, all(source), 0.1, { maxWork = 1 })
				end,
				function()
					M.insetRegion(source, all(source), 0.1, {
						checkpoint = function()
							error("cancel")
						end,
					})
				end,
			}
		do
			assert(not pcall(fn))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Empty and fully closed inset selections do not invent a boundary", function()
		local source = E.Primitives.box()
		local unchanged, r = M.insetRegion(source, {}, 0.1)
		assert(#r.addedFaces == 0 and #r.addedVertices == 0)
		near(unchanged:volume(), 8)
		local closed, rr = M.insetRegion(source, all(source), 0.1)
		assert(#rr.boundaryLoops == 0 and count(closed.faces) == 6)
		near(closed:volume(), 8)
	end)
	test("Mesh modeling commutes with uniform scale and representable world translations", function()
		local source = E.Primitives.box()
		local reference = M.insetRegion(source, { [5] = true }, 0.1, { depth = 0.2 })
		reference = M.loopCut(reference, "1:2", { 0.3, 0.7 })
		for _, scale in { 0.01, 1, 100 } do
			local frame = CFrame.new(Vector3.new(8, 4, -16) * scale)
			local transformed = E.Deform.transform(source, frame, Vector3.one * scale)
			local mesh = M.insetRegion(transformed, { [5] = true }, 0.1 * scale, { depth = 0.2 * scale })
			mesh = M.loopCut(mesh, "1:2", { 0.3, 0.7 })
			assert(mesh:validate().closed)
			for id, p in mesh.vertices do
				assert(
					(p - frame:PointToWorldSpace(reference.vertices[id] * scale)).Magnitude < scale * 0.00002
				)
			end
			near(mesh:volume() / scale ^ 3, reference:volume(), 0.0001)
		end
	end)
	report.success = report.failed == 0
	return report
end
