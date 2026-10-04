--!strict
-- Explicit light distributions; all returned PDFs include light-selection probability.
local B = require(script.Parent.BSDF)
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
-- A ray hit as produced by Spatial:raycast (distance is optional for synthetic hits).
export type Hit = {
	face: number,
	triangle: Types.Triangle,
	barycentric: Vector3,
	position: Vector3,
	normal: Vector3,
	distance: number?,
}
export type SurfaceContext = Hit & { uv: Vector2?, geometricNormal: Vector3, shadingNormal: Vector3 }
export type PointLight = { kind: "point", position: Vector3, intensity: Vector3, weight: number? }
export type DirectionalLight = { kind: "directional", direction: Vector3, radiance: Vector3, weight: number? }
export type EnvironmentLight = {
	kind: "environment",
	-- Color3/Vector3 radiance, a Texture (equirectangular), or a function of direction.
	source: any,
	cdf: { number }?,
	weights: { number }?,
	solidAngles: { number }?,
	total: number?,
	weight: number?,
}
export type TriangleLight = {
	kind: "triangle",
	a: Vector3,
	b: Vector3,
	c: Vector3,
	normal: Vector3,
	area: number,
	triangle: Types.Triangle,
	material: B.MaterialInput,
	weight: number?,
}
export type Light = PointLight | DirectionalLight | EnvironmentLight | TriangleLight
export type LightSample = {
	direction: Vector3,
	radiance: Vector3,
	pdf: number,
	distance: number,
	delta: boolean,
	position: Vector3?,
}
export type LightingOptions = {
	lights: { PointLight | DirectionalLight }?,
	-- An EnvironmentLight, or any source accepted by Lighting.environment.
	environment: any,
}
local L = {}
local Set = {}
Set.__index = Set
type SetData = {
	lights: { Light },
	cdf: { number },
	total: number,
	triangles: { [string]: TriangleLight },
	mesh: Types.Mesh,
	materials: { [number]: B.MaterialInput },
	environment: EnvironmentLight?,
}
export type LightSet = typeof(setmetatable({} :: SetData, Set))
local PI = math.pi
local function rgb(c: any): Vector3
	if typeof(c) == "Color3" then
		c = Vector3.new(c.R, c.G, c.B)
	end
	assert(U.vector(c) and c.X >= 0 and c.Y >= 0 and c.Z >= 0, "Expected nonnegative linear radiance")
	return c
end
local function luminance(c: Vector3): number
	return c.X * 0.2126 + c.Y * 0.7152 + c.Z * 0.0722
end
local function uniformDirection(u: number, v: number): Vector3
	local y, phi = 1 - 2 * u, 2 * PI * v
	local r = math.sqrt(math.max(0, 1 - y * y))
	return Vector3.new(r * math.cos(phi), y, r * math.sin(phi))
end
local function uv(direction: Vector3): Vector2
	return Vector2.new(
		(math.atan2(direction.Z, direction.X) / (2 * PI) + 0.5) % 1,
		math.acos(math.clamp(direction.Y, -1, 1)) / PI
	)
end
local function search(cdf: { number }, target: number): number
	local lo, hi = 1, #cdf
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if target < cdf[mid] then
			hi = mid
		else
			lo = mid + 1
		end
	end
	return lo
end
local function triangleKey(t: Types.Triangle): string
	return t.face .. ":" .. table.concat(t.corners, ",")
end
function L.surface(mesh: Types.Mesh, hit: Hit): SurfaceContext
	local context: SurfaceContext = table.clone(hit) :: any -- surface fields added below
	local face = mesh.faces[hit.face]
	local weights = { hit.barycentric.X, hit.barycentric.Y, hit.barycentric.Z }
	local coords, normal, hasUV, hasNormal = Vector2.zero, Vector3.zero, true, true
	for i = 1, 3 do
		local corner = face.corners[hit.triangle.corners[i]]
		if corner.uv then
			coords += corner.uv * weights[i]
		else
			hasUV = false
		end
		if corner.normal then
			normal += corner.normal * weights[i]
		else
			hasNormal = false
		end
	end
	context.uv = hasUV and coords or nil
	context.geometricNormal = hit.normal
	context.shadingNormal = hasNormal and U.unit(normal, hit.normal) or hit.normal
	if context.shadingNormal:Dot(hit.normal) < 0 then
		context.shadingNormal = -context.shadingNormal
	end
	return context
