return function(E)
	E = E or require(script.Parent.Parent)
	local C, D = E.Convex, E.Dynamics
	local tests, report = {}, { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		table.insert(tests, { name, fn })
	end
	local function near(a, b, epsilon)
		assert(math.abs(a - b) <= (epsilon or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function vector(a, b, epsilon)
		near((a - b).Magnitude, 0, epsilon)
	end
	local function finite(p)
		assert(p.X == p.X and p.Y == p.Y and p.Z == p.Z and p.Magnitude < math.huge)
	end
	test("Convex box mass and full inertia match analytic values", function()
		local shape = C.box(Vector3.new(2, 4, 6))
		local p = C.massProperties(shape, 12)
		near(p.volume, 48)
		vector(p.center, Vector3.zero)
		near(p.inertia.xx, 52)
		near(p.inertia.yy, 40)
		near(p.inertia.zz, 20)
		near(p.inertia.xy, 0)
		near(p.inverseInertia.zz, 1 / 20)
		local mesh, rotation = C.toMesh(shape), CFrame.Angles(0.2, 0.5, 0.7)
		local offset = Vector3.new(12, -5, 9)
		for id, point in mesh.vertices do
			mesh.vertices[id] = rotation:VectorToWorldSpace(point) + offset
		end
		local moved = C.massProperties(C.fromMesh(mesh), 12)
		vector(moved.center, offset, 1e-5)
		near(moved.volume, 48, 2e-4)
		local v = Vector3.new(0.2, -0.8, 1.7)
		vector(
			C.tensorMultiply(moved.inertia, v),
			rotation:VectorToWorldSpace(C.tensorMultiply(p.inertia, rotation:VectorToObjectSpace(v))),
			0.001
		)
		vector(C.tensorMultiply(moved.inverseInertia, C.tensorMultiply(moved.inertia, v)), v, 1e-5)
	end)
	test("Incremental point hull merges coplanar facets and excludes interior points", function()
		local points = {}
		for _, p in E.Primitives.box().vertices do
			table.insert(points, p)
		end
		table.insert(points, Vector3.zero)
		table.insert(points, Vector3.new(0.5, 0.2, 0.1))
		table.insert(points, points[1])
		local shape = C.hull(points)
		assert(#shape.faces == 6 and #shape.edges == 12 and #shape.vertices == 8)
		near(C.massProperties(shape, 1).volume, 8)
		assert(C.toMesh(shape):validate().closed)
		local frame = CFrame.new(3, 1, -2) * CFrame.Angles(0.3, 0.7, 0.1)
		local direction = Vector3.new(1, 2, 3)
		local support = C.support(shape, direction, frame)
		for _, p in shape.vertices do
			assert(support:Dot(direction) >= frame:PointToWorldSpace(p):Dot(direction) - 1e-5)
		end
	end)
	test("Invalid and over-budget convex inputs fail explicitly", function()
		assert(not pcall(function()
			C.fromMesh(E.Primitives.grid(1, 1))
		end))
		assert(not pcall(function()
			C.hull({ Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.xAxis + Vector3.yAxis })
		end))
		assert(not pcall(function()
			C.hull({ Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }, { maxPoints = 3 })
		end))
		local concave = E.Primitives.box()
		concave.vertices[1] = Vector3.new(0.8, 0.8, 0.8)
		assert(not pcall(function()
			C.fromMesh(concave)
		end))
		assert(not pcall(function()
			local s = C.box()
			C.contact(s, CFrame.identity, s, CFrame.identity, { maxAxes = 1 })
		end))
	end)
	test("SAT separation, containment depth, touching, and face manifold", function()
		local a = C.box(Vector3.new(2, 2, 2))
		local separated = C.contact(a, CFrame.identity, a, CFrame.new(3, 0, 0))
		assert(not separated.overlap)
		near(separated.separation, 1)
		vector(separated.normal, Vector3.xAxis)
		local hit = C.contact(a, CFrame.identity, a, CFrame.new(1.5, 0, 0))
		assert(hit.overlap and #hit.contacts == 4 and hit.feature == "face")
		near(hit.penetration, 0.5)
		vector(hit.normal, Vector3.xAxis)
		for _, point in hit.contacts do
			near(point.pointA.X, 1)
			near(point.pointB.X, 0.5)
			near(point.position.X, 0.75)
		end
		local contained = C.contact(a, CFrame.identity, C.box(Vector3.one), CFrame.identity)
		near(contained.penetration, 1.5)
		local touching = C.contact(a, CFrame.identity, a, CFrame.new(2, 0, 0))
		assert(touching.overlap)
		near(touching.penetration, 0)
	end)
	test("Rotated thin polyhedra produce an edge contact", function()
		local rod = C.box(Vector3.new(4, 0.2, 0.2))
		local frame = CFrame.Angles(0.6, 0.9, 0.4)
		local hit = C.contact(rod, CFrame.identity, rod, frame)
		assert(hit.overlap and hit.feature == "edge" and #hit.contacts == 1)
		near(hit.normal.Magnitude, 1)
		finite(hit.contacts[1].position)
		local reverse = C.contact(rod, frame, rod, CFrame.identity)
		near(reverse.penetration, hit.penetration, 1e-5)
	end)
	test("Random transformed convex contacts remain symmetric and finite", function()
		local a = C.hull({
			Vector3.new(-1, 0, -1),
			Vector3.new(1, 0, -1),
			Vector3.new(0, 0, 1),
			Vector3.new(0, 2, 0),
		})
		local b, random = C.box(Vector3.new(1.2, 0.8, 1.6)), Random.new(543)
		for _ = 1, 100 do
			local ra = CFrame.Angles(random:NextNumber(), random:NextNumber(), random:NextNumber())
			local rb = CFrame.new(
				random:NextNumber(-2, 2),
				random:NextNumber(-1, 2),
				random:NextNumber(-2, 2)
			) * CFrame.Angles(random:NextNumber(), random:NextNumber(), random:NextNumber())
			local ab, ba = C.contact(a, ra, b, rb), C.contact(b, rb, a, ra)
			assert(ab.overlap == ba.overlap)
			if ab.overlap then
				near(ab.penetration, ba.penetration, 1e-4)
				near(ab.normal.Magnitude, 1)
				assert(#ab.contacts > 0 and #ab.contacts <= 4)
				for _, p in ab.contacts do
					finite(p.position)
					assert(p.penetration >= 0)
					local pa, pb = ra:PointToObjectSpace(p.pointA), rb:PointToObjectSpace(p.pointB)
					for _, face in a.faces do
						assert(face.normal:Dot(pa) <= face.plane + 0.0001, "A contact lies outside A")
					end
					for _, face in b.faces do
						assert(face.normal:Dot(pb) <= face.plane + 0.0001, "B contact lies outside B")
					end
					near((p.pointA - p.pointB):Dot(ab.normal), p.penetration, 0.0001)
				end
			end
		end
	end)
	test("Center-of-mass frames and off-center impulses use full inertia", function()
		local world = D.new({ gravity = Vector3.zero })
		local shape = C.box(Vector3.new(2, 4, 6))
		local mesh = C.toMesh(shape)
		for id, p in mesh.vertices do
			mesh.vertices[id] = p + Vector3.new(4, 0, 0)
		end
		local frame = CFrame.new(3, 2, 1) * CFrame.Angles(0.3, 0.5, 0.8)
		local id = world:addConvex(C.fromMesh(mesh), 12, frame)
		vector(world:frame(id).Position, frame.Position, 1e-5)
		vector(world.bodies[id].position, frame:PointToWorldSpace(Vector3.new(4, 0, 0)), 1e-5)
		local b = world.bodies[id]
		local lever, impulse =
			frame:VectorToWorldSpace(Vector3.yAxis), frame:VectorToWorldSpace(Vector3.xAxis)
		world:impulse(id, impulse, b.position + lever)
		vector(b.velocity, impulse / 12)
		vector(b.angularVelocity, frame:VectorToWorldSpace(Vector3.new(0, 0, -1 / 20)), 1e-5)
	end)
	test("Torque-free asymmetric rotation conserves world angular momentum", function()
		local world = D.new({ gravity = Vector3.zero })
		local id = world:addBox(Vector3.new(1, 2, 3), 2, CFrame.Angles(0.3, 0.4, 0.5))
		world.bodies[id].angularVelocity = Vector3.new(1, 2, 3)
		local _, before = world:momentum()
		local energy = world:energy().kinetic
		for _ = 1, 240 do
			world:step(1 / 240, { substeps = 1, positionIterations = 0 })
		end
		local _, after = world:momentum()
		vector(before, after, 0.002)
		near(world:energy().kinetic / energy, 1, 0.002)
		near(world.bodies[id].rotation.RightVector:Dot(world.bodies[id].rotation.UpVector), 0, 1e-6)
	end)
	test("Applied forces and torques integrate once and clear after step", function()
		local world = D.new({ gravity = Vector3.zero })
		local id = world:addBox(Vector3.one, 2)
		world:force(id, Vector3.new(2, 0, 0))
		world:torque(id, Vector3.new(0, 0, 3))
		world:step(0.2, { substeps = 20 })
		vector(world.bodies[id].velocity, Vector3.new(0.2, 0, 0), 1e-5)
		local _, momentum = world:momentum()
		near(momentum.Z, 0.6, 1e-5)
		world:step(0.2, { substeps = 20 })
		vector(world.bodies[id].velocity, Vector3.new(0.2, 0, 0), 1e-5)
		local _, later = world:momentum()
		near(later.Z, momentum.Z, 1e-5)
	end)
	test("Elastic box collision exchanges velocity without spurious angular energy", function()
		local world = D.new({ gravity = Vector3.zero, restitutionThreshold = 0 })
		local a = world:addBox(Vector3.one, 1, CFrame.new(-0.49, 0, 0), { restitution = 1, friction = 0 })
		local b = world:addBox(Vector3.one, 1, CFrame.new(0.49, 0, 0), { restitution = 1, friction = 0 })
		world.bodies[a].velocity = Vector3.xAxis
		world.bodies[b].velocity = -Vector3.xAxis
		local momentum = world:momentum()
		world:step(1 / 120, { substeps = 1, velocityIterations = 60 })
		near(world.bodies[a].velocity.X, -1, 0.001)
		near(world.bodies[b].velocity.X, 1, 0.001)
		vector(world.bodies[a].angularVelocity, Vector3.zero, 0.001)
		vector(world:momentum(), momentum, 1e-5)
		near(world:energy().kinetic, 1, 0.002)
	end)
	test("Resting box settles on static floor with bounded penetration", function()
		local world = D.new()
		local floor = world:addBox(Vector3.new(10, 1, 10), 0, CFrame.new(0, -0.5, 0))
		local id = world:addBox(Vector3.one, 1, CFrame.new(0, 2, 0))
		for _ = 1, 180 do
			world:step(1 / 60, { velocityIterations = 20 })
		end
		local b = world.bodies[id]
		near(b.position.Y, 0.5, 0.01)
		assert(b.velocity.Magnitude < 0.03 and b.angularVelocity.Magnitude < 0.05)
		vector(world:frame(floor).Position, Vector3.new(0, -0.5, 0))
		world:impulse(floor, Vector3.one, Vector3.xAxis)
		vector(world.bodies[floor].velocity, Vector3.zero)
	end)
	test("Coulomb friction dissipates sliding while frictionless floor preserves it", function()
		local function run(friction)
			local world = D.new()
			world:addBox(Vector3.new(20, 1, 20), 0, CFrame.new(0, -0.5, 0), { friction = friction })
			local id = world:addBox(Vector3.one, 1, CFrame.new(0, 0.5001, 0), { friction = friction })
			world.bodies[id].velocity = Vector3.new(2, 0, 0)
			for _ = 1, 90 do
				world:step(1 / 60, { velocityIterations = 20 })
			end
			return world.bodies[id]
		end
		local rough, smooth = run(0.8), run(0)
		assert(math.abs(rough.velocity.X) < 0.05)
		near(smooth.velocity.X, 2, 0.005)
	end)
	test("Small convex stack stays ordered and deterministic", function()
		local function run()
			local world = D.new()
			world:addBox(Vector3.new(10, 1, 10), 0, CFrame.new(0, -0.5, 0))
			local ids = {}
			for i = 1, 3 do
				ids[i] = world:addBox(Vector3.one, 1, CFrame.new(0, i - 0.49, 0))
			end
			for _ = 1, 120 do
				world:step(1 / 60, { velocityIterations = 24, positionIterations = 6 })
			end
			return world, ids
		end
		local a, ids = run()
		local b = run()
		for i, id in ids do
			near(a.bodies[id].position.Y, i - 0.5, 0.04)
			vector(a.bodies[id].position, b.bodies[id].position, 1e-7)
			vector(a.bodies[id].angularVelocity, b.bodies[id].angularVelocity, 1e-7)
		end
	end)
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
