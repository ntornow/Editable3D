-- Original geometry, two shape keys and a portable animation. No scene mutation.
return function(API)
	local E = API or require(script.Parent.Parent)
	local base = E.Primitives.box(Vector3.new(2, 2, 2))
	base = E.Subdivision.catmullClark(base, 2)
	local tall = E.Deform.map(base, function(p)
		return Vector3.new(p.X, p.Y * (1 + 0.4 * (p.Y + 1)), p.Z)
	end)
	local wide = E.Deform.map(base, function(p)
		return Vector3.new(p.X * (1 + 0.5 * (1 - p.Y * p.Y)), p.Y, p.Z)
	end)
	local scene = E.GLTF.fromMesh(base, { name = "Original animated shape" })
	scene.morphTargets =
		{ { E.Morph.fromMeshes(base, tall, "Tall"), E.Morph.fromMeshes(base, wide, "Wide") } }
	scene.meshWeights = { { 0, 0 } }
	scene.animations = {
		E.Timeline.clip({
			E.Timeline.channel(
				"weights",
				{ 0, 1, 2, 3 },
				{ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 0, 0 } },
				{ node = 1 }
			),
			E.Timeline.channel(
				"rotation",
				{ 0, 3 },
				{ E.Quaternion.identity, E.Quaternion.fromAxisAngle(Vector3.yAxis, math.pi * 0.75) },
				{ node = 1 }
			),
		}, "Shape study"),
	}
	local bytes = E.GLTF.toGLB(scene)
	local restored = E.GLTF.fromGLB(bytes)
	local frames = {}
	for i = 0, 6 do
		local time = i * 0.5
		frames[#frames + 1] =
			{ time = time, mesh = E.GLTF.meshAt(restored, 1, E.GLTF.sampleAnimation(restored, 1, time)) }
	end
	return { scene = scene, glb = bytes, restored = restored, frames = frames }
end
