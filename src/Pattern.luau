--!strict
-- Procedural surface patterns for texture bakes: integer hashing, fractal noise, sheet-panel grids
-- and gravity-aligned streaks. Every function is pure and deterministic, so a bake shader
-- (Bake.rasterize) can combine them per sample in world space.
local P = {}
export type FbmOptions = {
	frequency: number?,
	octaves: number?,
	lacunarity: number?,
	gain: number?,
	seed: number?,
}
export type PanelOptions = {
	width: number,
	height: number,
	projection: ("cylindrical" | "planar")?,
	frame: CFrame?,
	radius: number?,
	seamAngle: number?,
	jitter: number?,
	rowOffset: number?,
	seed: number?,
}
export type PanelSample = {
	column: number,
	row: number,
	id: number,
	seam: number,
	u: number,
	v: number,
}
export type StreakOptions = {
	up: Vector3?,
	spacing: number?,
	length: number?,
	width: number?,
	coverage: number?,
	seed: number?,
}
local TWO_PI = 2 * math.pi
local function mul32(a: number, b: number): number
	local low, high = bit32.band(a, 0xFFFF), bit32.rshift(a, 16)
	return bit32.band(low * b + bit32.lshift(bit32.band(high * b, 0xFFFF), 16), 0xFFFFFFFF)
end
local function mix(h: number): number
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x7FEB352D)
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = mul32(h, 0x846CA68B)
	return bit32.bxor(h, bit32.rshift(h, 16))
end
-- Uniform value in [0, 1) for integer lattice coordinates; non-integers are floored.
function P.hash(i: number, j: number?, k: number?, seed: number?): number
	local h = mix(bit32.band(math.floor(seed or 0), 0xFFFFFFFF))
	h = mix(bit32.bxor(h, bit32.band(math.floor(i), 0xFFFFFFFF)))
	h = mix(bit32.bxor(h, bit32.band(math.floor(j or 0), 0xFFFFFFFF)))
	h = mix(bit32.bxor(h, bit32.band(math.floor(k or 0), 0xFFFFFFFF)))
	return h / 4294967296
end
function P.smoothstep(edge0: number, edge1: number, x: number): number
	if edge0 == edge1 then
		return if x < edge0 then 0 else 1
	end
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end
local function seedOffset(seed: number): Vector3
	if seed == 0 then
		return Vector3.zero
	end
	return Vector3.new(P.hash(seed, 1), P.hash(seed, 2), P.hash(seed, 3)) * 1000
end
-- Fractal sum of math.noise octaves, normalized so the result stays within [-1, 1].
function P.fbm(p: Vector3, options: FbmOptions?): number
	local o: FbmOptions = options or {}
	local frequency, octaves = o.frequency or 1, o.octaves or 4
	local lacunarity, gain = o.lacunarity or 2, o.gain or 0.5
	assert(frequency > 0 and octaves >= 1 and lacunarity > 0 and gain > 0, "Invalid fbm options")
	local q = p * frequency + seedOffset(o.seed or 0)
	local sum, amplitude, total = 0, 1, 0
	for _ = 1, math.floor(octaves) do
		sum += amplitude * math.noise(q.X, q.Y, q.Z)
		total += amplitude
		amplitude *= gain
		q *= lacunarity
	end
	return math.clamp(sum / total, -1, 1)
end
-- Sheet panels laid on a cylinder about frame's Y axis (arc length at a reference radius) or on
-- frame's XY plane. Rows run along the axis; each row may shift sideways by a random fraction of
-- the width (jitter). `seam` is the physical distance in studs from p to the nearest panel edge,
-- `id` a per-panel uniform value, (u, v) the position inside the panel in [0, 1).
function P.panels(p: Vector3, options: PanelOptions): PanelSample
	local width, height = options.width, options.height
	assert(width > 0 and height > 0, "Panel width and height must be positive")
	local frame = options.frame or CFrame.identity
	local seed, jitter = options.seed or 0, options.jitter or 0
	local q = frame:PointToObjectSpace(p)
	local y = (q.Y - (options.rowOffset or 0)) / height
	local row = math.floor(y)
	local v = y - row
	local shift = jitter * (P.hash(row, 0, 0, seed) - 0.5)
	local x: number, columns: number?, scale: number
	if (options.projection or "cylindrical") == "cylindrical" then
		local radius = assert(options.radius, "Cylindrical panels require a reference radius")
		assert(radius > 0, "Panel radius must be positive")
		local count = math.max(1, math.floor(TWO_PI * radius / width + 0.5))
		local angle = (math.atan2(q.Z, q.X) - (options.seamAngle or 0)) % TWO_PI
		x = angle / TWO_PI * count
		columns = count
		-- physical size of one column at this point's own radius
		scale = TWO_PI * math.max(Vector2.new(q.X, q.Z).Magnitude, 1e-9) / count
	else
		x = q.X / width
		scale = width
	end
	x += shift
	local column = math.floor(x)
	local u = x - column
	if columns then
		column %= columns
	end
	local seam = math.min(math.min(u, 1 - u) * scale, math.min(v, 1 - v) * height)
	return {
		column = column,
		row = row,
		id = P.hash(column, row, 7, seed),
		seam = seam,
		u = u,
		v = v,
	}
end
-- Thin runs elongated along `up` (rain or drip marks), in [0, 1]. The pattern is constant along
-- up within one streak length, so neighbouring surfaces at different heights line up. Surfaces
-- facing up or straight down receive none; vertical surfaces receive the most.
function P.streaks(p: Vector3, normal: Vector3, options: StreakOptions?): number
	local o: StreakOptions = options or {}
	local up = (o.up or Vector3.yAxis).Unit
	local spacing, length = o.spacing or 0.5, o.length or 8
	local width, coverage = o.width or 0.25, o.coverage or 0.5
	assert(spacing > 0 and length > 0 and width > 0 and width <= 1, "Invalid streak options")
	local facing = normal.Magnitude > 0 and normal.Unit:Dot(up) or 0
	local exposure = P.smoothstep(0.75, 0.15, facing) * P.smoothstep(-0.9, -0.4, facing)
	if exposure <= 0 then
		return 0
	end
	local h = up:Dot(p)
	local flat = p - up * h + seedOffset(o.seed or 0)
	local line = math.noise(flat.X / spacing, h / length, flat.Z / spacing)
	local ridge = P.smoothstep(1 - width, 1, 1 - math.abs(line) * 2)
	local envelope = math.noise(flat.X / (spacing * 7), h / (length * 1.7), flat.Z / (spacing * 7) + 17.3)
	-- coverage is the approximate fraction of the surface where streaks appear
	local threshold = (0.5 - math.clamp(coverage, 0, 1)) * 0.6
	local present = P.smoothstep(threshold - 0.08, threshold + 0.08, envelope)
	return math.clamp(ridge * present * exposure, 0, 1)
end
return table.freeze(P)
