--!strict
local Texture = require(script.Parent.Texture)
local Spatial = require(script.Parent.Spatial)
local U = require(script.Parent.Util)
local Budget = require(script.Parent.OperationBudget)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
type Texture = Types.Texture
type BakeOptions = Types.BakeOptions
type BakeReport = Types.BakeReport
local B = {}
local function preflight(mesh: Mesh, budget: Budget.Budget, options: BakeOptions)
	local count = 0
	local limit = options.maxTriangles or 250000
	U.integer(limit, 1)
	assert(limit < math.huge, "Invalid triangle limit")
	for _, face in mesh.faces do
		count += math.max(0, #face.vertices - 2)
		assert(count <= limit, "Bake triangle limit exceeded")
		budget:step(#face.vertices)
	end
	budget:reserve(count * 256)
	budget:check()
end
-- Triangles for baking. Faces that cannot be triangulated (zero area, degenerate or
-- self-intersecting polygons, common in meshes read back from Roblox) are skipped and counted
-- instead of aborting the bake; they cover no texels.
local function bakeTriangles(mesh: Mesh): ({ Types.Triangle }, number)
	local result: { Types.Triangle } = {}
	local skipped = 0
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		local ok, triangles = pcall(mesh.faceTriangles, mesh, fid)
		if ok then
			for _, c in triangles :: { { number } } do
				table.insert(
					result,
					{ f.vertices[c[1]], f.vertices[c[2]], f.vertices[c[3]], face = fid, corners = c }
				)
			end
		else
			skipped += 1
		end
	end
	return result, skipped
end
-- Spatial is not yet strict; its index is used through an untyped handle.
local function spatial(mesh: Mesh, budget: Budget.Budget, options: BakeOptions): any
	preflight(mesh, budget, options)
	local result = Spatial.new(mesh)
	budget:check()
	return result
end
local function complete(budget: Budget.Budget, owned: boolean): Types.Progress
	return owned and budget:finish() or budget:report()
end
function B.rasterize(
	mesh: Mesh,
	width: number,
	height: number,
	shader: (Types.BakeContext) -> (Color3, number?),
	options: BakeOptions?
): (Texture, BakeReport)
	local options: BakeOptions = options or {}
	local budget, owned = Budget.acquire(options, "Bake.rasterize")
	preflight(mesh, budget, options)
	local image = Texture.new(width, height, nil, nil, Budget.options(budget))
	budget:image(width, height, 1)
	local coverage = buffer.create(width * height)
	local written = 0
	local triangles, skipped = bakeTriangles(mesh)
	for _, t in triangles do
		budget:step()
		local f = mesh.faces[t.face]
		local ca, cb, cc = f.corners[t.corners[1]], f.corners[t.corners[2]], f.corners[t.corners[3]]
		local a, b, c = ca.uv, cb.uv, cc.uv
		assert(a and b and c, "Baking requires corner UVs")
		local a, b, c = a :: Vector2, b :: Vector2, c :: Vector2
		local e1, e2 = b - a, c - a
		local den = e1.X * e2.Y - e1.Y * e2.X
		if math.abs(den) > 1e-12 then
			local pa, pb, pc = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
			local geometric = U.unit((pb - pa):Cross(pc - pa))
			local tangent = ((pb - pa) * e2.Y - (pc - pa) * e1.Y) / den
			local bitangent = ((pc - pa) * e1.X - (pb - pa) * e2.X) / den
			local lo = a:Min(b):Min(c) * Vector2.new(width, height) - Vector2.one * 0.5
			local hi = a:Max(b):Max(c) * Vector2.new(width, height) - Vector2.one * 0.5
			for y = math.max(0, math.ceil(lo.Y)), math.min(height - 1, math.floor(hi.Y)) do
				for x = math.max(0, math.ceil(lo.X)), math.min(width - 1, math.floor(hi.X)) do
					budget:step()
					local uv = Vector2.new((x + 0.5) / width, (y + 0.5) / height)
					local d = uv - a
					local v = (d.X * e2.Y - d.Y * e2.X) / den
					local w = (e1.X * d.Y - e1.Y * d.X) / den
					local u = 1 - v - w
					if math.min(u, v, w) >= -1e-8 then
						local n = U.unit(
							(ca.normal or geometric) * u
								+ (cb.normal or geometric) * v
								+ (cc.normal or geometric) * w,
							geometric
						)
						local tx = U.unit(tangent - n * n:Dot(tangent))
						local by = n:Cross(tx)
						if by:Dot(bitangent) < 0 then
							by = -by
						end
						local color, alpha = shader({
							position = pa * u + pb * v + pc * w,
							normal = n,
							tangent = tx,
							bitangent = by,
							uv = uv,
							face = t.face,
							barycentric = Vector3.new(u, v, w),
						})
						image:set(x, y, color, alpha)
						local index = y * width + x
						if buffer.readu8(coverage, index) == 0 then
							written += 1
							buffer.writeu8(coverage, index, 1)
						end
					end
				end
			end
		end
	end
	if options.padding then
		image = B.dilate(image, coverage, options.padding, Budget.options(budget))
	end
	return image,
		{
			coveredPixels = written,
			totalPixels = width * height,
			coverage = coverage,
			skippedFaces = skipped,
			operation = complete(budget, owned),
		}
end
-- Multiplies RGBA8 pixels (width x height, row-major, as EditableImage:ReadPixelsBuffer returns them) by a factor
-- texture of the same size: where the factor texture has coverage (alpha > 0) and its RGB differs from 1 by more than
-- `tolerance` (default 0.004), each channel becomes round(byte x factor), clamped; every other byte is copied
-- unchanged. Returns the new buffer and the number of pixels changed. With a factor rasterized over a mesh read back
-- from its published asset (Bake.rasterize with padding), this re-shades part of an existing texture without
-- re-rasterizing its colour, which leaves seams along the read-back triangles' edges.
function B.modulateBytes(
	pixels: buffer,
	width: number,
	height: number,
	factor: Texture,
	tolerance: number?
): (buffer, number)
	U.integer(width, 1)
	U.integer(height, 1)
	assert(buffer.len(pixels) == width * height * 4, "modulateBytes needs width x height RGBA8 pixels")
	assert(factor.width == width and factor.height == height, "modulateBytes factor size mismatch")
	local tol = tolerance or 0.004
	assert(tol >= 0, "modulateBytes tolerance must be non-negative")
	local out = buffer.create(width * height * 4)
	buffer.copy(out, 0, pixels)
	local fp = factor.pixels
	local changed = 0
	for i = 0, width * height - 1 do
		local f = i * 16
		if buffer.readf32(fp, f + 12) > 0 then
			local fr, fg, fb = buffer.readf32(fp, f), buffer.readf32(fp, f + 4), buffer.readf32(fp, f + 8)
			if math.max(math.abs(fr - 1), math.abs(fg - 1), math.abs(fb - 1)) > tol then
				local k = i * 4
				buffer.writeu8(out, k, math.clamp(math.floor(buffer.readu8(pixels, k) * fr + 0.5), 0, 255))
				buffer.writeu8(
					out,
					k + 1,
					math.clamp(math.floor(buffer.readu8(pixels, k + 1) * fg + 0.5), 0, 255)
				)
				buffer.writeu8(
					out,
					k + 2,
					math.clamp(math.floor(buffer.readu8(pixels, k + 2) * fb + 0.5), 0, 255)
				)
				changed += 1
			end
		end
	end
	return out, changed
end
function B.dilate(image: Texture, coverage: buffer, iterations: number, options: Types.Limits?): Texture
	local budget, owned = Budget.acquire(options, "Bake.dilate")
	assert(buffer.len(coverage) == image.width * image.height, "Coverage size mismatch")
	U.integer(iterations, 0)
	local out = image:clone(Budget.options(budget))
	budget:image(image.width, image.height, 1)
	local mask = buffer.create(buffer.len(coverage))
	buffer.copy(mask, 0, coverage)
	for _ = 1, iterations do
		local src = out:clone(Budget.options(budget))
		budget:image(image.width, image.height, 1)
		local old = buffer.create(buffer.len(mask))
		buffer.copy(old, 0, mask)
		for y = 0, image.height - 1 do
			for x = 0, image.width - 1 do
				budget:step()
				local id = y * image.width + x
				if buffer.readu8(old, id) == 0 then
					for _, d in { Vector2.xAxis, -Vector2.xAxis, Vector2.yAxis, -Vector2.yAxis } do
						local a, b = x + d.X, y + d.Y
						if
							a >= 0
							and a < image.width
							and b >= 0
							and b < image.height
							and buffer.readu8(old, b * image.width + a) > 0
						then
							local c, alpha = src:get(a, b)
							out:set(x, y, c, alpha)
							buffer.writeu8(mask, id, 1)
							break
						end
					end
				end
			end
		end
	end
	complete(budget, owned)
	return out
end
function B.normalMap(
	low: Mesh,
	high: Mesh,
	width: number,
	height: number,
	options: BakeOptions?
): (Texture, BakeReport)
	local options: BakeOptions = options or {}
	local budget, owned = Budget.acquire(options, "Bake.normalMap")
	local index = spatial(high, budget, options)
	local shared = table.clone(options)
	shared._budget = budget
	local image, report = B.rasterize(low, width, height, function(ctx)
		budget:step()
		local hit = index:closest(ctx.position, options.maxDistance)
		if not hit then
			return Color3.new(0.5, 0.5, 1), 0
		end
		local t = hit.triangle
		local f = high.faces[t.face]
		local bary = hit.barycentric
		local n = Vector3.zero
		for i, w in { bary.X, bary.Y, bary.Z } do
			n += (f.corners[t.corners[i]].normal or hit.normal) * w
		end
		n = U.unit(n, hit.normal)
		return Color3.new(
			n:Dot(ctx.tangent) * 0.5 + 0.5,
			n:Dot(ctx.bitangent) * 0.5 + 0.5,
			n:Dot(ctx.normal) * 0.5 + 0.5
		),
			1
	end, shared)
	report.operation = complete(budget, owned)
	return image, report
end
function B.ambientOcclusion(
	mesh: Mesh,
	width: number,
	height: number,
	options: BakeOptions?
): (Texture, BakeReport)
	local options: BakeOptions = options or {}
	local budget, owned = Budget.acquire(options, "Bake.ambientOcclusion")
	local index = spatial(options.occluder or mesh, budget, options)
	local shared = table.clone(options)
	shared._budget = budget
	local samples = options.samples or 16
	U.integer(samples, 1)
	local distance = options.distance or 10
	local bias = options.bias or 0.0001
	local image, report = B.rasterize(mesh, width, height, function(ctx)
		local x, y = U.frame(ctx.normal)
		local blocked = 0
		for i = 0, samples - 1 do
			budget:step()
			local r = math.sqrt((i + 0.5) / samples)
			local a = i * 2.399963229728653
			local direction = x * (r * math.cos(a))
				+ y * (r * math.sin(a))
				+ ctx.normal * math.sqrt(1 - r * r)
			if index:raycast(ctx.position + ctx.normal * bias, direction, distance) then
				blocked += 1
			end
		end
		local value = 1 - blocked / samples
		return Color3.new(value, value, value), 1
	end, shared)
	report.operation = complete(budget, owned)
	return image, report
end
-- Per-vertex ambient occlusion: the same cosine-weighted hemisphere rays as ambientOcclusion, but
-- cast once per vertex (along its area-weighted normal) instead of once per texel, which makes
-- occlusion affordable on meshes of tens of thousands of vertices. Returns {[vertex] = openness}
-- (1 = unoccluded, 0 = fully enclosed). Combine with pointSampler to shade textures with it.
function B.vertexOcclusion(mesh: Mesh, options: BakeOptions?): ({ [number]: number }, Types.Progress)
	local options: BakeOptions = options or {}
	local budget, owned = Budget.acquire(options, "Bake.vertexOcclusion")
	local index = spatial(options.occluder or mesh, budget, options)
	local samples = options.samples or 16
	U.integer(samples, 1)
	local distance = options.distance or 10
	local bias = options.bias or 0.001
	local normals: { [number]: Vector3 } = {}
	for fid, f in mesh.faces do
		local n, area = mesh:faceNormal(fid)
		for _, v in f.vertices do
			normals[v] = (normals[v] or Vector3.zero) + n * area
		end
	end
	local result: { [number]: number } = {}
	for id, p in mesh.vertices do
		local n = normals[id]
		if n and n.Magnitude > 1e-12 then
			n = n.Unit
			local x, y = U.frame(n)
			local blocked = 0
			for i = 0, samples - 1 do
				budget:step()
				local r = math.sqrt((i + 0.5) / samples)
				local a = i * 2.399963229728653
				local direction = x * (r * math.cos(a)) + y * (r * math.sin(a)) + n * math.sqrt(1 - r * r)
				if index:raycast(p + n * bias, direction, distance) then
					blocked += 1
				end
			end
			result[id] = 1 - blocked / samples
		end
	end
	return result, complete(budget, owned)
end
export type OcclusionSamplerOptions = BakeOptions & {
	weld: number?,
	radius: number?,
	occluders: { Mesh }?,
}
-- Openness (1 = open, 0 = enclosed) anywhere on a model made of several meshes, such as published parts
-- read back with Roblox.fromPart: the meshes are joined and welded (weld, default 2e-3, so soups and chunk
-- seams share vertices), occlusion is cast once per vertex as in vertexOcclusion (samples, distance, bias)
-- against the meshes plus any `occluders` (other parts that shade them), and the result is wrapped in a
-- normal-aware pointSampler (radius, default 1.2). Returns sampler(position, normal?) -> openness? and the
-- mean openness. Per-vertex openness is noisy (standard deviation about sqrt(p(1 - p) / samples)); the
-- sampler radius averages it out. For shading textures, multiply the existing colour by a curve that only
-- darkens (lo + (1 - lo) * smoothstep(a, b, openness)): normalising to the mean brightens open surfaces.
function B.occlusionSampler(
	meshes: { Mesh },
	options: OcclusionSamplerOptions?
): ((Vector3, Vector3?) -> number?, number)
	local o: OcclusionSamplerOptions = options or {}
	assert(#meshes > 0, "occlusionSampler needs meshes")
	local Topology = require(script.Parent.Topology) :: any
	local welded = Topology.weld(Topology.join(meshes), o.weld or 2e-3)
	local occluder = welded
	if o.occluders and #o.occluders > 0 then
		local all = { welded }
		for _, m in o.occluders do
			table.insert(all, m)
		end
		occluder = Topology.join(all)
	end
	local bakeOptions: BakeOptions = table.clone(o) :: any
	bakeOptions.occluder = occluder
	local open = B.vertexOcclusion(welded, bakeOptions)
	local sums: { [number]: Vector3 } = {}
	for fid, f in welded.faces do
		local n, area = welded:faceNormal(fid)
		for _, v in f.vertices do
			sums[v] = (sums[v] or Vector3.zero) + n * area
		end
	end
	local points, values, normals = {}, {}, {}
	local total = 0
	for id, p in welded.vertices do
		local value = open[id]
		local n = sums[id]
		if value and n and n.Magnitude > 1e-12 then
			table.insert(points, p)
			table.insert(values, value)
			table.insert(normals, n.Unit)
			total += value
		end
	end
	assert(#values > 0, "occlusionSampler found no vertices with normals")
	return B.pointSampler(points, values, o.radius or 1.2, normals), total / #values
end
export type HeightOcclusionOptions = {
	cellX: number?,
	cellY: number?,
	periodicX: boolean?,
	curvatureRadius: number?,
	directions: number?,
	distances: { number }?,
}
-- Horizon-based ambient occlusion of a height field: heights[row][col] (rows along y, columns along x,
-- spacing cellY and cellX studs, default 1), height measured toward the viewer or outward. For each cell,
-- in `directions` (default 12) directions across the field, the steepest rise to the samples at
-- `distances` (studs, default 0.12 .. 2.5) gives the horizon angle; the occlusion is the mean of its sine,
-- 0 (open) to 1 (enclosed). periodicX wraps the columns (the azimuth of a cylindrical height field), and
-- curvatureRadius R lowers a neighbour at distance d across the columns by d^2 / (2R), the drop of a
-- convex cylinder, so its round surface is not counted as occluding. Much cheaper than ray casting and
-- free of sampling noise; use it on the height-field sheets of re-surfaced panels and wraps, then darken
-- the bake with a curve such as 1 - k * smoothstep(a, b, occlusion). NaN or missing cells are skipped.
function B.heightOcclusion(heights: { { number } }, options: HeightOcclusionOptions?): { { number } }
	local o: HeightOcclusionOptions = options or {}
	local rows = #heights
	assert(rows > 0, "heightOcclusion needs at least one row")
	local cols = #heights[1]
	for r = 2, rows do
		assert(#heights[r] == cols, "heightOcclusion rows must have matching lengths")
	end
	local cx, cy = o.cellX or 1, o.cellY or 1
	assert(cx > 0 and cy > 0, "heightOcclusion cell sizes must be positive")
	local periodic = o.periodicX == true
	local radius = o.curvatureRadius
	assert(radius == nil or radius > 0, "heightOcclusion curvatureRadius must be positive")
	local nDir = o.directions or 12
	assert(nDir >= 1, "heightOcclusion needs a direction")
	local dists: { number } = o.distances or { 0.12, 0.25, 0.4, 0.6, 0.9, 1.3, 1.8, 2.5 }
	local function at(r: number, c: number): number?
		if r < 1 or r > rows then
			return nil
		end
		if periodic then
			c = (c - 1) % cols + 1
		elseif c < 1 or c > cols then
			return nil
		end
		local v = heights[r][c]
		if v ~= v then
			return nil
		end
		return v
	end
	-- bilinear sample at fractional (row, col), nil if any corner is missing
	local function sample(fr: number, fc: number): number?
		local r0, c0 = math.floor(fr), math.floor(fc)
		local tr, tc = fr - r0, fc - c0
		local a, b = at(r0, c0), at(r0, c0 + 1)
		local c, d = at(r0 + 1, c0), at(r0 + 1, c0 + 1)
		if not (a and b and c and d) then
			return nil
		end
		return (a * (1 - tc) + b * tc) * (1 - tr) + (c * (1 - tc) + d * tc) * tr
	end
	local out: { { number } } = table.create(rows)
	for r = 1, rows do
		local row = table.create(cols, 0)
		for c = 1, cols do
			local h = at(r, c)
			if h then
				local sum = 0
				for k = 0, nDir - 1 do
					local angle = 2 * math.pi * (k + 0.5) / nDir
					local dx, dy = math.cos(angle), math.sin(angle)
					local best = 0
					for i = 1, #dists do
						local d = dists[i]
						local v = sample(r + dy * d / cy, c + dx * d / cx)
						if v then
							local drop = if radius then (dx * d) ^ 2 / (2 * radius) else 0
							local slope = (v - h - drop) / d
							if slope > best then
								best = slope
							end
						end
					end
					sum += best / math.sqrt(1 + best * best) -- sin(atan(slope))
				end
				row[c] = sum / nDir
			end
		end
		out[r] = row
	end
	return out
end
export type SlopeFitOptions = {
	cellX: number?,
	cellY: number?,
	periodicX: boolean?,
	weights: { { number } }?,
	gain: number?,
	keep: number?,
	trend: ("mean" | "linear")?,
	clip: number?,
	minFacing: number?,
	maxSlope: number?,
	radial: number?,
	iterations: number?,
	tolerance: number?,
	checkpoint: (() -> ())?,
}
export type SlopeFitReport = {
	cells: number,
	iterations: number,
	residual: number,
	slopeErrorBefore: number,
	slopeErrorAfter: number,
}
-- out[c] = sum of line[c - k .. c + k] (wrapped when periodic, zero outside otherwise), by prefix sums
local function windowSum(line: { number }, len: number, k: number, periodic: boolean, out: { number })
	if periodic then
		local kk = math.min(k, math.floor((len - 1) / 2))
		local pre = table.create(len + 2 * kk + 1, 0)
		for t = 1, len + 2 * kk do
			pre[t + 1] = pre[t] + line[(t - kk - 1) % len + 1]
		end
		for c = 1, len do
			out[c] = pre[c + 2 * kk + 1] - pre[c]
		end
	else
		local pre = table.create(len + 1, 0)
		for t = 1, len do
			pre[t + 1] = pre[t] + line[t]
		end
		for c = 1, len do
			out[c] = pre[math.min(len, c + k) + 1] - pre[math.max(1, c - k)]
		end
	end
end
-- three box passes of half-width k have variance (k^2 + k), so k^2 + k = sigma^2 / 3 each
local function boxHalf(sigma: number): number
	return math.max(0, math.floor((math.sqrt(1 + 4 * sigma * sigma / 3) - 1) / 2 + 0.5))
end
-- three box passes per axis over a flat row-major grid, in place (zero outside unless periodic in x)
local function boxBlur3(a: { number }, rows: number, cols: number, kx: number, ky: number, periodic: boolean)
	local lineX, outX = table.create(cols, 0), table.create(cols, 0)
	local lineY, outY = table.create(rows, 0), table.create(rows, 0)
	for _ = 1, 3 do
		if kx > 0 then
			for r = 0, rows - 1 do
				local base = r * cols
				for c = 1, cols do
					lineX[c] = a[base + c]
				end
				windowSum(lineX, cols, kx, periodic, outX)
				for c = 1, cols do
					a[base + c] = outX[c]
				end
			end
		end
		if ky > 0 then
			for c = 1, cols do
				for r = 1, rows do
					lineY[r] = a[(r - 1) * cols + c]
				end
				windowSum(lineY, rows, ky, false, outY)
				for r = 1, rows do
					a[(r - 1) * cols + c] = outY[r]
				end
			end
		end
	end
end
-- local-linear trend of `values` over the cells where `mask` is set, with the masked blur's weights: at each
-- cell, the weighted least-squares plane a + bx dx + by dy through its neighbourhood, evaluated there (a). Unlike
-- the weighted mean it has no bias where the values ramp up to the mask's edge. Periodic columns are unrolled:
-- the grid is padded by the window's reach with wrapped copies whose column coordinates continue.
local function maskedTrend(
	values: { number },
	mask: { boolean },
	rows: number,
	cols: number,
	sx: number,
	sy: number,
	periodic: boolean
): { number }
	local kx, ky = boxHalf(sx), boxHalf(sy)
	local pad = if periodic then math.min(3 * kx, cols) else 0
	local W = cols + 2 * pad
	local N = rows * W
	-- moments: m, m x, m y, m x^2, m y^2, m x y, m v, m v x, m v y (x, y relative to the grid's centre)
	local fields = {}
	for f = 1, 9 do
		fields[f] = table.create(N, 0)
	end
	local x0, y0 = (cols + 1) / 2, (rows + 1) / 2
	for r = 1, rows do
		local y = r - y0
		for C = 1, W do
			local c = ((C - pad - 1) % cols) + 1
			local i = (r - 1) * cols + c
			if mask[i] then
				local x = C - pad - x0
				local v = values[i]
				local k = (r - 1) * W + C
				fields[1][k] = 1
				fields[2][k] = x
				fields[3][k] = y
				fields[4][k] = x * x
				fields[5][k] = y * y
				fields[6][k] = x * y
				fields[7][k] = v
				fields[8][k] = v * x
				fields[9][k] = v * y
			end
		end
	end
	for f = 1, 9 do
		boxBlur3(fields[f], rows, W, kx, ky, false)
	end
	local out = table.create(rows * cols, 0)
	for r = 1, rows do
		local yi = r - y0
		for c = 1, cols do
			local k = (r - 1) * W + c + pad
			local s0 = fields[1][k]
			if s0 > 1e-9 then
				local xi = c - x0
				local sx_, sy_ = fields[2][k], fields[3][k]
				-- moments about the cell itself
				local Sx, Sy = sx_ - xi * s0, sy_ - yi * s0
				local Sxx = fields[4][k] - 2 * xi * sx_ + xi * xi * s0
				local Syy = fields[5][k] - 2 * yi * sy_ + yi * yi * s0
				local Sxy = fields[6][k] - xi * sy_ - yi * sx_ + xi * yi * s0
				local T0 = fields[7][k]
				local Tx, Ty = fields[8][k] - xi * T0, fields[9][k] - yi * T0
				-- solve [s0 Sx Sy; Sx Sxx Sxy; Sy Sxy Syy] (a, bx, by) = (T0, Tx, Ty) for a (Cramer's rule)
				local det = s0 * (Sxx * Syy - Sxy * Sxy)
					- Sx * (Sx * Syy - Sxy * Sy)
					+ Sy * (Sx * Sxy - Sxx * Sy)
				local a
				if math.abs(det) > 1e-9 * s0 * (Sxx * Syy + 1) then
					a = (
						T0 * (Sxx * Syy - Sxy * Sxy)
						- Sx * (Tx * Syy - Sxy * Ty)
						+ Sy * (Tx * Sxy - Sxx * Ty)
					) / det
				else
					a = T0 / s0 -- too few or collinear neighbours: the mean
				end
				out[(r - 1) * cols + c] = a
			end
		end
	end
	return out
end
-- separable masked blur of a flat row-major grid: three box passes per axis (close to a Gaussian of sigma `sx`
-- columns and `sy` rows), averaging only the cells where `mask` is set
local function maskedBlur(
	values: { number },
	mask: { boolean },
	rows: number,
	cols: number,
	sx: number,
	sy: number,
	periodic: boolean
): { number }
	local n = rows * cols
	local v = table.create(n, 0)
	local m = table.create(n, 0)
	for i = 1, n do
		if mask[i] then
			v[i] = values[i]
			m[i] = 1
		end
	end
	local kx, ky = boxHalf(sx), boxHalf(sy)
	boxBlur3(v, rows, cols, kx, ky, periodic)
	boxBlur3(m, rows, cols, kx, ky, periodic)
	local out = table.create(n, 0)
	for i = 1, n do
		out[i] = if m[i] > 1e-12 then v[i] / m[i] else 0
	end
	return out
end
-- Fit a height field's relief to target normals (estimated from a photograph, baked from a sculpt) while it
-- keeps its own large-scale shape. heights[row][col] (rows along y, columns along x, spacing cellY and cellX
-- studs) are heights toward the viewer or outward, NaN where missing; normals[row][col] is a target normal in
-- the field's frame (X across increasing columns, Y along increasing rows, Z the height direction) or nil;
-- `weights` (default 1 wherever a normal is given) say how far each is trusted. Where weighted, the mismatch
-- between `gain` x the targets' slopes (-nx/nz, -ny/nz, clamped to maxSlope; normals with nz < minFacing are
-- skipped) and the field's own slopes is integrated by least squares (conjugate gradients over the grid) into
-- a correction; its scales above `keep` studs (default 4, a Gaussian-like high-pass over the present cells)
-- are removed so the field's silhouette-fitted shape stays (trend "mean", the default, subtracts the local
-- weighted mean; "linear" the local weighted plane, which leaves no offset where the correction ramps up to the
-- domain's edge, about 0.8 x slope x keep with the mean), it fades out where there are no targets, and it is
-- clipped to `clip`. periodicX wraps the columns (a cylinder's azimuth); with `radial` = R the heights are
-- radii and cellX the column arc at radius R, so column slopes scale by h / R. Returns the corrected heights
-- and a report (median slope error before and after over cells weighted above 0.5, CG iterations, residual).
function B.slopeFit(
	heights: { { number } },
	normals: { { Vector3? } },
	options: SlopeFitOptions?
): ({ { number } }, SlopeFitReport)
	local o: SlopeFitOptions = options or {}
	local rows = #heights
	assert(rows > 1, "slopeFit needs at least two rows")
	local cols = #heights[1]
	assert(cols > 1, "slopeFit needs at least two columns")
	for r = 1, rows do
		assert(#heights[r] == cols, "slopeFit rows must have matching lengths")
	end
	assert(#normals == rows, "slopeFit needs a normals row for every heights row")
	local cx, cy = o.cellX or 1, o.cellY or 1
	assert(cx > 0 and cy > 0, "slopeFit cell sizes must be positive")
	local periodic = o.periodicX == true
	local gain = o.gain or 1
	local keep = o.keep or 4
	assert(keep > 0, "slopeFit keep must be positive")
	local trend = o.trend or "mean"
	assert(trend == "mean" or trend == "linear", "slopeFit trend must be mean or linear")
	local minFacing = o.minFacing or 0.25
	local maxSlope = o.maxSlope or 3
	local radial = o.radial
	assert(radial == nil or radial > 0, "slopeFit radial must be positive")
	local n = rows * cols
	local h = table.create(n, 0)
	local present: { boolean } = table.create(n, false)
	local tx = table.create(n, 0)
	local ty = table.create(n, 0)
	local w = table.create(n, 0)
	local cells = 0
	for r = 1, rows do
		local hr, nr = heights[r], normals[r]
		local wr = o.weights and o.weights[r]
		for c = 1, cols do
			local i = (r - 1) * cols + c
			local v = hr[c]
			if v == v then
				h[i] = v
				present[i] = true
				local nv = nr and nr[c]
				local wt = if wr then wr[c] else 1
				if nv and wt > 0 and nv.Magnitude > 1e-9 then
					local u = nv.Unit
					if u.Z >= minFacing then
						local sx = math.clamp(-u.X / u.Z, -maxSlope, maxSlope)
						if radial then
							sx *= v / radial
						end
						tx[i] = gain * sx
						ty[i] = gain * math.clamp(-u.Y / u.Z, -maxSlope, maxSlope)
						w[i] = math.min(wt, 1)
						cells += 1
					end
				end
			end
		end
	end
	local function right(i: number): number?
		local c = (i - 1) % cols + 1
		if c < cols then
			return i + 1
		end
		return if periodic then i - cols + 1 else nil
	end
	-- edges between present neighbours carry the weighted mismatch of the targets' slope and the field's own
	local ea: { number }, eb: { number }, elen: { number }, em: { number } = {}, {}, {}, {}
	for i = 1, n do
		if present[i] then
			local j = right(i)
			if j and present[j] then
				table.insert(ea, i)
				table.insert(eb, j)
				table.insert(elen, cx)
				table.insert(em, math.min(w[i], w[j]) * ((tx[i] + tx[j]) / 2 - (h[j] - h[i]) / cx))
			end
			local k = i + cols
			if k <= n and present[k] then
				table.insert(ea, i)
				table.insert(eb, k)
				table.insert(elen, cy)
				table.insert(em, math.min(w[i], w[k]) * ((ty[i] + ty[k]) / 2 - (h[k] - h[i]) / cy))
			end
		end
	end
	-- normal equations L d = b of min sum ((d_j - d_i) / len - m)^2, plus a tiny pull to 0 fixing the constant;
	-- Jacobi-preconditioned conjugate gradients
	local eps = 1e-6 / (cx * cy)
	local diag = table.create(n, eps)
	local b = table.create(n, 0)
	for e = 1, #ea do
		local i, j, len = ea[e], eb[e], elen[e]
		local k = 1 / (len * len)
		diag[i] += k
		diag[j] += k
		b[i] -= em[e] / len
		b[j] += em[e] / len
	end
	local function apply(x: { number }, out: { number })
		for i = 1, n do
			out[i] = eps * x[i]
		end
		for e = 1, #ea do
			local i, j, len = ea[e], eb[e], elen[e]
			local f = (x[j] - x[i]) / (len * len)
			out[i] -= f
			out[j] += f
		end
	end
	local d = table.create(n, 0)
	local res = table.clone(b)
	local z = table.create(n, 0)
	local rz, bnorm = 0, 0
	for i = 1, n do
		z[i] = if present[i] then res[i] / diag[i] else 0
		rz += res[i] * z[i]
		bnorm += b[i] * b[i]
	end
	bnorm = math.sqrt(bnorm)
	local p = table.clone(z)
	local q = table.create(n, 0)
	local maxIter = o.iterations or 600
	local tol = o.tolerance or 1e-4
	local iter, rel = 0, 0
	if bnorm > 0 then
		for it = 1, maxIter do
			iter = it
			apply(p, q)
			local pq = 0
			for i = 1, n do
				pq += p[i] * q[i]
			end
			if pq <= 0 then
				break
			end
			local alpha = rz / pq
			local rr = 0
			for i = 1, n do
				d[i] += alpha * p[i]
				res[i] -= alpha * q[i]
				rr += res[i] * res[i]
			end
			rel = math.sqrt(rr) / bnorm
			if rel < tol then
				break
			end
			local rz2 = 0
			for i = 1, n do
				z[i] = if present[i] then res[i] / diag[i] else 0
				rz2 += res[i] * z[i]
			end
			local beta = rz2 / rz
			rz = rz2
			for i = 1, n do
				p[i] = z[i] + beta * p[i]
			end
			if o.checkpoint and it % 20 == 0 then
				o.checkpoint()
			end
		end
	end
	-- the field keeps its own large scales: remove the correction's, then fade it out where nothing was targeted
	local low = if trend == "linear"
		then maskedTrend(d, present, rows, cols, keep / cx, keep / cy, periodic)
		else maskedBlur(d, present, rows, cols, keep / cx, keep / cy, periodic)
	local cover = maskedBlur(w, present, rows, cols, 1.5, 1.5, periodic)
	local clip = o.clip
	local outH: { { number } } = table.create(rows)
	local fitted = table.create(n, 0)
	for r = 1, rows do
		local row = table.create(cols, 0)
		for c = 1, cols do
			local i = (r - 1) * cols + c
			if present[i] then
				local dv = (d[i] - low[i]) * math.clamp(cover[i] / 0.5, 0, 1)
				if clip then
					dv = math.clamp(dv, -clip, clip)
				end
				row[c] = h[i] + dv
				fitted[i] = h[i] + dv
			else
				row[c] = 0 / 0
			end
		end
		outH[r] = row
	end
	-- median slope error over the well-targeted cells, before and after
	local function slopeError(field: { number }): number
		local errs = {}
		for i = 1, n do
			if w[i] > 0.5 then
				local j = right(i)
				local k = i + cols
				if j and k <= n and present[j] and present[k] then
					local gx = (field[j] - field[i]) / cx
					local gy = (field[k] - field[i]) / cy
					table.insert(errs, math.sqrt((gx - tx[i]) ^ 2 + (gy - ty[i]) ^ 2))
				end
			end
		end
		if #errs == 0 then
			return 0
		end
		table.sort(errs)
		return errs[math.floor((#errs + 1) / 2)]
	end
	return outH,
		{
			cells = cells,
			iterations = iter,
			residual = rel,
			slopeErrorBefore = slopeError(h),
			slopeErrorAfter = slopeError(fitted),
		}
end
export type FoldDirectionOptions = {
	cellX: number?,
	cellY: number?,
	periodicX: boolean?,
	rho: number?,
	columns: number?,
	checkpoint: (() -> ())?,
}
-- Fold directions of a relief from its slopes: slopes[row][col] = Vector2(dz/dx, dz/dy) (studs per stud; rows along
-- y, columns along x, spacing cellY and cellX studs, default 1), nil where unknown, as from a photograph's normals
-- (-nx/nz, -ny/nz); `false` also marks a missing cell. The grid is #slopes rows by `columns` (default: the largest
-- column index present in any row, since a row's length is undefined with holes). The structure tensor of the slopes,
-- smoothed over `rho` studs (default 0.5), gives at each cell
-- the dominant direction ACROSS the folds; the returned direction is the one ALONG them (a unit Vector2 in world
-- x, y; its sign is arbitrary) with a coherence in [0, 1]: 1 where every slope points across one direction (long
-- parallel folds), 0 where they point every way or there are none. periodicX wraps the columns. Feed the result to
-- Bake.flowSmooth to lengthen folds that came out as lumps.
function B.foldDirections(
	slopes: { { Vector2 | false | nil } },
	options: FoldDirectionOptions?
): ({ { Vector2 } }, { { number } })
	local o: FoldDirectionOptions = options or {}
	local rows = #slopes
	assert(rows > 0, "foldDirections needs at least one row")
	local cols = o.columns or 0
	if not o.columns then
		for r = 1, rows do
			for c in pairs(slopes[r]) do
				cols = math.max(cols, c)
			end
		end
	end
	assert(cols > 0, "foldDirections needs at least one column")
	local cx, cy = o.cellX or 1, o.cellY or 1
	assert(cx > 0 and cy > 0, "foldDirections cell sizes must be positive")
	local rho = o.rho or 0.5
	assert(rho >= 0, "foldDirections rho must not be negative")
	local periodic = o.periodicX == true
	local n = rows * cols
	local jxx, jxy, jyy, m = table.create(n, 0), table.create(n, 0), table.create(n, 0), table.create(n, 0)
	for r = 1, rows do
		local row = slopes[r]
		for c = 1, cols do
			local g = row[c]
			if typeof(g) == "Vector2" then
				local i = (r - 1) * cols + c
				jxx[i], jxy[i], jyy[i], m[i] = g.X * g.X, g.X * g.Y, g.Y * g.Y, 1
			end
		end
	end
	local kx, ky = boxHalf(rho / cx), boxHalf(rho / cy)
	for _, a in { jxx, jxy, jyy, m } do
		boxBlur3(a, rows, cols, kx, ky, periodic)
		if o.checkpoint then
			o.checkpoint()
		end
	end
	local directions: { { Vector2 } } = table.create(rows)
	local coherence: { { number } } = table.create(rows)
	for r = 1, rows do
		local drow, crow = table.create(cols), table.create(cols, 0)
		for c = 1, cols do
			local i = (r - 1) * cols + c
			local w = m[i]
			local dir = Vector2.new(0, 1)
			local coh = 0
			if w > 1e-9 then
				local a, b, d = jxx[i] / w, jxy[i] / w, jyy[i] / w
				local tr = a + d
				if tr > 1e-12 then
					local across = 0.5 * math.atan2(2 * b, a - d)
					dir = Vector2.new(-math.sin(across), math.cos(across))
					coh = math.clamp(math.sqrt((a - d) ^ 2 + 4 * b * b) / tr, 0, 1)
				end
			end
			drow[c], crow[c] = dir, coh
		end
		directions[r], coherence[r] = drow, crow
	end
	return directions, coherence
end
export type FlowSmoothOptions = {
	cellX: number?,
	cellY: number?,
	periodicX: boolean?,
	length: number?,
	step: number?,
	coherence: { { number } }?,
	minCoherence: number?,
	fullCoherence: number?,
	checkpoint: (() -> ())?,
}
-- Smooths a field along a direction field (line integral convolution): field[row][col] (NaN where missing; rows
-- along y, columns along x, spacing cellY and cellX studs) is averaged at each present cell along the streamline
-- through it, both ways over `length` studs (default 1; Gaussian weights, sigma length / 2; steps of `step`
-- studs, default half the smaller cell), following directions[row][col] (unit Vector2 in world x, y, either sign;
-- the walk keeps a consistent orientation) and stopping at missing cells. Detail along the folds is averaged away
-- while detail across them stays, so photo-derived relief that came out as lumps becomes long folds. With
-- `coherence` (from Bake.foldDirections) the result blends from the original below minCoherence (default 0.2) to
-- the smoothed value above fullCoherence (default 0.6). periodicX wraps the columns.
function B.flowSmooth(
	field: { { number } },
	directions: { { Vector2 } },
	options: FlowSmoothOptions?
): { { number } }
	local o: FlowSmoothOptions = options or {}
	local rows = #field
	assert(rows > 0, "flowSmooth needs at least one row")
	local cols = #field[1]
	assert(#directions == rows, "flowSmooth needs a directions row for every field row")
	for r = 1, rows do
		assert(#field[r] == cols and #directions[r] == cols, "flowSmooth rows must have matching lengths")
	end
	local cx, cy = o.cellX or 1, o.cellY or 1
	assert(cx > 0 and cy > 0, "flowSmooth cell sizes must be positive")
	local length = o.length or 1
	assert(length > 0, "flowSmooth length must be positive")
	local step = o.step or 0.5 * math.min(cx, cy)
	assert(step > 0, "flowSmooth step must be positive")
	local periodic = o.periodicX == true
	local lo, hi = o.minCoherence or 0.2, o.fullCoherence or 0.6
	assert(hi > lo, "flowSmooth fullCoherence must exceed minCoherence")
	local steps = math.max(1, math.floor(length / step + 0.5))
	local sigma = length / 2
	local weights = table.create(steps, 0)
	for k = 1, steps do
		weights[k] = math.exp(-0.5 * (k * step / sigma) ^ 2)
	end
	local function value(r: number, c: number): number?
		if r < 1 or r > rows then
			return nil
		end
		if periodic then
			c = (c - 1) % cols + 1
		elseif c < 1 or c > cols then
			return nil
		end
		local v = field[r][c]
		if v ~= v then
			return nil
		end
		return v
	end
	-- bilinear sample at fractional (row, col); nil if a corner it needs is missing (a sample on a row or column
	-- line reads only that line, so the last row and column are reachable)
	local function sample(fr: number, fc: number): number?
		local r0, c0 = math.floor(fr), math.floor(fc)
		local tr, tc = fr - r0, fc - c0
		if tr < 1e-9 then
			tr = 0
		end
		if tc < 1e-9 then
			tc = 0
		end
		local a = value(r0, c0)
		if not a then
			return nil
		end
		local b = if tc > 0 then value(r0, c0 + 1) else a
		local c = if tr > 0 then value(r0 + 1, c0) else a
		local d = if tc > 0 and tr > 0 then value(r0 + 1, c0 + 1) elseif tc > 0 then b else c
		if not (b and c and d) then
			return nil
		end
		return (a * (1 - tc) + b * tc) * (1 - tr) + (c * (1 - tc) + d * tc) * tr
	end
	local function direction(fr: number, fc: number): Vector2
		local r = math.clamp(math.floor(fr + 0.5), 1, rows)
		local c = math.floor(fc + 0.5)
		c = if periodic then (c - 1) % cols + 1 else math.clamp(c, 1, cols)
		return directions[r][c]
	end
	local out: { { number } } = table.create(rows)
	for r = 1, rows do
		local src, row = field[r], table.create(cols, 0)
		for c = 1, cols do
			local v0 = src[c]
			if v0 ~= v0 then
				row[c] = v0
				continue
			end
			local acc, wsum = v0, 1
			for _, sgn in { 1, -1 } do
				local fr, fc = r, c
				local d0 = directions[r][c]
				local px, py = sgn * d0.X, sgn * d0.Y
				for k = 1, steps do
					fc += step * px / cx
					fr += step * py / cy
					local v = sample(fr, fc)
					if not v then
						break
					end
					acc += weights[k] * v
					wsum += weights[k]
					local d = direction(fr, fc)
					if d.X * px + d.Y * py < 0 then
						px, py = -d.X, -d.Y
					else
						px, py = d.X, d.Y
					end
				end
			end
			local smoothed = acc / wsum
			local w = 1
			if o.coherence then
				local t = math.clamp((o.coherence[r][c] - lo) / (hi - lo), 0, 1)
				w = t * t * (3 - 2 * t)
			end
			row[c] = v0 + w * (smoothed - v0)
		end
		out[r] = row
		if o.checkpoint and r % 16 == 0 then
			o.checkpoint()
		end
	end
	return out
end
-- A smooth lookup of scattered point values (per-vertex occlusion, curvature, wetness) at any
-- position, for use inside bake shaders. Points are hashed into cells of size `radius`; a query
-- blends the points within `radius` with weights exp(-(d / (radius / 2))^2), times the agreement of
-- their normal with the query normal when both are given (so the two sheets of a thin fold do not
-- bleed into each other). Returns nil where no point contributes.
function B.pointSampler(
	points: { Vector3 },
	values: { number },
	radius: number,
	normals: { Vector3 }?
): (Vector3, Vector3?) -> number?
	assert(radius > 0 and #points == #values, "pointSampler needs one value per point and a positive radius")
	local cells: { [string]: { number } } = {}
	local function cell(x: number, y: number, z: number): string
		return string.format("%d,%d,%d", x, y, z)
	end
	local function cellOf(p: Vector3): (number, number, number)
		return math.floor(p.X / radius), math.floor(p.Y / radius), math.floor(p.Z / radius)
	end
	for i, p in points do
		local c = cell(cellOf(p))
		local list = cells[c]
		if not list then
			list = {}
			cells[c] = list
		end
		table.insert(list, i)
	end
	local sigma2 = (radius / 2) ^ 2
	return function(position: Vector3, normal: Vector3?): number?
		local cx, cy, cz = cellOf(position)
		local sum, weight = 0, 0
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local list = cells[cell(cx + dx, cy + dy, cz + dz)]
					if list then
						for _, i in list do
							local d2 = (points[i] - position):Dot(points[i] - position)
							if d2 <= radius * radius then
								local w = math.exp(-d2 / sigma2)
								if normal and normals then
									w *= math.max(0, normals[i]:Dot(normal))
								end
								sum += values[i] * w
								weight += w
							end
						end
					end
				end
			end
		end
		return if weight > 1e-9 then sum / weight else nil
	end
end
function B.project(
	mesh: Mesh,
	texture: Texture,
	camera: Types.Camera,
	width: number,
	height: number,
	options: BakeOptions?
): (Texture, BakeReport)
	local options: BakeOptions = options or {}
	local Camera = require(script.Parent.Camera)
	local budget, owned = Budget.acquire(options, "Bake.project")
	local index = options.occlusion and spatial(mesh, budget, options) or nil
	local shared = table.clone(options)
	shared._budget = budget
	local image, report = B.rasterize(mesh, width, height, function(ctx)
		local pixel = Camera.project(camera, ctx.position)
		if not pixel then
			return Color3.new(), 0
		end
		local uv = pixel / Vector2.new(camera.width, camera.height)
		if uv.X < 0 or uv.X > 1 or uv.Y < 0 or uv.Y > 1 then
			return Color3.new(), 0
		end
		local direction = ctx.position - camera.frame.Position
		if ctx.normal:Dot(-direction.Unit) < (options.facingThreshold or 0) then
			return Color3.new(), 0
		end
		if index then
			local hit = index:raycast(camera.frame.Position, direction)
			if hit and hit.distance < direction.Magnitude - (options.bias or 0.001) then
				return Color3.new(), 0
			end
		end
		return texture:sample(uv)
	end, shared)
	report.operation = complete(budget, owned)
	return image, report
end
-- Never called: lets the type checker verify the implementation against Types.BakeLibrary.
local function _contract(): Types.BakeLibrary
	return B
end
return B
