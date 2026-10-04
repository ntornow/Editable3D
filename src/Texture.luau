--!strict
-- Linear floating-point RGBA images. UV origin is upper-left; byte conversion is explicit.
local U = require(script.Parent.Util)
local Budget = require(script.Parent.OperationBudget)
local Types = require(script.Parent.Types)
type Texture = Types.Texture
type Limits = Types.Limits
local function finish<T>(value: T, budget: Budget.Budget, owned: boolean): T
	if owned then
		budget:finish()
	end
	return value
end
local Texture = {}
Texture.__index = Texture
-- UV 0/1 are image boundaries; texel centers are (index + 0.5) / size.
local function sampleAxis(value: number, size: number, wrap: boolean?): (number, number, number)
	assert(U.finite(value), "Texture coordinates must be finite")
	value = if wrap then value % 1 else math.clamp(value, 0, 1)
	local coordinate = value * size - 0.5
	local lower = math.floor(coordinate)
	local fraction = coordinate - lower
	if wrap then
		return lower % size, (lower + 1) % size, fraction
	end
	return math.clamp(lower, 0, size - 1), math.clamp(lower + 1, 0, size - 1), fraction
end
-- Stored RGB is straight alpha. Preserve hidden RGB when nothing is applied.
local function sourceOver(
	destination: Color3,
	destinationAlpha: number,
	source: Color3,
	coverage: number
): (Color3, number)
	if coverage == 0 then
		return destination, destinationAlpha
	end
	local retained = destinationAlpha * (1 - coverage)
	local alpha = coverage + retained
	if alpha == 0 then
		return Color3.new(), 0
	end
	return Color3.new(
		(source.R * coverage + destination.R * retained) / alpha,
		(source.G * coverage + destination.G * retained) / alpha,
		(source.B * coverage + destination.B * retained) / alpha
	),
		alpha
end
function Texture.new(width: number, height: number, color: Color3?, alpha: number?, options: Limits?): Texture
	local budget, owned = Budget.acquire(options, "Texture.new")
	budget:image(width, height)
	U.integer(width, 1)
	U.integer(height, 1)
	local self: Texture = setmetatable(
		{ width = width, height = height, pixels = buffer.create(width * height * 16) },
		Texture
	) :: any
	if color or alpha then
		for y = 0, height - 1 do
			for x = 0, width - 1 do
				budget:step()
				self:set(x, y, color or Color3.new(), if alpha == nil then 1 else alpha)
			end
		end
	end
	return finish(self, budget, owned)
end
function Texture.set(self: Texture, x: number, y: number, color: Color3, alpha: number?)
	assert(
		x % 1 == 0 and y % 1 == 0 and x >= 0 and y >= 0 and x < self.width and y < self.height,
		"Pixel out of bounds"
	)
	local i = (y * self.width + x) * 16
	buffer.writef32(self.pixels, i, color.R)
	buffer.writef32(self.pixels, i + 4, color.G)
	buffer.writef32(self.pixels, i + 8, color.B)
	buffer.writef32(self.pixels, i + 12, if alpha == nil then 1 else alpha)
end
function Texture.get(self: Texture, x: number, y: number): (Color3, number)
	assert(
		x % 1 == 0 and y % 1 == 0 and x >= 0 and y >= 0 and x < self.width and y < self.height,
		"Pixel out of bounds"
	)
	local i = (y * self.width + x) * 16
	return Color3.new(
		buffer.readf32(self.pixels, i),
		buffer.readf32(self.pixels, i + 4),
		buffer.readf32(self.pixels, i + 8)
	),
		buffer.readf32(self.pixels, i + 12)
end
function Texture.clone(self: Texture, options: Limits?): Texture
	local budget, owned = Budget.acquire(options, "Texture.clone")
	local t = Texture.new(self.width, self.height, nil, nil, Budget.options(budget))
	budget:step(self.width * self.height)
	buffer.copy(t.pixels, 0, self.pixels)
	return finish(t, budget, owned)
end
function Texture.sample(self: Texture, uv: Vector2, wrap: boolean?, wrapV: boolean?): (Color3, number)
	if wrapV == nil then
		wrapV = wrap
	end
	local x0, x1, fx = sampleAxis(uv.X, self.width, wrap)
	local y0, y1, fy = sampleAxis(uv.Y, self.height, wrapV)
	local a, aa = self:get(x0, y0)
	local b, ab = self:get(x1, y0)
	local c, ac = self:get(x0, y1)
	local d, ad = self:get(x1, y1)
	return a:Lerp(b, fx):Lerp(c:Lerp(d, fx), fy),
		(aa + (ab - aa) * fx) * (1 - fy) + (ac + (ad - ac) * fx) * fy
