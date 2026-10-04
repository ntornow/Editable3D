-- Reuse the original lattice deformation with a typed influence field.
return function(E)
	E = E or require(script.Parent.Parent)
	local cage = E.Primitives.grid(6, 6, Vector2.new(6, 6))
	local weights = {}
	for id, p in cage.vertices do
		weights[id] = math.max(0, 1 - (p.X * p.X + p.Z * p.Z) / 18)
	end
	cage = E.Attributes.set(
		E.Attributes.create(cage, "lattice_influence", "vertex", "number", 0),
		"lattice_influence",
		weights
	)
	local mesh, report = E.Deform.masked(cage, function(localMesh)
		return E.Deform.lattice(
			localMesh,
			Vector3.new(-3, -1, -3),
			Vector3.new(3, 1, 3),
			table.create(8, Vector3.yAxis)
		)
	end, { attribute = "lattice_influence", lockAxes = { X = true, Z = true } })
	assert(report.complete and report.operatorInvoked and mesh:validate().valid)
	for id, p in cage.vertices do
		assert(
			math.abs(mesh.vertices[id].Y - weights[id]) < 1e-6
				and mesh.vertices[id].X == p.X
				and mesh.vertices[id].Z == p.Z
		)
	end
	return { mesh = mesh, cage = cage, deformation = report, source = E.IO.encode(mesh) }
end
