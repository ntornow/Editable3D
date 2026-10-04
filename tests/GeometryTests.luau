return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, errorMessage = pcall(fn)
		if ok then
			report.passed += 1
		else
			report.failed += 1
		end
		table.insert(
			report.results,
			{ name = name, passed = ok, error = not ok and tostring(errorMessage) or nil }
		)
	end
	local function near(a, b, eps)
		assert(math.abs(a - b) <= (eps or 1e-4), tostring(a) .. " != " .. tostring(b))
	end
	local function closed(m)
		local r = m:validate()
		assert(r.valid and r.closed and r.windingErrors == 0, game.HttpService:JSONEncode(r))
	end
	local function fails(fn)
		assert(not pcall(fn), "Expected explicit rejection")
	end
	test("surface Boolean analytic overlapping-box volumes and immutable inputs", function()
		local a = E.Primitives.box()
		local b = E.Deform.transform(a, CFrame.new(1, 0, 0))
		local original = E.IO.encode(a)
		for operation, volume in { union = 12, intersect = 4, subtract = 4 } do
			local m = E.Boolean.apply(a, b, operation)
			closed(m)
			near(m:volume(), volume)
			closed(E.Topology.triangulate(m))
		end
		assert(E.IO.encode(a) == original)
	end)
	test("surface Boolean disjoint, containment, coplanar and empty set identities", function()
		local a = E.Primitives.box()
		local empty = E.Mesh.new()
		near(E.Boolean.union(a, empty):volume(), 8)
		near(E.Boolean.union(empty, a):volume(), 8)
		near(E.Boolean.subtract(a, empty):volume(), 8)
		assert(not next(E.Boolean.intersect(a, empty).faces))
		assert(not next(E.Boolean.subtract(empty, a).faces))
		assert(not next(E.Boolean.subtract(a, a).faces))
		near(E.Boolean.intersect(a, a):volume(), 8)
		local d = E.Deform.transform(a, CFrame.new(5, 0, 0))
		near(E.Boolean.union(a, d):volume(), 16)
		assert(not next(E.Boolean.intersect(a, d).faces))
		local contained = E.Primitives.box(Vector3.one)
		local shell = E.Boolean.subtract(a, contained)
		closed(shell)
		near(shell:volume(), 7)
		local touching = E.Deform.transform(a, CFrame.new(2, 0, 0))
		local joined = E.Boolean.union(a, touching)
		closed(joined)
		near(joined:volume(), 16)
		assert(not next(E.Boolean.intersect(a, touching).faces))
	end)
	test("surface Boolean rotated and curved intersection volume conservation", function()
		local a = E.Primitives.box()
		for _, b in
			{
				E.Deform.transform(a, CFrame.new(0.4, 0.2, 0.1) * CFrame.Angles(0.3, 0.2, 0.5)),
				E.Primitives.sphere(1.2, 16, 8),
			}
		do
			local u, i, d = E.Boolean.union(a, b), E.Boolean.intersect(a, b), E.Boolean.subtract(a, b)
			closed(u)
			closed(i)
			closed(d)
			near(u:volume() + i:volume(), a:volume() + b:volume())
			near(d:volume() + i:volume(), a:volume())
			closed(E.Topology.triangulate(u))
		end
	end)
	test("surface Boolean repeated cuts of concave solids", function()
		local a = E.Primitives.box()
		local l = E.Boolean.union(a, E.Deform.transform(a, CFrame.new(1, 1, 0)))
		closed(l)
		near(l:volume(), 14)
		local cutter = E.Deform.transform(E.Primitives.box(Vector3.new(0.6, 4, 0.6)), CFrame.new(0.2, 0.3, 0))
		local i = E.Boolean.intersect(l, cutter)
		local d = E.Boolean.subtract(l, cutter)
		closed(i)
		closed(d)
		near(i:volume() + d:volume(), 14)
	end)
	test("surface Boolean deterministic oblique cuts and near-coincident seams", function()
		local random = Random.new(8171)
		for _ = 1, 16 do
			local a = E.Primitives.box()
			local cf = CFrame.new(
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1)
			) * CFrame.Angles(random:NextNumber(-1, 1), random:NextNumber(-1, 1), random:NextNumber(-1, 1))
			local b = E.Deform.transform(E.Primitives.box(Vector3.new(2.4, 1.7, 2.1)), cf)
			local u, i, d = E.Boolean.union(a, b), E.Boolean.intersect(a, b), E.Boolean.subtract(a, b)
			closed(u)
			closed(i)
			closed(d)
			near(u:volume() + i:volume(), a:volume() + b:volume())
			near(d:volume() + i:volume(), a:volume())
		end
	end)
	test("surface Boolean material seams, UVs, normalized normals and skin interpolation", function()
		local a = E.Primitives.box()
		local b = E.Deform.transform(a, CFrame.new(0.6, 0, 0))
		for _, mesh in { a, b } do
			mesh.groups.test = {}
			for id, p in mesh.vertices do
				mesh.weights[id] = { [1] = (p.X + 2) / 4, [2] = 1 - (p.X + 2) / 4 }
				mesh.groups.test[id] = (p.X + 2) / 4
			end
		end
		local result = E.Boolean.union(a, b, { materialOffsetB = 10 })
		local materials = {}
		for id, p in result.vertices do
			near(result.weights[id][1], (p.X + 2) / 4)
			near(result.weights[id][1] + result.weights[id][2], 1)
			near(result.groups.test[id], (p.X + 2) / 4)
		end
		for _, f in result.faces do
			materials[f.material] = true
			for _, c in f.corners do
				assert(c.uv and c.normal)
				near(c.normal.Magnitude, 1)
			end
		end
		assert(materials[1] and materials[11])
	end)
	test("surface Boolean invalid surfaces and execution budgets reject", function()
		fails(function()
			E.Boolean.union(E.Primitives.grid(1, 1), E.Primitives.box())
		end)
		fails(function()
			E.Boolean.union(E.Primitives.box(), E.Primitives.box(), { maxWork = 1 })
		end)
		fails(function()
			E.Boolean.union(E.Primitives.box(), E.Primitives.box(), { epsilon = 0 })
		end)
	end)
	test("surface Boolean native mesh adapter retains closed triangles", function()
		local mesh = E.Boolean.subtract(
			E.Primitives.box(),
			E.Deform.transform(E.Primitives.box(), CFrame.new(0.5, 0.5, 0.5))
		)
		local handle = E.Roblox.toEditable(mesh)
		local ok, message = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			closed(restored)
			near(restored:volume(), mesh:volume())
		end)
		E.Roblox.destroy(handle)
		assert(ok, message)
	end)
	test("LSCM planar angle preservation on non-square tilted chart", function()
		local m = E.Deform.transform(E.Primitives.grid(8, 4, Vector2.new(4, 2)), CFrame.Angles(0.2, 0.4, 0.3))
		local result, r = E.Conformal.lscm(m)
		assert(r.converged and r.conformalEnergy < 1e-10)
		assert(r.distortion.maxAngleRadians < 1e-4 and r.distortion.flippedTriangles == 0)
		assert(m.faces[1].corners[1].uv ~= result.faces[1].corners[1].uv)
	end)
	test("LSCM pinned boundaries and bounded convergence", function()
		local m = E.Primitives.grid(6, 6)
		local pins = { [1] = Vector2.new(2, 3), [49] = Vector2.new(4, 3) }
		local result, r = E.Conformal.lscm(m, { pins = pins })
		assert(r.converged)
		for _, f in result.faces do
			for i, id in f.vertices do
				if pins[id] then
					assert(f.corners[i].uv == pins[id])
				end
			end
		end
		local _, limited = E.Conformal.lscm(m, { iterations = 1 })
		assert(not limited.converged and limited.iterations == 1)
	end)
	test("LSCM rejects closed, disconnected, non-disk and invalid pins", function()
		fails(function()
			E.Conformal.lscm(E.Primitives.box())
		end)
		local plane = E.Primitives.grid(2, 2)
		fails(function()
			E.Conformal.lscm(E.Topology.join({ plane, E.Deform.transform(plane, CFrame.new(4, 0, 0)) }))
		end)
		fails(function()
			E.Conformal.lscm(plane, { pins = { [1] = Vector2.zero, [9] = Vector2.zero } })
		end)
		fails(function()
			E.Conformal.lscm(plane, { pins = { [5] = Vector2.zero, [9] = Vector2.one } })
		end)
	end)
	test("LSCM explicit-seam unwrap packs independent cube charts without angle distortion", function()
		local cube = E.Primitives.box()
		local m, r = E.Unwrap.unwrap(cube, E.Unwrap.sharpSeams(cube), { method = "lscm" })
		assert(r.charts == 6)
		for _, reportItem in r.reports do
			assert(reportItem.converged)
		end
		assert(E.Conformal.distortion(m).maxAngleRadians < 1e-4)
		for _, f in m.faces do
			for _, c in f.corners do
				assert(c.uv.X >= 0 and c.uv.Y >= 0 and c.uv.X <= 1 and c.uv.Y <= 1)
			end
		end
	end)
	test("adaptive refinement local density, closed topology, and immutable inputs", function()
		local source = E.Primitives.sphere(1, 8, 4)
		local count = source:validate().vertices
		local m, r = E.Adaptive.refine(source, 0.3, {
			region = function(p)
				return p.X > 0.2
			end,
			maxOperations = 300,
		})
		closed(m)
		assert(r.splits > 0 and not r.budgetReached)
		assert(source:validate().vertices == count)
		for id, p in source.vertices do
			assert(m.vertices[id] == p)
		end
		for _, e in m:topology().edges do
			local p = (m.vertices[e.a] + m.vertices[e.b]) / 2
			if p.X > 0.2 then
				assert((m.vertices[e.a] - m.vertices[e.b]).Magnitude <= 0.4 + 1e-5)
			end
		end
		near(m:volume(), source:volume())
	end)
	test("adaptive refinement interpolates seam corners, groups and skin weights", function()
		local source = E.Primitives.box()
		source.groups.x = {}
		for id, p in source.vertices do
			source.weights[id] = { [1] = (p.X + 1) / 2, [2] = (1 - p.X) / 2 }
			source.groups.x[id] = (p.X + 1) / 2
		end
		local m = E.Adaptive.refine(source, 0.8)
		closed(m)
		for id, p in m.vertices do
			near(m.weights[id][1], (p.X + 1) / 2)
			near(m.groups.x[id], (p.X + 1) / 2)
		end
		for _, f in m.faces do
			for _, c in f.corners do
				assert(c.uv and c.normal)
			end
		end
	end)
	test("adaptive isotropic remesh collapses, flips, and projects to reference", function()
		local source = E.Primitives.sphere(1, 12, 6)
		local m, r = E.Adaptive.remesh(source, 0.5, { maxOperations = 300, iterations = 2 })
		closed(m)
		assert(r.collapses > 0 and r.splits > 0 and r.flips > 0)
		local reference = E.Spatial.new(source)
		for _, p in m.vertices do
			assert(reference:closest(p).distance < 1e-5)
		end
	end)
	test("adaptive remesh boundary constraints and operation budgets", function()
		local source = E.Primitives.grid(4, 4)
		local boundary = E.Selection.boundary(source)
		local m = E.Adaptive.remesh(source, 0.7, { iterations = 2 })
		for id in boundary do
			assert(m.vertices[id] == source.vertices[id])
		end
		local _, r = E.Adaptive.refine(source, 0.01, { maxOperations = 4 })
		assert(r.budgetReached and r.operations == 4)
	end)
	report.success = report.failed == 0
	return report
end
