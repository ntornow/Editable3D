-- Run: local bundle = require(Editable3D.Examples.SculptAndMaterial)(workspace)
-- Clean up: require(Editable3D).Roblox.destroy(bundle)
return function(parent)
	local E = require(script.Parent.Parent)
	local mesh = E.Subdivision.catmullClark(E.Primitives.box(Vector3.new(4, 5, 3)), 3)
	local mask = E.Selection.sphere(mesh, Vector3.new(0, 2, -1), 2)
	mesh = E.Sculpt.move(mesh, mask, Vector3.new(0, 0.6, -0.4))
	mesh = E.Sculpt.smooth(mesh, mask, 2)
	mesh = E.UV.spherical(mesh)
	local bundle = E.Roblox.toModel(mesh, { name = "Editable3D_SculptExample", parent = parent })
	local noise = E.Texture.noise(128, 128, 16, 4, 5)
	local copper = noise:map(function(color, alpha)
		return Color3.new(0.07, 0.22, 0.16):Lerp(Color3.new(0.2, 0.4, 0.3), color.R), alpha
	end)
	E.Roblox.applyMaterial(bundle, {
		ColorMap = copper,
		RoughnessMap = E.Texture.new(32, 32, Color3.new(0.7, 0.7, 0.7), 1),
		NormalMap = noise:normalFromHeight(0.3),
	})
	return bundle
end
