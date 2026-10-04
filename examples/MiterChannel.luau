-- An audited U-channel with planar faces and constant face offsets at its folds.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Mesh.new()
	local profile = { Vector2.new(-2, 1), Vector2.new(-2, 0), Vector2.new(2, 0), Vector2.new(2, 1) }
	for _, z in { -2, 2 } do
		for _, p in profile do
			source:addVertex(Vector3.new(p.X, p.Y, z))
		end
	end
	for i = 1, 3 do
		source:addFace({ i, i + 4, i + 5, i + 1 }, {
			{ uv = Vector2.new(0, 0) },
			{ uv = Vector2.new(0, 1) },
			{ uv = Vector2.new(1, 1) },
			{ uv = Vector2.new(1, 0) },
		})
	end
	local mesh, shell = E.Modifiers.shell(source, 0.25, { maxOffsetError = 1e-5 })
	assert(shell.complete and shell.outputIntersections.intersectionFree)
	assert(math.abs(mesh:volume() - 6) < 1e-5)
	return { mesh = mesh, shell = shell, source = E.IO.encode(mesh) }
end
