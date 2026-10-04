--!strict
-- Original nearest-triangle surface attachment. No Blender source or model data.
local U = require(script.Parent.Util)
local Spatial = require(script.Parent.Spatial)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
export type BindOptions = {
	maxDistance: number?,
	maxVertices: number?,
	mask: { [number]: number }?,
	checkpoint: ((fraction: number) -> ())?,
}
export type EvaluateOptions = { mode: string?, influence: number?, recalculateNormals: boolean? }
export type BindReport = {
	boundVertices: number,
	unboundVertices: number,
	maskedVertices: number,
	maximumDistance: number,
}
export type EvaluateReport = { affectedVertices: number, maximumDisplacement: number }
type Record = {
	triangle: { number },
	barycentric: Vector3,
	offset: Vector3,
	affine: Vector2,
	weight: number,
}
export type Binding = {
	source: Mesh,
	targetSignature: string,
	records: { [number]: Record },
	report: BindReport,
	evaluate: (Binding, Mesh, EvaluateOptions?) -> (Mesh, EvaluateReport),
}
type Self = Binding
local S = {}
S.__index = S

local function signature(mesh: Mesh): string
	local items: { string } = {}
	for _, id in U.keys(mesh.vertices) do
		table.insert(items, "v" .. id)
	end
	for _, id in U.keys(mesh.faces) do
		table.insert(items, "f" .. id .. ":" .. table.concat(mesh.faces[id].vertices, ","))
	end
	return table.concat(items, ";")
end

local function basis(a: Vector3, b: Vector3, c: Vector3): (Vector3, Vector3, Vector3, Vector3, Vector3)
	local e, f = b - a, c - a
	local cross = e:Cross(f)
	assert(e.Magnitude > 1e-10 and cross.Magnitude > 1e-10, "Surface control triangle collapsed")
	local x, z = e.Unit, cross.Unit
	return x, z:Cross(x), z, e, f
end

function S.bind(mesh: Mesh, target: Mesh, options: BindOptions?): (Binding, BindReport)
	local options: BindOptions = options or {}
	local limit = options.maxDistance or math.huge
	assert(limit >= 0 and limit == limit, "Invalid binding distance")
	assert(
		U.count(mesh.vertices) <= (options.maxVertices or 100000),
		"Surface binding vertex budget exceeded"
	)
	local index = Spatial.new(target)
	assert(index.root, "Surface control mesh is empty or degenerate")
	local self: Binding =
		setmetatable({ source = mesh:clone(), targetSignature = signature(target), records = {} }, S) :: any
	local report: BindReport =
		{ boundVertices = 0, unboundVertices = 0, maskedVertices = 0, maximumDistance = 0 }
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

function S.evaluate(self: Self, target: Mesh, options: EvaluateOptions?): (Mesh, EvaluateReport)
	local options: EvaluateOptions = options or {}
	assert(signature(target) == self.targetSignature, "Surface control topology changed; bind again")
	local mode = options.mode or "RIGID"
	assert(mode == "RIGID" or mode == "AFFINE", "Surface mode must be RIGID or AFFINE")
	local influence: number = (options.influence == nil and 1 or options.influence) :: number
	assert(U.finite(influence) and influence >= 0 and influence <= 1, "Influence must be in [0,1]")
	local out = self.source:clone()
	local report: EvaluateReport = { affectedVertices = 0, maximumDisplacement = 0 }
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
