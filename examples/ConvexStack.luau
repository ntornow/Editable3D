-- Headless deterministic convex-body study. Returns shapes and a sampled trajectory.
-- This does not create Parts, invoke Roblox physics, or alter the current scene.
return function(options)
	local E = require(script.Parent.Parent)
	options = options or {}
	local steps, dt = options.steps or 120, options.dt or 1 / 60
	local captureEvery = options.captureEvery or 5
	assert(steps >= 1 and steps % 1 == 0 and dt > 0)
	assert(captureEvery >= 1 and captureEvery % 1 == 0)
	local world = E.Dynamics.new({ velocityIterations = 24, positionIterations = 6 })
	local floor = world:addBox(Vector3.new(10, 1, 10), 0, CFrame.new(0, -0.5, 0), { friction = 0.7 })
	local ids = {}
	for i = 1, 3 do
		ids[i] = world:addBox(Vector3.one, 1, CFrame.new(0, i - 0.48, 0), { friction = 0.7 })
	end
	local wedge = E.Convex.hull({
		Vector3.new(-0.6, -0.4, -0.5),
		Vector3.new(0.6, -0.4, -0.5),
		Vector3.new(0.6, 0.4, -0.5),
		Vector3.new(-0.6, -0.4, 0.5),
		Vector3.new(0.6, -0.4, 0.5),
		Vector3.new(0.6, 0.4, 0.5),
	})
	ids[4] =
		world:addConvex(wedge, 1.5, CFrame.new(2, 1.8, 0) * CFrame.Angles(0, 0.2, 0.1), { friction = 0.6 })
	world:impulse(ids[4], Vector3.new(0.2, 0, 0.1), world.bodies[ids[4]].position + Vector3.yAxis * 0.2)
	local trajectory = {}
	local function capture()
		local frames = {}
		for _, id in ids do
			frames[id] = world:frame(id)
		end
		table.insert(trajectory, { time = world.time, frames = frames })
	end
	capture()
	local report
	for step = 1, steps do
		report = world:step(dt)
		if step % captureEvery == 0 or step == steps then
			capture()
		end
	end
	local meshes = { [floor] = E.Convex.toMesh(world.bodies[floor].shape) }
	for _, id in ids do
		meshes[id] = E.Convex.toMesh(world.bodies[id].shape)
	end
	return {
		world = world,
		bodyIds = ids,
		floorId = floor,
		meshes = meshes,
		trajectory = trajectory,
		report = report,
	}
end
