-- A variable-density panel with fixed boundary samples and native endpoint audits.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.grid(4, 4, Vector2.new(4, 4))
	local mesh, retopology = E.Remesh.quads(source, function(p)
		return 0.4 + 0.15 * (p.X + 2)
	end, {
		coarsen = false,
		maxDeviation = 0.001,
		minimumScaledJacobian = 0.2,
		maximumAspectRatio = 5,
	})
	assert(retopology.applied, "Quad panel failed its geometry audits")
	return { source = source, mesh = mesh, retopology = retopology }
end
