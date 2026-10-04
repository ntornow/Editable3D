-- One curved patch with a hole, both crossing the torus parameter seam.
return function(E)
	E = E or require(script.Parent.Parent)
	local v = Vector2.new
	local function box(a, b, c, d)
		return { v(a, b), v(c, b), v(c, d), v(a, d) }
	end
	local trimmed, decomposition = E.SurfaceTrim.regions(E.Surfaces.torus(CFrame.identity, 3, 1), {
		{ outer = box(0.625, 0.125, 1.375, 0.875), holes = { box(0.875, 0.375, 1.125, 0.625) } },
	}, { closedU = true, closedV = true })
	local mesh, approximation = E.SurfaceTrim.adaptive(trimmed, { tolerance = 0.3 })
	assert(approximation.converged and E.Connectivity.analyze(mesh).valid)
	assert(#E.Connectivity.boundaries(mesh) == 2)
	return {
		mesh = mesh,
		decomposition = decomposition,
		approximation = approximation,
		source = E.IO.encode(mesh),
	}
end
