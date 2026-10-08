-- Runs on demand. Temporary native assets are destroyed after each integration test.
return function(API, options)
	options = options or {}
	local tests = {}
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		table.insert(tests, { name, fn })
	end
	local function near(a, b, e)
		assert(math.abs(a - b) <= (e or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function vec(a, b, e)
		assert((a - b).Magnitude <= (e or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function closed(m)
		local r = m:validate()
		assert(r.valid and r.closed, game:GetService("HttpService"):JSONEncode(r))
		assert(m:volume() > 0)
	end
	test("box topology and signed volume", function()
		local m = API.Primitives.box()
		closed(m)
		near(m:volume(), 8)
		assert(m:validate().vertices == 8 and #m:triangles() == 12)
	end)
	test("sphere, cylinder, torus outward closed surfaces", function()
		for _, m in { API.Primitives.sphere(1, 16, 8), API.Primitives.cylinder(), API.Primitives.torus() } do
			closed(m)
		end
		near(API.Primitives.sphere(1, 32, 16):volume(), 4 * math.pi / 3, 0.08)
	end)
	test("concave polygon triangulation conserves area", function()
		local m = API.Mesh.new()
		for _, p in
			{
				Vector3.new(0, 0, 0),
				Vector3.new(2, 0, 0),
				Vector3.new(2, 1, 0),
				Vector3.new(1, 1, 0),
				Vector3.new(1, 2, 0),
				Vector3.new(0, 2, 0),
			}
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3, 4, 5, 6 })
		local area = 0
		for _, t in m:triangles() do
			area += (m.vertices[t[2]] - m.vertices[t[1]]):Cross(m.vertices[t[3]] - m.vertices[t[1]]).Magnitude / 2
		end
		near(area, 3)
		assert(#m:triangles() == 4)
	end)
	test("Catmull Clark counts and boundary preservation", function()
		local m = API.Subdivision.catmullClark(API.Primitives.box(), 2)
		closed(m)
		assert(m:validate().faces == 96 and m:validate().vertices == 98)
		local grid = API.Subdivision.catmullClark(API.Primitives.grid(1, 1), 1)
		assert(grid:validate().boundaryEdges == 8)
		vec(grid.vertices[1], Vector3.new(-0.75, 0, -0.75))
	end)
	test("extrusion and inset maintain closed topology", function()
		local box = API.Primitives.box()
		local m = API.Topology.extrude(box, { [5] = true }, Vector3.yAxis)
		closed(m)
		near(m:volume(), 12)
		closed(API.Topology.insetFaces(box, { [5] = true }, 0.3))
	end)
	test("edge split retains watertight volume", function()
		local m = API.Topology.splitEdge(API.Primitives.box(), 1, 2, 0.3)
		closed(m)
		near(m:volume(), 8)
	end)
	test("weld and connected components", function()
		local box = API.Primitives.box()
		local joined = API.Topology.join({ box, API.Deform.transform(box, CFrame.new(4, 0, 0)) })
		assert(#API.Topology.components(joined) == 2)
		local grid = API.Primitives.grid(1, 1)
		local doubled = API.Topology.join({ grid, API.Deform.transform(grid, CFrame.new(2, 0, 0)) })
		local m = API.Topology.weld(doubled, 1e-5)
		assert(m:validate().vertices == 6 and m:validate().boundaryEdges == 6)
	end)
	test("masked sculpt protects unselected vertices", function()
		local m = API.Primitives.box()
		local moved = API.Sculpt.move(m, { [1] = 1 }, Vector3.xAxis)
		vec(moved.vertices[1], m.vertices[1] + Vector3.xAxis)
		for id, p in m.vertices do
			if id ~= 1 then
				vec(moved.vertices[id], p)
			end
		end
	end)
	test("Taubin smoothing and geodesic selection", function()
		local m = API.Primitives.grid(4, 4)
		local b = API.Selection.boundary(m)
		m.vertices[13] += Vector3.yAxis
		local smooth = API.Sculpt.smooth(m, nil, 3)
		assert(smooth.vertices[13].Y < 1)
		for id in b do
			vec(m.vertices[id], smooth.vertices[id])
		end
		local mask = API.Selection.geodesic(m, { [1] = 1 }, 0.6)
		assert(mask[1] == 1 and mask[25] == nil)
	end)
	test("spatial closest point, ray and winding sign", function()
		local s = API.Spatial.new(API.Primitives.box())
		local h = s:closest(Vector3.new(3, 0.2, 0.3))
		near(h.distance, 2)
		vec(h.position, Vector3.new(1, 0.2, 0.3))
		local ray = s:raycast(Vector3.new(0, 0, -3), Vector3.zAxis)
		near(ray.distance, 2)
		assert(s:contains(Vector3.zero) and not s:contains(Vector3.new(3, 0, 0)))
		near(s:signedDistance(Vector3.zero), -1)
	end)
	test("RBF interpolation reproduces exact handles", function()
		local m = API.Primitives.box()
		local h = {
			{ from = m.vertices[1], to = m.vertices[1] + Vector3.yAxis },
			{
				from = m.vertices[7],
				to = m.vertices[7],
			},
		}
		local out = API.Deform.rbf(m, h, 2)
		vec(out.vertices[1], h[1].to)
		vec(out.vertices[7], h[2].to)
	end)
	test("SDF collision constraint", function()
		local m = API.Primitives.box()
		local out = API.Deform.contact(m, API.Fields.plane(Vector3.zero, Vector3.yAxis), 0.1)
		for _, p in out.vertices do
			assert(p.Y >= 0.0999)
		end
	end)
	test("marching tetrahedra creates closed sphere", function()
		local m = API.Remesh.fromField(
			API.Fields.sphere(Vector3.zero, 1),
			-Vector3.one * 1.4,
			Vector3.one * 1.4,
			0.25
		)
		closed(m)
		near(m:volume(), 4 * math.pi / 3, 0.25)
	end)
	test("curve evaluation and capped sweep", function()
		local curve =
			API.Curves.bezier({ Vector3.zero, Vector3.new(0, 1, 0), Vector3.new(0, 1, 1), Vector3.zAxis })
		vec(curve(0), Vector3.zero)
		vec(curve(1), Vector3.zAxis)
		local m = API.Curves.sweep(API.Curves.circle(0.2, 12), API.Curves.sample(curve, 12))
		closed(m)
		local nurbs = API.Curves.nurbs({ Vector3.zero, Vector3.xAxis, Vector3.new(2, 0, 0) }, 2)
		vec(nurbs(0.5), Vector3.xAxis)
	end)
	test("UV chart validation", function()
		local m = API.UV.faceCharts(API.Primitives.box())
		assert(API.UV.validate(m).valid)
		for _, f in m.faces do
			for _, c in f.corners do
				assert(c.uv.X >= 0 and c.uv.X <= 1 and c.uv.Y >= 0 and c.uv.Y <= 1)
			end
		end
	end)
	test("texture alpha compositing and byte conversion", function()
		local a = API.Texture.new(4, 4, Color3.new(1, 0, 0), 1)
		local b = API.Texture.new(4, 4, Color3.new(0, 0, 1), 0.5)
		local blended = a:blend(b)
		local c, alpha = blended:get(0, 0)
		near(c.R, 0.5)
		near(c.B, 0.5)
		near(alpha, 1)
		local copy = API.Texture.fromRGBA8(4, 4, blended:toRGBA8(true), true)
		near(copy:get(0, 0).R, 0.5, 0.005)
		local n = a:normalFromHeight()
		near(n:get(0, 0).B, 1)
	end)
	test("rig FK weights and linear blend skinning", function()
		local rig = API.Rig.new()
		local bone = rig:addBone("Root", nil, CFrame.identity)
		local m = rig:automaticWeights(API.Primitives.box())
		local out = rig:skin(m, { [bone] = CFrame.new(1, 2, 3) })
		for id, p in m.vertices do
			vec(out.vertices[id], p + Vector3.new(1, 2, 3))
		end
	end)
	test("FABRIK preserves lengths and reaches target", function()
		local target = Vector3.new(1, 1, 0)
		local p = API.Rig.fabrik({ Vector3.zero, Vector3.xAxis, Vector3.new(2, 0, 0) }, target)
		vec(p[1], Vector3.zero)
		near((p[2] - p[1]).Magnitude, 1)
		near((p[3] - p[2]).Magnitude, 1)
		vec(p[3], target, 1e-4)
	end)
	test("animation interpolation and looping", function()
		local t = API.Animation.track({ { time = 0, value = 0 }, { time = 2, value = 4 } })
		near(API.Animation.sample(t, 0.5), 1)
		near(API.Animation.evaluate({ x = t }, 2.5, 2, true).x, 1)
	end)
	test("XPBD distance pin and compliance", function()
		local s = API.Simulation.new({ gravity = Vector3.zero })
		local a = s:addParticle(Vector3.zero, 0)
		local b = s:addParticle(Vector3.new(2, 0, 0), 1)
		s:addDistance(a, b, 0, 1)
		s:step(0.1, 1, 8)
		vec(s.particles[a].position, Vector3.zero)
		near((s.particles[b].position - s.particles[a].position).Magnitude, 1)
	end)
	test("XPBD tetrahedral volume", function()
		local s = API.Simulation.new({ gravity = Vector3.zero })
		local a = s:addParticle(Vector3.zero, 0)
		local b = s:addParticle(Vector3.xAxis, 0)
		local c = s:addParticle(Vector3.yAxis, 0)
		local d = s:addParticle(Vector3.zAxis, 1)
		s:addVolume(a, b, c, d, 0)
		s.particles[d].position = Vector3.zAxis * 2
		s:step(0.1, 1, 8)
		near(s.particles[d].position.Z, 1)
	end)
	test("procedural graph rejects cycles", function()
		local g = API.Graph.new()
		local a = g:add(function(_, p)
			return p.value
		end, {}, { value = 2 })
		local b = g:add(function(inputs)
			return inputs.x * 3
		end, { x = a })
		assert(g:evaluate(b) == 6)
		assert(not pcall(function()
			g:connect(a, "x", b)
		end))
		assert(g:evaluate(b) == 6)
	end)
	test("history rollback, undo, redo", function()
		local h = API.History.new(API.Primitives.box())
		h:apply("Move", function(m)
			return API.Deform.transform(m, CFrame.new(1, 0, 0))
		end)
		near(h:undo().vertices[1].X, -1)
		near(h:redo().vertices[1].X, 0)
		assert(not pcall(function()
			h:apply("Fail", function()
				error("expected")
			end)
		end))
		near(h:current().vertices[1].X, 0)
	end)
	test("JSON and OBJ roundtrip", function()
		local m = API.UV.faceCharts(API.Primitives.box())
		local copy = API.IO.decode(API.IO.encode(m))
		closed(copy)
		near(copy:volume(), 8)
		local obj = API.IO.fromOBJ(API.IO.toOBJ(m))
		closed(obj)
		near(obj:volume(), 8)
		vec(copy.faces[1].corners[2].uv, m.faces[1].corners[2].uv)
	end)
	test("partition preserves global normal seams", function()
		local m = API.Primitives.sphere(1, 12, 6)
		local count = 0
		for _, chunk in API.Roblox.partition(m, 10) do
			assert(#chunk.mesh:triangles() <= 10)
			count += #chunk.mesh:triangles()
			for id, src in chunk.sourceVertices do
				vec(chunk.mesh.vertices[id], m.vertices[src])
			end
		end
		assert(count == #m:triangles())
	end)
	test("plane clipping and convex edge bevel", function()
		local box = API.Primitives.box()
		local half = API.Modifiers.clipPlane(box, Vector3.zero, Vector3.xAxis)
		closed(half)
		near(half:volume(), 4)
		local bevel = API.Modifiers.bevelConvex(box, 0.15)
		closed(bevel)
		assert(bevel:volume() < 8 and bevel:volume() > 6)
	end)
	test("solidify closes an open surface", function()
		local slab = API.Modifiers.solidify(API.Primitives.grid(3, 3), 0.2)
		closed(slab)
		near(slab:volume(), 0.8)
	end)
	test("coplanar dissolve restores a quad", function()
		local m = API.Topology.triangulate(API.Primitives.grid(1, 1))
		local edge
		for _, e in m:topology().edges do
			if #e.faces == 2 then
				edge = e
			end
		end
		local out = API.Topology.dissolveEdge(m, edge.a, edge.b)
		assert(out:validate().faces == 1 and out:validate().boundaryEdges == 4)
	end)
	test("multires preserves fine detail through coarse translation", function()
		local multi = API.Subdivision.multires(API.Primitives.box(), 2)
		local fine = multi:get()
		fine.vertices[1] += Vector3.yAxis * 0.05
		multi:commit(fine)
		multi:select(1)
		multi:commit(API.Deform.transform(multi:get(), CFrame.new(2, 1, 0)))
		local result = multi:select(3)
		for id, p in fine.vertices do
			vec(result.vertices[id], p + Vector3.new(2, 1, 0), 1e-4)
		end
	end)
	test("decimation conserves manifold sphere", function()
		local m = API.Primitives.sphere(1, 12, 6)
		local out, stats = API.Simplify.decimate(m, 80, { maxIterations = 100 })
		closed(out)
		assert(stats.targetReached and stats.collapses > 0)
		near(out:volume(), m:volume(), 0.6)
	end)
	test("camera projection inverse ray and calibration", function()
		local truth = API.Camera.new(CFrame.lookAt(Vector3.new(3, 2, 8), Vector3.zero), 45, 640, 480)
		local landmarks = {}
		for _, p in API.Primitives.box().vertices do
			local pixel = API.Camera.project(truth, p)
			table.insert(landmarks, { point = p, pixel = pixel })
			local o, d = API.Camera.ray(truth, pixel)
			near((p - o).Unit:Dot(d), 1)
		end
		local initial = API.Camera.new(
			CFrame.new(0.15, -0.1, 0.2) * truth.frame * CFrame.Angles(0.01, -0.01, 0),
			47,
			640,
			480
		)
		local _, fit = API.Camera.fit(initial, landmarks, { iterations = 60 })
		assert(fit.rms < 0.01, "Camera RMS " .. fit.rms)
	end)
	test("UV rasterization and tangent normal baking", function()
		local m = API.Primitives.box()
		local low = API.UV.faceCharts(m)
		local image, stats = API.Bake.rasterize(low, 32, 32, function(ctx)
			return Color3.new(0.25, 0.5, 0.75), 1
		end)
		assert(stats.coveredPixels > 300)
		local normal = API.Bake.normalMap(low, m, 32, 32)
		local covered = 0
		for y = 0, 31 do
			for x = 0, 31 do
				local c, a = normal:get(x, y)
				if a > 0 then
					near(c.R, 0.5, 1e-5)
					near(c.G, 0.5, 1e-5)
					near(c.B, 1, 1e-5)
					covered += 1
				end
			end
		end
		assert(covered > 300)
		local tiles = image:tiles(12)
		assert(#tiles == 9 and tiles[9].width == 8)
	end)
	test("Normal maps encode red along +u and green toward decreasing v, as Roblox reads them", function()
		-- a unit quad facing +z with the UV origin at its top-left: dP/du = +x, dP/dv = -y
		local m = API.Mesh.new()
		local tl = m:addVertex(Vector3.new(0, 1, 0))
		local tr = m:addVertex(Vector3.new(1, 1, 0))
		local bl = m:addVertex(Vector3.new(0, 0, 0))
		local br = m:addVertex(Vector3.new(1, 0, 0))
		local uv = {
			[tl] = Vector2.new(0, 0),
			[tr] = Vector2.new(1, 0),
			[bl] = Vector2.new(0, 1),
			[br] = Vector2.new(1, 1),
		}
		for _, vs in { { tl, bl, tr }, { tr, bl, br } } do
			local face = m.faces[m:addFace(vs)]
			for i, v in face.vertices do
				face.corners[i].uv = uv[v]
				face.corners[i].normal = Vector3.zAxis
			end
		end
		local function center(normal)
			local image = API.Bake.worldNormalMap(m, 8, 8, function(ctx)
				return normal(ctx)
			end)
			return image:get(4, 4)
		end
		-- tilted toward +y, the texture's up: green above 0.5 (Studio shades it like a surface tilted up)
		local c, a = center(function()
			return Vector3.new(0, 0.6, 0.8)
		end)
		near(c.R, 0.5)
		near(c.G, 0.8)
		near(c.B, 0.9)
		assert(a == 1)
		c = center(function()
			return Vector3.new(0.6, 0, 0.8)
		end)
		near(c.R, 0.8)
		near(c.G, 0.5)
		-- the normal is normalized; nil leaves the texel flat and uncovered
		c = center(function(ctx)
			return ctx.normal * 3
		end)
		near(c.B, 1)
		c, a = center(function()
			return nil
		end)
		assert(a == 0 and math.abs(c.B - 1) < 1e-5)
		-- Bake.normalMap uses the same encoding: a high mesh whose normals tilt toward +y
		local high = API.Mesh.new()
		local h1 = high:addVertex(Vector3.new(-1, 2, 0))
		local h2 = high:addVertex(Vector3.new(-1, -1, 0))
		local h3 = high:addVertex(Vector3.new(2, -1, 0))
		local hf = high.faces[high:addFace({ h1, h2, h3 })]
		for i in hf.vertices do
			hf.corners[i].normal = Vector3.new(0, 0.6, 0.8)
		end
		local baked = API.Bake.normalMap(m, high, 8, 8)
		near(baked:get(4, 4).G, 0.8)
	end)
	test("CPU silhouette renderer and image comparison", function()
		local camera = API.Camera.new(CFrame.lookAt(Vector3.new(0, 0, 5), Vector3.zero), 50, 32, 32)
		local image = API.Render.silhouette(API.Primitives.box(), camera)
		assert(image:get(16, 16).R == 1 and image:get(0, 0).R == 0)
		near(API.Render.compareSilhouettes(image, image).intersectionOverUnion, 1)
	end)
	test("deterministic area-weighted surface scatter", function()
		local mesh = API.Primitives.box()
		local a = API.Geometry.scatter(mesh, 50, 42)
		local b = API.Geometry.scatter(mesh, 50, 42)
		assert(#a == 50)
		for i, p in a do
			vec(p.position, b[i].position)
			near(math.max(math.abs(p.position.X), math.abs(p.position.Y), math.abs(p.position.Z)), 1)
		end
	end)
	test("seam-based harmonic unwrap", function()
		local box = API.Primitives.box()
		local unwrapped, stats = API.Unwrap.unwrap(box, API.Unwrap.sharpSeams(box, math.rad(45)))
		assert(stats.charts == 6 and API.UV.validate(unwrapped).valid)
		local grid = API.Primitives.grid(6, 6)
		local flat, report = API.Unwrap.harmonic(grid)
		assert(report.converged and API.UV.validate(flat).valid)
		assert(not pcall(function()
			API.Unwrap.harmonic(box)
		end))
	end)
	test("UV tile clipping preserves area and volume", function()
		local m = API.UV.faceCharts(API.Primitives.box())
		local volume = 0
		local area = 0
		for _, tile in API.UV.splitTiles(m, 3, 3) do
			volume += tile.mesh:volume()
			assert(API.UV.validate(tile.mesh).valid)
			for _, t in tile.mesh:triangles() do
				local v = tile.mesh.vertices
				area += (v[t[2]] - v[t[1]]):Cross(v[t[3]] - v[t[1]]).Magnitude / 2
			end
		end
		near(volume, 8, 1e-4)
		near(area, 24, 1e-4)
	end)
	test("rig IK returns usable local transforms", function()
		local rig = API.Rig.new()
		local a = rig:addBone("A", nil, CFrame.identity)
		local b = rig:addBone("B", a, CFrame.new(1, 0, 0))
		local c = rig:addBone("C", b, CFrame.new(1, 0, 0))
		local pose, report = rig:solveIK(nil, { a, b, c }, Vector3.new(1, 1, 0))
		assert(report.endpointError < 1e-4)
		local world = rig:worldTransforms(pose)
		vec(world[c].Position, Vector3.new(1, 1, 0), 1e-4)
	end)
	test("rigid sphere contact, restitution and static body", function()
		local s = API.RigidBody.new({ gravity = Vector3.zero })
		local a = s:addSphere(0.5, 1, CFrame.new(-0.55, 0, 0), { restitution = 1, friction = 0 })
		local b = s:addSphere(0.5, 1, CFrame.new(0.55, 0, 0), { restitution = 1, friction = 0 })
		s.bodies[a].velocity = Vector3.xAxis
		s.bodies[b].velocity = -Vector3.xAxis
		s:step(0.1, 4, 4)
		assert(s.bodies[a].velocity.X < 0 and s.bodies[b].velocity.X > 0)
		local fixed = s:addSphere(0.2, 0, CFrame.new(0, 3, 0))
		s:step(0.1)
		vec(s.bodies[fixed].position, Vector3.new(0, 3, 0))
	end)
	test("particle lifetimes and reproducible emitters", function()
		local p = API.Particles.new(9)
		p:emit(3, function(random)
			return {
				position = Vector3.new(random:NextNumber(), 0, 0),
				velocity = Vector3.yAxis,
				lifetime = 0.5,
			}
		end)
		p:step(0.1)
		assert(p.particles[1].position.Y > 0.09)
		p:step(0.5)
		assert(next(p.particles) == nil)
	end)
	test("SPH isolated particle and density", function()
		local f = API.Fluid.new({ gravity = Vector3.zero })
		f:add(Vector3.zero, Vector3.xAxis)
		f:step(0.01, 2)
		vec(f.particles[1].position, Vector3.new(0.01, 0, 0))
		assert(f.particles[1].density > 0 and f:field()(f.particles[1].position) < 0)
	end)
	test("path trace emission and deterministic output", function()
		local camera = API.Camera.new(CFrame.lookAt(Vector3.new(0, 0, 4), Vector3.zero), 35, 8, 8)
		local materials =
			{ { kind = "diffuse", albedo = Color3.new(), emission = Color3.new(0.3, 0.6, 0.9) } }
		local options = { samples = 2, bounces = 2, seed = 3, environment = Color3.new() }
		local a = API.PathTrace.render(API.Primitives.box(), camera, materials, options)
		local b = API.PathTrace.render(API.Primitives.box(), camera, materials, options)
		local ca = a:get(4, 4)
		near(ca.G, 0.6, 1e-6)
		assert(buffer.tostring(a.pixels) == buffer.tostring(b.pixels))
	end)
	test("job completion and cooperative cancellation", function()
		local job = API.Jobs.start(function(ctx)
			ctx.checkpoint(0.5)
			return 42
		end)
		assert(API.Jobs.await(job, 2) == 42 and job.status == "Complete")
		local cancelled = API.Jobs.start(function(ctx)
			ctx.checkpoint(0.1)
			ctx.checkpoint(0.9)
			return 1
		end)
		cancelled:cancel()
		local result = API.Jobs.await(cancelled, 2)
		assert(result == nil and cancelled.status == "Cancelled")
	end)
	if options.native ~= false then
		test("native EditableMesh roundtrip and update", function()
			local h
			local ok, err = pcall(function()
				local m = API.UV.faceCharts(API.Primitives.box())
				h = API.Roblox.toEditable(m)
				local copy = API.Roblox.fromEditable(h.editable)
				near(copy:volume(), 8)
				local p = API.Roblox.createPart(h)
				near(p.Size.X, 2)
				local moved = API.Deform.transform(m, CFrame.new(3, 0, 0))
				API.Roblox.update(h, moved)
				near(h.editable:GetPosition(h.vertexIds[1]).X, 2)
				near(p.Position.X, 3)
				local changed = API.Topology.triangulate(m)
				assert(not pcall(function()
					API.Roblox.update(h, changed)
				end))
			end)
			if h then
				if h.part then
					h.part:Destroy()
				end
				h.editable:Destroy()
			end
			assert(ok, err)
		end)
		test("native EditableImage and PBR material", function()
			local image, sa, images
			local ok, err = pcall(function()
				local t = API.Texture.new(8, 8, Color3.new(0.2, 0.4, 0.7), 1)
				image = API.Roblox.toEditableImage(t, true)
				local restored = API.Roblox.fromEditableImage(image, true)
				near(restored:get(0, 0).G, 0.4, 0.005)
				sa, images = API.Roblox.material({
					ColorMap = t,
					RoughnessMap = API.Texture.new(4, 4, Color3.new(0.6, 0.6, 0.6), 1),
				})
				assert(sa.ColorMapContent.SourceType == Enum.ContentSourceType.Object)
			end)
			if image then
				image:Destroy()
			end
			if sa then
				sa:Destroy()
			end
			for _, i in images or {} do
				i:Destroy()
			end
			assert(ok, err)
		end)
		test("native bones and weights roundtrip", function()
			local h
			local ok, err = pcall(function()
				local rig = API.Rig.new()
				local a = rig:addBone("Root", nil, CFrame.new(3, 0, 0))
				rig:addBone("Tip", a, CFrame.new(0, 1, 0))
				local mesh =
					rig:automaticWeights(API.Deform.transform(API.Primitives.box(), CFrame.new(3, 0, 0)))
				h = API.Roblox.toEditable(mesh, { rig = rig })
				assert(#h.editable:GetBones() == 2)
				local restored, _, restRig = API.Roblox.fromEditable(h.editable)
				assert(#restRig.order == 2)
				for _, weights in restored.weights do
					local sum = 0
					for _, w in weights do
						sum += w
					end
					near(sum, 1)
				end
				vec(restRig:worldTransforms()[1].Position, Vector3.zero)
			end)
			if h then
				h.editable:Destroy()
			end
			assert(ok, err)
		end)
		test("native Bone instances and runtime pose", function()
			local h
			local ok, err = pcall(function()
				local rig = API.Rig.new()
				local root = rig:addBone("Root", nil, CFrame.new(3, 0, 0))
				local tip = rig:addBone("Tip", root, CFrame.new(0, 1, 0))
				local mesh =
					rig:automaticWeights(API.Deform.transform(API.Primitives.box(), CFrame.new(3, 0, 0)))
				h = API.Roblox.toEditable(mesh, { rig = rig })
				API.Roblox.createPart(h)
				assert(h.boneInstances[root].Parent == h.part)
				assert(h.boneInstances[tip].Parent == h.boneInstances[root])
				API.Roblox.applyPose(h, { [root] = CFrame.new(3, 2, 0) })
				vec(h.boneInstances[root].TransformedWorldCFrame.Position, Vector3.new(3, 2, 0))
				vec(h.boneInstances[tip].TransformedWorldCFrame.Position, Vector3.new(3, 3, 0))
			end)
			if h then
				if h.part then
					h.part:Destroy()
				end
				h.editable:Destroy()
			end
			assert(ok, err)
		end)
		test("native tiled texture model", function()
			local bundle
			local ok, err = pcall(function()
				local mesh = API.UV.faceCharts(API.Primitives.box())
				bundle = API.Roblox.toTexturedModel(
					mesh,
					{ ColorMap = API.Texture.noise(24, 24, 4, 2, 1) },
					{ tileSize = 8 }
				)
				assert(bundle.tiles.columns == 3 and bundle.tiles.rows == 3 and #bundle.images > 0)
				for _, image in bundle.images do
					assert(image.Size.X <= 8 and image.Size.Y <= 8)
				end
				assert(bundle.model.Parent == nil)
			end)
			if bundle then
				API.Roblox.destroy(bundle)
			end
			assert(ok, err)
		end)
	end
	for _, entry in tests do
		local start = os.clock()
		local ok, err = xpcall(entry[2], debug.traceback)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, {
			name = entry[1],
			passed = ok,
			seconds = os.clock() - start,
			error = not ok and tostring(err) or nil,
		})
	end
	report.success = report.failed == 0
	return report
end
