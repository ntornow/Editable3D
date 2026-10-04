return function(E)
	local T, N, S = E.SurfaceTrim, E.NURBS, E.Surfaces
	local Clip = require(script.Parent.TrimClip)
	local fixtures = require(script.Parent.TrimClipFixtures)
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
	local function plane()
		return S.plane(CFrame.identity, v(2, 2))
	end
	local function torus()
		return S.torus(CFrame.identity, 3, 1)
	end
	local function near(a, b, t)
		assert(math.abs(a - b) <= (t or 1e-10), tostring(a) .. " ~= " .. tostring(b))
	end
	local function rejects(fn)
		assert(not pcall(fn), "Expected explicit rejection")
	end
	local function topology(m, components, loops, euler)
		local c = E.Connectivity.analyze(m)
		assert(c.valid and #c.components == components)
		assert(#c.boundaryLoops == loops and c.eulerCharacteristic == euler)
	end
	local function tess(regions, options, source)
		local set, d = T.regions(source or torus(), regions, options or { closedU = true, closedV = true })
		local mesh, r = T.adaptive(set, { tolerance = 0.3, maxWork = 10000000 })
		assert(r.converged and r.errorBound <= 0.3)
		return mesh, r, set, d
	end
	test("Exact clipping matches 160 independent rational vertex and distance references", function()
		for index, f in fixtures do
			local ring = {}
			for _, p in f.input do
				table.insert(ring, v(p[1], p[2]))
			end
			local out, bound = Clip.clip(ring, f.shift[1], f.shift[2], function() end)
			assert((out and #out or 0) == #f.output, "Vertex count " .. index)
			if out then
				for _, p in f.output do
					local expected = v(p[1], p[2])
					local found = false
					for _, q in out do
						if q == expected then
							found = true
							break
						end
					end
					assert(found, "Rational construction " .. index)
				end
				assert(
					bound >= f.bound and bound <= f.bound * (1 + 1e-12) + 1e-300,
					"Outward bound " .. index
				)
			end
		end
	end)
	test("Clipped midpoint ties round to the even native coordinate on both parity cases", function()
		for k = 0, 3 do
			local a = 0.5 + k * 2 ^ -24
			local path, bound = Clip.clip(
				{ v(-0.5, a), v(0.5, a + 2 ^ -24), v(0.5, 0.75) },
				0,
				0,
				function() end
			)
			local expected = 0.5 + (k + k % 2) * 2 ^ -24
			local found = false
			for _, p in path do
				if p.X == 0 and p.Y == expected then
					found = true
				end
			end
			assert(found and bound >= 2 ^ -25)
		end
	end)
	test("Disconnected regions classify evaluate and uniformly tessellate with independent areas", function()
		local set, r = T.regions(
			plane(),
			{ { outer = box(0.125, 0.125, 0.375, 0.875) }, { outer = box(0.625, 0.125, 0.875, 0.875) } }
		)
		assert(#set.regions == 2 and r.complete)
		near(r.area, 0.375)
		assert(T.classify(set, v(0.25, 0.5)) == "inside" and T.classify(set, v(0.5, 0.5)) == "outside")
		assert(T.classify(set, v(0.125, 0.5)) == "boundary")
		assert(T.evaluate(set, 0.25, 0.5) == N.evaluateSurface(set.surface, 0.25, 0.5))
		rejects(function()
			T.evaluate(set, 0.5, 0.5)
		end)
		local mesh, m = T.tessellate(set, { levels = 2, material = "regions" })
		topology(mesh, 2, 2, 2)
		near(m.parameterArea, 0.375)
		local area = 0
		for fid, f in mesh.faces do
			local _, a = mesh:faceNormal(fid)
			area += a
			assert(f.material == "regions")
		end
		near(area, 1.5, 1e-6)
		assert(not m.geometricErrorBound and m.periodicWelding == false)
	end)
	test("Overlapping duplicate and edge touching exteriors use union rather than parity", function()
		for _, case in
			{
				{
					regions = {
						{ outer = box(0.125, 0.125, 0.625, 0.625) },
						{ outer = box(0.375, 0.375, 0.875, 0.875) },
					},
					area = 0.4375,
				},
				{
					regions = {
						{ outer = box(0.125, 0.125, 0.5, 0.5) },
						{ outer = box(0.125, 0.125, 0.5, 0.5) },
					},
					area = 0.140625,
				},
				{
					regions = {
						{ outer = box(0.125, 0.125, 0.5, 0.5) },
						{ outer = box(0.5, 0.125, 0.875, 0.5) },
					},
					area = 0.28125,
				},
			}
		do
			local set, r = T.regions(plane(), case.regions)
			near(r.area, case.area)
			assert(#set.regions == 1)
		end
	end)
	test("Nested islands and overlapping exteriors preserve or cover holes by region membership", function()
		local ring = { outer = box(0.125, 0.125, 0.875, 0.875), holes = { box(0.25, 0.25, 0.75, 0.75) } }
		local set, r = T.regions(plane(), { ring, { outer = box(0.375, 0.375, 0.625, 0.625) } })
		near(r.area, 0.375)
		assert(
			#set.regions == 2
				and T.classify(set, v(0.5, 0.5)) == "inside"
				and T.classify(set, v(0.3, 0.5)) == "outside"
		)
		local covered, cr = T.regions(plane(), { ring, { outer = box(0.25, 0.25, 0.75, 0.75) } })
		near(cr.area, 0.5625)
		assert(#covered.regions == 1 and #covered.regions[1].holes == 0)
	end)
	test("Concave clipping decomposes weak boundary walks into three simple regions", function()
		local ring = {
			v(0.625, 0.125),
			v(1.375, 0.125),
			v(1.375, 0.375),
			v(0.875, 0.375),
			v(0.875, 0.625),
			v(1.375, 0.625),
			v(1.375, 0.875),
			v(0.625, 0.875),
		}
		local set, r = T.regions(plane(), { { outer = ring } }, { closedU = true })
		assert(#set.regions == 3)
		near(r.area, 0.4375)
		local m = T.tessellate(set, { levels = 1 })
		topology(m, 3, 3, 3)
	end)
	test("A wrapped disk joins its two chart pieces and keeps both seam UV records", function()
		local mesh, _, _, d = tess({ { outer = box(0.75, 0.25, 1.25, 0.75) } })
		topology(mesh, 1, 1, 1)
		assert(d.regions == 2)
		local seen = {}
		local shared = false
		for _, f in mesh.faces do
			for i, id in f.vertices do
				local x = f.corners[i].uv.X
				if x == 0 or x == 1 then
					seen[id] = seen[id] or {}
					seen[id][x] = true
					shared = shared or seen[id][0] and seen[id][1]
				end
			end
		end
		assert(shared)
	end)
	test("A doubly wrapped corner disk joins four rectangular pieces without a pinched vertex", function()
		local mesh, _, _, d = tess({ { outer = box(0.75, 0.75, 1.25, 1.25) } })
		topology(mesh, 1, 1, 1)
		assert(d.regions == 4)
		near(d.area, 0.25)
	end)
	test("Multiple period coverage produces one band or one closed torus without duplicate faces", function()
		local band, _, _, b = tess({ { outer = box(-0.25, 0.25, 1.25, 0.75) } })
		topology(band, 1, 2, 0)
		near(b.area, 0.5)
		local closed, _, _, c = tess({ { outer = box(-0.25, -0.25, 1.25, 1.25) } })
		topology(closed, 1, 0, 0)
		near(c.area, 1)
	end)
	test("A hole crossing the seam remains one physical hole after quotient tessellation", function()
		local mesh, _, _, r =
			tess({ { outer = box(0.625, 0.125, 1.375, 0.875), holes = { box(0.875, 0.375, 1.125, 0.625) } } })
		topology(mesh, 1, 2, 0)
		near(r.area, 0.5)
	end)
	test(
		"Slanted negative-coordinate wraps have matching native seam points and explicit rounding",
		function()
			local region = { { outer = { v(-0.2, 0.15), v(0.3, 0.27), v(0.22, 0.8), v(-0.15, 0.63) } } }
			local mesh, _, _, r = tess(region)
			topology(mesh, 1, 1, 1)
			assert(r.clippingError > 0 and r.clippingError < 1e-7)
			rejects(function()
				T.regions(torus(), region, { closedU = true, closedV = true, maxClippingError = 0 })
			end)
		end
	)
	test("Integer translations and U V exchange preserve represented area and membership", function()
		local a, ar = T.regions(plane(), { { outer = box(0.75, 0.25, 1.25, 0.75) } }, { closedU = true })
		local b, br = T.regions(plane(), { { outer = box(100.75, 0.25, 101.25, 0.75) } }, { closedU = true })
		local c, cr = T.regions(plane(), { { outer = box(0.25, 0.75, 0.75, 1.25) } }, { closedV = true })
		near(ar.area, br.area)
		near(ar.area, cr.area)
		for i = 0, 8 do
			for j = 0, 8 do
				assert(T.classify(a, v(i / 8, j / 8)) == T.classify(b, v(i / 8, j / 8)))
				assert(T.classify(a, v(i / 8, j / 8)) == T.classify(c, v(j / 8, i / 8)))
			end
		end
	end)
	test("Representable narrow strips survive while subnative translated edges reject", function()
		local set, r = T.regions(plane(), { { outer = box(0.5, 0.125, 0.5 + 2 ^ -23, 0.875) } })
		near(r.area, 0.75 * 2 ^ -23, 1e-20)
		assert(#set.regions == 1)
		rejects(function()
			T.regions(plane(), { { outer = box(-2 ^ -30, 0.25, 2 ^ -30, 0.75) } }, { closedU = true })
		end)
		rejects(function()
			T.regions(plane(), { { outer = box(-2 ^ -70, 0.25, 2 ^ -70, 0.75) } }, { closedU = true })
		end)
	end)
	test(
		"Point touching unions and invalid source holes reject instead of returning pinched domains",
		function()
			rejects(function()
				T.regions(
					plane(),
					{ { outer = box(0.1, 0.1, 0.5, 0.5) }, { outer = box(0.5, 0.5, 0.9, 0.9) } }
				)
			end)
			rejects(function()
				T.regions(
					plane(),
					{ { outer = box(0.25, 0.25, 0.75, 0.75), holes = { box(0, 0, 0.125, 0.125) } } }
				)
			end)
			rejects(function()
				T.regions(plane(), { { outer = { v(0, 0), v(1, 1), v(1, 0), v(0, 1) } } })
			end)
		end
	)
	test("Constructor source options and input loops are copied before callbacks", function()
		local source = plane()
		local regions = { { outer = box(0.125, 0.125, 0.875, 0.875) } }
		local options = { closedU = false }
		options.checkpoint = function()
			source.control[1][1] = Vector3.new(100, 100, 100)
			regions[1].outer[1] = v(0.5, 0.5)
			options.closedU = true
		end
		local set, r = T.regions(source, regions, options)
		assert(set.surface.control[1][1] ~= source.control[1][1] and not set.closedU)
		near(r.area, 0.5625)
	end)
	test("Uniform and adaptive tessellation snapshot edited descriptors before callbacks", function()
		for _, method in { "tessellate", "adaptive" } do
			local set = T.regions(plane(), { { outer = box(0.125, 0.125, 0.875, 0.875) } })
			local expected = T[method](set, { levels = 1 })
			local changed = false
			local actual = T[method](set, {
				levels = 1,
				checkpoint = function()
					if not changed then
						changed = true
						set.regions[1].outer[1] = v(0.6, 0.6)
						set.surface.control[1][1] = Vector3.new(100, 100, 100)
					end
				end,
			})
			assert(changed and E.IO.encode(actual) == E.IO.encode(expected))
		end
	end)
	test("Construction allocation coordinate copy control and work limits reject transactionally", function()
		local regions = { { outer = box(0.75, 0.125, 1.25, 0.875) } }
		local original = regions[1].outer[1]
		for _, opt in
			{
				{ maxWork = 1 },
				{ maxCopies = 1 },
				{ maxRegions = 1 },
				{ maxTrimVertices = 3 },
				{ maxParameterVertices = 4 },
				{ maxParameterTriangles = 1 },
				{ maxSegments = 1 },
				{ maxCoordinate = 1 },
				{ maxControls = 4 },
			}
		do
			opt.closedU = true
			rejects(function()
				T.regions(torus(), regions, opt)
			end)
			assert(regions[1].outer[1] == original)
		end
	end)
	test("Root cancellation is checked at begin during work and after callback execution", function()
		for _, method in { "regions", "adaptive", "tessellate" } do
			local source = plane()
			local regions = { { outer = box(0.125, 0.125, 0.875, 0.875) } }
			local set = T.regions(source, regions)
			local function run(options)
				if method == "regions" then
					return T.regions(source, regions, options)
				else
					return T[method](set, options)
				end
			end
			rejects(function()
				run({
					cancelled = function()
						return true
					end,
				})
			end)
			local flag = false
			rejects(function()
				run({
					checkpoint = function()
						flag = true
					end,
					cancelled = function()
						return flag
					end,
				})
			end)
			assert(set.regions[1].outer[1] == v(0.125, 0.125))
		end
	end)
	test("Empty sets and zero uniform refinement have explicit valid results", function()
		local set, r = T.regions(plane(), {})
		assert(r.complete and r.area == 0 and #set.regions == 0)
		assert(T.classify(set, v(0.5, 0.5)) == "outside")
		rejects(function()
			T.evaluate(set, 0.5, 0.5)
		end)
		local a, ar = T.adaptive(set)
		local b, br = T.tessellate(set, { levels = 0 })
		assert(
			next(a.faces) == nil
				and next(b.faces) == nil
				and ar.converged
				and ar.errorBound == 0
				and br.levels == 0
		)
	end)
	test("Edited region sets are revalidated for contact and overlap at tessellation time", function()
		for _, method in { "adaptive", "tessellate" } do
			local set = T.regions(
				plane(),
				{ { outer = box(0.125, 0.125, 0.375, 0.875) }, { outer = box(0.625, 0.125, 0.875, 0.875) } }
			)
			set.regions[2].outer = box(0.25, 0.25, 0.75, 0.75)
			rejects(function()
				T[method](set)
			end)
		end
	end)
	test("Declared periodic geometry and invalid nonperiodic unwrapped coordinates reject", function()
		rejects(function()
			T.regions(plane(), { { outer = box(0.75, 0.25, 1.25, 0.75) } })
		end)
		local set = T.regions(plane(), { { outer = box(0.75, 0.25, 1.25, 0.75) } }, { closedU = true })
		rejects(function()
			T.adaptive(set)
		end)
		rejects(function()
			T.regions(plane(), { { outer = box(0.25, 0.25, 0.75, 0.75) } }, { closedU = "yes" })
		end)
	end)
	test("Adaptive depth limits return a valid partial mesh with the actual remaining bound", function()
		local set = T.regions(
			torus(),
			{ { outer = box(0.75, 0.25, 1.25, 0.75) } },
			{ closedU = true, closedV = true }
		)
		local mesh, r = T.adaptive(set, { tolerance = 1e-5, maxDepth = 0 })
		assert(not r.converged and r.errorBound > 1e-5 and r.reason)
		topology(mesh, 1, 1, 1)
	end)
	test("A wrapped polar region shares one pole while preserving its boundary fan", function()
		local set = T.regions(
			S.sphere(CFrame.identity, 2),
			{ { outer = box(0, 0.75, 0.3, 1.25) } },
			{ closedV = true }
		)
		local mesh, r = T.adaptive(set, { tolerance = 0.2, collapsePoles = true, maxWork = 10000000 })
		assert(r.converged and r.collapsedPoleTriangles > 0)
		topology(mesh, 1, 1, 1)
	end)
	test("Wrapped surface regions preserve native position normal and seam UV topology", function()
		local bundle = require(script.Parent.Examples.PeriodicTrimWindow)(E)
		local native = E.Roblox.toEditable(bundle.mesh)
		local restored = E.Roblox.fromEditable(native.editable)
		native.editable:Destroy()
		assert(restored:validate().valid)
		topology(restored, 1, 2, 0)
	end)
	report.success = report.failed == 0
	return report
end
