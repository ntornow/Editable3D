return function(E)
	E = E or require(script.Parent.Parent)
	local mesh = E.Geometry.parametric(function(u, v)
		return Vector3.new(u * 6, v * 2, 0.12 * math.sin(v * 8))
	end, 16, 6)
	local anchors = {}
	for id, p in mesh.vertices do
		if p.X < 0.01 then
			anchors[id] = p
		elseif p.X > 5.99 then
			anchors[id] = Vector3.new(4, 3, 0)
				+ CFrame.Angles(0, 0, 0.9):VectorToWorldSpace(p - Vector3.new(6, 0, 0))
		end
	end
	local initial = E.Laplacian.bind(mesh):solve(anchors, { order = 1 })
	local result, report = E.ARAP.bind(mesh):solve(anchors, { initial = initial, maxIterations = 50 })
	return { source = mesh, initial = initial, mesh = result, report = report }
end
