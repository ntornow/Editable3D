-- Pure-data rational sheet with a circular trimmed opening.
return function(API)
	local E = API or require(script.Parent.Parent)
	local surface = E.NURBS.surface({
		{ Vector3.new(-2, -2, 0), Vector3.new(-2, 0, 0.5), Vector3.new(-2, 2, 0) },
		{ Vector3.new(0, -2, 0.5), Vector3.new(0, 0, 1.5), Vector3.new(0, 2, 0.5) },
		{ Vector3.new(2, -2, 0), Vector3.new(2, 0, 0.5), Vector3.new(2, 2, 0) },
	}, 2, 2)
	local rim = E.Surfaces.arc(CFrame.new(0.5, 0.5, 0), 0.47, 0, 2 * math.pi)
	local opening = E.Surfaces.arc(CFrame.new(0.5, 0.5, 0), 0.16, 0, 2 * math.pi)
	local trimmed, boundaries = E.SurfaceTrim.fromCurves(
		surface,
		rim,
		{ opening },
		{ curveTolerance = 0.003 }
	)
	local mesh, report = E.SurfaceTrim.tessellate(trimmed, { levels = 2 })
	assert(mesh:validate().valid)
	return { surface = trimmed, mesh = mesh, boundaries = boundaries, tessellation = report }
end
