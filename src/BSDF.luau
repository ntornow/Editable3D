--!strict
-- Headless, linear-RGB surface scattering. Directions point AWAY from the surface.
-- Original implementation of the equations referenced in SHADING.md.
local U = require(script.Parent.Util)
-- Material inputs are polymorphic: a constant (number/Color3/Vector3), a Texture, or a
-- function of the shading context. Those value fields are therefore `any`.
export type Material = {
	kind: string?,
	baseColor: any,
	albedo: any,
	ior: any,
	exteriorIor: any,
	roughness: any,
	metallic: any,
	f0: any,
	emission: any,
	twoSidedEmission: boolean?,
	a: MaterialInput?,
	b: MaterialInput?,
	weight: any,
	_resolved: boolean?,
}
-- Fields other than kind/emission/twoSidedEmission are only present for the kinds that use them.
export type Resolved = {
	kind: string,
	_resolved: boolean,
	a: Resolved?,
	b: Resolved?,
	weight: number?,
	baseColor: Vector3?,
	ior: number?,
	exteriorIor: number?,
	alpha: number?,
	metallic: number?,
	f0: Vector3?,
	emission: Vector3,
	twoSidedEmission: boolean,
}
export type MaterialInput = Material | Resolved
-- A Random, or a function returning uniform numbers in [0,1).
export type RandomSource = Random | () -> number
export type Sample =
	{ direction: Vector3, pdf: number, weight: Vector3, delta: boolean, transmission: boolean }
local B = {}
local PI = math.pi
local ZERO, ONE = Vector3.zero, Vector3.one
local function multiply(a: Vector3, b: Vector3): Vector3
	return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
local function rgb(c: any): Vector3
	if typeof(c) == "Color3" then
		c = Vector3.new(c.R, c.G, c.B)
	end
	assert(U.vector(c) and c.X >= 0 and c.Y >= 0 and c.Z >= 0, "Expected finite nonnegative linear RGB")
	return c
end
local function read(value: any, context: any): any
	if type(value) == "function" then
		return value(context)
	end
	if type(value) == "table" and value.sample then
		assert(context and context.uv, "Texture-valued material requires UVs")
		return value:sample(context.uv, context.wrap ~= false)
	end
	return value
end
local function scalar(value: any, context: any, default: any): number
	local v = read(value == nil and default or value, context)
	if typeof(v) == "Color3" then
		v = v.R
	end
	assert(type(v) == "number" and U.finite(v), "Expected finite scalar material value")
	return v
end
local function boundedColor(value: any, context: any, default: any): Vector3
	local c = rgb(read(value == nil and default or value, context))
	assert(c.X <= 1 and c.Y <= 1 and c.Z <= 1, "Reflectance must be in [0,1]")
	return c
end
local function draw(random: any): number -- RandomSource
	return type(random) == "function" and random() or random:NextNumber()
end
local function validDirection(v: Vector3)
	assert(U.vector(v) and math.abs(v.Magnitude - 1) < 1e-4, "Expected unit direction")
end
function B.diffuse(color: any?): Material
	return { kind = "diffuse", baseColor = color or Color3.new(0.8, 0.8, 0.8) }
end
function B.ggx(options: Material?): Material
	local m = table.clone(options or {})
	m.kind = "ggx"
	return m
end
function B.metallicRoughness(options: Material?): Material
	local m = table.clone(options or {})
	m.kind = "metallicRoughness"
	return m
end
function B.dielectric(ior: number?, tint: any?): Material
	return { kind = "dielectric", ior = ior or 1.5, baseColor = tint or Color3.new(1, 1, 1) }
end
function B.mix(a: MaterialInput, b: MaterialInput, weight: any?): Material
	assert(type(a) == "table" and type(b) == "table", "Mix requires two materials")
	return { kind = "mix", a = a, b = b, weight = weight == nil and 0.5 or weight }
