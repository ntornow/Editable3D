-- Pure-data target controls, path motion and a constrained two-bone rig.
return function(API)
	local E = API or require(script.Parent.Parent)
	local path = E.Stroke.path(
		E.Curves.sample(
			E.Curves.bezier({ Vector3.new(-2, 1, -3), Vector3.new(0, 4, -5), Vector3.new(2, 2, -3) }),
			32
		)
	)
	local rig = E.Rig.new()
	local root = rig:addBone("Root")
	local tip = rig:addBone("Tip", root, CFrame.new(0, 2, 0))
	local frames = {}
	for i = 0, 8 do
		local controller = E.Constraints.followPath(CFrame.identity, path, i / 8, { followRotation = false })
		local pose, report = E.Constraints.rig(
			rig,
			nil,
			{ [tip] = { { type = "DAMPED_TRACK", trackAxis = "Y", target = controller } } }
		)
		frames[#frames + 1] = { factor = i / 8, target = controller, pose = pose, world = report.world }
	end
	local mesh = E.Primitives.cylinder(0.3, 2, 16)
	for id in mesh.vertices do
		mesh.weights[id] = { [root] = 0.5, [tip] = 0.5 }
	end
	local deformed = rig:skinDualQuaternion(mesh, frames[5].pose)
	return { rig = rig, path = path, frames = frames, mesh = deformed }
end
