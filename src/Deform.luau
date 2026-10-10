--!strict
local U = require(script.Parent.Util)
local Spatial = require(script.Parent.Spatial)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Per-vertex blend weights in [0, 1], keyed by vertex id; with a mask, missing ids weigh 0 (only the
-- listed vertices move); without one, every vertex weighs 1.
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
-- View-projected relief. A view is either a CFrame (orthographic: its LookVector is the viewing
-- direction, a point's view coordinates are (x, y) in the view plane and its depth runs along the
-- look direction) or a Camera (Camera.new, a pinhole photo camera: view coordinates are the
-- camera's pixel coordinates as Camera.project gives them, y down, depth is the distance along
-- the camera's look direction, and points move along their own ray from the camera). With a
-- Camera, envelope steps and blur radii are in pixels.
export type View = CFrame | Types.Camera
export type Envelope = {
	view: View,
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
local makeEnvelope: (View, number, Vector2, number, number, { number | false }) -> Envelope
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
-- Projection and displacement for a view. project returns nil for a point at or behind a camera;
-- move takes a point from its depth to another depth (along the look direction, or along the
-- point's ray from a camera); toward is that direction of motion (away from the viewer).
type Projector = {
	perspective: boolean,
	project: (Vector3) -> (Vector2?, number),
	move: (Vector3, number, number) -> Vector3,
	toward: (Vector3) -> Vector3,
}
local function projector(view: View): Projector
	if typeof(view) == "CFrame" then
		local frame = view :: CFrame
		local look = frame.LookVector
		return {
			perspective = false,
			project = function(p: Vector3): (Vector2?, number)
				local q = frame:PointToObjectSpace(p)
				return Vector2.new(q.X, q.Y), -q.Z
			end,
			move = function(p: Vector3, depth: number, goal: number): Vector3
				return p + look * (goal - depth)
			end,
			toward = function(_: Vector3): Vector3
				return look
			end,
		}
	end
	local camera = view :: Types.Camera
	assert(
		type(camera) == "table" and typeof(camera.frame) == "CFrame" and type(camera.fov) == "number",
		"View must be a CFrame or a Camera"
	)
	local frame, centre, principal = camera.frame, camera.frame.Position, camera.principal
	local focal = camera.height / (2 * math.tan(math.rad(camera.fov) / 2))
	return {
		perspective = true,
		project = function(p: Vector3): (Vector2?, number)
			local q = frame:PointToObjectSpace(p)
			local depth = -q.Z
			if depth <= 1e-6 then
				return nil, depth
			end
			return principal + Vector2.new(q.X, -q.Y) * (focal / depth), depth
		end,
		move = function(p: Vector3, depth: number, goal: number): Vector3
			return centre + (p - centre) * (goal / depth)
		end,
		toward = function(p: Vector3): Vector3
			return (p - centre).Unit
		end,
	}
end
-- Default envelope step: 0.25 studs, or for a camera the pixel size of 0.25 studs at the meshes'
-- mean depth.
local function defaultStep(view: View, meshes: { Mesh }, studs: number): number
	if typeof(view) == "CFrame" then
		return studs
	end
	local camera = view :: Types.Camera
	local proj = projector(view)
	local sum, n = 0, 0
	for _, mesh in meshes do
		for _, v in mesh.vertices do
			local q, depth = proj.project(v)
			if q then
				sum += depth
				n += 1
			end
		end
	end
	assert(n > 0, "Nothing in front of the camera")
	local focal = camera.height / (2 * math.tan(math.rad(camera.fov) / 2))
	return studs * focal / (sum / n)
end
local function meshList(meshes: Mesh | { Mesh }): { Mesh }
	if (meshes :: any).vertices ~= nil then
		return { meshes :: Mesh }
	end
	return meshes :: { Mesh }
end
-- Front envelope of a mesh, or of several meshes together (pass a list: each occludes the
-- others, as the parts of a model do), seen from `view`: the smallest depth at each cell centre of
-- a `step`-sized grid, rasterized from the triangles (any tessellation, soups included; with a
-- camera, depth is interpolated perspective-correctly and faces reaching behind it are skipped).
-- Sample it bilinearly with envelope:sample(Vector2); envelope:blurred(radius) low-passes it.
-- fill (default 0): passes of hole filling. A step finer than the mesh's triangles leaves empty
-- cells between rasterized ones; each pass fills empty cells that have filled 4-neighbours on
-- both sides along a row or a column (average of the filled 4-neighbours), so holes inside the
-- surface close while the silhouette stays where it is.
function D.envelope(meshes: Mesh | { Mesh }, view: View, step: number, fill: number?): Envelope
	assert(step > 0, "Envelope step must be positive")
	local list = meshList(meshes)
	local proj = projector(view)
	local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for _, mesh in list do
		for _, v in mesh.vertices do
			local q = proj.project(v)
			if q then
				lo, hi = lo:Min(q), hi:Max(q)
			end
		end
	end
	assert(lo.X <= hi.X, "Envelope needs vertices")
	local origin = lo - Vector2.one * step
	local width = math.floor((hi.X - origin.X) / step) + 3
	local height = math.floor((hi.Y - origin.Y) / step) + 3
	local raw: { number } = table.create(width * height, math.huge)
	local perspective = proj.perspective
	for _, mesh in list do
		for _, f in mesh.faces do
			local q: { Vector2 }, d: { number } = {}, {}
			local visible = true
			for i, v in f.vertices do
				local qi, di = proj.project(mesh.vertices[v])
				if not qi then
					visible = false
					break
				end
				q[i], d[i] = qi, di
			end
			for t = 2, if visible then #q - 1 else 0 do
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
								-- with a camera, inverse depth is what varies linearly across the image
								local depth = if perspective
									then 1 / ((1 - v - w) / d[1] + v / d[t] + w / d[t + 1])
									else d[1] * (1 - v - w) + d[t] * v + d[t + 1] * w
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
	end
	local depth: { number | false } = table.create(width * height, false :: number | false)
	for k, value in raw do
		if value < math.huge then
			depth[k] = value
		end
	end
	for _ = 1, fill or 0 do
		local updates: { [number]: number } = {}
		for j = 0, height - 1 do
			for i = 0, width - 1 do
				local k = j * width + i + 1
				if depth[k] == false then
					local l = i > 0 and depth[k - 1] or false
					local r = i < width - 1 and depth[k + 1] or false
					local d = j > 0 and depth[k - width] or false
					local u = j < height - 1 and depth[k + width] or false
					if (l ~= false and r ~= false) or (d ~= false and u ~= false) then
						local sum, n = 0, 0
						for _, x in { l, r, d, u } do
							if x ~= false then
								sum += x :: number
								n += 1
							end
						end
						updates[k] = sum / n
					end
				end
			end
		end
		if next(updates) == nil then
			break
		end
		for k, x in updates do
			depth[k] = x
		end
	end
	return makeEnvelope(view, step, origin, width, height, depth)
end
-- alpha: fraction of the existing relief below the envelope that survives (0 replaces it).
-- depth: vertices deeper than this below the envelope keep their place (fading over `fade`).
-- minFacing: vertices must face the view this much (dot of normal with the direction toward the
-- viewer) to move. step: grid step of the envelope built when none is given (default 0.25 studs;
-- with a camera, the pixel size of 0.25 studs at the mesh's mean depth).
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
-- Moves the visible front layer of a mesh, along the view direction (with a camera, along each
-- point's ray), onto target(point, envelopeDepth) -> depth (nil leaves that point alone). A vertex at depth b below the envelope
-- goes to target + alpha * b, so existing folds are compressed and the target relief imposed,
-- while the back, the sides and deep fold-unders stay put. Use it to transfer relief measured
-- from a photo (depth maps, height fields) onto a sculpt seen from the same direction; with the
-- photo's Camera as the view, target receives the photo's pixel coordinates. For a model made of
-- several meshes, pass options.envelope = Deform.envelope({ ...all meshes }, view, step) so parts
-- hidden behind other parts stay put.
function D.relief(mesh: Mesh, view: View, target: (Vector2, number) -> number?, options: ReliefOptions?): Mesh
	local o: ReliefOptions = options or {}
	local alpha, maxDepth, fade = o.alpha or 0.2, o.depth or 2.5, o.fade or 1.5
	local minFacing = o.minFacing or 0.15
	assert(alpha >= 0 and maxDepth >= 0 and fade > 0, "Invalid relief options")
	local env = o.envelope or D.envelope(mesh, view, o.step or defaultStep(view, { mesh }, 0.25), 3)
	local proj = projector(view)
	-- Facing is gathered per position, not per vertex id: in a triangle soup (meshes read back from
	-- Roblox) every corner is its own vertex, and per-id weights would move coincident corners by
	-- different amounts and crack the surface open.
	local function positionKey(p: Vector3): string
		return string.format("%.5f,%.5f,%.5f", p.X, p.Y, p.Z)
	end
	local facingAt: { [string]: number } = {}
	for fid, f in mesh.faces do
		local normal = mesh:faceNormal(fid)
		for i, v in f.vertices do
			local n = f.corners[i].normal or normal
			local p = mesh.vertices[v]
			local k = positionKey(p)
			facingAt[k] = math.max(facingAt[k] or -1, -(n :: Vector3):Dot(proj.toward(p)))
		end
	end
	local facing: { [number]: number } = {}
	for id, v in mesh.vertices do
		facing[id] = facingAt[positionKey(v)]
	end
	local function smoothstep(e0: number, e1: number, x: number): number
		local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
		return t * t * (3 - 2 * t)
	end
	local out = mesh:clone()
	for id, v in mesh.vertices do
		local q, depth = proj.project(v)
		local front = q and env:sample(q)
		if q and front then
			local below = math.max(0, depth - front)
			local w = smoothstep(minFacing, minFacing + 0.4, facing[id] or -1)
				* (1 - smoothstep(maxDepth, maxDepth + fade, below))
			if w > 1e-4 then
				local goal = target(q, front)
				if goal then
					out.vertices[id] = proj.move(v, depth, depth + (goal + alpha * below - depth) * w)
				end
			end
		end
	end
	if o.normals == false then
		return out
	end
	return out:recalculateNormals()
end
export type EdgeOptions = {
	height: number?,
	width: number?,
	drop: number?,
	dropWidth: number?,
	layer: number?,
	envelope: Envelope?,
	step: number?,
	profile: string?,
	radius: number?,
}
-- Raises a crisp layer edge (a cloth hem, the border of an overlapping sheet) along a polyline
-- given in view coordinates (Vector2, as Deform.relief's q). The side to the LEFT of the polyline
-- direction is the upper layer: it is pushed toward the viewer by height * exp(-(d/width)^2), a
-- rounded lip; the right side is pushed back by drop, fading over dropWidth, so a step forms
-- at the line. Only the front layer moves (vertices within `layer` of the view envelope), and the
-- offset depends on position alone, so coincident corners in soups move together. Beyond the
-- polyline's ends nothing moves. Returns the mesh with normals recalculated (pass the result
-- through Normals.unify for soups).
-- profile = "roll" (with radius R, default 1) makes the upper side a rounded roll of cloth instead
-- of a lip: a quarter circle rising from the line to `height` at distance R, then easing back to the
-- surface over about 1.2 R (a swag or a rolled hem whose lower edge is the polyline).
-- profile = "softroll" rises as a half cosine instead (zero slope at the line): a quarter circle stands
-- vertical at its edge, so a tall roll seen edge-on from the side makes the silhouette ragged.
-- profile = "groove" cuts a symmetric valley of depth `height` and half-width `width` along the line
-- (a fold line drawn in an elevation; no layer step, both sides move).
function D.edge(mesh: Mesh, view: View, polyline: { Vector2 }, options: EdgeOptions?): Mesh
	local o: EdgeOptions = table.clone(options or {})
	o.envelope = o.envelope or D.envelope(mesh, view, o.step or defaultStep(view, { mesh }, 0.2), 3)
	return D.map(mesh, D.edgeField(view, polyline, o))
end
-- The position map behind Deform.edge, for deformers that work one position at a time
-- (Roblox.reshape's map, Deform.map over several parts): field(position) -> moved position. It
-- needs the view envelope of all the surfaces being edited (options.envelope, for example
-- Deform.envelope({ ...meshes }, view, step, 3)), so the layer test sees every part at once.
function D.edgeField(view: View, polyline: { Vector2 }, options: EdgeOptions): (Vector3) -> Vector3
	assert(#polyline >= 2, "Edge needs a polyline")
	local o: EdgeOptions = options
	local env = assert(o.envelope, "edgeField needs options.envelope")
	local height, width = o.height or 0.3, o.width or 0.7
	local drop, dropWidth = o.drop or 0.2, o.dropWidth or 0.5
	local layer = o.layer or 0.9
	local roll = o.profile == "roll"
	local softroll = o.profile == "softroll"
	local groove = o.profile == "groove"
	assert(
		o.profile == nil or o.profile == "lip" or roll or softroll or groove,
		'edge profile must be "lip", "roll", "softroll" or "groove"'
	)
	local radius = o.radius or 1
	assert(radius > 0, "edge radius must be positive")
	local proj = projector(view)
	local function smoothstep(e0: number, e1: number, x: number): number
		local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
		return t * t * (3 - 2 * t)
	end
	local function signedDistance(q: Vector2): number?
		local best, signed: number? = math.huge, nil
		for i = 1, #polyline - 1 do
			local a, b = polyline[i], polyline[i + 1]
			local ab = b - a
			local t = (q - a):Dot(ab) / ab:Dot(ab)
			local c = a + ab * math.clamp(t, 0, 1)
			local d = (q - c).Magnitude
			if d < best then
				best = d
				local inside = (i > 1 or t >= 0) and (i < #polyline - 1 or t <= 1)
				-- left of the direction a -> b is positive
				local cross = ab.X * (q - a).Y - ab.Y * (q - a).X
				signed = if inside then (if cross >= 0 then d else -d) else nil
			end
		end
		return signed
	end
	return function(p: Vector3): Vector3
		local q, depth = proj.project(p)
		local d = q and signedDistance(q)
		if not q or not d then
			return p
		end
		local front = env:sample(q)
		if not front then
			return p
		end
		local w = 1 - smoothstep(layer * 0.4, layer, depth - front)
		if w <= 0 then
			return p
		end
		if groove then
			return p + proj.toward(p) * (height * math.exp(-(d / width) ^ 2) * w)
		end
		local up: number
		if d < 0 then
			up = 0
		elseif roll then
			up = if d <= radius
				then height * math.sqrt(math.max(0, 1 - ((d - radius) / radius) ^ 2))
				else height * math.exp(-((d - radius) / (1.2 * radius)) ^ 2)
		elseif softroll then
			up = if d <= radius
				then height * (0.5 - 0.5 * math.cos(math.pi * d / radius))
				else height * math.exp(-((d - radius) / (1.2 * radius)) ^ 2)
		else
			up = height * math.exp(-(d / width) ^ 2)
		end
		local offset = if d >= 0 then -up else drop * (1 - smoothstep(0, dropWidth, -d))
		return p + proj.toward(p) * (offset * w)
	end
end
-- A position map from a table of per-vertex moves computed elsewhere (offline relaxation, repair or
-- fitting passes on exported geometry): moves[i] = { x, y, z, dx, dy, dz } moves a vertex found at
-- (x, y, z) by (dx, dy, dz); a flat list { x1, y1, z1, dx1, dy1, dz1, x2, ... } (as decoded from a large
-- JSON array, without a table per move) works too. Positions are matched in a hash of `cell` (default
-- 0.01) within `tolerance` (default 0.003) per axis, so every split copy of a vertex (UV seams, soups,
-- chunked parts) moves with it; unmatched positions pass through. Only the cells the tolerance box
-- reaches are probed (usually one). Returns the field and a live stats table { size, hits }. Use it as
-- Roblox.reshape's map to apply corrections without re-deriving them in Luau (with changedOnly, so
-- chunks the table never touches are not rebuilt).
export type MoveTableOptions = { cell: number?, tolerance: number? }
function D.moveTable(
	moves: { any },
	options: MoveTableOptions?
): ((Vector3) -> Vector3, { size: number, hits: number })
	local o: MoveTableOptions = options or {}
	local cell = o.cell or 0.01
	local tol = o.tolerance or 0.003
	assert(cell > 0 and tol >= 0 and tol < cell, "moveTable needs 0 <= tolerance < cell")
	-- numeric cell keys: a collision only adds candidates, since every candidate's distance is checked
	local function key(x: number, y: number, z: number): number
		return x * 73856093 + y * 19349663 + z * 83492791
	end
	local hash: { [number]: { number } } = {}
	local entries: { number } = {}
	local function add(x: number, y: number, z: number, dx: number, dy: number, dz: number)
		local n = #entries
		entries[n + 1], entries[n + 2], entries[n + 3] = x, y, z
		entries[n + 4], entries[n + 5], entries[n + 6] = dx, dy, dz
		local k = key(math.floor(x / cell), math.floor(y / cell), math.floor(z / cell))
		local list = hash[k]
		if not list then
			list = {}
			hash[k] = list
		end
		table.insert(list, n + 1)
	end
	local size = 0
	if type(moves[1]) == "number" then
		assert(#moves % 6 == 0, "a flat moveTable has six numbers per move")
		for i = 1, #moves, 6 do
			add(moves[i], moves[i + 1], moves[i + 2], moves[i + 3], moves[i + 4], moves[i + 5])
		end
		size = #moves // 6
	else
		for _, m in moves do
			assert(#m >= 6, "moveTable entries are { x, y, z, dx, dy, dz }")
			add(m[1], m[2], m[3], m[4], m[5], m[6])
		end
		size = #moves
	end
	local stats = { size = size, hits = 0 }
	-- the neighbouring cells along one axis that a box of half-width tol around v reaches
	local function span(v: number): (number, number)
		local c = math.floor(v / cell)
		local lo = if v - c * cell < tol then c - 1 else c
		local hi = if (c + 1) * cell - v <= tol then c + 1 else c
		return lo, hi
	end
	local function field(p: Vector3): Vector3
		local x0, x1 = span(p.X)
		local y0, y1 = span(p.Y)
		local z0, z1 = span(p.Z)
		for cx = x0, x1 do
			for cy = y0, y1 do
				for cz = z0, z1 do
					local list = hash[key(cx, cy, cz)]
					if list then
						for _, i in list do
							if
								math.abs(entries[i] - p.X) <= tol
								and math.abs(entries[i + 1] - p.Y) <= tol
								and math.abs(entries[i + 2] - p.Z) <= tol
							then
								stats.hits += 1
								return Vector3.new(
									p.X + entries[i + 3],
									p.Y + entries[i + 4],
									p.Z + entries[i + 5]
								)
							end
						end
					end
				end
			end
		end
		return p
	end
	return field, stats
end
-- Thickens or thins elongated pieces (rays, spikes, petals, fingers) independently: every
-- connected component (welded within weld, default 1e-4) gets its principal axis, its base is the
-- end nearer `anchor`, and points are scaled about the axis by baseScale at the base blending
-- linearly to tipScale at the tip. Works on soups (components come from a welded copy; the
-- returned mesh keeps the input's topology, corners and UVs).
function D.taperComponents(
	mesh: Mesh,
	anchor: Vector3,
	baseScale: number,
	tipScale: number?,
	weld: number?
): Mesh
	local Topology = require(script.Parent.Topology) :: any
	local Geometry = require(script.Parent.Geometry) :: any
	local welded = Topology.weld(mesh, weld or 1e-4)
	local pieces = Topology.components(welded)
	local tip = tipScale or 1
	local rays = {}
	for _, piece in pieces do
		local pa = Geometry.principalAxes(piece)
		local axis = pa.axes[1]
		local lo, hi = math.huge, -math.huge
		for _, v in piece.vertices do
			local t = (v - pa.center):Dot(axis)
			lo, hi = math.min(lo, t), math.max(hi, t)
		end
		local baseT = if (anchor - pa.center):Dot(axis) < 0 then lo else hi
		local tipT = if baseT == lo then hi else lo
		table.insert(rays, { c = pa.center, a = axis, base = baseT, tip = tipT })
	end
	return D.map(mesh, function(v: Vector3): Vector3
		local best, ray = math.huge, nil
		for _, r in rays do
			local d = v - r.c
			local radial = (d - r.a * d:Dot(r.a)).Magnitude
			local along = d:Dot(r.a)
			local outside = math.max(0, math.min(r.base, r.tip) - along, along - math.max(r.base, r.tip))
			local score = radial + outside
			if score < best then
				best, ray = score, r
			end
		end
		if not ray then
			return v
		end
		local t = (v - ray.c):Dot(ray.a)
		local u = if ray.tip ~= ray.base then math.clamp((t - ray.base) / (ray.tip - ray.base), 0, 1) else 0
		local k = baseScale + (tip - baseScale) * u
		local axial = ray.c + ray.a * t
		return axial + (v - axial) * k
	end)
end
export type SectionScaleOptions = {
	mask: Mask?,
	blend: number?,
}
-- Scales every section of a mesh along one direction, separately on either side of a per-height
-- centre. In frame coordinates (height = local Y, the scaled axis = local Z; CFrame.identity scales
-- world Z per world height), section(height) -> (centre, below, above) gives the centre on that axis
-- and the scales for points with z < centre (below) and z > centre (above); nil leaves the height
-- alone. Positions alone decide the result, so soups stay closed. blend (studs along the axis,
-- default 0) moves from one scale to the other over centre +- blend instead of switching at the
-- centre. Use it to fit a figure's front and back profiles to measured side elevations
-- independently; fade the scales to 1 where the fit should stop.
function D.sectionScale(
	mesh: Mesh,
	frame: CFrame,
	section: (number) -> (number?, number?, number?),
	options: SectionScaleOptions?
): Mesh
	local o: SectionScaleOptions = options or {}
	return D.map(mesh, D.sectionScaleMap(frame, section, o.blend), o.mask)
end
-- The point map of Deform.sectionScale, for Roblox.reshape (published parts) or Deform.map: positions are scaled
-- about the per-height centre along the frame's local Z, with the same section(height) -> (centre, below, above)
-- rule and blend. A band of a figure widened or slimmed by a height bump (a neck, a waist) is
-- sectionScaleMap(CFrame.fromMatrix(Vector3.zero, Vector3.zAxis, Vector3.yAxis), function(y) return 0, k(y), k(y) end):
-- local Z then runs along world -X, so world x scales by k(y) about x = 0.
function D.sectionScaleMap(
	frame: CFrame,
	section: (number) -> (number?, number?, number?),
	blend: number?
): (Vector3) -> Vector3
	local b = blend or 0
	assert(b >= 0, "Section blend must be nonnegative")
	return function(p: Vector3): Vector3
		local q = frame:PointToObjectSpace(p)
		local centre, below, above = section(q.Y)
		if centre == nil then
			return p
		end
		local c, sBelow, sAbove = centre :: number, below or 1, above or 1
		assert(U.finite(c) and U.finite(sBelow) and U.finite(sAbove), "Section returned invalid values")
		local scale
		if b > 0 then
			local t = math.clamp((q.Z - c + b) / (2 * b), 0, 1)
			scale = sBelow + (sAbove - sBelow) * t * t * (3 - 2 * t)
		else
			scale = if q.Z < c then sBelow else sAbove
		end
		return frame:PointToWorldSpace(Vector3.new(q.X, q.Y, c + (q.Z - c) * scale))
	end
end
-- A point map in cylindrical coordinates about a frame's local Y axis, for Roblox.reshape or Deform.map: each point's
-- radius r from the axis, angle phi round it (degrees, 0 toward the frame's +X, 90 toward its -Z, in (-180, 180]) and
-- height h along it go through fn(r, phi, h) -> (r', phi', h') (nil for any keeps it). Squeezing pieces toward a
-- handle over an angular sector, swelling a sleeve toward one side, lifting a band of cloth round a waist or twisting
-- a column are each a few lines. Points on the axis (r < 1e-9) keep their angle at 0.
function D.cylindricalMap(
	frame: CFrame,
	fn: (number, number, number) -> (number?, number?, number?)
): (Vector3) -> Vector3
	return function(p: Vector3): Vector3
		local q = frame:PointToObjectSpace(p)
		local r = math.sqrt(q.X * q.X + q.Z * q.Z)
		local phi = if r < 1e-9 then 0 else math.deg(math.atan2(-q.Z, q.X))
		local r2, phi2, h2 = fn(r, phi, q.Y)
		r2, phi2, h2 = r2 or r, phi2 or phi, h2 or q.Y
		assert(U.finite(r2) and U.finite(phi2) and U.finite(h2), "cylindricalMap returned invalid values")
		local a = math.rad(phi2)
		return frame:PointToWorldSpace(Vector3.new(r2 * math.cos(a), h2, -r2 * math.sin(a)))
	end
end
export type SmoothDisplacementOptions = {
	sigma: number?,
	reach: number?,
}
-- Smooths a per-position displacement rule over the surface neighbourhood, across several meshes at
-- once (the parts of one model, so seams between parts stay closed). displace(position) -> Vector3 is
-- evaluated once per distinct position (coincident corners of soups count once); the returned
-- field(position) -> Vector3 is the Gaussian-weighted mean (sigma, default 0.5 studs, over
-- neighbours within reach, default 3 sigma) of the displacements around that position. Use it when
-- a per-point rule (pushing points out of a primitive, clamping to a clearance) would flatten or
-- crease detail: relief finer than sigma rides along instead of being ironed out. Pass the field to
-- Deform.map or Roblox.reshape as p + field(p).
function D.smoothDisplacement(
	meshes: Mesh | { Mesh },
	displace: (Vector3) -> Vector3,
	options: SmoothDisplacementOptions?
): (Vector3) -> Vector3
	local o: SmoothDisplacementOptions = options or {}
	local sigma = o.sigma or 0.5
	local reach = o.reach or 3 * sigma
	assert(sigma > 0 and reach > 0, "Invalid smoothing options")
	local function key(p: Vector3): string
		return string.format("%.5f,%.5f,%.5f", p.X, p.Y, p.Z)
	end
	local function cellOf(p: Vector3): (number, number, number)
		return math.floor(p.X / reach), math.floor(p.Y / reach), math.floor(p.Z / reach)
	end
	local seen: { [string]: boolean } = {}
	local cells: { [string]: { { position: Vector3, value: Vector3 } } } = {}
	local any = false
	for _, mesh in meshList(meshes) do
		for _, v in mesh.vertices do
			local k = key(v)
			if not seen[k] then
				seen[k] = true
				local d = displace(v)
				assert(U.vector(d), "Displacement must be a finite Vector3")
				local i, j, l = cellOf(v)
				local ck = i .. "," .. j .. "," .. l
				local list = cells[ck]
				if not list then
					list = {}
					cells[ck] = list
				end
				table.insert(list, { position = v, value = d })
				if d.Magnitude > 0 then
					any = true
				end
			end
		end
	end
	local cache: { [string]: Vector3 } = {}
	local twoSigma2 = 2 * sigma * sigma
	return function(p: Vector3): Vector3
		if not any then
			return Vector3.zero
		end
		local k = key(p)
		local hit = cache[k]
		if hit then
			return hit
		end
		local ci, cj, cl = cellOf(p)
		local sum, weight, moving = Vector3.zero, 0, false
		for i = ci - 1, ci + 1 do
			for j = cj - 1, cj + 1 do
				for l = cl - 1, cl + 1 do
					local list = cells[i .. "," .. j .. "," .. l]
					if list then
						for _, e in list do
							local d2 = (e.position - p):Dot(e.position - p)
							if d2 <= reach * reach then
								local w = math.exp(-d2 / twoSigma2)
								sum += e.value * w
								weight += w
								if e.value.Magnitude > 0 then
									moving = true
								end
							end
						end
					end
				end
			end
		end
		local result = if moving and weight > 0 then sum / weight else Vector3.zero
		cache[k] = result
		return result
	end
end
return D
