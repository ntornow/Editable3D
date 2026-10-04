-- Original nearest-triangle surface attachment. No Blender source or model data.
local U = require(script.Parent.Util)
local Spatial = require(script.Parent.Spatial)
local S = {}
S.__index = S

local function signature(mesh)
	local items = {}
	for _, id in U.keys(mesh.vertices) do
		table.insert(items, "v" .. id)
	end
	for _, id in U.keys(mesh.faces) do
		table.insert(items, "f" .. id .. ":" .. table.concat(mesh.faces[id].vertices, ","))
	end
	return table.concat(items, ";")
end

local function basis(a, b, c)
	local e, f = b - a, c - a
	local cross = e:Cross(f)
	assert(e.Magnitude > 1e-10 and cross.Magnitude > 1e-10, "Surface control triangle collapsed")
	local x, z = e.Unit, cross.Unit
	return x, z:Cross(x), z, e, f
end

function S.bind(mesh, target, options)
	options = options or {}
	local limit = options.maxDistance or math.huge
	assert(limit >= 0 and limit == limit, "Invalid binding distance")
	assert(
		U.count(mesh.vertices) <= (options.maxVertices or 100000),
		"Surface binding vertex budget exceeded"
	)
	local index = Spatial.new(target)
	assert(index.root, "Surface control mesh is empty or degenerate")
	local self = setmetatable({ source = mesh:clone(), targetSignature = signature(target), records = {} }, S)
	local report = { boundVertices = 0, unboundVertices = 0, maskedVertices = 0, maximumDistance = 0 }
	local ids = U.keys(mesh.vertices)
	for i, id in ids do
		local p = mesh.vertices[id]
		assert(U.vector(p), "Invalid source position")
		local weight = U.weight(options.mask, id)
		assert(U.finite(weight) and weight >= 0 and weight <= 1, "Binding mask must be in [0,1]")
		local h = weight > 0 and index:closest(p, limit) or nil
		if h then
			local tri = h.triangle
			local a, b, c = target.vertices[tri[1]], target.vertices[tri[2]], target.vertices[tri[3]]
			local x, y, z, e, f = basis(a, b, c)
			local d = p - h.position
			local ex, fx, fy = e:Dot(x), f:Dot(x), f:Dot(y)
			local v = d:Dot(y) / fy
			self.records[id] = {
				triangle = { tri[1], tri[2], tri[3] },
				barycentric = h.barycentric,
				offset = Vector3.new(d:Dot(x), d:Dot(y), d:Dot(z)),
				affine = Vector2.new((d:Dot(x) - fx * v) / ex, v),
				weight = weight,
			}
			report.boundVertices += 1
			report.maximumDistance = math.max(report.maximumDistance, h.distance)
		elseif weight == 0 then
			report.maskedVertices += 1
		else
			report.unboundVertices += 1
		end
		if options.checkpoint and i % 256 == 0 then
			options.checkpoint(i / #ids)
		end
	end
	self.report = report
	return self, report
end

function S:evaluate(target, options)
	options = options or {}
	assert(signature(target) == self.targetSignature, "Surface control topology changed; bind again")
	local mode = options.mode or "RIGID"
	assert(mode == "RIGID" or mode == "AFFINE", "Surface mode must be RIGID or AFFINE")
	local influence = options.influence == nil and 1 or options.influence
	assert(U.finite(influence) and influence >= 0 and influence <= 1, "Influence must be in [0,1]")
	local out = self.source:clone()
	local report = { affectedVertices = 0, maximumDisplacement = 0 }
	for _, id in U.keys(self.records) do
		local r = self.records[id]
		local a, b, c =
			target.vertices[r.triangle[1]], target.vertices[r.triangle[2]], target.vertices[r.triangle[3]]
		assert(U.vector(a) and U.vector(b) and U.vector(c), "Invalid control position")
		local x, y, z, e, f = basis(a, b, c)
		local w, d = r.barycentric, r.offset
		local q = a * w.X + b * w.Y + c * w.Z + z * d.Z
		if mode == "AFFINE" then
			q += e * r.affine.X + f * r.affine.Y
		else
			q += x * d.X + y * d.Y
		end
		out.vertices[id] = self.source.vertices[id]:Lerp(q, r.weight * influence)
		local moved = (out.vertices[id] - self.source.vertices[id]).Magnitude
		if moved > 0 then
			report.affectedVertices += 1
		end
		report.maximumDisplacement = math.max(report.maximumDisplacement, moved)
	end
	if options.recalculateNormals ~= false then
		out:recalculateNormals()
	end
	return out, report
end
return S
