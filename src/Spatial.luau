--!strict
local Types = require(script.Parent.Types)
export type Hit = {
	position: Vector3,
	distance: number,
	barycentric: Vector3,
	normal: Vector3,
	triangle: Types.Triangle,
	face: number,
}
type Tri = {
	a: Vector3,
	b: Vector3,
	c: Vector3,
	normal: Vector3,
	source: Types.Triangle,
	lo: Vector3,
	hi: Vector3,
	center: Vector3,
}
type Node = { lo: Vector3, hi: Vector3, leaves: { Tri }?, left: Node?, right: Node? }
export type Index = {
	mesh: Types.Mesh,
	triangles: { Tri },
	root: Node?,
	closest: (Index, Vector3, number?) -> Hit?,
	raycast: (Index, Vector3, Vector3, number?) -> Hit?,
	contains: (Index, Vector3) -> boolean,
	signedDistance: (Index, Vector3) -> number,
}
export type CoincidentOptions = {
	-- largest gap between the surfaces, studs (default 0.05)
	tolerance: number?,
	-- largest angle between the facings, degrees (default 30)
	angle: number?,
	-- test every n-th triangle of the first mesh (default 1)
	stride: number?,
}
-- Area of a mesh that lies on another surface. "same" is co-facing area (it z-fights when
-- rendered); "opposite" is back-to-back area (harmless for single-sided rendering).
export type Coincidence = {
	area: number,
	same: number,
	opposite: number,
	sameFraction: number,
	oppositeFraction: number,
}
export type CoincidentPair = Coincidence & { a: number, b: number }
type Self = Index
local Spatial = {}
Spatial.__index = Spatial
local function closestTriangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3): (Vector3, Vector3)
	local ab, ac, ap = b - a, c - a, p - a
	local d1, d2 = ab:Dot(ap), ac:Dot(ap)
	if d1 <= 0 and d2 <= 0 then
		return a, Vector3.new(1, 0, 0)
	end
	local bp = p - b
	local d3, d4 = ab:Dot(bp), ac:Dot(bp)
	if d3 >= 0 and d4 <= d3 then
		return b, Vector3.new(0, 1, 0)
	end
	local vc = d1 * d4 - d3 * d2
	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return a + ab * v, Vector3.new(1 - v, v, 0)
	end
	local cp = p - c
	local d5, d6 = ab:Dot(cp), ac:Dot(cp)
	if d6 >= 0 and d5 <= d6 then
		return c, Vector3.new(0, 0, 1)
	end
	local vb = d5 * d2 - d1 * d6
	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return a + ac * w, Vector3.new(1 - w, 0, w)
	end
	local va = d3 * d6 - d5 * d4
	if va <= 0 and d4 - d3 >= 0 and d5 - d6 >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w, Vector3.new(0, 1 - w, w)
	end
	local den = 1 / (va + vb + vc)
	local v, w = vb * den, vc * den
	return a + ab * v + ac * w, Vector3.new(1 - v - w, v, w)
end
Spatial.closestTriangle = closestTriangle
local function rayTriangle(o: Vector3, d: Vector3, a: Vector3, b: Vector3, c: Vector3): (number?, Vector3?)
	local e1, e2 = b - a, c - a
	local h = d:Cross(e2)
	local determinant = e1:Dot(h)
	if math.abs(determinant) < 1e-12 then
		return nil
	end
	local s = o - a
	local u = s:Dot(h) / determinant
	if u < -1e-8 or u > 1 + 1e-8 then
		return nil
	end
	local q = s:Cross(e1)
	local v = d:Dot(q) / determinant
	if v < -1e-8 or u + v > 1 + 1e-8 then
		return nil
	end
	local t = e2:Dot(q) / determinant
	if t < 0 then
		return nil
	end
	return t, Vector3.new(1 - u - v, u, v)
end
local function boxDistance(p: Vector3, lo: Vector3, hi: Vector3): number
	local q = p:Max(lo):Min(hi)
	local d = p - q
	return d:Dot(d)
end
-- Vectors are indexed by axis name, so they are untyped here.
local function rayBox(o: any, d: any, lo: any, hi: any, limit: number): boolean
	local near, far = 0, limit
	for _, axis in { "X", "Y", "Z" } do
		if math.abs(d[axis]) < 1e-15 then
			if o[axis] < lo[axis] or o[axis] > hi[axis] then
				return false
			end
		else
			local a, b = (lo[axis] - o[axis]) / d[axis], (hi[axis] - o[axis]) / d[axis]
			if a > b then
				a, b = b, a
			end
			near = math.max(near, a)
			far = math.min(far, b)
			if near > far then
				return false
			end
		end
	end
	return true
