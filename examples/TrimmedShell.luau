-- Pure-data spherical band with a window and a welded angular seam.
return function(E)
	E = E or require(script.Parent.Parent)
	local v = Vector2.new
	local surface = E.Surfaces.sphere(CFrame.identity, 2)
	local trimmed = E.SurfaceTrim.surface(
		surface,
		{ v(0.15, 0), v(0.85, 0), v(0.85, 1), v(0.15, 1) },
		{ { v(0.35, 0.3), v(0.65, 0.3), v(0.65, 0.7), v(0.35, 0.7) } }
	)
	local mesh, approximation = E.SurfaceTrim.adaptive(trimmed, { tolerance = 0.3, closedV = true })
	assert(approximation.converged and mesh:validate().valid)
	assert(#E.Connectivity.boundaries(mesh) == 3)
	return { mesh = mesh, approximation = approximation, source = E.IO.encode(mesh) }
end