end
function B.resolve(input: MaterialInput, context: any?): Resolved
	if input._resolved then
		return input :: Resolved
	end
	local material = input :: Material
	local kind = material.kind or "metallicRoughness"
	local m: Resolved = { kind = kind, _resolved = true } :: any -- remaining fields assigned below
	if kind == "mix" then
		m.a, m.b =
			B.resolve(material.a :: MaterialInput, context), B.resolve(material.b :: MaterialInput, context)
		local weight = scalar(material.weight, context, 0.5)
		m.weight = weight
		assert(weight >= 0 and weight <= 1, "Mix weight must be in [0,1]")
	else
		assert(
			kind == "diffuse" or kind == "ggx" or kind == "metallicRoughness" or kind == "dielectric",
			"Unsupported BSDF kind: " .. tostring(kind)
		)
		m.baseColor = boundedColor(material.baseColor or material.albedo, context, Color3.new(0.8, 0.8, 0.8))
		local ior = scalar(material.ior, context, 1.5)
		m.ior = ior
		assert(ior > 0, "IOR must be positive")
		local exteriorIor = scalar(material.exteriorIor, context, 1)
		m.exteriorIor = exteriorIor
		assert(exteriorIor > 0, "Exterior IOR must be positive")
		if kind == "ggx" or kind == "metallicRoughness" then
			local roughness = scalar(material.roughness, context, 0.5)
			assert(roughness >= 0 and roughness <= 1, "Roughness must be in [0,1]")
			m.alpha = math.max(0.001, roughness * roughness)
			local metallic = scalar(material.metallic, context, 0)
			m.metallic = metallic
			assert(metallic >= 0 and metallic <= 1, "Metallic must be in [0,1]")
			m.f0 = material.f0 and boundedColor(material.f0, context, ZERO) or nil
		end
	end
	m.emission = rgb(read(material.emission or ZERO, context))
	m.twoSidedEmission = material.twoSidedEmission == true
	return m
end
-- Incident cosine is positive; etaI and etaT identify the two actual media.
function B.fresnelDielectric(cosine: number, etaI: number, etaT: number): number
	assert(U.finite(cosine) and etaI > 0 and etaT > 0 and U.finite(etaI) and U.finite(etaT))
	cosine = math.clamp(math.abs(cosine), 0, 1)
	if etaI == etaT then
		return 0
	end
	local sin2 = (etaI / etaT) ^ 2 * math.max(0, 1 - cosine * cosine)
	if sin2 >= 1 then
		return 1
	end
	local transmitted = math.sqrt(1 - sin2)
	local parallel = (etaT * cosine - etaI * transmitted) / (etaT * cosine + etaI * transmitted)
	local perpendicular = (etaI * cosine - etaT * transmitted) / (etaI * cosine + etaT * transmitted)
	return (parallel * parallel + perpendicular * perpendicular) * 0.5
end
function B.fresnelSchlick(cosine: number, f0: Color3 | Vector3): Vector3
	local f0: Vector3 = rgb(f0)
	return f0 + (ONE - f0) * (1 - math.clamp(math.abs(cosine), 0, 1)) ^ 5
end
function B.distributionGGX(cosine: number, alpha: number): number
	assert(alpha > 0 and U.finite(alpha), "GGX alpha must be positive")
	if cosine <= 0 then
		return 0
	end
	local c = math.clamp(cosine, 0, 1)
	-- This form avoids tan(theta) and its singularity at the horizon.
	local denominator = 1 - c * c + alpha * alpha * c * c
	return alpha * alpha / (PI * denominator * denominator)
end
local function lambda(cosine: number, alpha: number): number
	if cosine <= 0 then
		return math.huge
	end
	return 0.5 * (math.sqrt(1 + alpha * alpha * math.max(0, 1 - cosine * cosine) / (cosine * cosine)) - 1)
end
function B.maskingGGX(cosine: number, alpha: number): number
	assert(alpha > 0 and U.finite(alpha))
	return 1 / (1 + lambda(cosine, alpha))