end
function Spatial.new(mesh: Types.Mesh): Index
	local self: Index = setmetatable({ mesh = mesh:clone(), triangles = {} }, Spatial) :: any
	for _, t in mesh:triangles() do
		local a, b, c = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
		if (b - a):Cross(c - a).Magnitude > 1e-12 then
			table.insert(self.triangles, {
				a = a,
				b = b,
				c = c,
				normal = (b - a):Cross(c - a).Unit,
				source = t,
				lo = a:Min(b):Min(c),
				hi = a:Max(b):Max(c),
				center = (a + b + c) / 3,
			})
		end
	end
	local function build(list: { Tri }): Node?
		if #list == 0 then
			return nil
		end
		local lo = Vector3.new(math.huge, math.huge, math.huge)
		local hi = -lo
		for _, t in list do
			lo = lo:Min(t.lo)
			hi = hi:Max(t.hi)
		end
		local node: Node = { lo = lo, hi = hi }
		if #list <= 8 then
			node.leaves = list
			return node
		end
		local size = hi - lo
		local axis = size.X >= size.Y and size.X >= size.Z and "X" or size.Y >= size.Z and "Y" or "Z"
		table.sort(list, function(a: Tri, b: Tri)
			return (a.center :: any)[axis] < (b.center :: any)[axis]
		end)
		local left, right = {}, {}
		for i, t in list do
			table.insert(i <= math.floor(#list / 2) and left or right, t)
		end
		node.left = build(left)
		node.right = build(right)
		return node
	end
	self.root = build(table.clone(self.triangles))
	return self
end
function Spatial.closest(self: Self, point: Vector3, maxDistance: number?): Hit?
	local best = (maxDistance or math.huge) ^ 2
	local hit: Hit? = nil
	local function visit(node: Node?)
		if not node or boxDistance(point, node.lo, node.hi) > best then
			return
		end
		if node.leaves then
			for _, t in node.leaves do
				local p, bary = closestTriangle(point, t.a, t.b, t.c)
				local d = (point - p):Dot(point - p)
				if d <= best then
					best = d
					hit = {
						position = p,
						distance = math.sqrt(d),
						barycentric = bary,
						normal = t.normal,
						triangle = t.source,
						face = t.source.face,
					}
				end
			end
		else
			local a, b = node.left :: Node, node.right :: Node
			if boxDistance(point, a.lo, a.hi) > boxDistance(point, b.lo, b.hi) then
				a, b = b, a
			end
			visit(a)
			visit(b)
		end
	end
	visit(self.root)
	return hit
end
function Spatial.raycast(self: Self, origin: Vector3, direction: Vector3, maxDistance: number?): Hit?
	assert(direction.Magnitude > 0)
	local d = direction.Unit
	local best = maxDistance or math.huge
	local hit: Hit? = nil
	local function visit(node: Node?)
		if not node or not rayBox(origin, d, node.lo, node.hi, best) then
			return
		end
		if node.leaves then
			for _, t in node.leaves do
				local distance, bary = rayTriangle(origin, d, t.a, t.b, t.c)
				if distance and distance <= best then
					best = distance
					hit = {
						position = origin + d * distance,
						distance = distance,
						barycentric = bary :: Vector3,
						normal = t.normal,
						triangle = t.source,
						face = t.source.face,
					}
				end
			end
		else
			visit(node.left)
			visit(node.right)
		end
	end
	visit(self.root)
	return hit
end
function Spatial.contains(self: Self, point: Vector3): boolean
	-- Generalized winding number; closed consistently oriented input required.
	local sum = 0
	for _, t in self.triangles do
		local a, b, c = t.a - point, t.b - point, t.c - point
		local la, lb, lc = a.Magnitude, b.Magnitude, c.Magnitude
		if math.min(la, lb, lc) < 1e-10 then
			return true
		end
		sum += 2 * math.atan2(a:Dot(b:Cross(c)), la * lb * lc + a:Dot(b) * lc + b:Dot(c) * la + c:Dot(a) * lb)
	end
	return math.abs(sum) > 2 * math.pi
end
function Spatial.signedDistance(self: Self, point: Vector3): number
	local h = assert(self:closest(point), "Empty spatial index")
	return self:contains(point) and -h.distance or h.distance
end
-- How much of mesh `a` lies on the surface of `b` (an Index or a Mesh), in area. Each triangle
-- of `a` counts when its centroid is within `tolerance` of `b` and the facings agree within
-- `angle` (or are opposite within it). Finds duplicated or overlapping layers that z-fight.
function Spatial.coincident(a: Types.Mesh, b: any, options: CoincidentOptions?): Coincidence
	local o: CoincidentOptions = options or {}
	local tolerance = o.tolerance or 0.05
	local cosine = math.cos(math.rad(o.angle or 30))
	local stride = math.max(1, math.floor(o.stride or 1))
	local index: Index = if getmetatable(b) == Spatial then b else Spatial.new(b)
	local area, same, opposite = 0, 0, 0
	for i, t in a:triangles() do
		if (i - 1) % stride == 0 then
			local p, q, r = a.vertices[t[1]], a.vertices[t[2]], a.vertices[t[3]]
			local cross = (q - p):Cross(r - p)
			local size = cross.Magnitude / 2
			if size > 1e-12 then
				area += size
				local hit = index:closest((p + q + r) / 3, tolerance)
				if hit then
					local facing = (cross / (2 * size)):Dot(hit.normal)
					if facing >= cosine then
						same += size
					elseif facing <= -cosine then
						opposite += size
					end
				end
			end
		end
	end
	return {
		area = area,
		same = same,
		opposite = opposite,
		sameFraction = if area > 0 then same / area else 0,
		oppositeFraction = if area > 0 then opposite / area else 0,
	}
end
-- Every ordered pair of meshes (bounding boxes within `tolerance`) whose co-facing coincident
-- area is at least `minFraction` (default 0.01) of the first mesh. Sorted by `same`, largest first.
function Spatial.coincidentPairs(
	meshes: { Types.Mesh },
	options: (CoincidentOptions & { minFraction: number? })?
): { CoincidentPair }
	local o: CoincidentOptions & { minFraction: number? } = options or {} :: any
	local tolerance = o.tolerance or 0.05
	local minFraction = o.minFraction or 0.01
	local boxes, indices = {}, {}
	for i, m in meshes do
		local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
		for _, v in m.vertices do
			lo, hi = lo:Min(v), hi:Max(v)
		end
		boxes[i] = { lo = lo - Vector3.one * tolerance, hi = hi + Vector3.one * tolerance }
	end
	local out: { CoincidentPair } = {}
	for i, m in meshes do
		for j = 1, #meshes do
			local A, B = boxes[i], boxes[j]
			if
				i ~= j
				and A.lo.X <= B.hi.X
				and B.lo.X <= A.hi.X
				and A.lo.Y <= B.hi.Y
				and B.lo.Y <= A.hi.Y
				and A.lo.Z <= B.hi.Z
				and B.lo.Z <= A.hi.Z
			then
				indices[j] = indices[j] or Spatial.new(meshes[j])
				local c = Spatial.coincident(m, indices[j], o)
				if c.sameFraction >= minFraction then
					table.insert(out, {
						a = i,
						b = j,
						area = c.area,
						same = c.same,
						opposite = c.opposite,
						sameFraction = c.sameFraction,
						oppositeFraction = c.oppositeFraction,
					})
				end
			end
		end
	end
	table.sort(out, function(x, y)
		return x.same > y.same
	end)
	return out
end
-- Removes the faces of `mesh` that lie on any of `keepers` (Indexes or Meshes) and face the same
-- way, so the keepers alone render there. Returns the trimmed mesh and the removed face count.
-- Use it to resolve z-fighting between layers built on one surface (cloth over cloth, a frame
-- over glazing) or chunk borders duplicated when a mesh was split.
function Spatial.trimCoincident(
	mesh: Types.Mesh,
	keepers: { any },
	options: CoincidentOptions?
): (Types.Mesh, number)
	local o: CoincidentOptions = options or {}
	local tolerance = o.tolerance or 0.05
	local cosine = math.cos(math.rad(o.angle or 30))
	local indices: { Index } = {}
	for i, k in keepers do
		indices[i] = if getmetatable(k) == Spatial then k else Spatial.new(k)
	end
	local out = mesh:clone()
	local removed = 0
	for id, f in out.faces do
		local vs = f.vertices
		local p0 = out.vertices[vs[1]]
		local normal, center, area = Vector3.zero, Vector3.zero, 0
		for i = 2, #vs - 1 do
			local cross = (out.vertices[vs[i]] - p0):Cross(out.vertices[vs[i + 1]] - p0)
			local size = cross.Magnitude / 2
			normal += cross
			center += (p0 + out.vertices[vs[i]] + out.vertices[vs[i + 1]]) / 3 * size
			area += size
		end
		if area > 1e-12 then
			center /= area
			normal = normal.Unit
			for _, index in indices do
				local hit = index:closest(center, tolerance)
				if hit and normal:Dot(hit.normal) >= cosine then
					out.faces[id] = nil
					removed += 1
					break
				end
			end
		end
	end
	return out:removeUnused(), removed
end
return Spatial
