return function(E)
	local T, N, S = E.SurfaceTrim, E.NURBS, E.Surfaces
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local v = Vector2.new
	local function box(a, b, c, d)
		return { v(a, b), v(c, b), v(c, d), v(a, d) }
	end
	local outer, hole = box(0, 0, 1, 1), box(0.25, 0.25, 0.75, 0.75)
	local function near(a, b, e)
		assert(math.abs(a - b) <= (e or 1e-5), a .. " ~= " .. b)
	end
	local function area(m)
		local total = 0
		for fid in m.faces do
			local _, a = m:faceNormal(fid)
			total += a
		end
		return total
	end
	local function patch(count)
		local p, w = {}, {}
		for i = 1, count or 4 do
			p[i], w[i] = {}, {}
			for j = 1, count or 4 do
				p[i][j] = Vector3.new(i - 1, j - 1, i == 2 and j == 2 and 1.5 or 0)
				w[i][j] = 1 + (i * j % 5) * 0.08
			end
		end
		return N.surface(p, 3, 3, { weights = w })
	end
	local function verify(t, mesh, r, slack)
		assert(mesh:validate().valid and r.geometricErrorBound)
		local evaluator = N.compileSurface(t.surface)
		for fid, f in mesh.faces do
			for _, weights in { { 1 / 3, 1 / 3, 1 / 3 }, { 0.6, 0.2, 0.2 }, { 0.1, 0.7, 0.2 } } do
				local x, y, z, u, w = 0, 0, 0, 0, 0
				for i, weight in weights do
					local p, uv = mesh.vertices[f.vertices[i]], f.corners[i].uv
					x += p.X * weight
					y += p.Y * weight
					z += p.Z * weight
					u += uv.X * weight
					w += uv.Y * weight
				end
				local distance = (evaluator.evaluate(u, w) - Vector3.new(x, y, z)).Magnitude
				assert(
					distance <= r.faceErrorBounds[fid] + (slack or 3e-5),
					distance .. " exceeds face bound " .. r.faceErrorBounds[fid]
				)
				assert(T.classify(t, v(u, w)) ~= "outside", "Triangle entered an excluded trim region")
			end
		end
	end
	test("Adaptive affine trim preserves exact area and holes with zero geometric bound", function()
		local t = T.surface(S.plane(CFrame.identity, v(2, 2)), outer, { hole })
		local m, r = T.adaptive(t, { tolerance = 1e-5 })
		assert(r.converged and r.leaves == 1 and r.triangles == 8 and r.boundaryEdges == 8)
		near(r.errorBound, 0, 1e-12)
		near(r.parameterArea, 0.75)
		near(area(m), 3)
		verify(t, m, r)
	end)
	test("Adaptive rational trim bounds interior triangle samples while excluding curved holes", function()
		local source = patch()
		local c = S.arc(CFrame.new(0.5, 0.5, 0), 0.45, 0, 2 * math.pi)
		local h = S.arc(CFrame.new(0.5, 0.5, 0), 0.15, 0, 2 * math.pi)
		local t = T.fromCurves(source, c, { h }, { curveTolerance = 0.005 })
		local m, r = T.adaptive(t, { tolerance = 0.08, material = "trimmed" })
		assert(r.converged and r.errorBound <= 0.08 and r.leaves > 1)
		near(r.parameterArea, r.originalParameterArea, 1e-6)
		for _, face in m.faces do
			assert(face.material == "trimmed")
		end
		verify(t, m, r)
	end)
	test("Nonuniform trim refinement has no interior cracks or missing trim edges", function()
		local t = T.surface(patch(5), box(0.05, 0.03, 0.93, 0.91), { box(0.31, 0.37, 0.67, 0.63) })
		local m, r = T.adaptive(t, { tolerance = 0.08 })
		assert(r.converged)
		local uvByVertex = {}
		for _, face in m.faces do
			for i, id in face.vertices do
				uvByVertex[id] = face.corners[i].uv
			end
		end
		for _, edge in m:topology().edges do
			if #edge.faces == 1 then
				local a, b = uvByVertex[edge.a], uvByVertex[edge.b]
				local matched = false
				for _, loop in r.trimLoops do
					for i, p in loop do
						local q = loop[i % #loop + 1]
						if a == p and b == q or a == q and b == p then
							matched = true
						end
					end
				end
				assert(matched, "Interior adaptive trim crack")
			end
		end
		verify(t, m, r)
	end)
	test("Concave exteriors and several excluded regions survive adaptive clipping", function()
		local shape = { v(0, 0), v(1, 0), v(1, 0.4), v(0.4, 0.4), v(0.4, 1), v(0, 1) }
		local holes = { box(0.1, 0.1, 0.2, 0.2), box(0.6, 0.1, 0.8, 0.3) }
		local t = T.surface(patch(), shape, holes)
		local m, r = T.adaptive(t, { tolerance = 0.12 })
		assert(r.converged)
		near(r.parameterArea, 0.59)
		verify(t, m, r)
	end)
	test("Adaptive trims prune distant excluded patches before refinement", function()
		local t = T.surface(patch(5), box(0.02, 0.02, 0.14, 0.14))
		local m, r = T.adaptive(t, { tolerance = 0.02 })
		assert(r.converged and r.discardedLeaves > 0 and r.partitionLeaves > r.leaves)
		near(r.parameterArea, 0.12 ^ 2)
		verify(t, m, r)
	end)
	test("A complete trimmed sphere closes its periodic seam and collapses both poles", function()
		local t = T.surface(S.sphere(CFrame.identity, 2), outer)
		local m, r = T.adaptive(t, { tolerance = 0.4, closedV = true, collapsePoles = true })
		assert(r.converged and m:validate().closed and r.poles.U0 and r.poles.U1)
		assert(r.collapsedPoleTriangles > 0 and m:volume() > 30)
		near(r.parameterArea, 1)
		for _, face in m.faces do
			for i, id in face.vertices do
				assert(face.corners[i].normal:Dot(m.vertices[id].Unit) > 0.98)
			end
		end
		verify(t, m, r)
	end)
	test("Trimmed sphere bands weld seam samples and retain exactly two physical boundary loops", function()
		local t = T.surface(S.sphere(CFrame.identity, 2), box(0.25, 0, 0.75, 1))
		local m, r = T.adaptive(t, { tolerance = 0.4, closedV = true })
		assert(r.converged and m:validate().valid and not m:validate().closed)
		local loops = E.Connectivity.boundaries(m)
		assert(#loops == 2)
		local uv0, uv1 = {}, {}
		for _, face in m.faces do
			for i, id in face.vertices do
				if face.corners[i].uv.Y == 0 then
					uv0[id] = true
				end
				if face.corners[i].uv.Y == 1 then
					uv1[id] = true
				end
			end
		end
		local n = 0
		for id in uv0 do
			assert(uv1[id])
			n += 1
		end
		assert(n > 2)
		verify(t, m, r)
	end)
	test("Periodic trim holes preserve both torus seams and the hole boundary", function()
		local t = T.surface(S.torus(CFrame.identity, 3, 1), outer, { hole })
		local m, r = T.adaptive(t, { tolerance = 0.6, closedU = true, closedV = true })
		assert(r.converged and m:validate().valid and not m:validate().closed)
		assert(#E.Connectivity.boundaries(m) == 1)
		near(r.parameterArea, 0.75)
		verify(t, m, r)
	end)
	test("Partial pole domains form valid boundary fans with separate corner UVs", function()
		local t = T.surface(S.sphere(CFrame.identity, 2), box(0, 0.1, 0.35, 0.7))
		local m, r = T.adaptive(t, { tolerance = 0.4, collapsePoles = true })
		assert(r.converged and r.poles.U0 and not m:validate().closed)
		assert(#E.Connectivity.boundaries(m) == 1 and r.collapsedPoleTriangles > 0)
		verify(t, m, r)
	end)
	test("Trim approximation failure reports a useful valid mesh and an actual remaining bound", function()
		local t = T.surface(patch(), outer, { hole })
		local m, r = T.adaptive(t, { tolerance = 1e-9, maxDepth = 0 })
		assert(not r.converged and r.reason and r.errorBound > 1e-9 and m:validate().valid)
		verify(t, m, r)
	end)
	test("Non-native knot boundaries add an explicit parameter-rounding contribution", function()
		local s = patch(5)
		s.knotsU[5], s.knotsV[5] = 1 / 3, 2 / 3
		local t = T.surface(s, box(0.07, 0.11, 0.9, 0.88), { box(0.4, 0.4, 0.6, 0.6) })
		local m, r = T.adaptive(t, { tolerance = 0.15 })
		assert(r.converged and r.parameterRoundingBound > 0)
		verify(t, m, r)
	end)
	test("Adaptive trim geometry and bounds retain scale translation and common-weight behavior", function()
		for _, scale in { 0.1, 10 } do
			local s = patch()
			local offset = Vector3.new(4, -8, 2) * scale
			for i, row in s.control do
				for j, p in row do
					s.control[i][j] = p * scale + offset
					s.weights[i][j] *= 1e100
				end
			end
			local t = T.surface(s, box(0.1, 0.1, 0.9, 0.9), { hole })
			local m, r = T.adaptive(t, { tolerance = 0.15 * scale, seamTolerance = 1e-4 * scale })
			assert(r.converged and r.errorBound <= 0.15 * scale)
			verify(t, m, r, 3e-5 * scale)
		end
	end)
	test("Invalid trim domains singularities and mismatched periodic boundaries reject", function()
		local plane = T.surface(S.plane(CFrame.identity, v(2, 2)), outer)
		assert(not pcall(T.adaptive, plane, { closedU = true }))
		local sphere = T.surface(S.sphere(CFrame.identity, 1), outer)
		assert(not pcall(T.adaptive, sphere, { tolerance = 0.6 }))
		plane.outer[2] = v(-1, 0)
		assert(not pcall(T.adaptive, plane))
	end)
	test("Adaptive trim allocation work and cancellation limits preserve source data", function()
		local t = T.surface(patch(), outer, { hole })
		local original = t.surface.control[2][2]
		for _, options in
			{
				{ maxVertices = 3 },
				{ maxTriangles = 1 },
				{ maxWork = 10 },
				{ maxParameterVertices = 4 },
				{ maxParameterTriangles = 2 },
				{ maxSegments = 4 },
				{ maxTrimVertices = 3 },
				{ maxDepth = 25 },
				{ tolerance = -1 },
				{
					checkpoint = function(progress)
						if progress.stage == "refine" then
							error("cancel trim refinement")
						end
					end,
				},
			}
		do
			assert(not pcall(T.adaptive, t, options))
		end
		assert(t.surface.control[2][2] == original and #t.outer == 4 and #t.holes[1] == 4)
	end)
	test("Adaptive trim meshes preserve holes normals and UVs through native EditableMesh", function()
		local t = T.surface(patch(), outer, { hole })
		local m = T.adaptive(t, { tolerance = 0.15 })
		local handle = E.Roblox.toEditable(m)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid and #restored:triangles() == #m:triangles())
			assert(restored:validate().boundaryEdges == m:validate().boundaryEdges)
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal.Magnitude > 0.99)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Asymmetric seam trim contacts synchronize unequal boundary partitions", function()
		local shape = { v(0.17, 0), v(0.79, 0), v(0.71, 1), v(0.29, 1) }
		local t = T.surface(S.sphere(CFrame.identity, 2), shape)
		local m, r = T.adaptive(t, { tolerance = 0.5, closedV = true })
		assert(r.converged and m:validate().valid and #E.Connectivity.boundaries(m) == 2)
		verify(t, m, r)
	end)
	test("Trimmed polar caps combine periodic welding with a single collapsed pole", function()
		local t = T.surface(S.sphere(CFrame.identity, 2), box(0, 0, 0.35, 1))
		local m, r = T.adaptive(t, { tolerance = 0.4, closedV = true, collapsePoles = true })
		assert(r.converged and r.collapsedPoleTriangles > 0 and #E.Connectivity.boundaries(m) == 1)
		verify(t, m, r)
	end)
	test("Thin representable trim strips retain hole topology without centroid classification", function()
		local width = 2 ^ -18
		local t =
			T.surface(S.plane(CFrame.identity, v(2, 2)), outer, { box(width, width, 1 - width, 1 - width) })
		local m, r = T.adaptive(t, { tolerance = 0.01 })
		assert(r.converged and r.boundaryEdges == 8 and #E.Connectivity.boundaries(m) == 2)
		near(r.parameterArea, 1 - (1 - 2 * width) ^ 2, 1e-12)
		near(area(m), 4 * r.parameterArea, 1e-9)
		verify(t, m, r)
	end)
	report.success = report.failed == 0
	return report
end
