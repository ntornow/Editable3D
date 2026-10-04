-- Six conformal box charts, common texel density, and a rectangular texture atlas.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.box(Vector3.new(4, 2, 1))
	local charts = E.Unwrap.unwrap(source, E.Unwrap.sharpSeams(source), { method = "lscm" })
	local mesh, packing = E.UV.packIslands(
		charts,
		{ textureSize = Vector2.new(1024, 512), margin = 4, normalizeDensity = true, requireComplete = true }
	)
	local analysis = E.UV.analyze(mesh, { textureSize = Vector2.new(1024, 512), requireComplete = true })
	assert(analysis.overlapFree and analysis.consistentOrientation and #analysis.islands == 6)
	return { mesh = mesh, source = source, packing = packing, analysis = analysis }
end
