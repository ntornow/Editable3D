local Spatial = {}
Spatial.__index = Spatial
local function closestTriangle(p, a, b, c)
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
local function rayTriangle(o, d, a, b, c)
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
local function boxDistance(p, lo, hi)
	local q = p:Max(lo):Min(hi)
	local d = p - q
	return d:Dot(d)
end
local function rayBox(o, d, lo, hi, limit)
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
function Spatial.new(mesh)
	local self = setmetatable({ mesh = mesh:clone(), triangles = {} }, Spatial)
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
	local function build(list)
		if #list == 0 then
			return nil
		end
		local lo = Vector3.new(math.huge, math.huge, math.huge)
		local hi = -lo
		for _, t in list do
			lo = lo:Min(t.lo)
			hi = hi:Max(t.hi)
		end
		local node = { lo = lo, hi = hi }
		if #list <= 8 then
			node.leaves = list
			return node
		end
		local size = hi - lo
		local axis = size.X >= size.Y and size.X >= size.Z and "X" or size.Y >= size.Z and "Y" or "Z"
		table.sort(list, function(a, b)
			return a.center[axis] < b.center[axis]
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
function Spatial:closest(point, maxDistance)
	local best = (maxDistance or math.huge) ^ 2
	local hit = nil
	local function visit(node)
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
			local a, b = node.left, node.right
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
function Spatial:raycast(origin, direction, maxDistance)
	assert(direction.Magnitude > 0)
	local d = direction.Unit
	local best = maxDistance or math.huge
	local hit = nil
	local function visit(node)
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
						barycentric = bary,
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
function Spatial:contains(point)
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
function Spatial:signedDistance(point)
	local h = assert(self:closest(point), "Empty spatial index")
	return self:contains(point) and -h.distance or h.distance
end
return Spatial
