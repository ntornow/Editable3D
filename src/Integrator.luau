--!strict
-- CPU reference renderer with BSDF/light multiple importance sampling.
-- Returns unclamped linear radiance, not Roblox viewport output.
local B = require(script.Parent.BSDF)
local Lighting = require(script.Parent.Lighting)
local Spatial = require(script.Parent.Spatial)
local Camera = require(script.Parent.Camera)
local Texture = require(script.Parent.Texture)
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
export type IntegratorOptions = Lighting.LightingOptions & {
	seed: number?,
	bounces: number?,
	bias: number?,
	directLighting: boolean?,
	rouletteDepth: number?,
	samples: number?,
	yieldEvery: number?,
	cancelled: (() -> boolean)?,
	progress: ((number) -> ())?,
}
export type Scene = {
	mesh: Types.Mesh,
	index: Spatial.Index,
	materials: { [number]: B.MaterialInput },
	lights: Lighting.LightSet,
}
export type TraceStats = { rays: number, shadowRays: number, bounces: number }
export type RenderReport = {
	samples: number,
	completedRows: number,
	rays: number,
	shadowRays: number,
	cancelled: boolean,
}
local I = {}
local function multiply(a: Vector3, b: Vector3): Vector3
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
local function maximum(v: Vector3): number
	return math.max(v.X, v.Y, v.Z)
end
function I.powerHeuristic(a: number, b: number): number
	assert(a >= 0 and b >= 0)
	if a == 0 then
		return 0
	end
	local ratio = b / a
	return 1 / (1 + ratio * ratio)
end
function I.prepare(
	mesh: Types.Mesh,
	materials: { [number]: B.MaterialInput }?,
	options: IntegratorOptions?
): Scene
	local index = Spatial.new(mesh)
	local materials: { [number]: B.MaterialInput } = materials or { B.diffuse() }
	return {
		mesh = index.mesh,
		index = index,
		materials = materials,
		lights = Lighting.new(index.mesh, materials, options),
	}
end
function I.trace(
	scene: Scene,
	origin: Vector3,
	direction: Vector3,
	options: IntegratorOptions?,
	random: Random?
): (Vector3, TraceStats)
	local options: IntegratorOptions = options or {}
	local random: Random = random or Random.new(options.seed or 0)
	local bounces, bias = options.bounces or 8, options.bias or 0.0001
	U.integer(bounces, 0)
	assert(U.vector(origin) and U.vector(direction) and direction.Magnitude > 0)
	assert(bias > 0 and U.finite(bias))
	direction = direction.Unit
	local radiance, throughput = Vector3.zero, Vector3.one
	local previousPosition: Vector3?, previousPDF, previousDelta = nil, 0, true
	local stats: TraceStats = { rays = 0, shadowRays = 0, bounces = 0 }
	local direct = options.directLighting ~= false
	for depth = 0, bounces do
		stats.rays += 1
		local hit = scene.index:raycast(origin, direction)
		local emitted: Vector3
		local surface: Lighting.SurfaceContext, material: B.Resolved, normal: Vector3, entering: boolean
		if hit then
			surface = Lighting.surface(scene.mesh, hit)
			entering = direction:Dot(hit.normal) < 0
			material = B.resolve(scene.materials[scene.mesh.faces[hit.face].material] or B.diffuse(), surface)
			emitted = B.emission(material, nil, entering)
			normal = entering and hit.normal or -hit.normal
		else
			emitted = scene.lights:environmentRadiance(direction)
		end
		local weight = 1
		if direct and not previousDelta then
			weight =
				I.powerHeuristic(previousPDF, scene.lights:pdf(previousPosition :: Vector3, direction, hit))
		end
		radiance += multiply(throughput, emitted) * weight
		if not hit or depth == bounces then
			break
		end
		if direct then
			local light = scene.lights:sample(hit.position, random)
			if
				light
				and light.pdf > 0
				and maximum(light.radiance) > 0
				and normal:Dot(light.direction) > 0
			then
				local f = B.evaluate(material, normal, -direction, light.direction)
				if maximum(f) > 0 then
					stats.shadowRays += 1
					local shadowOrigin = hit.position + normal * bias
					local maxDistance = light.distance
					local shadowDirection = light.direction
					if maxDistance < math.huge then
						local destination = hit.position + light.direction * maxDistance
						local delta = destination - shadowOrigin
						shadowDirection, maxDistance = delta.Unit, math.max(0, delta.Magnitude - bias)
					end
					if not scene.index:raycast(shadowOrigin, shadowDirection, maxDistance) then
						local mis = light.delta and 1
							or I.powerHeuristic(
								light.pdf,
								B.pdf(material, normal, -direction, light.direction)
							)
						radiance += multiply(throughput, multiply(f, light.radiance)) * (normal:Dot(
							light.direction
						) * mis / light.pdf)
					end
				end
			end
		end
		local sample = B.sample(material, normal, -direction, random, entering)
		if not sample then
			break
		end
		throughput = multiply(throughput, sample.weight)
		assert(U.vector(throughput), "Nonfinite path throughput")
		if maximum(throughput) <= 0 then
			break
		end
		stats.bounces += 1
		previousPosition, previousPDF, previousDelta = hit.position, sample.pdf, sample.delta
		direction = sample.direction
		origin = hit.position + normal * (direction:Dot(normal) >= 0 and bias or -bias)
		if depth + 1 >= (options.rouletteDepth or 3) then
			local survival = math.clamp(maximum(throughput), 0.05, 0.95)
			if random:NextNumber() >= survival then
				break
			end
			throughput /= survival
		end
	end
	return radiance, stats