end
-- Visible-normal sampling: stretch the view, sample its projected disk, unstretch.
function B.sampleGGX(normal: Vector3, outgoing: Vector3, alpha: number, u: number, v: number): Vector3?
	validDirection(normal)
	validDirection(outgoing)
	assert(alpha > 0 and U.finite(alpha) and u >= 0 and u < 1 and v >= 0 and v < 1)
	if normal:Dot(outgoing) <= 0 then
		return nil
	end
	local x, y = U.frame(normal)
	local view = Vector3.new(alpha * outgoing:Dot(x), alpha * outgoing:Dot(y), outgoing:Dot(normal)).Unit
	local side = Vector3.new(-view.Y, view.X, 0)
	side = side.Magnitude > 1e-8 and side.Unit or Vector3.xAxis
	local up = view:Cross(side)
	local radius, angle = math.sqrt(u), 2 * PI * v
	local diskX, diskY = radius * math.cos(angle), radius * math.sin(angle)
	local blend = (1 + view.Z) * 0.5
	diskY = blend * diskY + (1 - blend) * math.sqrt(math.max(0, 1 - diskX * diskX))
	local sphere = side * diskX
		+ up * diskY
		+ view * math.sqrt(math.max(0, 1 - diskX * diskX - diskY * diskY))
	local localNormal = Vector3.new(alpha * sphere.X, alpha * sphere.Y, math.max(0, sphere.Z)).Unit
	return (x * localNormal.X + y * localNormal.Y + normal * localNormal.Z).Unit
end
local function fresnel(m: Resolved, cosine: number): Vector3
	if m.f0 then
		return B.fresnelSchlick(cosine, m.f0)
	end
	local dielectric = ONE * B.fresnelDielectric(cosine, m.exteriorIor :: number, m.ior :: number)
	if m.kind == "metallicRoughness" then
		return dielectric:Lerp(B.fresnelSchlick(cosine, m.baseColor :: Vector3), m.metallic :: number)
	end
	return dielectric
end
local function specularProbability(m: Resolved): number
	if m.kind == "ggx" then
		return 1
	end
	if m.kind == "diffuse" then
		return 0
	end
	local f = fresnel(m, 1)
	local spec = math.max(f.X, f.Y, f.Z)
	local diffuse = (1 - (m.metallic :: number))
		* math.max((m.baseColor :: Vector3).X, (m.baseColor :: Vector3).Y, (m.baseColor :: Vector3).Z)
	if diffuse == 0 then
		return 1
	end
	return math.clamp(spec / (spec + diffuse), 0.05, 0.95)
end
function B.evaluate(material: MaterialInput, normal: Vector3, outgoing: Vector3, incoming: Vector3): Vector3
	local m = B.resolve(material)
	local co, ci = normal:Dot(outgoing), normal:Dot(incoming)
	if co <= 0 or ci <= 0 then
		return ZERO
	end
	if m.kind == "mix" then
		return B.evaluate(m.a :: Resolved, normal, outgoing, incoming) * (1 - (m.weight :: number))
			+ B.evaluate(m.b :: Resolved, normal, outgoing, incoming) * (m.weight :: number)
	end
	if m.kind == "dielectric" then
		return ZERO
	end -- delta distribution
	if m.kind == "diffuse" then
		return (m.baseColor :: Vector3) / PI
	end
	local half = outgoing + incoming
	if half.Magnitude < 1e-12 then
		return ZERO
	end
	half = half.Unit
	local f = fresnel(m, math.max(0, outgoing:Dot(half)))
	local alpha = m.alpha :: number
	local geometry = 1 / (1 + lambda(co, alpha) + lambda(ci, alpha))
	local specular = f * (B.distributionGGX(normal:Dot(half), alpha) * geometry / (4 * co * ci))
	if m.kind == "ggx" then
		return specular
	end
	-- A reciprocal, attenuated diffuse substrate, not a full layered transport solver.
	local escape = multiply(ONE - fresnel(m, co), ONE - fresnel(m, ci))
	return specular + multiply(m.baseColor :: Vector3, escape) * ((1 - (m.metallic :: number)) / PI)
