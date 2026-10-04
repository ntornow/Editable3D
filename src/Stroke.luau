--!strict
-- Continuous polyline distance fields for masked surface strokes and cloth folds.
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
type Segment = { a: Vector3, b: Vector3, delta: Vector3, length: number, arc: number, index: number }
type Node = { lo: Vector3, hi: Vector3, segments: { Segment }?, left: Node?, right: Node? }
export type Hit = {
	position: Vector3,
	distance: number,
	arc: number,
	fraction: number,
	tangent: Vector3,
	segment: number,
	t: number,
	signedDistance: number?,
}
-- Custom profiles receive the normalized distance and the closest-point hit.
export type ProfileFunction = (number, Hit) -> number
export type FieldOptions = {
	radius: number?,
	width: ((fraction: number) -> number)?,
	amplitude: ((fraction: number) -> number)?,
	fadeStart: number?,
	fadeEnd: number?,
	signedProfile: boolean?,
	profile: (string | ProfileFunction)?,
}
export type SculptOptions = FieldOptions & {
	height: number?,
	direction: (Vector3 | (position: Vector3, id: number) -> Vector3)?,
	mask: { [number]: number }?,
	normalAngle: number?,
}
export type SculptReport = { affectedVertices: number, maxDisplacement: number }
type PathData = { segments: { Segment }, length: number, closed: boolean, tree: Node }
local S = {}
local Path = {}
Path.__index = Path
export type Path = typeof(setmetatable({} :: PathData, Path))
local function distanceBox(p: Vector3, lo: Vector3, hi: Vector3): number
	local q =
		Vector3.new(math.clamp(p.X, lo.X, hi.X), math.clamp(p.Y, lo.Y, hi.Y), math.clamp(p.Z, lo.Z, hi.Z))
	return (p - q):Dot(p - q)