end
function I.render(
	mesh: Types.Mesh,
	camera: Types.Camera,
	materials: { [number]: B.MaterialInput }?,
	options: IntegratorOptions?
): (Types.Texture?, RenderReport)
	local options: IntegratorOptions = options or {}
	local samples = U.integer(options.samples or 16, 1)
	U.integer(camera.width, 1)
	U.integer(camera.height, 1)
	if options.yieldEvery then
		U.integer(options.yieldEvery, 1)
	end
	local scene = I.prepare(mesh, materials, options)
	local random = Random.new(options.seed or 0)
	local image = Texture.new(camera.width, camera.height)
	local report: RenderReport =
		{ samples = samples, completedRows = 0, rays = 0, shadowRays = 0, cancelled = false }
	for y = 0, camera.height - 1 do
		if options.cancelled and options.cancelled() then
			report.cancelled = true
			return nil, report
		end
		for x = 0, camera.width - 1 do
			local sum = Vector3.zero
			for _ = 1, samples do
				local o, d = Camera.ray(camera, Vector2.new(x + random:NextNumber(), y + random:NextNumber()))
				local value, trace = I.trace(scene, o, d, options, random)
				sum += value
				report.rays += trace.rays
				report.shadowRays += trace.shadowRays
			end
			sum /= samples
			image:set(x, y, Color3.new(sum.X, sum.Y, sum.Z), 1)
		end
		report.completedRows = y + 1
		if options.progress then
			options.progress(report.completedRows / camera.height)
		end
		if options.yieldEvery and (y + 1) % options.yieldEvery == 0 then
			task.wait()
		end
	end
	return image, report
end
function I.toneMap(image: Types.Texture, exposure: number?, method: string?): Types.Texture
	local exposure: number, method: string = exposure or 0, method or "reinhard"
	assert(U.finite(exposure) and (method == "reinhard" or method == "clamp"))
	local scale = 2 ^ exposure
	local function channel(x: number): number
		x = math.max(0, x * scale)
		return method == "reinhard" and x / (1 + x) or math.clamp(x, 0, 1)
	end
	return image:map(function(c, a)
		return Color3.new(channel(c.R), channel(c.G), channel(c.B)), a
	end)
end
return I
