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
	projection: ("world" | "cylindrical" | "planar")?,
	frame: CFrame?,
	radius: number?,
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
-- Soft window: 1 well inside [low, high], 0 outside, with smoothstep shoulders of half-width
-- `edge` centred on each bound. For masks such as "this height band, fading over 0.2".
function P.band(x: number, low: number, high: number, edge: number?): number
	local e = edge or 0
	return P.smoothstep(low - e, low + e, x) * (1 - P.smoothstep(high - e, high + e, x))
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
-- Rain or drip streaks in [0, 1]. Each active source drops a run with a random top, a length
-- around `length` and a random strength, fading toward its bottom; `coverage` is the fraction of
-- sources active per height period. Where sources sit depends on `projection`:
--   "world" (default): a jittered grid of `spacing` studs in the plane perpendicular to `up`. Each
--     run is a vertical curtain of radius `width`, so it marks surfaces it passes through. Runs are
--     long on vertical surfaces and short where a surface leans away from the curtain.
--   "cylindrical": sources every `spacing` studs of arc around frame's Y axis at `radius`. Runs
--     ignore depth, so they follow a leaning or folded surface like water running down it. Width
--     is measured at the point's own radius.
--   "planar": sources every `spacing` studs along frame's X axis; depth along Z is ignored.
-- Cylindrical and planar runs follow frame's Y axis (`up` is ignored). Surfaces facing up or
-- straight down receive none; vertical surfaces receive the most.
function P.streaks(p: Vector3, normal: Vector3, options: StreakOptions?): number
	local o: StreakOptions = options or {}
	local projection = o.projection or "world"
	local spacing, length, width = o.spacing or 0.3, o.length or 6, o.width or 0.05
	local coverage, seed = math.clamp(o.coverage or 0.5, 0, 1), o.seed or 0
	assert(spacing > 0 and length > 0 and width > 0, "Invalid streak options")
	local frame = o.frame or CFrame.identity
	local up: Vector3
	if projection == "world" then
		up = (o.up or Vector3.yAxis).Unit
	else
		assert(projection == "cylindrical" or projection == "planar", "Unknown streak projection")
		up = frame.UpVector
	end
	local facing = normal.Magnitude > 0 and normal.Unit:Dot(up) or 0
	local exposure = P.smoothstep(0.75, 0.15, facing) * P.smoothstep(-0.9, -0.4, facing)
	if exposure <= 0 or coverage <= 0 then
		return 0
	end
	-- (a, b): source-grid coordinates in units of spacing; scale converts a distance in a to studs
	local a: number, b: number?, h: number, scale: number, wrap: number?
	if projection == "world" then
		local e1 = (if math.abs(up.X) < 0.9 then Vector3.xAxis else Vector3.zAxis):Cross(up).Unit
		local e2 = up:Cross(e1)
		a, b, h, scale = p:Dot(e1) / spacing, p:Dot(e2) / spacing, p:Dot(up), spacing
	else
		local q = frame:PointToObjectSpace(p)
		h = q.Y
		if projection == "planar" then
			a, scale = q.X / spacing, spacing
		else
			local radius = assert(o.radius, "Cylindrical streaks require a reference radius")
			assert(radius > 0, "Streak radius must be positive")
			local count = math.max(1, math.floor(TWO_PI * radius / spacing + 0.5))
			a = (math.atan2(q.Z, q.X) % TWO_PI) / TWO_PI * count
			scale = TWO_PI * math.max(Vector2.new(q.X, q.Z).Magnitude, 1e-9) / count
			wrap = count
		end
	end
	local period = length * 1.5
	local ci, cj = math.floor(a), math.floor(h / period)
	local ck = if b then math.floor(b) else 0
	local best = 0
	for di = -1, 1 do
		for dk = (if b then -1 else 0), (if b then 1 else 0) do
			local i, k = ci + di, ck + dk
			if wrap then
				i %= wrap
			end
			local da = a - (ci + di) - P.hash(i, k, 1, seed)
			local d = if b
				then Vector2.new(da, b - k - P.hash(i, k, 2, seed)).Magnitude * scale
				else math.abs(da) * scale
			if d < width then
				local profile = 1 - P.smoothstep(0, width, d)
				-- a run can start in this height period or the one above and reach into this one
				for dj = 0, 1 do
					local j = cj - dj
					if P.hash(i, k, j, seed + 101) < coverage then
						local top = (j + P.hash(i, k, j, seed + 102)) * period
						local run = length * (0.4 + 1.2 * P.hash(i, k, j, seed + 103))
						local t = (top - h) / run
						if t >= 0 and t <= 1 then
							local strength = 0.5 + 0.5 * P.hash(i, k, j, seed + 104)
							local fade = (1 - t) ^ 0.6 * P.smoothstep(0, 0.04, t)
							best = math.max(best, profile * strength * fade)
						end
					end
				end
			end
		end
	end
	return math.clamp(best * exposure, 0, 1)
end
return table.freeze(P)
