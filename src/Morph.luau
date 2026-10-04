-- Sparse per-vertex and per-corner additive shape keys; weights need not sum to one.
local U = require(script.Parent.Util)
local Spatial = require(script.Parent.Spatial)
local M = {}
local vectorFields = { normal = true, tangent = true, uv = true, uv1 = true }
local function deltaCorner(a, b)
	local d = {}
	for key in vectorFields do
		assert((a[key] ~= nil) == (b[key] ~= nil), "Shape attribute layout differs")
		if a[key] and b[key] then
			d[key] = b[key] - a[key]
		end
	end
	assert((a.color ~= nil) == (b.color ~= nil), "Shape color layout differs")
	if a.color and b.color then
		d.color = Vector3.new(b.color.R - a.color.R, b.color.G - a.color.G, b.color.B - a.color.B)
	end
	if a.alpha ~= nil or b.alpha ~= nil then
		d.alpha = (b.alpha or 1) - (a.alpha or 1)
	end
	return d
end
function M.fromMeshes(base, target, name)
	assert(
		U.count(base.vertices) == U.count(target.vertices) and U.count(base.faces) == U.count(target.faces),
		"Shape topology differs"
	)
	local result = { name = name, positions = {}, corners = {} }
	for id, p in base.vertices do
		result.positions[id] = assert(target.vertices[id], "Shape vertex missing") - p
	end
	for fid, f in base.faces do
		local g = assert(target.faces[fid], "Shape face missing")
		assert(#f.vertices == #g.vertices, "Shape topology differs")
		local corners = {}
		for i, id in f.vertices do
			assert(g.vertices[i] == id, "Shape topology differs")
			corners[i] = deltaCorner(f.corners[i], g.corners[i])
		end
		result.corners[fid] = corners
	end
	return result
end
function M.evaluate(base, targets, weights, options)
	options = options or {}
	weights = weights or {}
	for index, weight in weights do
		assert(type(index) == "number" and index % 1 == 0 and targets[index], "Morph weight has no target")
		assert(type(weight) == "number" and U.finite(weight), "Nonfinite morph weight")
	end
	local out = base:clone()
	for index, target in targets do
		local weight = weights[index] or 0
		assert(type(weight) == "number" and U.finite(weight), "Nonfinite morph weight")
		if weight ~= 0 then
			for id, delta in target.positions or {} do
				assert(out.vertices[id] and U.vector(delta), "Invalid morph vertex")
				out.vertices[id] += delta * weight
			end
			for fid, corners in target.corners or {} do
				local face = assert(out.faces[fid], "Invalid morph face")
				for i, delta in corners do
					local c = assert(face.corners[i], "Invalid morph corner")
					for key, value in delta do
						if vectorFields[key] then
							assert(
								c[key]
									and typeof(c[key]) == typeof(value)
									and (
										(typeof(value) == "Vector3" and U.vector(value))
										or (
											typeof(value) == "Vector2"
											and U.finite(value.X)
											and U.finite(value.Y)
										)
									),
								"Morph attribute requires matching base attribute"
							)
							c[key] += value * weight
						elseif key == "color" then
							assert(
								c.color and U.vector(value),
								"Color delta must be Vector3 over a base color"
							)
							c.color = Color3.new(
								c.color.R + value.X * weight,
								c.color.G + value.Y * weight,
								c.color.B + value.Z * weight
							)
						elseif key == "alpha" then
							assert(U.finite(value), "Invalid alpha delta")
							c.alpha = (c.alpha or 1) + value * weight
						else
							error("Unsupported morph attribute " .. tostring(key))
						end
					end
				end
			end
		end
	end
	for fid, f in out.faces do
		for i, c in f.corners do
			if c.normal then
				c.normal = U.unit(c.normal, base.faces[fid].corners[i].normal)
			end
			if c.tangent then
				c.tangent = U.unit(c.tangent, base.faces[fid].corners[i].tangent)
			end
			if c.color then
				c.color = Color3.new(
					math.clamp(c.color.R, 0, 1),
					math.clamp(c.color.G, 0, 1),
					math.clamp(c.color.B, 0, 1)
				)
			end
			if c.alpha then
				c.alpha = math.clamp(c.alpha, 0, 1)
			end
		end
	end
	if options.recalculateNormals then
		out:recalculateNormals(options.normalAngle)
	end
	out.revision += 1
	return out
end
function M.transfer(sourceBase, targetBase, target, options)
	options = options or {}
	local index = Spatial.new(sourceBase)
	local result = { name = target.name, positions = {}, corners = {} }
	local maximum = 0
	for id, p in targetBase.vertices do
		local hit = index:closest(p)
		assert(
			hit and (not options.maxDistance or hit.distance <= options.maxDistance),
			"Morph transfer exceeds source distance"
		)
		local triangle = hit.triangle
		local v = hit.barycentric
		local bary = { v.X, v.Y, v.Z }
		local delta = Vector3.zero
		for i = 1, 3 do
			delta += (target.positions[triangle[i]] or Vector3.zero) * bary[i]
		end
		result.positions[id] = delta
		maximum = math.max(maximum, hit.distance)
	end
	return result, { maxSourceDistance = maximum }
end
return M
