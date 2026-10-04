-- Demonstrates mesh/UV splitting across several native EditableImages.
return function(parent)
	local E = require(script.Parent.Parent)
	local mesh = E.UV.faceCharts(E.Modifiers.bevelConvex(E.Primitives.box(), 0.15))
	return E.Roblox.toTexturedModel(mesh, {
		ColorMap = E.Texture.noise(192, 192, 6, 4, 4),
		RoughnessMap = E.Texture.new(192, 192, Color3.new(0.6, 0.6, 0.6), 1),
	}, { name = "Editable3D_TiledExample", parent = parent, tileSize = 64 })
end
