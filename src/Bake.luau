local Texture = require(script.Parent.Texture)
local Spatial = require(script.Parent.Spatial)
local U = require(script.Parent.Util)
local Budget = require(script.Parent.OperationBudget)
local B = {}
local function preflight(mesh, budget, options)
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
local function spatial(mesh, budget, options)
	preflight(mesh, budget, options)
	local result = Spatial.new(mesh)
	budget:check()
	return result
end
local function complete(budget, owned)
	return owned and budget:finish() or budget:report()
end
function B.rasterize(mesh, width, height, shader, options)
	options = options or {}
	local budget, owned = Budget.acquire(options, "Bake.rasterize")
	preflight(mesh, budget, options)
	local image = Texture.new(width, height, nil, nil, Budget.options(budget))
	budget:image(width, height, 1)
	local coverage = buffer.create(width * height)
	local written = 0
	for _, t in mesh:triangles() do
		budget:step()
		local f = mesh.faces[t.face]
		local ca, cb, cc = f.corners[t.corners[1]], f.corners[t.corners[2]], f.corners[t.corners[3]]
		local a, b, c = ca.uv, cb.uv, cc.uv
		assert(a and b and c, "Baking requires corner UVs")
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
			operation = complete(budget, owned),
		}
end
function B.dilate(image, coverage, iterations, options)
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
function B.normalMap(low, high, width, height, options)
	options = options or {}
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
function B.ambientOcclusion(mesh, width, height, options)
	options = options or {}
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
function B.project(mesh, texture, camera, width, height, options)
	options = options or {}
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
return B
