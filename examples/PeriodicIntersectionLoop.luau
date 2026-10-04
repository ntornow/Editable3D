-- A closed intersection has one mesh vertex and two parameter representatives
-- at the periodic seam. The original rectangular-domain path stays available.
return function(E)
	E = E or require(script.Parent.Parent)
	local control = {}
	for _, p in { Vector3.new(1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0), Vector3.new(0, -1, 0) } do
		table.insert(control, { p - Vector3.zAxis, p + Vector3.zAxis })
	end
	local cylinder = E.Cyclic.surface(control, 2, 1, { cyclicU = true, cyclicV = false })
	local plane = E.NURBS.surface({
		{ Vector3.new(-2, -2, 0), Vector3.new(-2, 2, 0) },
		{ Vector3.new(2, -2, 0), Vector3.new(2, 2, 0) },
	}, 1, 1)
	local intersections = E.SplineQuery.intersectSurfaces(cylinder, plane, {
		tolerance = 0.005,
		requireQuotient = true,
	})
	local path = intersections.periodicQuotient.paths[1]
	assert(path.closed and not intersections.components[1].ordered.closed)
	local mesh = E.Mesh.new()
	local center, ids = mesh:addVertex(Vector3.zero), {}
	for i, sample in path.samples do
		ids[i] = mesh:addVertex(sample.position)
	end
	for _, segment in path.segments do
		local a, b = path.samples[segment.first].position, path.samples[segment.last].position
		mesh:addFace({ center, ids[segment.first], ids[segment.last] }, {
			{ uv = Vector2.new(0.5, 0.5) },
			{ uv = Vector2.new((a.X + 1) / 2, (a.Y + 1) / 2) },
			{ uv = Vector2.new((b.X + 1) / 2, (b.Y + 1) / 2) },
		})
	end
	mesh:recalculateNormals()
	assert(mesh:validate().valid)
	return { surface = cylinder, intersections = intersections, path = path, mesh = mesh }
end
