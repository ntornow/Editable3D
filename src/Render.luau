-- Deterministic CPU reference renderer: pinhole camera, diffuse direct light, shadows.
local Spatial = require(script.Parent.Spatial)
local Texture = require(script.Parent.Texture)
local Camera = require(script.Parent.Camera)
local R = {}
function R.render(mesh, camera, options)
	options = options or {}
	local index = Spatial.new(mesh)
	local light = (options.lightDirection or Vector3.new(-1, 2, -1)).Unit
	local ambient = options.ambient or 0.15
	local image = Texture.new(camera.width, camera.height)
	local depth = buffer.create(camera.width * camera.height * 4)
	for y = 0, camera.height - 1 do
		for x = 0, camera.width - 1 do
			local origin, direction = Camera.ray(camera, Vector2.new(x + 0.5, y + 0.5))
			local hit = index:raycast(origin, direction)
			local color = options.background or Color3.new(0.05, 0.05, 0.05)
			if hit then
				local n = hit.normal
				local f = mesh.faces[hit.face]
				local t = hit.triangle
				local bc = hit.barycentric
				local weights = { bc.X, bc.Y, bc.Z }
				local normal = Vector3.zero
				local uv = Vector2.zero
				for i, w in weights do
					local c = f.corners[t.corners[i]]
					normal += (c.normal or n) * w
					uv += (c.uv or Vector2.zero) * w
				end
				if normal.Magnitude > 0 then
					n = normal.Unit
				end
				local albedo = options.shader
						and options.shader({
							position = hit.position,
							normal = n,
							uv = uv,
							material = f.material,
						})
					or options.color
					or Color3.new(0.7, 0.7, 0.7)
				local diffuse = math.max(0, n:Dot(light))
				if
					options.shadows ~= false
					and diffuse > 0
					and index:raycast(hit.position + n * 0.0001, light)
				then
					diffuse = 0
				end
				local intensity = ambient + (1 - ambient) * diffuse
				color = Color3.new(albedo.R * intensity, albedo.G * intensity, albedo.B * intensity)
				buffer.writef32(depth, (y * camera.width + x) * 4, hit.distance)
			else
				buffer.writef32(depth, (y * camera.width + x) * 4, math.huge)
			end
			image:set(x, y, color, hit and 1 or (options.backgroundAlpha or 1))
		end
		if options.yieldEvery and y % options.yieldEvery == 0 then
			task.wait()
		end
	end
	return image, depth
end
function R.silhouette(mesh, camera)
	return R.render(
		mesh,
		camera,
		{ color = Color3.new(1, 1, 1), ambient = 1, shadows = false, background = Color3.new() }
	)
end
function R.compareSilhouettes(a, b, threshold)
	assert(a.width == b.width and a.height == b.height)
	threshold = threshold or 0.5
	local intersection, union = 0, 0
	for y = 0, a.height - 1 do
		for x = 0, a.width - 1 do
			local av = a:get(x, y).R >= threshold
			local bv = b:get(x, y).R >= threshold
			if av or bv then
				union += 1
			end
			if av and bv then
				intersection += 1
			end
		end
	end
	return {
		intersectionOverUnion = union == 0 and 1 or intersection / union,
		intersection = intersection,
		union = union,
	}
end
return R
