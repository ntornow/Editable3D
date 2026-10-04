-- Angle-optimized disk charts, packed and rechecked in the final texture metric.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.torus(3, 1, 12, 8)
	local seams, cutting = E.Unwrap.autoSeams(
		source,
		{ angleLimit = math.rad(45), normalCone = math.rad(60), maxChartFaces = 12 }
	)
	local mesh, unwrap = E.Unwrap.unwrap(source, seams, {
		method = "angle",
		textureSize = Vector2.new(1024, 512),
		packing = { margin = 4 },
		requireComplete = true,
	})
	return { mesh = mesh, source = source, seams = seams, cutting = cutting, unwrap = unwrap }
end
