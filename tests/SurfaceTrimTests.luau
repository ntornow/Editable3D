return function(E)
	local T, S, N = E.SurfaceTrim, E.Surfaces, E.NURBS
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local outer = { Vector2.zero, Vector2.xAxis, Vector2.one, Vector2.yAxis }
	local hole =
		{ Vector2.new(0.25, 0.25), Vector2.new(0.75, 0.25), Vector2.new(0.75, 0.75), Vector2.new(0.25, 0.75) }
	test("Trim classification and evaluation respect outer and hole boundaries", function()
		local t = T.surface(S.plane(CFrame.identity, Vector2.new(2, 2)), outer, { hole })
		assert(T.classify(t, Vector2.new(0.1, 0.1)) == "inside")
		assert(T.classify(t, Vector2.one * 0.5) == "outside")
		assert(T.classify(t, Vector2.new(0.25, 0.5)) == "boundary")
		assert((T.evaluate(t, 0.25, 0.5) - Vector3.new(-0.5, 0, 0)).Magnitude < 1e-6)
		assert(not pcall(function()
			T.evaluate(t, 0.5, 0.5)
		end))
		assert(#outer == 4 and hole[1] == Vector2.new(0.25, 0.25))
	end)
	test("Trimmed plane triangles preserve area and both boundary loops after subdivision", function()
		local t = T.surface(S.plane(CFrame.identity, Vector2.new(2, 2)), outer, { hole })
		local mesh, r = T.tessellate(t, { levels = 2 })
		local v = mesh:validate()
		assert(v.valid and v.boundaryEdges == 32 and #mesh:triangles() == 128)
		assert(r.parameterArea == 0.75 and r.boundaryEdges == 32 and r.geometricErrorBound == false)
		local area = 0
		for id in mesh.faces do
			local _, value = mesh:faceNormal(id)
			area += value
		end
		assert(math.abs(area - 3) < 1e-6)
	end)
	test("Trimmed curved meshes sample the exact surface and leave hole interiors empty", function()
		local s = S.sphere(CFrame.identity, 2)
		local rim =
			{ Vector2.new(0.15, 0.1), Vector2.new(0.85, 0.1), Vector2.new(0.85, 0.9), Vector2.new(0.15, 0.9) }
		local t = T.surface(s, rim, { hole })
		local mesh, r = T.tessellate(t, { levels = 3, material = 2 })
		assert(mesh:validate().valid and r.triangles == 512)
		for _, face in mesh.faces do
			local center = Vector2.zero
			assert(face.material == 2)
			for i, id in face.vertices do
				local uv = face.corners[i].uv
				center += uv / 3
				assert((mesh.vertices[id] - N.evaluateSurface(s, uv.X, uv.Y)).Magnitude < 1e-5)
			end
			assert(T.classify(t, center) == "inside")
		end
	end)
	test("Rational trim curves provide explicit approximation reports for a circular annulus", function()
		local c = S.arc(CFrame.new(0.5, 0.5, 0), 0.45, 0, 2 * math.pi)
		local h = S.arc(CFrame.new(0.5, 0.5, 0), 0.15, 0, 2 * math.pi)
		local t, r = T.fromCurves(S.plane(CFrame.identity, Vector2.one), c, { h }, { curveTolerance = 0.002 })
		assert(#r.curves == 2 and r.curves[1].converged and r.curves[2].errorBound <= 0.002)
		assert(T.classify(t, Vector2.one * 0.5) == "outside")
		local mesh, m = T.tessellate(t, { levels = 1 })
		assert(mesh:validate().valid and m.boundaryEdges == 2 * (#t.outer + #t.holes[1]))
		assert(math.abs(m.parameterArea - math.pi * (0.45 ^ 2 - 0.15 ^ 2)) < 0.008)
	end)
	test("Trim constructors copy source controls and loops before later edits", function()
		local s = S.plane(CFrame.identity, Vector2.one)
		local loop = table.clone(outer)
		local t = T.surface(s, loop)
		s.control[1][1] = Vector3.new(10, 10, 10)
		loop[1] = Vector2.new(0.2, 0.2)
		assert(t.surface.control[1][1] ~= s.control[1][1] and t.outer[1] == Vector2.zero)
	end)
	test("Invalid domains open curves unresolved poles and allocation budgets reject", function()
		local s = S.plane(CFrame.identity, Vector2.one)
		local t = T.surface(s, outer)
		assert(not pcall(function()
			T.surface(s, { Vector2.zero, Vector2.new(2, 0), Vector2.one })
		end))
		assert(not pcall(function()
			T.fromCurves(s, N.curve({ Vector3.zero, Vector3.xAxis }, 1))
		end))
		assert(not pcall(function()
			T.tessellate(t, { levels = 8, maxTriangles = 1000 })
		end))
		assert(not pcall(function()
			T.tessellate(t, { maxVertices = 5 })
		end))
		assert(not pcall(function()
			T.tessellate(T.surface(S.sphere(CFrame.identity, 1), outer), { levels = 0 })
		end))
	end)
	test("Trim cancellation leaves source domains intact", function()
		local t = T.surface(S.plane(CFrame.identity, Vector2.one), outer, { hole })
		assert(not pcall(function()
			T.tessellate(t, {
				checkpoint = function()
					error("cancel")
				end,
			})
		end))
		assert(#t.outer == 4 and #t.holes[1] == 4)
	end)
	test("Trim mesh UV holes and normals survive native EditableMesh roundtrip", function()
		local t = T.surface(S.plane(CFrame.identity, Vector2.new(2, 2)), outer, { hole })
		local mesh = T.tessellate(t, { levels = 2 })
		local h = E.Roblox.toEditable(mesh)
		local ok, err = pcall(function()
			local copy = E.Roblox.fromEditable(h.editable)
			assert(copy:validate().valid and copy:validate().boundaryEdges == 32 and #copy:triangles() == 128)
			for _, face in copy.faces do
				for _, corner in face.corners do
					assert(corner.normal.Z > 0.99)
				end
			end
		end)
		h.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
