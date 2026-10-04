-- CPU Monte Carlo path tracer for diffuse, ideal metal and dielectric materials.
-- No GPU, denoiser or participating media. Linear radiance output, deterministic seed.
local Spatial = require(script.Parent.Spatial)
local Texture = require(script.Parent.Texture)
local Camera = require(script.Parent.Camera)
local U = require(script.Parent.Util)
local P = {}
local function mul(a, b)
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
local function color(c)
	return Vector3.new(c.R, c.G, c.B)
end
function P.render(mesh, camera, materials, options)
	options = options or {}
	local samples = options.samples or 16
	local bounces = options.bounces or 8
	U.integer(samples, 1)
	U.integer(bounces, 1)
	local index = Spatial.new(mesh)
	local random = Random.new(options.seed or 0)
	local image = Texture.new(camera.width, camera.height)
	local function radiance(origin, direction)
		local throughput = Vector3.one
		local light = Vector3.zero
		for bounce = 1, bounces do
			local hit = index:raycast(origin, direction)
			if not hit then
				local environment = options.environment
				local c = type(environment) == "function" and environment(direction)
					or environment
					or Color3.new(0.5, 0.6, 0.8)
				light += mul(throughput, color(c))
				break
			end
			local material = materials[mesh.faces[hit.face].material]
				or { kind = "diffuse", albedo = Color3.new(0.8, 0.8, 0.8) }
			local emitted = material.emission or Color3.new()
			light += mul(throughput, color(emitted))
			local outward = hit.normal
			local entering = direction:Dot(outward) < 0
			local normal = entering and outward or -outward
			local albedo = type(material.albedo) == "function" and material.albedo(hit)
				or material.albedo
				or Color3.new(1, 1, 1)
			throughput = mul(throughput, color(albedo))
			if material.kind == "dielectric" then
				local ior = material.ior or 1.5
				assert(ior > 0)
				local eta = entering and 1 / ior or ior
				local cosine = math.clamp(-direction:Dot(normal), 0, 1)
				local k = 1 - eta * eta * (1 - cosine * cosine)
				local r0 = ((1 - ior) / (1 + ior)) ^ 2
				local fresnel = r0 + (1 - r0) * (1 - cosine) ^ 5
				if k < 0 or random:NextNumber() < fresnel then
					direction = direction - normal * 2 * direction:Dot(normal)
				else
					direction = direction * eta + normal * (eta * cosine - math.sqrt(k))
					throughput *= eta * eta
				end
			elseif material.kind == "metal" then
				direction = direction - normal * 2 * direction:Dot(normal)
			else
				assert(material.kind == nil or material.kind == "diffuse", "Unknown material kind")
				local r = math.sqrt(random:NextNumber())
				local a = 2 * math.pi * random:NextNumber()
				local x, y = U.frame(normal)
				direction = x * (r * math.cos(a)) + y * (r * math.sin(a)) + normal * math.sqrt(1 - r * r)
			end
			direction = direction.Unit
			origin = hit.position + direction * (options.bias or 0.0001)
			if bounce >= 3 then
				local survival = math.clamp(math.max(throughput.X, throughput.Y, throughput.Z), 0.05, 0.95)
				if random:NextNumber() > survival then
					break
				end
				throughput /= survival
			end
		end
		return light
	end
	for y = 0, camera.height - 1 do
		if options.cancelled and options.cancelled() then
			return nil, { cancelled = true, completedRows = y }
		end
		for x = 0, camera.width - 1 do
			local sum = Vector3.zero
			for _ = 1, samples do
				local o, d = Camera.ray(camera, Vector2.new(x + random:NextNumber(), y + random:NextNumber()))
				sum += radiance(o, d)
			end
			sum /= samples
			image:set(x, y, Color3.new(sum.X, sum.Y, sum.Z), 1)
		end
		if options.progress then
			options.progress((y + 1) / camera.height)
		end
		if options.yieldEvery and y % options.yieldEvery == 0 then
			task.wait()
		end
	end
	return image, { samples = samples, bounces = bounces, cancelled = false }
end
return P
