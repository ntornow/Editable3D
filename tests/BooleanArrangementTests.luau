return function(E)
	local B, A = E.Boolean, E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 2e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function box(offset, size)
		local m = E.Primitives.box(size)
		for id, p in m.vertices do
			m.vertices[id] = p + (offset or Vector3.zero)
		end
		return m
	end
	local function check(mesh, r)
		assert(r.complete and r.validation.valid and (r.empty or r.validation.closed), r.reason)
		if r.method == "arrangement" then
			assert(r.intersections.complete and r.intersections.intersectionFree)
		end
		assert(mesh:validate().valid)
	end
	local function apply(a, b, operation, options)
		options = options or {}
		options.method = "arrangement"
		local m, r = B.apply(a, b, operation, options)
		check(m, r)
		return m, r
	end
	test("Arrangement Boolean operations match analytic spatial and coplanar box volumes", function()
		for _, delta in { Vector3.new(0.5, 0.25, 0), Vector3.new(0.7, 0.3, 0.2) } do
			local overlap = (2 - delta.X) * (2 - delta.Y) * (2 - delta.Z)
			for operation, volume in { union = 16 - overlap, intersect = overlap, subtract = 8 - overlap } do
				local m = apply(box(), box(delta), operation)
				near(m:volume(), volume)
			end
		end
	end)
	test("Coincident operand identity and reversed winding are classified independently", function()
		local a = box()
		for _, b in { a, E.Topology.reverse(a) } do
			for operation, volume in { union = 8, intersect = 8, subtract = 0 } do
				local m, r = apply(a, b, operation)
				near(m:volume(), volume)
				assert(r.empty == (volume == 0))
			end
		end
	end)
	test("Nested operand winding rules distinguish double winding from a cavity", function()
		local inner = box(nil, Vector3.one)
		local nested = E.Topology.join({ box(), inner })
		local m = apply(nested, inner, "intersect")
		near(m:volume(), 1)
		m = apply(nested, inner, "intersect", { windingRuleA = "odd" })
		assert(not next(m.faces))
		m = apply(nested, inner, "subtract")
		near(m:volume(), 7)
		m = apply(box(), E.Topology.reverse(box()), "subtract", { windingRuleB = "positive" })
		near(m:volume(), 8)
	end)
	test("Oriented cavity shells perform regularized union intersection and subtraction", function()
		local inner = box()
		local shell = E.Topology.join({ box(nil, Vector3.one * 4), E.Topology.reverse(inner) })
		for operation, volume in { union = 64, intersect = 0, subtract = 56 } do
			local m = apply(shell, inner, operation)
			near(m:volume(), volume)
		end
	end)
	test("Self intersecting operand sheets use their winding region before Boolean composition", function()
		local a = E.Topology.join({ box(), box(Vector3.new(0.5, 0.25, 0)) })
		local b = box(nil, Vector3.one * 0.5)
		for operation, volume in { union = 10.75, intersect = 0.125, subtract = 10.625 } do
			local m, r = apply(a, b, operation)
			near(m:volume(), volume)
			assert(r.arrangement.inputIntersections.crossings > 0)
		end
		assert(not pcall(B.union, a, b, { method = "arrangement", checkIntersections = true }))
	end)
	test("Face edge and vertex touching intersections are regularized to empty volume", function()
		for _, delta in { Vector3.new(2, 0, 0), Vector3.new(2, 2, 0), Vector3.new(2, 2, 2) } do
			local a, b = box(), box(delta)
			local m, r = apply(a, b, "intersect")
			assert(r.empty and not next(m.faces))
			m = apply(a, b, "subtract")
			near(m:volume(), 8)
		end
		local m = apply(box(), box(Vector3.new(2, 0, 0)), "union")
		near(m:volume(), 16)
	end)
	test("Nonmanifold Boolean unions reject or expose an explicitly incomplete candidate", function()
		local a, b = box(), box(Vector3.new(2, 2, 0))
		assert(not pcall(B.union, a, b, { method = "arrangement" }))
		local _, r = B.union(a, b, { method = "arrangement", allowInvalid = true })
		assert(not r.complete and r.reason == "invalid_topology")
		assert(
			not pcall(
				B.union,
				a,
				b,
				{ method = "arrangement", allowInvalid = true, checkIntersections = true }
			)
		)
	end)
	test("Rotated Boolean volumes match the independent clipped square area", function()
		local a, b = box(), box()
		local frame = CFrame.Angles(0, 0, math.pi / 4)
		for id, p in b.vertices do
			b.vertices[id] = frame:PointToWorldSpace(p)
		end
		local overlap = 16 * (math.sqrt(2) - 1)
		for operation, volume in { union = 16 - overlap, intersect = overlap, subtract = 8 - overlap } do
			local m = apply(a, b, operation)
			near(m:volume(), volume)
		end
	end)
	test("Curved Boolean cutters retain closed boundaries and conserve operand volume", function()
		local a, b = box(), E.Primitives.sphere(1.2, 12, 6)
		local union, intersection, difference =
			apply(a, b, "union"), apply(a, b, "intersect"), apply(a, b, "subtract")
		near(union:volume() + intersection:volume(), a:volume() + b:volume(), 1e-4)
		near(difference:volume() + intersection:volume(), a:volume(), 1e-4)
	end)
	test("Deterministic oblique Boolean cuts preserve volume identities and geometric validity", function()
		local random = Random.new(8171)
		for _ = 1, 5 do
			local frame = CFrame.new(
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1)
			) * CFrame.Angles(random:NextNumber(-1, 1), random:NextNumber(-1, 1), random:NextNumber(-1, 1))
			local a, b = box(), box(nil, Vector3.new(2.4, 1.7, 2.1))
			for id, p in b.vertices do
				b.vertices[id] = frame:PointToWorldSpace(p)
			end
			local u, i, d = apply(a, b, "union"), apply(a, b, "intersect"), apply(a, b, "subtract")
			near(u:volume() + i:volume(), a:volume() + b:volume(), 1e-4)
			near(d:volume() + i:volume(), a:volume(), 1e-4)
		end
	end)
	test("Repeated arrangement cuts of a concave solid remain closed and conserve volume", function()
		local base = apply(box(), box(Vector3.new(1, 1, 0)), "union")
		near(base:volume(), 14)
		local cutter = box(Vector3.new(0.2, 0.3, 0), Vector3.new(0.6, 4, 0.6))
		local intersection = apply(base, cutter, "intersect")
		local difference = apply(base, cutter, "subtract")
		near(intersection:volume() + difference:volume(), 14)
	end)
	test("Both Boolean methods transfer every typed domain and retain independent corner seams", function()
		local operands = { a = box(), b = box(Vector3.new(0.5, 0.25, 0)) }
		for name, source in operands do
			local vx, cx, labels, edgeValues = {}, {}, {}, {}
			source.groups.test = {}
			for id, p in source.vertices do
				vx[id] = p.X
				source.groups.test[id] = (p.X + 1) / 4
				source.weights[id] = { Left = 1 - (p.X + 1) / 4, Right = (p.X + 1) / 4 }
			end
			for fid, f in source.faces do
				local tag = fid + (name == "b" and 100 or 0)
				labels[fid] = name .. fid
				for i, id in f.vertices do
					cx[fid .. ":" .. i] = source.vertices[id].X
					f.corners[i].uv = Vector2.new(source.vertices[id].X, tag)
				end
			end
			for key in E.Connectivity.index(source).edges do
				edgeValues[key] = 7
			end
			for _, schema in
				{
					{ "x", "vertex", "number", vx },
					{ "xc", "corner", "number", cx },
					{ "label", "face", "string", labels },
					{ "rim", "edge", "number", edgeValues },
				}
			do
				source = A.set(
					A.create(source, schema[1], schema[2], schema[3], schema[3] == "string" and "" or 0),
					schema[1],
					schema[4]
				)
			end
			operands[name] = source
		end
		local beforeA, beforeB = E.IO.encode(operands.a), E.IO.encode(operands.b)
		for _, method in { "bsp", "arrangement" } do
			for _, operation in { "union", "intersect", "subtract" } do
				local m, r = B.apply(
					operands.a,
					operands.b,
					operation,
					{ method = method, materialOffsetB = 10, checkIntersections = true }
				)
				check(m, r)
				for id, p in m.vertices do
					near(A.get(m, "x", id), p.X)
					near(m.groups.test[id], (p.X + 1) / 4)
					near(m.weights[id].Right, (p.X + 1) / 4)
				end
				for fid, f in m.faces do
					local ref = r.inputMaps.face[r.maps.face[fid][1][1]]
					assert(A.get(m, "label", fid) == ref.operand .. ref.id)
					assert(f.material == (ref.operand == "b" and 11 or 1))
					for i, id in f.vertices do
						near(A.get(m, "xc", fid .. ":" .. i), m.vertices[id].X)
						near(f.corners[i].uv.X, m.vertices[id].X)
						near(f.corners[i].uv.Y, ref.id + (ref.operand == "b" and 100 or 0))
					end
				end
				assert(next(r.maps.edge))
				for key in r.maps.edge do
					near(A.get(m, "rim", key), 7)
				end
			end
		end
		assert(E.IO.encode(operands.a) == beforeA and E.IO.encode(operands.b) == beforeB)
	end)
	test("Boolean correspondence respects sparse input IDs and source material strings", function()
		local a = box()
		local source = box(Vector3.new(0.7, 0.3, 0.2))
		local b = E.Mesh.new()
		for id, p in source.vertices do
			b.vertices[id + 100] = p
		end
		for fid, f in source.faces do
			local ids = {}
			for i, id in f.vertices do
				ids[i] = id + 100
			end
			b.faces[fid + 50] = { vertices = ids, corners = f.corners, material = "right" }
		end
		b.nextVertex, b.nextFace = 200, 100
		for _, f in a.faces do
			f.material = "left"
		end
		for _, method in { "bsp", "arrangement" } do
			local m, r = B.union(a, b, { method = method })
			check(m, r)
			for fid, f in m.faces do
				local ref = r.inputMaps.face[r.maps.face[fid][1][1]]
				assert((ref.operand == "a" and a or b).faces[ref.id])
				assert(f.material == (ref.operand == "a" and "left" or "right"))
			end
			local identity = B.union(E.Mesh.new(), b, { method = method })
			near(identity:volume(), 8)
		end
	end)
	test(
		"Boolean schemas preserve defaults missing from one operand and reject incompatible channels",
		function()
			local a, b = box(), box(Vector3.new(0.5, 0.25, 0))
			local values = {}
			for id in a.vertices do
				values[id] = 10
			end
			a = A.set(A.create(a, "tag", "vertex", "number", 5), "tag", values)
			for _, method in { "bsp", "arrangement" } do
				local m, r = B.union(a, b, { method = method })
				check(m, r)
				for id in m.vertices do
					local sum, weight = 0, 0
					for _, ref in r.maps.vertex[id] do
						local original = r.inputMaps.vertex[ref[1]]
						sum += (original.operand == "a" and 10 or 5) * ref[2]
						weight += ref[2]
					end
					near(A.get(m, "tag", id), sum / weight)
				end
				local bad = A.create(b, "tag", "vertex", "string", "")
				assert(not pcall(B.union, a, bad, { method = method }))
			end
		end
	)
	test("Empty Boolean identities retain typed channels and explicit correspondence", function()
		local full = A.create(box(), "tag", "face", "number", 3)
		local empty = A.create(E.Mesh.new(), "other", "vertex", "number", 7)
		for _, method in { "bsp", "arrangement" } do
			for _, pair in { { full, empty }, { empty, full } } do
				local m, r = B.union(pair[1], pair[2], { method = method })
				check(m, r)
				near(m:volume(), 8)
				assert(m.attributes.other and m.attributes.tag and next(r.maps.face))
				for fid in m.faces do
					near(A.get(m, "tag", fid), 3)
				end
			end
			for _, operation in { "intersect", "subtract" } do
				local m, r = B.apply(empty, full, operation, { method = method })
				check(m, r)
				assert(r.empty and m.attributes.tag and m.attributes.other)
			end
		end
	end)
	test("Arrangement Boolean volumes survive scale and oblique world transforms", function()
		for _, scale in { 0.001, 1, 1000 } do
			local a, b = box(), box(Vector3.new(0.7, 0.3, 0.2))
			local frame = scale == 1 and CFrame.new(16, -8, 32) * CFrame.Angles(0.2, 0.4, 0.3)
				or CFrame.identity
			for _, m in { a, b } do
				for id, p in m.vertices do
					m.vertices[id] = frame:PointToWorldSpace(p * scale)
				end
			end
			local m = apply(a, b, "subtract")
			near(m:volume() / scale ^ 3, 4.022, 5e-5)
		end
	end)
	test("Arrangement Boolean input output and cancellation budgets never imply completion", function()
		local a, b = box(), box(Vector3.new(0.5, 0.25, 0))
		local beforeA, beforeB = E.IO.encode(a), E.IO.encode(b)
		for _, options in
			{
				{ maxWork = 1 },
				{ maxPolygons = 1 },
				{ maxVertices = 8 },
				{ intersectionOptions = { maxTests = 1 } },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(state)
						if state.stage == "classify" then
							error("cancel Boolean")
						end
					end,
				},
			}
		do
			options.method = "arrangement"
			assert(not pcall(B.union, a, b, options))
		end
		local _, input = E.Intersections.mesh(E.Topology.join({ a, b }))
		assert(
			not pcall(
				B.union,
				a,
				b,
				{ method = "arrangement", intersectionOptions = { maxTests = input.tests + 1 } }
			)
		)
		local _, r = B.union(a, b, {
			method = "arrangement",
			allowInvalid = true,
			intersectionOptions = { maxTests = input.tests + 1 },
		})
		assert(not r.complete and r.reason == "incomplete_audit")
		assert(E.IO.encode(a) == beforeA and E.IO.encode(b) == beforeB)
	end)
	test("Boolean methods reject invalid inputs and unknown methods even with an empty operand", function()
		for _, method in { "bsp", "arrangement" } do
			assert(not pcall(B.intersect, E.Primitives.grid(1, 1), E.Mesh.new(), { method = method }))
			assert(not pcall(B.union, box(), box(), { method = method, materialOffsetB = math.huge }))
		end
		assert(not pcall(B.union, box(), box(), { method = "unknown" }))
		assert(not pcall(B.union, box(), box(), { method = "arrangement", windingRuleB = "unknown" }))
		assert(not pcall(B.union, box(), box(), { method = "arrangement", epsilon = 0 }))
		assert(not pcall(B.union, box(), box(), { method = "arrangement", weldEpsilon = 0.01 }))
		assert(not pcall(B.union, box(), box(), { method = "arrangement", maxDepth = 100 }))
		assert(not pcall(B.union, box(), box(), { method = "bsp", windingRule = "odd" }))
		assert(not pcall(B.union, box(), box(), { method = "bsp", vertexBlend = "average" }))
	end)
	test("Native arrangement Boolean conversion preserves audited geometry and corner UVs", function()
		local m = apply(box(), box(Vector3.new(0.7, 0.3, 0.2)), "subtract", { materialOffsetB = 10 })
		local handle = E.Roblox.toEditable(m)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), 4.022)
			local _, audit = E.Intersections.mesh(restored)
			assert(audit.complete and audit.intersectionFree)
			for _, f in restored.faces do
				for _, c in f.corners do
					assert(typeof(c.uv) == "Vector2" and typeof(c.normal) == "Vector3")
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
