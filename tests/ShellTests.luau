return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function vec(a, b, tolerance)
		assert((a - b).Magnitude < (tolerance or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function fold(angle)
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.new(-2, 0, -1),
				Vector3.new(0, 0, -1),
				Vector3.new(2 * math.cos(angle), 2 * math.sin(angle), -1),
				Vector3.new(-2, 0, 1),
				Vector3.new(0, 0, 1),
				Vector3.new(2 * math.cos(angle), 2 * math.sin(angle), 1),
			}
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 4, 5, 2 })
		m:addFace({ 2, 5, 6, 3 })
		for _, f in m.faces do
			for i, uv in { Vector2.new(0, 0), Vector2.new(0, 1), Vector2.new(1, 1), Vector2.new(1, 0) } do
				f.corners[i].uv = uv
			end
		end
		return m:recalculateNormals()
	end
	local function pyramid()
		local m = E.Mesh.new()
		for _, p in
			{
				Vector3.new(-2, -1, 0),
				Vector3.new(2, -1, 0),
				Vector3.new(2, 1, 0),
				Vector3.new(-2, 1, 0),
				Vector3.new(0.2, 0.1, 1.4),
			}
		do
			m:addVertex(p)
		end
		m:addFace({ 4, 3, 2, 1 })
		for i = 1, 4 do
			m:addFace({ i, i % 4 + 1, 5 })
		end
		return m:recalculateNormals()
	end
	test("Miter box shells have independent analytic offsets and volumes", function()
		local source = E.Primitives.box()
		for _, offset in { -1, 0, 1 } do
			local out, r = E.Modifiers.shell(source, 0.2, { offset = offset, maxOffsetError = 1e-5 })
			assert(
				r.complete
					and r.validation.closed
					and r.intersectionChecked
					and r.outputIntersections.intersectionFree
			)
			assert(r.ranks[3] == 8 and r.closedComponents == 1 and r.orientationFailures == 0)
			local outer, inner = 1 + 0.1 * (offset + 1), 1 + 0.1 * (offset - 1)
			near(out:volume(), 8 * (outer ^ 3 - inner ^ 3), 2e-5)
			near(r.maximumMiter, math.sqrt(3))
			for id, p in source.vertices do
				vec(out.vertices[r.top[id]], p * outer)
				vec(out.vertices[r.bottom[id]], p * inner)
			end
		end
	end)
	test("Planar sheets use rank-one joins and close their boundary rims", function()
		local source = E.Primitives.grid(2, 2, Vector2.new(4, 3))
		local out, r = E.Modifiers.shell(source, 0.4, { maxOffsetError = 1e-5 })
		assert(r.complete and r.ranks[1] == source:validate().vertices and r.closedComponents == 0)
		near(math.abs(out:volume()), 4.8, 2e-5)
		near(r.maximumMiter, 1)
	end)
	test("Convex and concave folded sheets retain analytic wall thickness", function()
		for _, angle in { math.pi / 2, -math.pi / 2, math.pi / 3, -math.pi / 3 } do
			local source = fold(angle)
			local out, r = E.Modifiers.shell(source, 0.2, { maxOffsetError = 1e-5 })
			assert(r.complete and r.ranks[2] == 2 and r.ranks[1] == 4)
			near(out:volume(), 1.6, 2e-5)
			for _, id in { 2, 5 } do
				local expected = Vector3.new(-math.tan(angle / 2), 1, 0) * 0.1
				vec(out.vertices[r.top[id]] - source.vertices[id], expected)
			end
		end
	end)
	test("Miter limits report excessive spikes without silently clamping thickness", function()
		local source = fold(math.rad(160))
		assert(not pcall(E.Modifiers.shell, source, 0.1, { miterLimit = 2 }))
		local out, r = E.Modifiers.shell(
			source,
			0.1,
			{ miterLimit = 2, requireComplete = false, checkIntersections = false }
		)
		assert(
			not r.complete
				and r.miterLimitExceeded == 2
				and r.maximumMiter > 5
				and r.maximumOffsetError < 1e-5
		)
		assert(out:validate().valid and r.reason)
	end)
	test("Incompatible high-valence plane offsets expose their residual and least-squares balance", function()
		local source = pyramid()
		local out, r = E.Modifiers.shell(source, 0.1, { maxOffsetError = 0.1, miterLimit = 5 })
		assert(r.complete and r.maximumOffsetError > 1e-5)
		local _, strict =
			E.Modifiers.shell(source, 0.1, { maxOffsetError = 1e-7, requireComplete = false, miterLimit = 5 })
		assert(not strict.complete and strict.reason and strict.maximumOffsetError == r.maximumOffsetError)
		local uniform, ur = E.Modifiers.shell(
			source,
			0.1,
			{ maxOffsetError = 0.1, joinWeighting = "uniform", miterLimit = 5 }
		)
		assert(ur.complete)
		local delta = (uniform.vertices[ur.top[5]] - uniform.vertices[ur.bottom[5]]) / 0.1
		local residual = Vector3.zero
		for _, fid in source:topology().vertexFaces[5] do
			local n = source:faceNormal(fid)
			residual += n * (n:Dot(delta) - 1)
		end
		assert(residual.Magnitude < 2e-5)
		assert(out:volume() > 0)
	end)
	test("Angle weighting is invariant to planar face triangulation", function()
		local source = pyramid()
		local triangles = E.Topology.triangulate(source)
		local a, ar = E.Modifiers.shell(source, 0.1, { maxOffsetError = 0.1, miterLimit = 5 })
		local b, br = E.Modifiers.shell(triangles, 0.1, { maxOffsetError = 0.1, miterLimit = 5 })
		assert(ar.complete and br.complete)
		for id in source.vertices do
			vec(a.vertices[ar.top[id]], b.vertices[br.top[id]], 2e-5)
			vec(a.vertices[ar.bottom[id]], b.vertices[br.bottom[id]], 2e-5)
		end
	end)
	test("Shell coordinates and measured residuals respect rigid and scale transforms", function()
		local source = fold(math.pi / 3)
		local base, reportA = E.Modifiers.shell(source, 0.2, { maxOffsetError = 1e-5 })
		local frame = CFrame.new(5, -3, 7) * CFrame.Angles(0.3, -0.4, 0.5)
		for _, scale in { 0.1, 2 } do
			local moved = E.Deform.transform(source, frame, Vector3.one * scale)
			local result, r =
				E.Modifiers.shell(moved, 0.2 * scale, { maxOffsetError = 2e-5, planarityTolerance = 2e-5 })
			assert(r.complete)
			for id in source.vertices do
				vec(
					result.vertices[r.top[id]],
					frame:PointToWorldSpace(base.vertices[reportA.top[id]] * scale),
					2e-5
				)
			end
		end
	end)
	test("All typed domains intrinsic seams skin and groups have shell correspondence", function()
		local source = E.Primitives.box()
		local A = E.Attributes
		for _, c in
			{
				{ "v", "vertex", "boolean", true },
				{ "e", "edge", "number", 0 },
				{ "f", "face", "string", "" },
				{ "c", "corner", "number", 0 },
			}
		do
			source = A.create(source, c[1], c[2], c[3], c[4])
		end
		local vv, ee, ff, cc = {}, {}, {}, {}
		source.groups.retained = {}
		for id in source.vertices do
			vv[id] = false
			source.groups.retained[id] = id / 8
			source.weights[id] = { [1] = 0.25, [2] = 0.75 }
		end
		for key in source:topology().edges do
			ee[key] = 7
		end
		for fid, f in source.faces do
			ff[fid] = "face" .. fid
			for i, corner in f.corners do
				cc[fid .. ":" .. i] = i
				corner.tangentSign = 1
			end
		end
		for name, values in { v = vv, e = ee, f = ff, c = cc } do
			source = A.set(source, name, values)
		end
		local before = E.IO.encode(source)
		local out, r = E.Modifiers.shell(source, 0.2)
		for _, map in { r.top, r.bottom } do
			for id, newId in map do
				assert(A.get(out, "v", newId) == false)
				near(out.groups.retained[newId], id / 8)
				near(out.weights[newId][2], 0.75)
			end
		end
		for id, refs in r.inputMaps.face do
			assert(A.get(out, "f", id) == ff[refs[1][1]])
		end
		for id, refs in r.inputMaps.corner do
			near(A.get(out, "c", id), cc[refs[1][1]])
			local fid, index = id:match("^(%d+):(%d+)$")
			local oldFace, oldIndex = refs[1][1]:match("^(%d+):(%d+)$")
			assert(
				out.faces[tonumber(fid)].corners[tonumber(index)].uv
					== source.faces[tonumber(oldFace)].corners[tonumber(oldIndex)].uv
			)
		end
		for id, refs in r.inputMaps.edge do
			near(A.get(out, "e", id), ee[refs[1][1]])
		end
		assert(E.IO.encode(source) == before and #A.names(E.IO.decode(E.IO.encode(out))) == 4)
	end)
	test("The single-result solidify API retains its normal-offset default", function()
		local source = E.Primitives.box()
		local list = { E.Modifiers.solidify(source, 0.2) }
		assert(#list == 1)
		local normal, r = E.Modifiers.shell(source, 0.2, { join = "normal" })
		assert(r.complete and r.maximumOffsetError > 0.04)
		near(normal:volume(), list[1]:volume(), 1e-6)
		local miter = E.Modifiers.solidify(source, 0.2, { join = "miter", maxOffsetError = 1e-5 })
		near(miter:volume(), 2.2 ^ 3 - 1.8 ^ 3, 2e-5)
	end)
	test("Consumed inner shells reject even without a boundary intersection", function()
		local source = E.Primitives.box()
		local out, r = E.Modifiers.shell(source, 4, { offset = -1, requireComplete = false })
		assert(out:validate().valid and r.outputIntersections.intersectionFree)
		assert(not r.complete and r.orientationFailures > 0 and r.componentVolumes[1].bottom > 0)
		assert(not pcall(E.Modifiers.shell, source, 4, { offset = -1 }))
	end)
	test("Disconnected sheets detect collisions introduced by their shell thickness", function()
		local a = E.Primitives.grid(1, 1, Vector2.new(2, 2))
		local b = E.Deform.transform(a, CFrame.new(0, 0.05, 0))
		local source = E.Topology.join({ a, b })
		local _, r = E.Modifiers.shell(source, 0.2, { requireComplete = false })
		assert(
			not r.complete
				and r.inputIntersections.intersectionFree
				and not r.outputIntersections.intersectionFree
		)
	end)
	test("Nonplanar faces require explicit triangulation before a miter shell", function()
		local source = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.xAxis, Vector3.new(1, 1, 0.2), Vector3.yAxis } do
			source:addVertex(p)
		end
		source:addFace({ 1, 2, 3, 4 })
		assert(not pcall(E.Modifiers.shell, source, 0.1))
		local out, r = E.Modifiers.shell(E.Topology.triangulate(source), 0.1)
		assert(r.complete and out:validate().closed)
	end)
	test("Shell invalid data budgets audits and cancellation reject transactionally", function()
		local source = E.Primitives.box()
		local before = E.IO.encode(source)
		assert(not pcall(E.Modifiers.shell, E.Mesh.new(), 0.2))
		assert(not pcall(E.Modifiers.shell, source, 0.2, { checkIntersections = "no" }))
		assert(not pcall(E.Modifiers.shell, source, 0.2, { requireComplete = 0 }))
		for _, options in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxWork = 1 },
				{ rankTolerance = 0 },
				{ miterLimit = 0.5 },
				{ join = "unknown" },
				{ joinWeighting = "unknown" },
				{ maxOffsetError = -1 },
				{ intersectionOptions = { maxTests = 1 } },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function()
						error("cancel")
					end,
				},
			}
		do
			assert(not pcall(E.Modifiers.shell, source, 0.2, options))
		end
		assert(E.IO.encode(source) == before)
		local loose = source:clone()
		loose:addVertex(Vector3.one * 5)
		assert(not pcall(E.Modifiers.shell, loose, 0.2))
	end)
	test("Sharp shells survive native UV and skin conversion", function()
		local source = fold(math.pi / 2)
		for id in source.vertices do
			source.weights[id] = { [1] = 0.4, [2] = 0.6 }
		end
		local mesh, r = E.Modifiers.shell(source, 0.2, { normalAngle = 0.1 })
		assert(r.complete)
		local rig = E.Rig.new()
		rig:addBone("A")
		rig:addBone("B")
		local handle = E.Roblox.toEditable(mesh, { rig = rig })
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), mesh:volume(), 1e-5)
			for _, weights in restored.weights do
				near(weights[2], 0.6)
			end
			local count = 0
			for _, f in restored.faces do
				for _, c in f.corners do
					assert(c.uv and (c.uv.X == 0 or c.uv.X == 1) and (c.uv.Y == 0 or c.uv.Y == 1))
					if c.uv.X == 1 then
						count += 1
					end
				end
			end
			assert(count > 0)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Inward and disconnected closed components keep independent orientation checks", function()
		local box = E.Primitives.box()
		local inverted = E.Topology.reverse(box)
		local joined = E.Topology.join({ box, E.Deform.transform(inverted, CFrame.new(5, 0, 0)) })
		local out, r = E.Modifiers.shell(joined, 0.2)
		assert(r.complete and r.closedComponents == 2 and r.orientationFailures == 0)
		near(out:volume(), 2 * (2.2 ^ 3 - 1.8 ^ 3), 4e-5)
		assert(r.componentVolumes[1].source * r.componentVolumes[2].source < 0)
	end)
	test("Native precision collapse and zero offset tolerance cannot report complete", function()
		local source = E.Deform.transform(E.Primitives.box(), CFrame.new(1000000, 1000000, 1000000))
		local _, r = E.Modifiers.shell(source, 0.001, { requireComplete = false })
		assert(
			not r.complete
				and r.validation.valid
				and r.maximumOffsetError > r.maxOffsetError
				and not r.outputIntersections.intersectionFree
		)
		local m = E.Primitives.box()
		local _, rounding = E.Modifiers.shell(m, 0.2, { maxOffsetError = 0, requireComplete = false })
		assert(not rounding.complete and rounding.maximumOffsetError > 0)
	end)
	report.success = report.failed == 0
	return report
end
