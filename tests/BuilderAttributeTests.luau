return function(E)
	local A = E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 2e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function count(values)
		local n = 0
		for _ in values do
			n += 1
		end
		return n
	end
	local function area(mesh)
		local total = 0
		for fid in mesh.faces do
			local _, a = mesh:faceNormal(fid)
			total += a
		end
		return total
	end
	local function decorate(mesh, faceSeams)
		local out = mesh:clone()
		local values = { x = {}, cx = {}, owner = {}, edge = {}, vflag = {}, cflag = {}, fflag = {} }
		out.groups.horizontal = {}
		for id, p in out.vertices do
			values.x[id] = p.X
			values.vflag[id] = false
			out.groups.horizontal[id] = (p.X + 2) / 4
			out.weights[id] = { Left = 1 - (p.X + 2) / 4, Right = (p.X + 2) / 4 }
		end
		for fid, f in out.faces do
			values.owner[fid] = faceSeams and fid or 1
			values.fflag[fid] = false
			for i, id in f.vertices do
				values.cx[fid .. ":" .. i] = out.vertices[id].X
				values.cflag[fid .. ":" .. i] = false
				f.corners[i].uv = Vector2.new(out.vertices[id].X, faceSeams and fid or out.vertices[id].Z)
				f.corners[i].tangentSign = 1
			end
		end
		for key in E.Connectivity.index(out).edges do
			values.edge[key] = 9
		end
		for _, entry in
			{
				{ "x", "vertex", "number", 0 },
				{ "cx", "corner", "number", 0 },
				{ "owner", "face", "number", 0 },
				{ "edge", "edge", "number", 0 },
				{ "vflag", "vertex", "boolean", true },
				{ "cflag", "corner", "boolean", true },
				{ "fflag", "face", "boolean", true },
			}
		do
			out = A.set(A.create(out, entry[1], entry[2], entry[3], entry[4]), entry[1], values[entry[1]])
		end
		return out
	end
	local function checkLinear(mesh)
		assert(mesh:validate().valid)
		local restored = E.IO.decode(E.IO.encode(mesh))
		assert(#A.names(restored) == 7)
		for id, p in mesh.vertices do
			near(A.get(mesh, "x", id), p.X)
			near(mesh.groups.horizontal[id], (p.X + 2) / 4)
			near(mesh.weights[id].Right, (p.X + 2) / 4)
			near(mesh.weights[id].Left + mesh.weights[id].Right, 1)
			assert(A.get(mesh, "vflag", id) == false)
		end
		for fid, f in mesh.faces do
			assert(A.get(mesh, "fflag", fid) == false)
			for i, id in f.vertices do
				near(A.get(mesh, "cx", fid .. ":" .. i), mesh.vertices[id].X)
				near(f.corners[i].uv.X, mesh.vertices[id].X)
				assert(A.get(mesh, "cflag", fid .. ":" .. i) == false)
			end
		end
	end
	local function remeshOptions()
		return {
			maxOperations = 3,
			iterations = 1,
			flip = false,
			relaxation = 0,
			project = false,
			sharpAngle = false,
		}
	end
	test("Adaptive refinement transfers every domain and keeps false values with true defaults", function()
		local source = decorate(E.Primitives.grid(2, 1, Vector2.new(4, 2)), true)
		local before = E.IO.encode(source)
		local m, r = E.Adaptive.refine(source, 0.6, { maxOperations = 100 })
		assert(r.splits > 0)
		checkLinear(m)
		near(area(m), 8)
		for fid, f in m.faces do
			local parent = A.get(m, "owner", fid)
			assert(parent == 1 or parent == 2)
			for _, c in f.corners do
				near(c.uv.Y, parent)
			end
		end
		for key, edge in E.Connectivity.index(m).edges do
			local a, b = m.vertices[edge.a], m.vertices[edge.b]
			if a.X == b.X and (math.abs(a.X) == 2 or a.X == 0) or a.Z == b.Z and math.abs(a.Z) == 1 then
				near(A.get(m, "edge", key), 9)
			end
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Repeated local refinement keeps sparse channels valid without stale face entries", function()
		local source = decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)), false)
		local first = E.Adaptive.refine(source, 1, { maxOperations = 20 })
		local second = E.Adaptive.refine(first, 0.6, { maxOperations = 25 })
		checkLinear(second)
		near(area(second), 16)
	end)
	test("Adaptive edge collapse transports linear vertex corner group and skin fields", function()
		local source = decorate(E.Primitives.grid(4, 4, Vector2.new(4, 4)), false)
		local m, r = E.Adaptive.remesh(source, 4, remeshOptions())
		assert(r.collapses > 0 and r.splits == 0 and r.flips == 0)
		checkLinear(m)
		near(area(m), 16)
		for fid in m.faces do
			near(A.get(m, "owner", fid), 1)
		end
	end)
	test("Valence edge flips transfer face corner and surviving edge values", function()
		local source = E.Mesh.new()
		local center = source:addVertex(Vector3.zero)
		local ring = {}
		for i = 1, 10 do
			local angle = 2 * math.pi * (i - 1) / 10
			ring[i] = source:addVertex(Vector3.new(2 * math.cos(angle), 0, 2 * math.sin(angle)))
		end
		for i = 1, 10 do
			source:addFace({ center, ring[i % 10 + 1], ring[i] })
		end
		source = decorate(source, false)
		local oldEdges = E.Connectivity.index(source).edges
		local m, r = E.Adaptive.remesh(source, 1, {
			maxOperations = 20,
			iterations = 1,
			splitThreshold = 10,
			collapseThreshold = 0,
			relaxation = 0,
			project = false,
			preserveBoundary = false,
			preserveSeams = false,
			sharpAngle = false,
		})
		assert(r.flips > 0 and r.splits == 0 and r.collapses == 0)
		checkLinear(m)
		near(area(m), 20 * math.sin(math.pi / 5))
		local fresh = 0
		for key in E.Connectivity.index(m).edges do
			if oldEdges[key] then
				near(A.get(m, "edge", key), 9)
			else
				near(A.get(m, "edge", key), 0)
				fresh += 1
			end
		end
		assert(fresh > 0)
	end)
	test("Typed corner discontinuities and face boundaries protect remesh vertices by default", function()
		local source = decorate(E.Primitives.grid(4, 4, Vector2.new(4, 4)), true)
		local m, r = E.Adaptive.remesh(source, 4, remeshOptions())
		assert(r.collapses == 0 and r.flips == 0)
		for id, p in source.vertices do
			assert(m.vertices[id] == p)
		end
		for fid, f in m.faces do
			for _, c in f.corners do
				near(c.uv.Y, A.get(m, "owner", fid))
			end
		end
	end)
	test("Explicit seam edge channels keep remesh feature endpoints fixed", function()
		local source = decorate(E.Primitives.grid(4, 4, Vector2.new(4, 4)), false)
		local edgeKey = "12:13"
		source = A.set(A.create(source, "feature", "edge", "boolean", false), "feature", { [edgeKey] = true })
		local options = remeshOptions()
		options.seamAttributes = { "feature" }
		options.maxOperations = 8
		local m = E.Adaptive.remesh(source, 4, options)
		assert(m.vertices[12] == source.vertices[12] and m.vertices[13] == source.vertices[13])
		assert(E.Connectivity.index(m).edges[edgeKey] and A.get(m, "feature", edgeKey))
	end)
	test("Decimation transfers fields using the selected endpoint or midpoint location", function()
		local source = decorate(E.Primitives.sphere(2, 8, 4), false)
		local before = E.IO.encode(source)
		local m, r = E.Simplify.decimate(source, 30, { maxIterations = 20, preserveSeams = false })
		assert(r.collapses > 0 and m:validate().closed)
		checkLinear(m)
		assert(E.IO.encode(source) == before)
	end)
	test("Decimation honors typed face seams and preserves labels when seam merging is explicit", function()
		local source = decorate(E.Primitives.sphere(2, 8, 4), false)
		local labels = {}
		for fid in source.faces do
			labels[fid] = fid
		end
		source = A.set(source, "owner", labels)
		local protected, r = E.Simplify.decimate(source, 30, { maxIterations = 10 })
		assert(r.collapses == 0 and count(protected.vertices) == count(source.vertices))
		local merged, changed = E.Simplify.decimate(source, 30, { maxIterations = 10, preserveSeams = false })
		assert(changed.collapses > 0)
		checkLinear(merged)
		for fid in merged.faces do
			assert(labels[A.get(merged, "owner", fid)])
		end
	end)
	test("Decimation retains permanently sharp edge data and its endpoints", function()
		local source = decorate(E.Primitives.sphere(2, 8, 4), false)
		local index = E.Connectivity.index(source)
		local key, edge = next(index.edges)
		source =
			A.set(A.create(source, "sharp_edge", "edge", "boolean", false), "sharp_edge", { [key] = true })
		local m, r = E.Simplify.decimate(source, 30, { maxIterations = 12 })
		assert(r.collapses > 0)
		assert(
			m.vertices[edge.a] == source.vertices[edge.a] and m.vertices[edge.b] == source.vertices[edge.b]
		)
		assert(E.Connectivity.index(m).edges[key] and A.get(m, "sharp_edge", key))
	end)
	test("Shell construction transfers all domains and reverses inner corner handedness", function()
		local source = decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)), true)
		local before = E.IO.encode(source)
		local m = E.Modifiers.solidify(source, 0.4)
		assert(m:validate().closed)
		checkLinear(m)
		near(m:volume(), 6.4)
		local reverseCorners = 0
		for fid, f in m.faces do
			local parent = A.get(m, "owner", fid)
			for _, c in f.corners do
				near(c.uv.Y, parent)
				if c.tangentSign == -1 then
					reverseCorners += 1
				end
			end
		end
		assert(reverseCorners == 16)
		for key, edge in E.Connectivity.index(m).edges do
			local a, b = m.vertices[edge.a], m.vertices[edge.b]
			near(A.get(m, "edge", key), a.Y == b.Y and 9 or 0)
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Shell offset places the thickness on either side without changing transferred fields", function()
		local source = decorate(E.Primitives.grid(1, 1, Vector2.new(4, 4)), false)
		for _, offset in { -1, 0, 1 } do
			local m = E.Modifiers.solidify(source, 0.5, { offset = offset })
			checkLinear(m)
			near(m:volume(), 8)
			local lo, hi = m:bounds()
			near(lo.Y, 0.25 * (offset - 1))
			near(hi.Y, 0.25 * (offset + 1))
		end
	end)
	test("Plane clipping preserves all surviving source domains and defaults generated caps", function()
		local source = decorate(E.Primitives.box(Vector3.one * 4), true)
		local before = E.IO.encode(source)
		local m = E.Modifiers.clipPlane(source, Vector3.new(0.5, 0, 0), Vector3.xAxis)
		assert(m:validate().closed)
		near(m:volume(), 40)
		for id, p in m.vertices do
			near(A.get(m, "x", id), p.X)
			near(m.weights[id].Right, (p.X + 2) / 4)
			near(m.groups.horizontal[id], (p.X + 2) / 4)
		end
		local caps = 0
		for fid, f in m.faces do
			local parent = A.get(m, "owner", fid)
			if parent == 0 then
				caps += 1
				assert(A.get(m, "fflag", fid) == true)
				for i, id in f.vertices do
					near(m.vertices[id].X, 0.5)
					near(A.get(m, "cx", fid .. ":" .. i), 0)
					assert(A.get(m, "cflag", fid .. ":" .. i))
				end
			else
				for i, id in f.vertices do
					near(A.get(m, "cx", fid .. ":" .. i), m.vertices[id].X)
					near(f.corners[i].uv.Y, parent)
				end
			end
		end
		assert(caps > 0 and E.IO.encode(source) == before)
	end)
	test("Plane clip convenience handles disconnected closed components and empty schemas", function()
		local a = E.Primitives.box()
		local b = E.Deform.transform(a, CFrame.new(0, 4, 0))
		local source = decorate(E.Topology.join({ a, b }), false)
		local m = E.Modifiers.clipPlane(source, Vector3.zero, Vector3.xAxis)
		assert(m:validate().closed and m:validate().surfaceComponents == 2)
		near(m:volume(), 8)
		local empty = E.Modifiers.clipPlane(source, Vector3.new(-3, 0, 0), Vector3.xAxis)
		assert(not next(empty.faces) and #A.names(empty) == 7)
		assert(not next(E.IO.decode(E.IO.encode(empty)).faces))
	end)
	test("Open plane clipping retains boundary corner fields when capping is disabled", function()
		local source = decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)), false)
		local m = E.Modifiers.clipPlane(source, Vector3.new(0.5, 0, 0), Vector3.xAxis, false)
		checkLinear(m)
		near(area(m), 10)
		assert(not m:validate().closed)
	end)
	test("Array mirror and convex bevel compose with typed builder transfer", function()
		local source = decorate(E.Primitives.box(), false)
		local repeated = E.Modifiers.array(source, 2, CFrame.new(4, 0, 0))
		assert(#A.names(repeated) == 7 and repeated:validate().closed)
		local mirrored = E.Modifiers.mirror(source, "X")
		assert(#A.names(mirrored) == 7 and mirrored:validate().valid)
		local beveled = E.Modifiers.bevelConvex(source, 0.1)
		assert(#A.names(beveled) == 7 and beveled:validate().closed)
		assert(beveled:volume() > 0 and beveled:volume() < 8)
	end)
	test("UV tile cuts transfer all domains groups and skin while remapping only intrinsic UVs", function()
		local source = decorate(E.Primitives.grid(1, 1, Vector2.new(4, 4)), false)
		for _, f in source.faces do
			for i, id in f.vertices do
				local p = source.vertices[id]
				f.corners[i].uv = Vector2.new((p.X + 2) / 4, (p.Z + 2) / 4)
			end
		end
		local before, total = E.IO.encode(source), 0
		local tiles = E.UV.splitTiles(source, 2, 3)
		assert(#tiles == 6)
		for _, tile in tiles do
			local m = tile.mesh
			assert(m:validate().valid and #A.names(E.IO.decode(E.IO.encode(m))) == 7)
			total += area(m)
			for id, p in m.vertices do
				near(A.get(m, "x", id), p.X)
				near(m.groups.horizontal[id], (p.X + 2) / 4)
				near(m.weights[id].Right, (p.X + 2) / 4)
				assert(A.get(m, "vflag", id) == false)
			end
			for fid, f in m.faces do
				assert(
					f.material == tile.tile
						and A.get(m, "owner", fid) == 1
						and A.get(m, "fflag", fid) == false
				)
				for i, id in f.vertices do
					local p, c = m.vertices[id], f.corners[i]
					near(A.get(m, "cx", fid .. ":" .. i), p.X)
					near(c.uv.X, (p.X + 2) / 2 - tile.column)
					near(c.uv.Y, (p.Z + 2) * 3 / 4 - tile.row)
					assert(A.get(m, "cflag", fid .. ":" .. i) == false)
				end
			end
			for key, edge in E.Connectivity.index(m).edges do
				local a, b = m.vertices[edge.a], m.vertices[edge.b]
				local perimeter = a.X == b.X and math.abs(a.X) == 2 or a.Z == b.Z and math.abs(a.Z) == 2
				near(A.get(m, "edge", key), perimeter and 9 or 0)
			end
		end
		near(total, 16)
		assert(E.IO.encode(source) == before)
	end)
	test("UV tile interpolation retains categorical face charts at shared geometric vertices", function()
		local source = decorate(E.Primitives.grid(2, 1, Vector2.new(4, 4)), true)
		local labels = {}
		for fid, f in source.faces do
			for i, id in f.vertices do
				local p = source.vertices[id]
				f.corners[i].uv = Vector2.new((p.X + 2) / 4, (p.Z + 2) / 4)
				f.corners[i].chart = "chart" .. fid
				labels[fid .. ":" .. i] = "chart" .. fid
			end
		end
		source = A.set(A.create(source, "chart", "corner", "string", ""), "chart", labels)
		local total = 0
		for _, tile in E.UV.splitTiles(source, 3, 3) do
			local m = tile.mesh
			assert(m:validate().valid and #A.names(m) == 8)
			total += area(m)
			for fid, f in m.faces do
				local expected = "chart" .. A.get(m, "owner", fid)
				for i, c in f.corners do
					assert(c.chart == expected and A.get(m, "chart", fid .. ":" .. i) == expected)
				end
			end
		end
		near(total, 16)
	end)
	test("Material and triangle partitions retain source correspondence and default new diagonals", function()
		local source = decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)), true)
		for fid, f in source.faces do
			f.material = fid % 2 + 1
		end
		local before, total = E.IO.encode(source), 0
		local sourceEdges = E.Connectivity.index(source).edges
		local chunks = E.Roblox.partition(source, 1)
		assert(#chunks == 8)
		for _, chunk in chunks do
			local m = chunk.mesh
			checkLinear(m)
			assert(count(m.faces) == 1)
			total += area(m)
			for id, old in chunk.sourceVertices do
				assert(m.vertices[id] == source.vertices[old])
			end
			for fid, f in m.faces do
				local owner = A.get(m, "owner", fid)
				assert(f.material == source.faces[owner].material and chunk.material == f.material)
				for _, c in f.corners do
					near(c.uv.Y, owner)
				end
			end
			for key, edge in E.Connectivity.index(m).edges do
				local a, b = chunk.sourceVertices[edge.a], chunk.sourceVertices[edge.b]
				local old = math.min(a, b) .. ":" .. math.max(a, b)
				near(A.get(m, "edge", key), sourceEdges[old] and 9 or 0)
			end
		end
		near(total, 16)
		assert(E.IO.encode(source) == before)
	end)
	test("UV tile budgets and cancellation are transactional", function()
		local source = E.UV.faceCharts(decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)), true))
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxTiles = 2 },
				{ maxWork = 2 },
				{ maxVertices = 2 },
				{ maxFaces = 2 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function()
						error("cancel tiles")
					end,
				},
			}
		do
			assert(not pcall(E.UV.splitTiles, source, 3, 3, options))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Builder allocation and cancellation failures leave every source channel unchanged", function()
		local source = decorate(E.Primitives.grid(4, 4, Vector2.new(4, 4)), false)
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxVertices = 2 },
				{ maxFaces = 2 },
				{ maxWork = 2 },
				{ offset = 2 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function()
						error("cancel shell")
					end,
				},
			}
		do
			assert(not pcall(E.Modifiers.solidify, source, 0.2, options))
		end
		assert(not pcall(E.Adaptive.refine, source, 0.1, {
			cancelled = function()
				return true
			end,
		}))
		assert(not pcall(E.Adaptive.remesh, source, 4, {
			cancelled = function()
				return true
			end,
		}))
		assert(not pcall(E.Simplify.decimate, source, 4, {
			cancelled = function()
				return true
			end,
		}))
		assert(not pcall(E.Modifiers.clipPlane, source, Vector3.zero, Vector3.xAxis, false, {
			checkpoint = function()
				error("cancel clip")
			end,
		}))
		assert(E.IO.encode(source) == before)
	end)
	test("Refined shelled and clipped geometry retains native EditableMesh topology and UVs", function()
		local source = decorate(E.Primitives.grid(2, 2, Vector2.new(4, 4)), false)
		local rig = E.Rig.new()
		local left, right = rig:addBone("Left"), rig:addBone("Right")
		for id, weights in source.weights do
			source.weights[id] = { [left] = weights.Left, [right] = weights.Right }
		end
		local refined = E.Adaptive.refine(source, 1, { maxOperations = 20 })
		local shell = E.Modifiers.solidify(refined, 0.4)
		local mesh = E.Modifiers.clipPlane(shell, Vector3.zero, Vector3.xAxis)
		assert(mesh:validate().closed)
		near(mesh:volume(), 3.2)
		local handle = E.Roblox.toEditable(mesh, { rig = rig })
		local ok, err = pcall(function()
			local restored, _, importedRig = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), 3.2)
			for id, p in restored.vertices do
				local total = 0
				for bone, weight in restored.weights[id] do
					total += weight
					if importedRig.bones[bone].name == "Right" then
						near(weight, (p.X + handle.origin.X + 2) / 4)
					end
				end
				near(total, 1)
			end
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