end
function Texture.generate(
	width: number,
	height: number,
	fn: (Vector2, number, number) -> (Color3, number?),
	options: Limits?
): Texture
	local budget, owned = Budget.acquire(options, "Texture.generate")
	local t = Texture.new(width, height, nil, nil, Budget.options(budget))
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			budget:step()
			local c, a = fn(Vector2.new((x + 0.5) / width, (y + 0.5) / height), x, y)
			t:set(x, y, c, a)
		end
	end
	return finish(t, budget, owned)
end
function Texture.map(
	self: Texture,
	fn: (Color3, number, Vector2, number, number) -> (Color3, number?),
	options: Limits?
): Texture
	return Texture.generate(self.width, self.height, function(uv, x, y)
		local c, a = self:get(x, y)
		return fn(c, a, uv, x, y)
	end, options)
end
function Texture.resize(self: Texture, width: number, height: number, options: Limits?): Texture
	if width == self.width and height == self.height then
		return self:clone(options)
	end
	return Texture.generate(width, height, function(uv)
		return self:sample(uv)
	end, options)
end
function Texture.blend(self: Texture, other: Texture, opacity: number?, options: Limits?): Texture
	assert(self.width == other.width and self.height == other.height)
	local opacity = math.clamp(opacity or 1, 0, 1)
	return Texture.generate(self.width, self.height, function(_, x, y)
		local a, aa = self:get(x, y)
		local b, ab = other:get(x, y)
		ab *= opacity
		return sourceOver(a, aa, b, ab)
	end, options)
end
function Texture.blur(self: Texture, radius: number, sigma: number?, options: Limits?): Texture
	local budget, owned = Budget.acquire(options, "Texture.blur")
	U.integer(radius, 0)
	if radius == 0 then
		return finish(self:clone(Budget.options(budget)), budget, owned)
	end
	local sigma = sigma or radius / 2
	assert(sigma > 0)
	budget:reserve((2 * radius + 1) * 8)
	local weights: { [number]: number } = {}
	local sum = 0
	for i = -radius, radius do
		budget:step()
		local w = math.exp(-i * i / (2 * sigma * sigma))
		weights[i] = w
		sum += w
	end
	local source: Texture = self
	for _, axis in { "x", "y" } do
		local input = source
		source = Texture.generate(self.width, self.height, function(_, x, y)
			local r, g, b, a = 0, 0, 0, 0
			for i = -radius, radius do
				budget:step()
				local c, alpha = input:get(
					math.clamp(x + (axis == "x" and i or 0), 0, self.width - 1),
					math.clamp(y + (axis == "y" and i or 0), 0, self.height - 1)
				)
				local w = weights[i] / sum
				r += c.R * w
				g += c.G * w
				b += c.B * w
				a += alpha * w
			end
			return Color3.new(r, g, b), a
		end, Budget.options(budget))
	end
	return finish(source, budget, owned)
end
function Texture.normalFromHeight(self: Texture, strength: number?, options: Limits?): Texture
	local strength = strength or 1
	return Texture.generate(self.width, self.height, function(_, x, y)
		local left = self:get(math.max(x - 1, 0), y).R
		local right = self:get(math.min(x + 1, self.width - 1), y).R
		local up = self:get(x, math.max(y - 1, 0)).R
		local down = self:get(x, math.min(y + 1, self.height - 1)).R
		local n = Vector3.new(-(right - left) * strength, (down - up) * strength, 1).Unit
		return Color3.new(n.X * 0.5 + 0.5, n.Y * 0.5 + 0.5, n.Z * 0.5 + 0.5), 1
	end, options)
end
function Texture.paint(
	self: Texture,
	center: Vector2,
	radius: number,
	color: Color3,
	opacity: number?,
	options: Limits?
): Texture
	local budget, owned = Budget.acquire(options, "Texture.paint")
	assert(radius > 0)
	local out = self:clone(Budget.options(budget))
	local opacity = math.clamp(opacity or 1, 0, 1)
	for y = math.max(0, math.floor(center.Y - radius)), math.min(self.height - 1, math.ceil(center.Y + radius)) do
		for x = math.max(0, math.floor(center.X - radius)), math.min(self.width - 1, math.ceil(center.X + radius)) do
			budget:step()
			local w = U.smooth(1 - (Vector2.new(x, y) - center).Magnitude / radius) * opacity
			local c, a = self:get(x, y)
			out:set(x, y, sourceOver(c, a, color, w))
		end
	end
	return finish(out, budget, owned)
