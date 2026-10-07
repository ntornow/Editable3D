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