end
function L.point(position: Vector3, intensity: Color3 | Vector3): PointLight
	assert(U.vector(position))
	return { kind = "point", position = position, intensity = rgb(intensity) }
end
-- direction points from a surface TOWARDS the distant light.
function L.directional(direction: Vector3, radiance: Color3 | Vector3): DirectionalLight
	assert(U.vector(direction) and direction.Magnitude > 0)
	return { kind = "directional", direction = direction.Unit, radiance = rgb(radiance) }
end
function L.environment(source: any?): EnvironmentLight
	local source: any = source or Color3.new()
	local env: EnvironmentLight = { kind = "environment", source = source }
	if type(source) == "table" and source.sample and source.width and source.height then
		local cdf: { number }, weights: { number }, solidAngles: { number } = {}, {}, {}
		env.cdf, env.weights, env.solidAngles, env.total = cdf, weights, solidAngles, 0
		for y = 0, source.height - 1 do
			local omega = 2
				* PI
				/ source.width
				* (math.cos(PI * y / source.height) - math.cos(PI * (y + 1) / source.height))
			for x = 0, source.width - 1 do
				local index = y * source.width + x + 1
				local weight = luminance(rgb(source:get(x, y))) * omega
				env.total = (env.total :: number) + weight
				cdf[index], weights[index], solidAngles[index] = env.total :: number, weight, omega
			end
		end
	elseif type(source) ~= "function" then
		rgb(source)
	end
	return env
end
function L.environmentRadiance(env: EnvironmentLight, direction: Vector3): Vector3
	local source = env.source
	if type(source) == "function" then
		return rgb(source(direction))
	end
	if type(source) == "table" and source.sample then
		return rgb(source:sample(uv(direction), true, false))
	end
	return rgb(source)
end
function L.environmentPDF(env: EnvironmentLight, direction: Vector3): number
	if not env.total or env.total == 0 then
		return 1 / (4 * PI)
	end
	local p = uv(direction)
	local x = math.min(env.source.width - 1, math.floor(p.X * env.source.width))
	local y = math.min(env.source.height - 1, math.floor(p.Y * env.source.height))
	local index = y * env.source.width + x + 1
	return (env.weights :: { number })[index] / (env.total * (env.solidAngles :: { number })[index])
end
function L.sampleEnvironment(env: EnvironmentLight, random: Random): LightSample
	local direction: Vector3
	if env.total and env.total > 0 then
		local index = search(env.cdf :: { number }, random:NextNumber() * env.total)
		local x, y = (index - 1) % env.source.width, math.floor((index - 1) / env.source.width)
		local theta0, theta1 = PI * y / env.source.height, PI * (y + 1) / env.source.height
		local cosine = math.cos(theta0) + random:NextNumber() * (math.cos(theta1) - math.cos(theta0))
		local phi = 2 * PI * ((x + random:NextNumber()) / env.source.width - 0.5)
		local sine = math.sqrt(math.max(0, 1 - cosine * cosine))
		direction = Vector3.new(sine * math.cos(phi), cosine, sine * math.sin(phi))
	else
		direction = uniformDirection(random:NextNumber(), random:NextNumber())
	end
	return {
		direction = direction,
		radiance = L.environmentRadiance(env, direction),
		pdf = L.environmentPDF(env, direction),
		distance = math.huge,
		delta = false,
	}
end
local function potentialEmission(m: B.MaterialInput): boolean
	if
		m.kind == "mix"
		and (potentialEmission(m.a :: B.MaterialInput) or potentialEmission(m.b :: B.MaterialInput))
	then
		return true
	end
	if m.emission == nil then
		return false
	end
	if type(m.emission) == "function" or type(m.emission) == "table" then
		return true
	end
	return luminance(rgb(m.emission)) > 0
