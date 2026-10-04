-- Geometric disk charts for a closed genus-one surface, then conformal atlas packing.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.torus(3, 1, 12, 8)
	local seams, cutting = E.Unwrap.autoSeams(
		source,
		{ angleLimit = math.rad(45), normalCone = math.rad(60), maxChartFaces = 12 }
	)
	local charts, unwrap = E.Unwrap.unwrap(source, seams, { method = "lscm" })
	for _, report in unwrap.reports do
		assert(report.converged)
	end
	local mesh, packing =
		E.UV.packIslands(charts, { normalizeDensity = true, margin = 0.01, requireComplete = true })
	local analysis = E.UV.analyze(mesh)
	assert(analysis.complete and analysis.overlapFree and analysis.consistentOrientation)
	return {
		mesh = mesh,
		source = source,
		seams = seams,
		cutting = cutting,
		unwrap = unwrap,
		packing = packing,
		analysis = analysis,
	}
end
