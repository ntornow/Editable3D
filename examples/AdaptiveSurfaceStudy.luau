-- Pure-data surface study: queries, adaptive approximation and topology diagnostics.
return function(API)
	local E = API or require(script.Parent.Parent)
	local surface = E.Surfaces.sphere(CFrame.identity, 2)
	local nearest = E.SplineQuery.closestSurface(surface, Vector3.new(3, 2, 1), { tolerance = 0.001 })
	local mesh, report =
		E.SurfaceAdaptive.tessellate(surface, { tolerance = 0.05, closedV = true, collapsePoles = true })
	local profile = E.Surfaces.arc(CFrame.identity, 2, 0, math.pi)
	local length = E.SplineQuery.length(profile, { tolerance = 0.001 })
	local points, sampling = E.SplineQuery.sample(profile, { tolerance = 0.01 })
	assert(nearest.converged and report.converged and length.converged and sampling.converged)
	assert(mesh:validate().closed)
	return { mesh = mesh, nearest = nearest, approximation = report, profile = points, length = length, sampling = sampling }
end
