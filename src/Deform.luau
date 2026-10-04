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
-- View-projected relief. A view is a CFrame whose LookVector is the viewing direction; a point's
-- view coordinates are (x, y) in the view plane and depth along the look direction.
export type Envelope = {
	view: CFrame,
	step: number,
	origin: Vector2,
	width: number,
	height: number,
	-- frontmost depth per cell centre (row-major, false where nothing is visible)
	depth: { number | false },
	sample: (Envelope, Vector2) -> number?,
	blurred: (Envelope, number) -> Envelope,
}
local envelopeMethods = {}
function envelopeMethods.sample(self: Envelope, p: Vector2): number?
	local fx, fy = (p.X - self.origin.X) / self.step - 0.5, (p.Y - self.origin.Y) / self.step - 0.5
	local i, j = math.floor(fx), math.floor(fy)
	if i < 0 or j < 0 or i >= self.width - 1 or j >= self.height - 1 then
		return nil
	end
	local tx, ty = fx - i, fy - j
	local a = self.depth[j * self.width + i + 1]
	local b = self.depth[j * self.width + i + 2]
	local c = self.depth[(j + 1) * self.width + i + 1]
	local d = self.depth[(j + 1) * self.width + i + 2]
	if a == false or b == false or c == false or d == false then
		return nil
	end
	local a, b, c, d = a :: number, b :: number, c :: number, d :: number
	return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
end
local makeEnvelope: (CFrame, number, Vector2, number, number, { number | false }) -> Envelope
-- Gaussian low-pass of the envelope (radius = standard deviation in studs), normalized over the
-- visible cells so silhouettes do not bleed. Use it as the smooth base when replacing relief.
function envelopeMethods.blurred(self: Envelope, radius: number): Envelope
	assert(radius > 0, "Blur radius must be positive")
	local sigma = radius / self.step
	local reach = math.ceil(sigma * 3)
	local kernel = {}
	for k = -reach, reach do
		kernel[k] = math.exp(-0.5 * (k / sigma) ^ 2)
	end
	local w, h = self.width, self.height
	local function pass(
		values: { number },
		weights: { number },
		horizontal: boolean
	): ({ number }, { number })
		local v2, w2 = table.create(w * h, 0), table.create(w * h, 0)
		for j = 0, h - 1 do
			for i = 0, w - 1 do
				local sv, sw = 0, 0
				for k = -reach, reach do
					local a, b = if horizontal then i + k else i, if horizontal then j else j + k
					if a >= 0 and b >= 0 and a < w and b < h then
						local idx = b * w + a + 1
						sv += values[idx] * kernel[k]
						sw += weights[idx] * kernel[k]
					end
				end
				v2[j * w + i + 1], w2[j * w + i + 1] = sv, sw
			end
		end
		return v2, w2
	end
	local values, weights = table.create(w * h, 0), table.create(w * h, 0)
	for k, d in self.depth do
		if d ~= false then
			values[k], weights[k] = d :: number, 1
		end
	end
	values, weights = pass(values, weights, true)
	values, weights = pass(values, weights, false)
	local depth: { number | false } = table.create(w * h, false :: number | false)
	for k, d in self.depth do
		if d ~= false and weights[k] > 1e-9 then
			depth[k] = values[k] / weights[k]
		end
	end
	return makeEnvelope(self.view, self.step, self.origin, w, h, depth)
end
makeEnvelope = function(view, step, origin, width, height, depth)
	return {
		view = view,
		step = step,
		origin = origin,
		width = width,
		height = height,
		depth = depth,
		sample = envelopeMethods.sample,
		blurred = envelopeMethods.blurred,
	}
end
local function viewCoordinates(view: CFrame, p: Vector3): (Vector2, number)
	local q = view:PointToObjectSpace(p)
	return Vector2.new(q.X, q.Y), -q.Z
