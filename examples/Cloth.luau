-- Returns a simulated mesh and state; does not add anything to the scene.
return function()
	local E = require(script.Parent.Parent)
	local mesh = E.Deform.transform(E.Primitives.grid(12, 12, Vector2.new(3, 3)), CFrame.new(0, 2, 0))
	local cloth = E.Simulation.fromMesh(mesh, {
		stretchCompliance = 0.000001,
		shearCompliance = 0.00001,
		bendCompliance = 0.005,
	})
	cloth:pin(cloth.vertexMap[1])
	cloth:pin(cloth.vertexMap[13])
	cloth:addCollider(E.Fields.sphere(Vector3.new(0, 0.1, 0), 0.8), 0.02)
	cloth:addCollider(E.Fields.plane(Vector3.new(0, -1, 0), Vector3.yAxis), 0.02)
	for _ = 1, 60 do
		cloth:step(1 / 60, 4, 8)
	end
	return cloth:toMesh(), cloth
end