end
function L.new(
	mesh: Types.Mesh,
	materials: { [number]: B.MaterialInput },
	options: LightingOptions?
): LightSet
	local options: LightingOptions = options or {}
	local self: LightSet = setmetatable(
		{ lights = {}, cdf = {}, total = 0, triangles = {}, mesh = mesh, materials = materials } :: SetData,
		Set
	)
	local function add(original: Light, weight: number): Light
		local light = table.clone(original)
		light.weight = math.max(weight, 1e-10)
		self.total += light.weight
		table.insert(self.lights, light)
		table.insert(self.cdf, self.total)
		return light
	end
	for _, t in mesh:triangles() do
		local material = materials[mesh.faces[t.face].material]
		if material and potentialEmission(material) then
			local a, b, c = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
			local cross = (b - a):Cross(c - a)
			local area = cross.Magnitude * 0.5
			if area > 1e-12 then
				local normal = cross.Unit
				local center = L.surface(mesh, {
					face = t.face,
					triangle = t,
					barycentric = Vector3.one / 3,
					position = (a + b + c) / 3,
					normal = normal,
				})
				local power = math.max(luminance(B.emission(material, center, true)), 0.001)
				local light = add({
					kind = "triangle",
					a = a,
					b = b,
					c = c,
					normal = normal,
					area = area,
					triangle = t,
					material = material,
				}, area * power)
				self.triangles[triangleKey(t)] = light :: TriangleLight
			end
		end
	end
	for _, light in (options.lights or {}) :: { PointLight | DirectionalLight } do
		assert(
			light.kind == "point" or light.kind == "directional",
			"Explicit lights must be point or directional; supply environment separately"
		)
		add(light, luminance((light :: any).intensity or (light :: any).radiance))
	end
	if options.environment then
		local env: EnvironmentLight = type(options.environment) == "table"
				and options.environment.kind == "environment"
				and options.environment
			or L.environment(options.environment)
		self.environment = add(env, env.total or 1) :: EnvironmentLight
	end
	return self
end
function Set.environmentRadiance(self: LightSet, direction: Vector3): Vector3
	return self.environment and L.environmentRadiance(self.environment, direction) or Vector3.zero
end
function Set.sample(self: LightSet, point: Vector3, random: Random): LightSample?
	if #self.lights == 0 then
		return nil
	end
	local light = self.lights[search(self.cdf, random:NextNumber() * self.total)]
	local probability = (light.weight :: number) / self.total
	if light.kind == "environment" then
		local s = L.sampleEnvironment(light, random)
		s.pdf *= probability
		return s
	elseif light.kind == "directional" then
		return {
			direction = light.direction,
			radiance = light.radiance,
			pdf = probability,
			distance = math.huge,
			delta = true,
		}
	elseif light.kind == "point" then
		local delta = light.position - point
		if delta.Magnitude < 1e-12 then
			return nil
		end
		return {
			direction = delta.Unit,
			radiance = light.intensity / delta:Dot(delta),
			pdf = probability,
			distance = delta.Magnitude,
			delta = true,
		}
	end
	local root = math.sqrt(random:NextNumber())
	local bary = Vector3.new(1 - root, root * (1 - random:NextNumber()), 0)
	bary = Vector3.new(bary.X, bary.Y, 1 - bary.X - bary.Y)
	local position = light.a * bary.X + light.b * bary.Y + light.c * bary.Z
	local delta = position - point
	if delta.Magnitude < 1e-12 then
		return nil
	end
	local direction = delta.Unit
	local cosine = math.abs(light.normal:Dot(direction))
	if cosine < 1e-12 then
		return nil
	end
	local context = L.surface(self.mesh, {
		face = light.triangle.face,
		triangle = light.triangle,
		barycentric = bary,
		position = position,
		normal = light.normal,
	})
	return {
		direction = direction,
		radiance = B.emission(light.material, context, light.normal:Dot(-direction) > 0),
		pdf = probability * delta:Dot(delta) / (light.area * cosine),
		distance = delta.Magnitude,
		delta = false,
		position = position,
	}
end
function Set.pdf(self: LightSet, point: Vector3, direction: Vector3, hit: Hit?): number
	if self.total == 0 then
		return 0
	end
	if not hit then
		return self.environment
				and (self.environment.weight :: number) / self.total * L.environmentPDF(
					self.environment,
					direction
				)
			or 0
	end
	local light = self.triangles[triangleKey(hit.triangle)]
	if not light then
		return 0
	end
	local cosine = math.abs(light.normal:Dot(direction))
	if cosine < 1e-12 then
		return 0
	end
	local delta = hit.position - point
	return (light.weight :: number) / self.total * delta:Dot(delta) / (light.area * cosine)
end
return L
