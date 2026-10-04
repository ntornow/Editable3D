-- Pure-data crossed panel cuts on a closed box, with shared neighbor edges.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.box(Vector3.new(8, 2, 8))
	local strokes = {
		{ face = 5, path = { { edge = 1, t = 0.5 }, { edge = 3, t = 0.5 } } },
		{ face = 5, path = { { edge = 2, t = 0.5 }, { edge = 4, t = 0.5 } } },
		{
			face = 5,
			path = {
				Vector3.new(-2, 1, -2),
				Vector3.new(2, 1, -2),
				Vector3.new(2, 1, 2),
				Vector3.new(-2, 1, 2),
				Vector3.new(-2, 1, -2),
			},
		},
	}
	local mesh, network = E.MeshEdit.knifeNetwork(source, strokes)
	mesh = E.Normals.recalculate(mesh, { creaseAngle = math.rad(60), weighting = "area" })
	assert(mesh:validate().closed and math.abs(mesh:volume() - 128) < 1e-4)
	return { mesh = mesh, network = network, source = E.IO.encode(mesh) }
end
