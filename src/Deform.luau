--!strict
local U = require(script.Parent.Util)
local Spatial = require(script.Parent.Spatial)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Per-vertex blend weights in [0, 1], keyed by vertex id; missing ids weigh 1.
export type Mask = { [number]: number }
export type Handle = { from: Vector3, to: Vector3 }
local D = {}
-- Operation and options are forwarded to the non-strict DeformMasked module.
function D.masked(mesh: Mesh, operation: any, options: any?)
	return require(script.Parent.DeformMasked)(mesh, operation, options)
end
function D.map(mesh: Mesh, callback: (Vector3, number) -> Vector3, mask: Mask?): Mesh
	local out = mesh:clone()
	for id, p in mesh.vertices do
		local q = callback(p, id)
		assert(U.vector(q), "Deformation returned invalid position")
		out.vertices[id] = p:Lerp(q, U.weight(mask, id))
	end
	return out:recalculateNormals()
end
-- normals = "transform" keeps authored corner normals and tangents, mapping them through the
-- transform (normals by the inverse transpose) instead of recalculating them from positions.
export type TransformOptions = { normals: ("recalculate" | "transform")? }
function D.transform(mesh: Mesh, frame: CFrame, scale: Vector3?, options: TransformOptions?): Mesh
	local scale: Vector3 = scale or Vector3.one
	assert(scale.X ~= 0 and scale.Y ~= 0 and scale.Z ~= 0, "Scale must be nonsingular")
	local mode = options and options.normals or "recalculate"
	assert(mode == "recalculate" or mode == "transform", "Unknown normals mode")
	if mode == "transform" then
		local mirrored = scale.X * scale.Y * scale.Z < 0
		local out = mesh:clone()
		for id, p in mesh.vertices do
			out.vertices[id] = frame:PointToWorldSpace(p * scale)
		end
		if mirrored then
			out = require(script.Parent.Topology).reverse(out) -- also negates corner normals
		end
		local sign = if mirrored then -1 else 1
		local rotation = frame.Rotation
		for _, f in out.faces do
			for _, c in f.corners do
				local n = c.normal
				if n then
					local m = rotation:VectorToWorldSpace(n * sign / scale)
					c.normal = if m.Magnitude > 0 then m.Unit else m
				end
				local t = c.tangent
				if t then
					local m = rotation:VectorToWorldSpace(t * scale)
					c.tangent = if m.Magnitude > 0 then m.Unit else m
				end
			end
		end
		out.revision += 1
		return out
	end
	local out = D.map(mesh, function(p: Vector3): Vector3
		return frame:PointToWorldSpace(p * scale)
	end)
	if scale.X * scale.Y * scale.Z < 0 then
		out = require(script.Parent.Topology).reverse(out)
	end
	return out
end
function D.twist(mesh: Mesh, radians: number, lo: number, hi: number, mask: Mask?): Mesh
	assert(hi > lo)
	return D.map(mesh, function(p: Vector3): Vector3
		local a = radians * (p.Y - lo) / (hi - lo)
		return Vector3.new(p.X * math.cos(a) - p.Z * math.sin(a), p.Y, p.X * math.sin(a) + p.Z * math.cos(a))
	end, mask)
end
function D.taper(mesh: Mesh, bottom: number, top: number, lo: number, hi: number, mask: Mask?): Mesh
	assert(hi > lo)
	return D.map(mesh, function(p: Vector3): Vector3
		local s = bottom + (top - bottom) * math.clamp((p.Y - lo) / (hi - lo), 0, 1)
		return Vector3.new(p.X * s, p.Y, p.Z * s)
	end, mask)
end
function D.bend(mesh: Mesh, curvature: number, mask: Mask?): Mesh
	if math.abs(curvature) < 1e-10 then
		return mesh:clone()
	end
	return D.map(mesh, function(p: Vector3): Vector3
		local a = p.Y * curvature
		local r = 1 / curvature + p.X
		return Vector3.new(math.cos(a) * r - 1 / curvature, math.sin(a) * r, p.Z)
	end, mask)
