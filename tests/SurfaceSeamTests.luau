return function(E)
	local N, S = E.NURBS, E.Surfaces
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	test("Sphere pole fans and periodic seam make one outward closed manifold", function()
		local mesh, r =
			N.tessellate(S.sphere(CFrame.identity, 2), 16, 24, { closedV = true, collapsePoles = true })
		local v = mesh:validate()
		assert(v.valid and v.boundaryEdges == 0 and v.nonmanifoldEdges == 0)
		assert(v.vertices == 15 * 24 + 2 and r.collapsedQuads == 48 and r.poles.U0 and r.poles.U1)
		assert(mesh:volume() > 31 and mesh:volume() < 34)
		assert(E.UV.validate(mesh).valid)
		for _, f in mesh.faces do
			for _, c in f.corners do
				assert(c.normal.Magnitude > 0.999)
			end
		end
	end)
	test("Doubly closed torus retains separate UV corners on shared vertices", function()
		local mesh = N.tessellate(S.torus(CFrame.identity, 3, 1), 16, 24, { closedU = true, closedV = true })
		local v = mesh:validate()
		assert(v.valid and v.boundaryEdges == 0 and v.vertices == 16 * 24)
		local charts = {}
		for _, f in mesh.faces do
			for i, id in f.vertices do
				local uv = f.corners[i].uv
				charts[id] = charts[id] or {}
				charts[id][tostring(uv)] = true
			end
		end
		local seams = 0
		for _, set in charts do
			local count = 0
			for _ in set do
				count += 1
			end
			if count > 1 then
				seams += 1
			end
		end
		assert(seams >= 16 + 24 - 1 and mesh:volume() > 50)
	end)
	test("Open cone pole fan retains its base boundary and directional apex normals", function()
		local mesh, r =
			N.tessellate(S.cone(CFrame.identity, 2, 3), 8, 24, { closedV = true, collapsePoles = true })
		local v = mesh:validate()
		assert(v.valid and v.boundaryEdges == 24 and v.vertices == 8 * 24 + 1 and r.poles.U0)
		assert(r.collapsedQuads == 24)
		local normals = {}
		for _, f in mesh.faces do
			for i, id in f.vertices do
				if (mesh.vertices[id] - Vector3.new(0, 0, 3)).Magnitude < 1e-6 then
					table.insert(normals, f.corners[i].normal)
				end
			end
		end
		assert(#normals == 24 and normals[1]:Dot(normals[13]) < 0.5)
	end)
	test("Seam closure rejects open edges maps that separate the seam and insufficient samples", function()
		local plane = S.plane(CFrame.identity, Vector2.one)
		assert(not pcall(function()
			N.tessellate(plane, 8, 8, { closedU = true })
		end))
		local cylinder = S.cylinder(CFrame.identity, 1, 2)
		assert(not pcall(function()
			N.tessellate(cylinder, 2, 8, { closedU = true })
		end))
		assert(not pcall(function()
			N.tessellate(cylinder, 8, 8, {
				closedU = true,
				map = function(p, uv)
					return p + Vector3.xAxis * uv.X
				end,
			})
		end))
		assert(not pcall(function()
			N.tessellate(S.sphere(CFrame.identity, 1), 8, 8)
		end))
	end)
	test("Closed pole meshes roundtrip through native EditableMesh without topology loss", function()
		local mesh =
			N.tessellate(S.sphere(CFrame.identity, 1), 8, 12, { closedV = true, collapsePoles = true })
		local handle = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			local v = restored:validate()
			assert(v.valid and v.boundaryEdges == 0 and #restored:triangles() == #mesh:triangles())
			assert(E.UV.validate(restored).valid)
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
