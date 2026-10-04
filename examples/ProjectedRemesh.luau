-- Resolution-dependent reconstruction with explicit source-data projection reports.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.sphere(1.3, 8, 4)
	local values = {}
	source.groups.horizontal = {}
	for id, p in source.vertices do
		values[id] = (p.X + 1.3) / 2.6
		source.groups.horizontal[id] = values[id]
	end
	source = E.Attributes.set(
		E.Attributes.create(source, "horizontal", "vertex", "number", 0),
		"horizontal",
		values
	)
	local mesh, reconstruction = E.Remesh.voxel(source, 0.6)
	assert(reconstruction.complete and mesh:validate().closed)
	for id in mesh.vertices do
		local value = E.Attributes.get(mesh, "horizontal", id)
		assert(value >= 0 and value <= 1 and math.abs(value - mesh.groups.horizontal[id]) < 1e-6)
	end
	return { mesh = mesh, reconstruction = reconstruction, source = E.IO.encode(mesh) }
end
