-- Pressure-varying spaced draw dabs with a mirrored counterpart on a UV panel.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Primitives.grid(12, 12, Vector2.new(4, 4))
	local mesh, stroke = E.Sculpt.stroke(source, {
		{ position = Vector3.new(0.65, 0, -1), pressure = 0.25 },
		{ position = Vector3.new(0.85, 0, 0), pressure = 1 },
		{ position = Vector3.new(0.65, 0, 1), pressure = 0.25 },
	}, {
		normal = Vector3.yAxis,
		radius = 0.6,
		spacing = 0.3,
		strength = 0.15,
		falloff = "smoother",
		pinBoundary = true,
		symmetry = { mirror = { X = true } },
		adjustStrengthForSpacing = true,
		requireComplete = true,
	})
	return { mesh = mesh, source = source, stroke = stroke }
end
