-- Authoring channels survive refinement, shell construction, clipping and partitions.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.grid(2, 2, Vector2.new(4, 4))
	local values = {}
	source.groups.horizontal = {}
	for id, p in source.vertices do
		values[id] = (p.X + 2) / 4
		source.groups.horizontal[id] = values[id]
	end
	source = E.Attributes.set(
		E.Attributes.create(source, "horizontal", "vertex", "number", 0),
		"horizontal",
		values
	)
	local refined, refinement = E.Adaptive.refine(source, 0.8, { maxOperations = 100 })
	local shell = E.Modifiers.solidify(refined, 0.3, { offset = 1 })
	local mesh = E.Modifiers.clipPlane(shell, Vector3.new(0.5, 0, 0), Vector3.xAxis)
	assert(mesh:validate().closed and math.abs(mesh:volume() - 3) < 1e-5)
	for id, p in mesh.vertices do
		assert(math.abs(E.Attributes.get(mesh, "horizontal", id) - (p.X + 2) / 4) < 1e-6)
	end
	local chunks = E.Roblox.partition(mesh, 24)
	for _, chunk in chunks do
		assert(#E.Attributes.names(chunk.mesh) == 1)
	end
	return { mesh = mesh, refinement = refinement, chunks = chunks, source = E.IO.encode(mesh) }
end