end
function B.pdf(material: MaterialInput, normal: Vector3, outgoing: Vector3, incoming: Vector3): number
	local m = B.resolve(material)
	local co, ci = normal:Dot(outgoing), normal:Dot(incoming)
	if co <= 0 or ci <= 0 then
		return 0
	end
	if m.kind == "mix" then
		return (1 - (m.weight :: number)) * B.pdf(m.a :: Resolved, normal, outgoing, incoming)
			+ (m.weight :: number) * B.pdf(m.b :: Resolved, normal, outgoing, incoming)
	end
	if m.kind == "dielectric" then
		return 0
	end
	local probability = specularProbability(m)
	local specular = 0
	if probability > 0 then
		local half = outgoing + incoming
		if half.Magnitude > 1e-12 then
			specular = B.distributionGGX(normal:Dot(half.Unit), m.alpha :: number)
				* B.maskingGGX(co, m.alpha :: number)
				/ (4 * co)
		end
	end
	return probability * specular + (1 - probability) * ci / PI
end
function B.sample(
	material: MaterialInput,
	normal: Vector3,
	outgoing: Vector3,
	random: RandomSource?,
	entering: boolean?
): Sample?
	local m = B.resolve(material)
	local random: RandomSource = random or Random.new()
	validDirection(normal)
	validDirection(outgoing)
	local co = normal:Dot(outgoing)
	if co <= 0 then
		return nil
	end
	if m.kind == "mix" then
		local chooseB = draw(random) < (m.weight :: number)
		local probability = chooseB and (m.weight :: number) or (1 - (m.weight :: number))
		local sample = B.sample((chooseB and m.b or m.a) :: Resolved, normal, outgoing, random, entering)
		if not sample then
			return nil
		end
		if sample.delta then
			sample.pdf *= probability
			return sample
		end
		local p = B.pdf(m, normal, outgoing, sample.direction)
		sample.pdf = p
		sample.weight = B.evaluate(m, normal, outgoing, sample.direction)
			* (math.max(0, normal:Dot(sample.direction)) / p)
		return sample
	end
	if m.kind == "dielectric" then
		local etaI, etaT = m.exteriorIor :: number, m.ior :: number
		if entering == false then
			etaI, etaT = etaT, etaI
		end
		local f = B.fresnelDielectric(co, etaI, etaT)
		if draw(random) < f then
			return {
				direction = (normal * (2 * co) - outgoing).Unit,
				pdf = f,
				weight = m.baseColor :: Vector3,
				delta = true,
				transmission = false,
			}
		end
		local eta = etaI / etaT
		local ct = math.sqrt(math.max(0, 1 - eta * eta * (1 - co * co)))
		return {
			direction = (-outgoing * eta + normal * (eta * co - ct)).Unit,
			pdf = 1 - f,
			weight = (m.baseColor :: Vector3) * (eta * eta),
			delta = true,
			transmission = true,
		}
	end
	local direction: Vector3
	if draw(random) < specularProbability(m) then
		local h = B.sampleGGX(normal, outgoing, m.alpha :: number, draw(random), draw(random)) :: Vector3
		direction = h * (2 * outgoing:Dot(h)) - outgoing
	else
		local r, phi = math.sqrt(draw(random)), 2 * PI * draw(random)
		local x, y = U.frame(normal)
		direction = x * (r * math.cos(phi))
			+ y * (r * math.sin(phi))
			+ normal * math.sqrt(math.max(0, 1 - r * r))
	end
	direction = direction.Unit
	-- Invalid reflected VNDF samples are null events, never renormalized or retried.
	if normal:Dot(direction) <= 0 then
		return nil
	end
	local pdf = B.pdf(m, normal, outgoing, direction)
	if pdf <= 0 then
		return nil
	end
	return {
		direction = direction,
		pdf = pdf,
		weight = B.evaluate(m, normal, outgoing, direction) * (normal:Dot(direction) / pdf),
		delta = false,
		transmission = false,
	}
end
function B.emission(material: MaterialInput, context: any?, frontFacing: boolean?): Vector3
	local m = B.resolve(material, context)
	local value = frontFacing == false and not m.twoSidedEmission and ZERO or m.emission
	if m.kind == "mix" then
		value += B.emission(m.a :: Resolved, nil, frontFacing) * (1 - (m.weight :: number)) + B.emission(
			m.b :: Resolved,
			nil,
			frontFacing
		) * (m.weight :: number)
	end
	return value
end
return B
