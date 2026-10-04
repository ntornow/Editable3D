-- Original procedural geometry only. Returns in-memory interchange data; does not
-- fetch models, create Instances, upload assets, or change the open scene.
return function(E)
	local mesh = E.Primitives.box(Vector3.new(2, 3, 1))
	mesh:recalculateNormals(math.rad(35))
	local scene = E.GLTF.fromMesh(mesh, {
		name = "Original procedural box",
		materials = {
			{
				name = "Patinated copper",
				pbrMetallicRoughness = {
					baseColorFactor = { 0.22, 0.46, 0.38, 1 },
					metallicFactor = 0.15,
					roughnessFactor = 0.8,
				},
			},
		},
	})
	local glb = E.GLTF.toGLB(scene)
	local restored = E.GLTF.fromGLB(glb)
	local evaluated = E.GLTF.meshAt(restored, 1)
	assert(#evaluated:triangles() == #mesh:triangles())
	local json, buffers = E.GLTF.toJSON(scene, "geometry.bin")
	return { glb = glb, json = json, buffers = buffers, scene = restored, mesh = evaluated }
end