end
function D.lattice(mesh: Mesh, lo: Vector3, hi: Vector3, controls: { Vector3 }, mask: Mask?): Mesh
	assert(#controls == 8 and hi.X > lo.X and hi.Y > lo.Y and hi.Z > lo.Z)
	return D.map(mesh, function(p: Vector3): Vector3
		local t = (p - lo) / (hi - lo)
		local x, y, z = math.clamp(t.X, 0, 1), math.clamp(t.Y, 0, 1), math.clamp(t.Z, 0, 1)
		local a = controls[1]:Lerp(controls[2], x):Lerp(controls[3]:Lerp(controls[4], x), y)
		local b = controls[5]:Lerp(controls[6], x):Lerp(controls[7]:Lerp(controls[8], x), y)
		return p + a:Lerp(b, z) -- controls are displacement vectors in x-fast order
	end, mask)
end
function D.shrinkwrap(mesh: Mesh, target: Mesh, offset: number?, mask: Mask?, maxDistance: number?): Mesh
	local index = Spatial.new(target)
	return D.map(mesh, function(p: Vector3): Vector3
		local h = index:closest(p, maxDistance)
		return h and h.position + h.normal * (offset or 0) or p
	end, mask)
end
function D.contact(
	mesh: Mesh,
	field: (Vector3) -> number,
	clearance: number?,
	mask: Mask?,
	iterations: number?
): Mesh
	local clearance: number = clearance or 0
	local epsilon = 1e-4
	return D.map(mesh, function(p: Vector3): Vector3
		for _ = 1, iterations or 8 do
			local d = field(p)
			if d >= clearance - 1e-6 then
				break
			end
			local x, y, z = Vector3.xAxis * epsilon, Vector3.yAxis * epsilon, Vector3.zAxis * epsilon
			local g = Vector3.new(
				field(p + x) - field(p - x),
				field(p + y) - field(p - y),
				field(p + z) - field(p - z)
			) / (2 * epsilon)
			if g.Magnitude < 1e-10 then
				break
			end
			p += g * (clearance - d) / g:Dot(g)
		end
		return p
	end, mask)
end
function D.rbf(mesh: Mesh, handles: { Handle }, radius: number, mask: Mask?): Mesh
	assert(radius > 0 and #handles > 0)
	local n = #handles
	local matrix: { { number } } = {}
	local rhs: { Vector3 } = {}
	local function kernel(d: number): number
		local r = d / radius
		return math.exp(-r * r)
	end
	for i, h in handles do
		matrix[i] = {}
		rhs[i] = h.to - h.from
		for j, k in handles do
			matrix[i][j] = kernel((h.from - k.from).Magnitude)
		end
	end
	-- Pivoted Gaussian elimination, shared factorization for three coordinates.
	for col = 1, n do
		local pivot = col
		for row = col + 1, n do
			if math.abs(matrix[row][col]) > math.abs(matrix[pivot][col]) then
				pivot = row
			end
		end
		assert(math.abs(matrix[pivot][col]) > 1e-12, "Duplicate or ill-conditioned RBF handles")
		matrix[col], matrix[pivot] = matrix[pivot], matrix[col]
		rhs[col], rhs[pivot] = rhs[pivot], rhs[col]
		local div = matrix[col][col]
		for j = col, n do
			matrix[col][j] /= div
		end
		rhs[col] /= div
		for row = 1, n do
			if row ~= col then
				local factor = matrix[row][col]
				for j = col, n do
					matrix[row][j] -= factor * matrix[col][j]
				end
				rhs[row] -= rhs[col] * factor
			end
		end
	end
	return D.map(mesh, function(p: Vector3): Vector3
		local q = p
		for i, h in handles do
			q += rhs[i] * kernel((p - h.from).Magnitude)
		end
		return q
	end, mask)
end
-- Options for the kernels below are forwarded to non-strict modules.
function D.simple(mesh: Mesh, mode: string, amount: number, options: any?)
	return require(script.Parent.DeformOperations).simple(mesh, mode, amount, options)
end
function D.shear(mesh: Mesh, factor: number, options: any?)
	return require(script.Parent.DeformOperations).shear(mesh, factor, options)
end
function D.cast(mesh: Mesh, shape: string, options: any?)
	return require(script.Parent.DeformOperations).cast(mesh, shape, options)
end
function D.warp(mesh: Mesh, from: CFrame, to: CFrame, options: any?)
	return require(script.Parent.DeformOperations).warp(mesh, from, to, options)
end
function D.taperProfile(mesh: Mesh, profile: any, options: any?)
	return require(script.Parent.DeformOperations).taper(mesh, profile, options)
end
function D.curve(mesh: Mesh, curve: any, options: any?)
	return require(script.Parent.DeformCurve)(mesh, curve, options)
end
return D
