-- Headless material study. Returns linear HDR image, display image, and render report.
-- No instances, viewport changes or uploads. toRGBA8(true) encodes the display image.
return function(options)
	local E = require(script.Parent.Parent)
	options = options or {}
	local meshes = {}
	for i = 1, 3 do
		local sphere = E.Primitives.sphere(0.8, 32, 16)
		local faces = {}
		for id in sphere.faces do
			faces[id] = true
		end
		sphere = E.Geometry.assignMaterial(sphere, faces, i)
		table.insert(meshes, E.Deform.transform(sphere, CFrame.new((i - 2) * 1.9, 0, 0)))
	end
	local materials = {
		E.BSDF.metallicRoughness({ baseColor = Color3.new(0.45, 0.12, 0.06), roughness = 0.55 }),
		E.BSDF.metallicRoughness({ baseColor = Color3.new(0.75, 0.52, 0.22), roughness = 0.25, metallic = 1 }),
		E.BSDF.mix(
			E.BSDF.diffuse(Color3.new(0.15, 0.4, 0.5)),
			E.BSDF.ggx({ f0 = Color3.new(0.6, 0.8, 0.9), roughness = 0.5 }),
			0.65
		),
	}
	local mesh = E.Topology.join(meshes)
	local camera = E.Camera.new(
		CFrame.lookAt(Vector3.new(0, 2, 8), Vector3.zero),
		35,
		options.width or 96,
		options.height or 48
	)
	local image, report = E.Integrator.render(mesh, camera, materials, {
		samples = options.samples or 16,
		bounces = 4,
		seed = 42,
		environment = Color3.new(0.12, 0.15, 0.2),
		lights = {
			E.Lighting.point(Vector3.new(-3, 5, 4), Color3.new(90, 80, 65)),
			E.Lighting.directional(Vector3.new(2, 3, -2), Color3.new(0.8, 0.9, 1.2)),
		},
		yieldEvery = 4,
		progress = options.progress,
		cancelled = options.cancelled,
	})
	return image, image and E.Integrator.toneMap(image, options.exposure or 0) or nil, report
end