end
local function encode(x: number): number
	return x <= 0.0031308 and 12.92 * x or 1.055 * x ^ (1 / 2.4) - 0.055
end
local function decode(x: number): number
	return x <= 0.04045 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4
end
function Texture.toRGBA8(self: Texture, srgb: boolean?, options: Limits?): buffer
	local budget, owned = Budget.acquire(options, "Texture.toRGBA8")
	budget:image(self.width, self.height, 4)
	local bytes = buffer.create(self.width * self.height * 4)
	for y = 0, self.height - 1 do
		for x = 0, self.width - 1 do
			budget:step()
			local c, a = self:get(x, y)
			local i = (y * self.width + x) * 4
			local values = { c.R, c.G, c.B, a }
			for k, v in values do
				if srgb and k < 4 then
					v = encode(math.max(v, 0))
				end
				buffer.writeu8(bytes, i + k - 1, math.floor(math.clamp(v, 0, 1) * 255 + 0.5))
			end
		end
	end
	return finish(bytes, budget, owned)
end
function Texture.fromRGBA8(
	width: number,
	height: number,
	bytes: buffer,
	srgb: boolean?,
	options: Limits?
): Texture
	assert(buffer.len(bytes) == width * height * 4)
	return Texture.generate(width, height, function(_, x, y)
		local i = (y * width + x) * 4
		local r, g, b =
			buffer.readu8(bytes, i) / 255,
			buffer.readu8(bytes, i + 1) / 255,
			buffer.readu8(bytes, i + 2) / 255
		if srgb then
			r, g, b = decode(r), decode(g), decode(b)
		end
		return Color3.new(r, g, b), buffer.readu8(bytes, i + 3) / 255
	end, options)
end
function Texture.noise(
	width: number,
	height: number,
	frequency: number?,
	octaves: number?,
	seed: number?,
	options: Limits?
): Texture
	local budget, owned = Budget.acquire(options, "Texture.noise")
	U.integer(octaves or 4, 1)
	local out = Texture.generate(width, height, function(uv)
		local f, a, sum, total = frequency or 8, 1, 0, 0
		for _ = 1, octaves or 4 do
			budget:step()
			sum += math.noise(uv.X * f, uv.Y * f, seed or 0) * a
			total += a
			f *= 2
			a *= 0.5
		end
		local v = math.clamp(0.5 + sum / total, 0, 1)
		return Color3.new(v, v, v), 1
	end, Budget.options(budget))
	return finish(out, budget, owned)
end
function Texture.tiles(self: Texture, size: number, options: Limits?): { Types.Tile }
	local budget, owned = Budget.acquire(options, "Texture.tiles")
	U.integer(size, 1)
	local tiles: { Types.Tile } = {}
	for y = 0, self.height - 1, size do
		for x = 0, self.width - 1, size do
			local width, height = math.min(size, self.width - x), math.min(size, self.height - y)
			local tile = Texture.generate(width, height, function(_, px, py)
				return self:get(x + px, y + py)
			end, Budget.options(budget))
			table.insert(tiles, {
				texture = tile,
				x = x,
				y = y,
				width = width,
				height = height,
				uvOffset = Vector2.new(x / self.width, y / self.height),
				uvScale = Vector2.new(width / self.width, height / self.height),
			})
		end
	end
	return finish(tiles, budget, owned)
end
-- Never called: lets the type checker verify the implementation against the public contracts.
local function _contract(t: Texture): (Types.TextureLibrary, Types.Texture)
	return Texture,
		{
			width = t.width,
			height = t.height,
			pixels = t.pixels,
			set = Texture.set,
			get = Texture.get,
			clone = Texture.clone,
			sample = Texture.sample,
			map = Texture.map,
			resize = Texture.resize,
			blend = Texture.blend,
			blur = Texture.blur,
			normalFromHeight = Texture.normalFromHeight,
			paint = Texture.paint,
			toRGBA8 = Texture.toRGBA8,
			tiles = Texture.tiles,
		}
end
return Texture