end
local function build(segments: { Segment }): Node
	local lo, hi = Vector3.one * math.huge, Vector3.one * -math.huge
	for _, s in segments do
		lo = lo:Min(s.a):Min(s.b)
		hi = hi:Max(s.a):Max(s.b)
	end
	local node: Node = { lo = lo, hi = hi }
	if #segments <= 8 then
		node.segments = segments
		return node
	end
	local span = hi - lo
	local axis = span.X >= span.Y and span.X >= span.Z and "X" or (span.Y >= span.Z and "Y" or "Z")
	table.sort(segments, function(a, b)
		return (a.a :: any)[axis] + (a.b :: any)[axis] < (b.a :: any)[axis] + (b.b :: any)[axis]
	end)
	local a, b = {}, {}
	for i, s in segments do
		table.insert(i <= #segments / 2 and a or b, s)
	end
	node.left, node.right = build(a), build(b)
	return node
end
function S.path(points: { Vector3 }, closed: boolean?): Path
	assert(#points >= 2, "Stroke path needs at least two points")
	points = table.clone(points)
	for _, p in points do
		assert(U.vector(p), "Nonfinite path point")
	end
	if closed and (points[1] - points[#points]).Magnitude > 1e-10 then
		table.insert(points, points[1])
	end
	local segments: { Segment }, length = {}, 0
	for i = 1, #points - 1 do
		local delta = points[i + 1] - points[i]
		local size = delta.Magnitude
		if size > 1e-10 then
			table.insert(
				segments,
				{ a = points[i], b = points[i + 1], delta = delta, length = size, arc = length, index = i }
			)
			length += size
		end
	end
	assert(#segments > 0, "Stroke path has zero length")
	return setmetatable(
		{ segments = segments, length = length, closed = closed == true, tree = build(table.clone(segments)) } :: PathData,
		Path
	)
end
function Path.closest(self: Path, point: Vector3, normal: Vector3?, maxDistance: number?): Hit?
	assert(U.vector(point), "Invalid query position")
	if normal then
		assert(U.vector(normal) and normal.Magnitude > 1e-10, "Invalid surface normal")
	end
	assert(maxDistance == nil or (U.finite(maxDistance) and maxDistance >= 0), "Invalid maximum distance")
	local best: Hit?, bestSquared = nil, maxDistance and maxDistance ^ 2 or math.huge
	local function visit(node: Node)
		if distanceBox(point, node.lo, node.hi) > bestSquared then
			return
		end
		if node.segments then
			for _, s in node.segments do
				local t = math.clamp((point - s.a):Dot(s.delta) / (s.length * s.length), 0, 1)
				local position = s.a + s.delta * t
				local distanceSquared = (point - position):Dot(point - position)
				if
					distanceSquared < bestSquared
					or (distanceSquared == bestSquared and (not best or s.index < best.segment))
				then
					local tangent = s.delta / s.length
					local lateral = normal and U.unit(normal:Cross(tangent), Vector3.zero) or nil
					bestSquared = distanceSquared
					best = {
						position = position,
						distance = math.sqrt(distanceSquared),
						arc = s.arc + t * s.length,
						fraction = (s.arc + t * s.length) / self.length,
						tangent = tangent,
						segment = s.index,
						t = t,
						signedDistance = lateral and (point - position):Dot(lateral) or nil,
					}
				end
			end
		else
			local a, b = node.left :: Node, node.right :: Node
			if distanceBox(point, a.lo, a.hi) > distanceBox(point, b.lo, b.hi) then
				a, b = b, a
			end
			visit(a)
			visit(b)
		end
	end
	visit(self.tree)
	return best
end
function Path.sample(self: Path, arc: number): (Vector3, Vector3)
	assert(U.finite(arc), "Invalid arc length")
	arc = self.closed and arc % self.length or math.clamp(arc, 0, self.length)
	local lo, hi = 1, #self.segments
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if self.segments[mid].arc <= arc then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local s = self.segments[lo]
	return s.a + s.delta * math.clamp((arc - s.arc) / s.length, 0, 1), s.delta / s.length
end
function S.profile(distance: number, radius: number, kind: string?): number
	assert(U.finite(radius) and radius > 0 and U.finite(distance), "Invalid stroke distance/radius")
	local x = distance / radius
	if math.abs(x) >= 1 then
		return 0
	end
	local envelope = (1 - x * x) ^ 2
	kind = kind or "ridge"
	if kind == "ridge" then
		return math.exp(-x * x / 0.14) * envelope
	elseif kind == "crease" then
		return -math.exp(-x * x / 0.08) * envelope
	elseif kind == "fold" then
		return (math.exp(-x * x / 0.1) - 0.62 * math.exp(-((math.abs(x) - 0.57) / 0.2) ^ 2)) * envelope
	end
	error("Unknown stroke profile")
end
function S.field(path: Path, point: Vector3, normal: Vector3?, options: FieldOptions?): (number, Hit?)
	local options: FieldOptions = options or {}
	local radius = options.radius or 1
	assert(type(radius) == "number" and U.finite(radius) and radius > 0, "Positive radius required")
	local hit = path:closest(point, normal, radius)
	if not hit then
		return 0, nil
	end
	local width = options.width and options.width(hit.fraction) or 1
	assert(
		type(width) == "number" and U.finite(width) and width > 0 and width <= 1,
		"Width fraction must be in (0,1]"
	)
	local amplitude = options.amplitude and options.amplitude(hit.fraction) or 1
	assert(type(amplitude) == "number" and U.finite(amplitude), "Invalid amplitude")
	local fadeStart = options.fadeStart or (path.closed and 0 or radius)
	local fadeEnd = options.fadeEnd or (path.closed and 0 or radius)
	assert(fadeStart >= 0 and fadeEnd >= 0, "Nonnegative endpoint fade required")
	local fade = (fadeStart > 0 and U.smooth(hit.arc / fadeStart) or 1)
		* (fadeEnd > 0 and U.smooth((path.length - hit.arc) / fadeEnd) or 1)
	local distance = options.signedProfile and hit.signedDistance or hit.distance
	assert(distance ~= nil, "Signed profile needs a surface normal")
	local profile = options.profile or "ridge"
	local value = type(profile) == "function" and profile(distance / (radius * width), hit)
		or S.profile(distance, radius * width, profile :: string)
	assert(type(value) == "number" and U.finite(value), "Nonfinite stroke profile")
	-- Compact radial support also bounds custom signed profiles off the surface.
	if hit.distance >= radius * width then
		return 0, hit
	end
	return value * fade * amplitude, hit
end
function S.sculpt(mesh: Mesh, path: Path, options: SculptOptions?): (Mesh, SculptReport)
	local options: SculptOptions = options or {}
	local height = options.height or 0.1
	assert(type(height) == "number" and U.finite(height), "Finite stroke height required")
	local normals: { [number]: Vector3 } = {}
	if not options.direction then
		for fid, f in mesh.faces do
			local n, area = mesh:faceNormal(fid)
			for _, id in f.vertices do
				normals[id] = (normals[id] or Vector3.zero) + n * area
			end
		end
	end
	local out = mesh:clone()
	local report: SculptReport = { affectedVertices = 0, maxDisplacement = 0 }
	for id, p in mesh.vertices do
		local mask = U.weight(options.mask, id)
		if mask > 0 then
			local direction = options.direction
			local n: Vector3 = type(direction) == "function" and direction(p, id)
				or direction :: Vector3?
				or normals[id]
			assert(U.vector(n) and n.Magnitude > 1e-12, "Stroke needs a nonzero displacement direction")
			n = n.Unit
			local value = S.field(path, p, n, options) * height * mask
			if value ~= 0 then
				out.vertices[id] = p + n * value
				report.affectedVertices += 1
				report.maxDisplacement = math.max(report.maxDisplacement, math.abs(value))
			end
		end
	end
	out:recalculateNormals(options.normalAngle)
	return out, report
end
return S
