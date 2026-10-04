return function(E)
	local N, A = E.Normals, E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, e)
		assert(math.abs(a - b) < (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function vector(a, b, e)
		assert((a - b).Magnitude < (e or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function cornersAt(m, v, callback)
		for fid, f in m.faces do
			for i, id in f.vertices do
				if id == v then
					callback(f.corners[i], fid, i)
				end
			end
		end
	end
	test("Uniform and area normal weights match independent anisotropic-box formulas", function()
		local source = E.Primitives.box(Vector3.new(6, 4, 2))
		local uniform = N.recalculate(source, { weighting = "uniform" })
		cornersAt(uniform, 7, function(c)
			vector(c.normal, Vector3.one.Unit)
		end)
		local area = N.recalculate(source, { weighting = "area" })
		cornersAt(area, 7, function(c)
			vector(c.normal, Vector3.new(8, 12, 24).Unit)
		end)
		local angle = N.recalculate(source, { weighting = "angle" })
		cornersAt(angle, 7, function(c)
			vector(c.normal, Vector3.one.Unit)
		end)
		local combined = N.recalculate(source, { weighting = "areaAngle" })
		cornersAt(combined, 7, function(c)
			vector(c.normal, Vector3.new(8, 12, 24).Unit)
		end)
	end)
	test("Dihedral limits split cube normals and preserve connected smooth cylinder sides", function()
		local box = N.recalculate(E.Primitives.box(), { angle = math.pi / 4 })
		for fid, f in box.faces do
			for _, c in f.corners do
				vector(c.normal, box:faceNormal(fid))
			end
		end
		local cylinder =
			N.recalculate(E.Primitives.cylinder(2, 3, 16), { angle = math.pi / 4, weighting = "angle" })
		for fid, f in cylinder.faces do
			local normal = cylinder:faceNormal(fid)
			for i, c in f.corners do
				if math.abs(normal.Y) > 0.9 then
					vector(c.normal, normal)
				else
					local p = cylinder.vertices[f.vertices[i]]
					vector(c.normal, Vector3.new(p.X, 0, p.Z).Unit, 1e-4)
				end
			end
		end
	end)
	test("Face strengths restrict fan contributors and explicit multipliers change weighting", function()
		local source = E.Primitives.box()
		local strong = N.recalculate(source, { faceStrength = { [5] = 2 }, weighting = "uniform" })
		cornersAt(strong, 7, function(c)
			vector(c.normal, Vector3.yAxis)
		end)
		local weighted = N.recalculate(source, { faceWeights = { [5] = 4 }, weighting = "uniform" })
		cornersAt(weighted, 7, function(c)
			vector(c.normal, Vector3.new(1, 4, 1).Unit)
		end)
		local zeroth =
			N.recalculate(E.Primitives.box(Vector3.new(6, 4, 2)), { weighting = "area", power = 0 })
		cornersAt(zeroth, 7, function(c)
			vector(c.normal, Vector3.one.Unit)
		end)
	end)
	test("Sharp edge editing persists typed booleans and supports true-default clearing", function()
		local source = E.Primitives.box()
		local edges = {}
		for key in source:topology().edges do
			edges[key] = true
		end
		local sharp = N.markSharp(source, edges)
		for fid, f in sharp.faces do
			for _, c in f.corners do
				vector(c.normal, sharp:faceNormal(fid))
			end
		end
		assert(source.attributes.sharp_edge == nil)
		local default = A.create(source, "sharp_edge", "edge", "boolean", true)
		local clear = {}
		for key in source:topology().edges do
			clear[key] = false
		end
		local smooth = N.markSharp(default, clear, { weighting = "uniform" })
		for key in clear do
			assert(A.get(smooth, "sharp_edge", key) == false)
		end
		cornersAt(smooth, 7, function(c)
			vector(c.normal, Vector3.one.Unit)
		end)
	end)
	test("Corner masks and mix blend only requested normals and keep geometry metadata unchanged", function()
		local source = E.Primitives.grid(1, 1)
		source.weights[1] = { A = 0.4 }
		source.groups.g = { [1] = 0.7 }
		source = A.set(A.create(source, "tag", "face", "string", ""), "tag", { [1] = "front" })
		local before = E.IO.encode(source)
		local mesh, r = N.direction(source, Vector3.xAxis, { mask = { ["1:1"] = 0.5, ["1:2"] = false } })
		vector(mesh.faces[1].corners[1].normal, Vector3.new(1, 1, 0).Unit)
		for i = 2, 4 do
			vector(mesh.faces[1].corners[i].normal, Vector3.yAxis)
		end
		assert(
			r.changedCorners == 1
				and mesh.weights[1].A == 0.4
				and mesh.groups.g[1] == 0.7
				and A.get(mesh, "tag", 1) == "front"
		)
		for id, p in source.vertices do
			assert(mesh.vertices[id] == p)
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Custom normal dictionaries validate targets and normalize extreme finite vectors", function()
		local source = E.Primitives.grid(1, 1)
		local mesh =
			N.set(source, { ["1:1"] = Vector3.new(1e30, 1e30, 0), ["1:2"] = Vector3.new(1e-30, 0, 0) })
		vector(mesh.faces[1].corners[1].normal, Vector3.new(1, 1, 0).Unit)
		vector(mesh.faces[1].corners[2].normal, Vector3.xAxis)
		assert(not pcall(N.set, source, { ["9:1"] = Vector3.xAxis }))
		assert(not pcall(N.set, source, { ["1:1"] = Vector3.zero }))
		assert(not pcall(N.direction, source, -Vector3.yAxis, { mix = 0.5 }))
	end)
	test("Normal point edits support inward outward and explicit coincident behavior", function()
		local source = E.Primitives.box()
		local outward = N.point(source, Vector3.zero, { direction = "away" })
		local inward = N.point(source, Vector3.zero)
		for fid, f in outward.faces do
			for i, id in f.vertices do
				vector(f.corners[i].normal, source.vertices[id].Unit)
				vector(inward.faces[fid].corners[i].normal, -source.vertices[id].Unit)
			end
		end
		assert(not pcall(N.point, source, source.vertices[1]))
		local keep, r = N.point(source, source.vertices[1], { coincident = "keep" })
		assert(r.coincidentCorners == 3 and keep:validate().valid)
		assert(pcall(N.point, source, source.vertices[1], { mask = { ["2:1"] = true } }))
	end)
	test("Normal rotations ignore translation and flips retain face winding", function()
		local source = E.Primitives.grid(1, 1)
		local rotation = CFrame.new(100, 200, 300) * CFrame.Angles(0, 0, math.pi / 2)
		local mesh = N.rotate(source, rotation)
		for _, c in mesh.faces[1].corners do
			vector(c.normal, -Vector3.xAxis)
		end
		local flipped = N.flip(source)
		for _, c in flipped.faces[1].corners do
			vector(c.normal, -Vector3.yAxis)
		end
		vector(flipped:faceNormal(1), Vector3.yAxis)
	end)
	test("Custom normal averaging uses connected fans and reports cancelling directions", function()
		local source = E.Primitives.box()
		local average = N.average(source, { weighting = "uniform" })
		cornersAt(average, 7, function(c)
			vector(c.normal, Vector3.one.Unit)
		end)
		local grid = E.Primitives.grid(2, 1)
		for fid, f in grid.faces do
			for _, c in f.corners do
				c.normal = fid == 1 and Vector3.xAxis or -Vector3.xAxis
			end
		end
		assert(not pcall(N.average, grid, { weighting = "uniform" }))
		local fallback, r = N.average(grid, { weighting = "uniform", zeroSum = "face" })
		assert(r.zeroSums == 2)
		cornersAt(fallback, 2, function(c)
			vector(c.normal, Vector3.yAxis)
		end)
	end)
	test("Normal edits reproject inherited tangents and report parallel-frame fallbacks", function()
		local source = E.Primitives.grid(1, 1)
		for _, c in source.faces[1].corners do
			c.tangent = Vector3.xAxis
			c.tangentSign = -1
		end
		local mesh, r = N.direction(source, Vector3.xAxis)
		assert(r.tangentFallbacks == 4)
		for _, c in mesh.faces[1].corners do
			near(c.normal:Dot(c.tangent), 0)
			near(c.tangent.Magnitude, 1)
			assert(c.tangentSign == -1)
		end
	end)
	test("Normal budgets masks and invalid weights fail without source mutation", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxWork = 1 },
				{ maxElements = 2 },
				{ weighting = "unknown" },
				{ faceWeights = { [1] = -1 } },
				{ faceWeights = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 } },
				{ angle = -1 },
				{ mask = { ["9:1"] = 1 } },
				{ mask = { ["1:1"] = 2 } },
				{ power = 17 },
				{
					checkpoint = function()
						error("cancel")
					end,
				},
			}
		do
			assert(not pcall(N.recalculate, source, options))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("UV derivative tangents form the expected oriented grid basis", function()
		local source = E.Primitives.grid(3, 2)
		local mesh, r = N.tangents(source)
		assert(r.complete and r.degenerateUVTriangles == 0)
		for _, f in mesh.faces do
			for _, c in f.corners do
				vector(c.tangent, Vector3.xAxis)
				assert(c.tangentSign == -1)
				vector(c.normal:Cross(c.tangent) * c.tangentSign, Vector3.zAxis)
			end
		end
	end)
	test("Mirrored UVs change tangent handedness without merging across UV seams", function()
		local source = E.Primitives.grid(2, 1)
		for _, c in source.faces[2].corners do
			c.uv = Vector2.new(-c.uv.X, c.uv.Y)
		end
		local mesh = N.tangents(source)
		for fid, f in mesh.faces do
			for _, c in f.corners do
				vector(c.tangent, fid == 1 and Vector3.xAxis or -Vector3.xAxis)
				assert(c.tangentSign == (fid == 1 and -1 or 1))
			end
		end
	end)
	test("Tangents use typed UV channels independently from intrinsic texture coordinates", function()
		local source = E.Primitives.grid(1, 1)
		local values = {}
		for i, c in source.faces[1].corners do
			values["1:" .. i] = Vector2.new(c.uv.Y, c.uv.X)
		end
		source = A.set(A.create(source, "detailUV", "corner", "Vector2", Vector2.zero), "detailUV", values)
		local mesh = N.tangents(source, { uvChannel = "detailUV" })
		for i, c in mesh.faces[1].corners do
			vector(c.tangent, Vector3.zAxis)
			assert(c.tangentSign == 1 and c.uv == source.faces[1].corners[i].uv)
		end
	end)
	test("Degenerate UV tangents fail or explicitly report deterministic fallback frames", function()
		local source = E.Primitives.grid(1, 1)
		for _, c in source.faces[1].corners do
			c.uv = Vector2.zero
		end
		assert(not pcall(N.tangents, source))
		local mesh, r = N.tangents(source, { degenerate = "fallback" })
		assert(not r.complete and r.degenerateUVTriangles == 2 and r.fallbackCorners == 4)
		for _, c in mesh.faces[1].corners do
			near(c.normal:Dot(c.tangent), 0)
			near(c.tangent.Magnitude, 1)
		end
	end)
	test("Tangent generation rejects UV folds at shared corners and fractional masks", function()
		local source = E.Primitives.grid(1, 1)
		local uv = { Vector2.zero, Vector2.xAxis, Vector2.yAxis, Vector2.one }
		for i, c in source.faces[1].corners do
			c.uv = uv[i]
		end
		assert(not pcall(N.tangents, source))
		assert(not pcall(N.tangents, E.Primitives.grid(1, 1), { mask = { ["1:1"] = 0.5 } }))
		assert(not pcall(N.tangents, E.Primitives.grid(1, 1), { maxWork = 1 }))
	end)
	test("Custom normals survive native EditableMesh conversion at every corner", function()
		local source = N.direction(E.Primitives.box(), Vector3.new(1, 2, 3))
		local handle = E.Roblox.toEditable(source)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			for _, f in restored.faces do
				for _, c in f.corners do
					vector(c.normal, Vector3.new(1, 2, 3).Unit)
				end
			end
			near(restored:volume(), 8)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Normal directions and tangents are invariant under uniform scale and translation", function()
		local source = E.Primitives.box(Vector3.new(6, 4, 2))
		local base = N.recalculate(source)
		for _, scale in { 0.001, 1, 1000 } do
			local transformed =
				E.Deform.transform(source, CFrame.new(Vector3.new(8, 4, -16) * scale), Vector3.one * scale)
			local mesh = N.recalculate(transformed)
			for fid, f in mesh.faces do
				for i, c in f.corners do
					vector(c.normal, base.faces[fid].corners[i].normal, 1e-4)
				end
			end
		end
	end)
	test("Reflex polygon corners contribute their full interior angle to weighted normals", function()
		local source = E.Mesh.new()
		for _, p in
			{
				Vector3.zero,
				Vector3.new(2, 0, 0),
				Vector3.new(2, 1, 0),
				Vector3.new(1, 1, 0),
				Vector3.new(1, 2, 0),
				Vector3.new(0, 2, 0),
				Vector3.new(2, 1, 1),
				Vector3.new(1, 1, 1),
			}
		do
			source:addVertex(p)
		end
		source:addFace({ 1, 2, 3, 4, 5, 6 })
		source:addFace({ 4, 3, 7, 8 })
		local mesh = N.recalculate(source, { weighting = "angle" })
		cornersAt(mesh, 4, function(c)
			vector(c.normal, Vector3.new(0, -1, 3).Unit)
		end)
		local triangles = N.recalculate(E.Topology.triangulate(source), { weighting = "angle" })
		cornersAt(triangles, 4, function(c)
			vector(c.normal, Vector3.new(0, -1, 3).Unit)
		end)
	end)
	test("Sharp metadata can change without overwriting custom normals before a later merge", function()
		local source = N.direction(E.Primitives.box(), Vector3.new(1, 2, 3))
		local edges = {}
		for key in source:topology().edges do
			edges[key] = true
		end
		local sharp = N.markSharp(source, edges, { recalculate = false })
		for _, f in sharp.faces do
			for _, c in f.corners do
				vector(c.normal, Vector3.new(1, 2, 3).Unit)
			end
		end
		local merged = N.average(sharp, { sharpEdges = {} })
		for _, f in merged.faces do
			for _, c in f.corners do
				vector(c.normal, Vector3.new(1, 2, 3).Unit)
			end
		end
	end)
	test("Disconnected fans sharing a vertex are rejected before normal smoothing", function()
		local source = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.xAxis, Vector3.yAxis, -Vector3.xAxis, -Vector3.yAxis } do
			source:addVertex(p)
		end
		source:addFace({ 1, 2, 3 })
		source:addFace({ 1, 4, 5 })
		assert(not pcall(N.recalculate, source))
	end)
	test("Tangent directions transform with a tilted scaled plane and preserve exact corner masks", function()
		local frame = CFrame.new(3, 5, 7) * CFrame.Angles(0.2, 0.4, 0.6)
		local source = E.Deform.transform(E.Primitives.grid(2, 2), frame, Vector3.one * 3)
		local mesh, r = N.tangents(source, { mask = { ["1:1"] = true } })
		assert(r.changedCorners == 1)
		vector(mesh.faces[1].corners[1].tangent, frame:VectorToWorldSpace(Vector3.xAxis), 1e-4)
		for fid, f in mesh.faces do
			for i, c in f.corners do
				if fid ~= 1 or i ~= 1 then
					assert(c.tangent == nil)
				end
			end
		end
	end)
	report.success = report.failed == 0
	return report
end