end
-- Front envelope of a mesh seen from `view`: the smallest depth at each cell centre of a
-- `step`-sized grid, rasterized from the mesh's triangles (any tessellation, soups included).
-- Sample it bilinearly with envelope:sample(Vector2); envelope:blurred(radius) low-passes it.
function D.envelope(mesh: Mesh, view: CFrame, step: number): Envelope
	assert(step > 0, "Envelope step must be positive")
	local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for _, v in mesh.vertices do
		local q = viewCoordinates(view, v)
		lo, hi = lo:Min(q), hi:Max(q)
	end
	assert(lo.X <= hi.X, "Envelope needs vertices")
	local origin = lo - Vector2.one * step
	local width = math.floor((hi.X - origin.X) / step) + 3
	local height = math.floor((hi.Y - origin.Y) / step) + 3
	local raw: { number } = table.create(width * height, math.huge)
	for _, f in mesh.faces do
		local q: { Vector2 }, d: { number } = {}, {}
		for i, v in f.vertices do
			q[i], d[i] = viewCoordinates(view, mesh.vertices[v])
		end
		for t = 2, #q - 1 do
			local a, b, c = q[1], q[t], q[t + 1]
			local e1, e2 = b - a, c - a
			local den = e1.X * e2.Y - e1.Y * e2.X
			if math.abs(den) > 1e-12 then
				local mn, mx = a:Min(b):Min(c), a:Max(b):Max(c)
				local i0 = math.max(0, math.ceil((mn.X - origin.X) / step - 0.5))
				local i1 = math.min(width - 1, math.floor((mx.X - origin.X) / step - 0.5))
				local j0 = math.max(0, math.ceil((mn.Y - origin.Y) / step - 0.5))
				local j1 = math.min(height - 1, math.floor((mx.Y - origin.Y) / step - 0.5))
				for j = j0, j1 do
					for i = i0, i1 do
						local p = origin + Vector2.new((i + 0.5) * step, (j + 0.5) * step) - a
						local v = (p.X * e2.Y - p.Y * e2.X) / den
						local w = (e1.X * p.Y - e1.Y * p.X) / den
						if v >= -1e-9 and w >= -1e-9 and v + w <= 1 + 1e-9 then
							local depth = d[1] * (1 - v - w) + d[t] * v + d[t + 1] * w
							local k = j * width + i + 1
							if depth < raw[k] then
								raw[k] = depth
							end
						end
					end
				end
			end
		end
	end
	local depth: { number | false } = table.create(width * height, false :: number | false)
	for k, value in raw do
		if value < math.huge then
			depth[k] = value
		end
	end
	return makeEnvelope(view, step, origin, width, height, depth)
end
-- alpha: fraction of the existing relief below the envelope that survives (0 replaces it).
-- depth: vertices deeper than this below the envelope keep their place (fading over `fade`).
-- minFacing: vertices must face the view this much (dot of normal with -look) to move.
export type ReliefOptions = {
	-- false keeps corner normals (call Normals.unify for meshes read back from Roblox)
	normals: boolean?,
	alpha: number?,
	depth: number?,
	fade: number?,
	minFacing: number?,
	envelope: Envelope?,
	step: number?,
}
-- Moves the visible front layer of a mesh, along the view direction, onto target(point,
-- envelopeDepth) -> depth (nil leaves that point alone). A vertex at depth b below the envelope
-- goes to target + alpha * b, so existing folds are compressed and the target relief imposed,
-- while the back, the sides and deep fold-unders stay put. Use it to transfer relief measured
-- from a photo (depth maps, height fields) onto a sculpt seen from the same direction.
function D.relief(
	mesh: Mesh,
	view: CFrame,
	target: (Vector2, number) -> number?,
	options: ReliefOptions?
): Mesh
	local o: ReliefOptions = options or {}
	local alpha, maxDepth, fade = o.alpha or 0.2, o.depth or 2.5, o.fade or 1.5
	local minFacing = o.minFacing or 0.15
	assert(alpha >= 0 and maxDepth >= 0 and fade > 0, "Invalid relief options")
	local env = o.envelope or D.envelope(mesh, view, o.step or 0.25)
	local look = view.LookVector
	local facing: { [number]: number } = {}
	for fid, f in mesh.faces do
		local normal = mesh:faceNormal(fid)
		for i, v in f.vertices do
			local n = f.corners[i].normal or normal
			facing[v] = math.max(facing[v] or -1, -(n :: Vector3):Dot(look))
		end
	end
	local function smoothstep(e0: number, e1: number, x: number): number
		local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
		return t * t * (3 - 2 * t)
	end
	local out = mesh:clone()
	for id, v in mesh.vertices do
		local q, depth = viewCoordinates(view, v)
		local front = env:sample(q)
		if front then
			local below = math.max(0, depth - front)
			local w = smoothstep(minFacing, minFacing + 0.4, facing[id] or -1)
				* (1 - smoothstep(maxDepth, maxDepth + fade, below))
			if w > 1e-4 then
				local goal = target(q, front)
				if goal then
					out.vertices[id] = v + look * ((goal + alpha * below - depth) * w)
				end
			end
		end
	end
	if o.normals == false then
		return out
	end
	return out:recalculateNormals()
end
return D
