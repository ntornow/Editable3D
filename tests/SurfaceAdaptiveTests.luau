return function(E)
	local N, A, S = E.NURBS, E.SurfaceAdaptive, E.Surfaces
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function patch()
		local p, w = {}, {}
		for i = 1, 4 do
			p[i], w[i] = {}, {}
			for j = 1, 4 do
				p[i][j] = Vector3.new(i - 1, j - 1, i == 2 and j == 2 and 1.5 or 0)
				w[i][j] = 1 + (i * j % 5) * 0.08
			end
		end
		return N.surface(p, 3, 3, { weights = w })
	end
	local function verifyError(surface, mesh, r)
		local eval = N.compileSurface(surface)
		local maximum = 0
		for _, f in mesh.faces do
			for _, weights in { { 1 / 3, 1 / 3, 1 / 3 }, { 0.6, 0.2, 0.2 }, { 0.1, 0.7, 0.2 } } do
				local point, uv = Vector3.zero, Vector2.zero
				for i, w in weights do
					point += mesh.vertices[f.vertices[i]] * w
					uv += f.corners[i].uv * w
				end
				maximum = math.max(maximum, (eval.evaluate(uv.X, uv.Y) - point).Magnitude)
			end
		end
		assert(maximum <= r.errorBound + 0.00003, tostring(maximum) .. " exceeds " .. r.errorBound)
	end
	test("Affine plane has zero approximation bound and needs one adaptive leaf", function()
		local s = S.plane(CFrame.identity, Vector2.new(3, 2))
		local bound = A.bound(s)
		assert(bound.errorBound < 1e-12)
		local mesh, r = A.tessellate(s, { tolerance = 0.001 })
		assert(r.converged and r.leaves == 1 and r.triangles == 4 and mesh:validate().boundaryEdges == 4)
		verifyError(s, mesh, r)
	end)
	test("Bilinear twist contributes a conservative triangle approximation bound", function()
		local s =
			N.surface({ { Vector3.zero, Vector3.yAxis }, { Vector3.xAxis, Vector3.new(1, 1, 1) } }, 1, 1)
		local bound = A.bound(s)
		assert(bound.rationalDeviation < 1e-12 and math.abs(bound.errorBound - 0.25) < 1e-12)
		local mesh, r = A.tessellate(s, { tolerance = 0.01 })
		assert(r.converged and r.leaves > 1)
		verifyError(s, mesh, r)
	end)
	test("Rational adaptive tessellation bounds pointwise error inside every tested triangle", function()
		local s = patch()
		local mesh, r = A.tessellate(s, { tolerance = 0.03 })
		assert(r.converged and r.errorBound <= 0.03 and r.leaves > 4)
		assert(mesh:validate().valid and E.UV.validate(mesh).valid)
		verifyError(s, mesh, r)
		local finer, fr = A.tessellate(s, { tolerance = 0.01 })
		assert(fr.converged and fr.leaves > r.leaves)
		verifyError(s, finer, fr)
	end)
	test("Adaptive neighboring leaves share all edge vertices without interior cracks", function()
		local p = {}
		for i = 1, 5 do
			p[i] = {}
			for j = 1, 5 do
				p[i][j] = Vector3.new(i - 1, j - 1, i <= 2 and j <= 2 and 0.8 * i * j or 0)
			end
		end
		local s = N.surface(p, 3, 3)
		local mesh, r = A.tessellate(s, { tolerance = 0.04 })
		assert(r.converged)
		for _, edge in mesh:topology().edges do
			if #edge.faces == 1 then
				local a, b = mesh.vertices[edge.a], mesh.vertices[edge.b]
				local onBoundary = (math.abs(a.X) < 1e-6 and math.abs(b.X) < 1e-6)
					or (math.abs(a.X - 4) < 1e-6 and math.abs(b.X - 4) < 1e-6)
					or (math.abs(a.Y) < 1e-6 and math.abs(b.Y) < 1e-6)
					or (math.abs(a.Y - 4) < 1e-6 and math.abs(b.Y - 4) < 1e-6)
				assert(onBoundary, "Interior T-junction boundary")
			end
		end
	end)
	test("Adaptive sphere closes angular seams and pole fans with preserved error bound", function()
		local s = S.sphere(CFrame.identity, 2)
		local mesh, r = A.tessellate(s, { tolerance = 0.08, closedV = true, collapsePoles = true })
		assert(r.converged and mesh:validate().closed and mesh:volume() > 30)
		verifyError(s, mesh, r)
	end)
	test("Adaptive torus synchronizes both periodic boundaries despite uneven subdivisions", function()
		local s = S.torus(CFrame.identity, 3, 1)
		local mesh, r = A.tessellate(s, { tolerance = 0.08, closedU = true, closedV = true })
		assert(r.converged and mesh:validate().closed and mesh:volume() > 50)
		verifyError(s, mesh, r)
	end)
	test("Adaptive budget reports distinguish approximation failure from valid mesh topology", function()
		local s = patch()
		local mesh, r = A.tessellate(s, { tolerance = 1e-8, maxLeaves = 1 })
		assert(not r.converged and r.reason and r.errorBound > 1e-8 and mesh:validate().valid)
		assert(not pcall(function()
			A.tessellate(s, { maxVertices = 2 })
		end))
		assert(not pcall(function()
			A.tessellate(s, { maxTriangles = 1 })
		end))
		assert(not pcall(function()
			A.tessellate(s, {
				checkpoint = function()
					error("cancel")
				end,
			})
		end))
		assert(not pcall(function()
			A.tessellate(S.sphere(CFrame.identity, 1), { closedU = true, collapsePoles = true })
		end))
	end)
	test("Adaptive triangles and corner attributes survive native EditableMesh conversion", function()
		local s = patch()
		local mesh = A.tessellate(s, { tolerance = 0.04, material = 3 })
		local h = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local copy = E.Roblox.fromEditable(h.editable)
			assert(
				copy:validate().valid and #copy:triangles() == #mesh:triangles() and E.UV.validate(copy).valid
			)
			for id, p in mesh.vertices do
				assert((h.editable:GetPosition(h.vertexIds[id]) + h.origin - p).Magnitude < 1e-5)
			end
		end)
		h.editable:Destroy()
		assert(ok, err)
	end)
	test("Adaptive bounds retain scale and common rational weight invariance", function()
		local source = patch()
		local baseline, br = A.tessellate(source, { tolerance = 0.03 })
		for _, scale in { 0.01, 100 } do
			local s = patch()
			for i, row in s.control do
				for j, p in row do
					s.control[i][j] = p * scale
					s.weights[i][j] *= 1e150
				end
			end
			local mesh, r = A.tessellate(s, { tolerance = 0.03 * scale, seamTolerance = 1e-5 * scale })
			assert(r.converged and r.leaves == br.leaves)
			assert(math.abs(r.errorBound / scale - br.errorBound) < 0.00002)
			verifyError(s, mesh, r)
		end
		assert(baseline:validate().valid)
	end)
	test("Adaptive world translation retains topology within explicit native precision tolerance", function()
		local s = patch()
		local base, br = A.tessellate(s, { tolerance = 0.03 })
		local offset = Vector3.new(32, 64, -16)
		for i, row in s.control do
			for j, p in row do
				s.control[i][j] = p + offset
			end
		end
		local mesh, r = A.tessellate(s, { tolerance = 0.03, seamTolerance = 0.0001 })
		assert(r.converged and r.leaves == br.leaves and #mesh:triangles() == #base:triangles())
		verifyError(s, mesh, r)
	end)
	report.success = report.failed == 0
	return report
end
