--!strict
-- Original convex-polyhedron construction, SAT manifolds, and volume integrals.
-- No service access or native physics dependency. See DYNAMICS.md for conventions.
local Mesh = require(script.Parent.Mesh)
local Primitives = require(script.Parent.Primitives)
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Symmetric 3x3 tensor stored by its six unique components.
export type Tensor = { xx: number, yy: number, zz: number, xy: number, xz: number, yz: number }
export type ConvexFace = { vertices: { number }, normal: Vector3, plane: number }
export type ConvexEdge = { a: number, b: number, direction: Vector3 }
export type Shape = {
	vertices: { Vector3 },
	faces: { ConvexFace },
	edges: { ConvexEdge },
	tolerance: number,
	lower: Vector3,
	upper: Vector3,
}
export type MassProperties = {
	volume: number,
	mass: number,
	center: Vector3,
	inertia: Tensor,
	inverseInertia: Tensor,
}
export type ShapeOptions = { tolerance: number? }
export type HullOptions = { tolerance: number?, maxPoints: number?, maxFaces: number? }
export type ContactOptions = {
	tolerance: number?,
	maxAxes: number?,
	maxContacts: number?,
	parallelTolerance: number?,
}
export type ContactPoint = {
	position: Vector3,
	pointA: Vector3,
	pointB: Vector3,
	penetration: number,
	-- Written by Dynamics after solving.
	normalImpulse: number?,
	tangentImpulse: Vector2?,
}
export type SeparatedContact = {
	overlap: false,
	normal: Vector3,
	separation: number,
	axisCount: number,
}
export type OverlapContact = {
	overlap: true,
	normal: Vector3,
	penetration: number,
	contacts: { ContactPoint },
	feature: string,
	axisCount: number,
	-- Set by Dynamics.collisions.
	bodyA: number?,
	bodyB: number?,
}
export type Contact = SeparatedContact | OverlapContact
type PlaneGroup = { normal: Vector3, plane: number, ids: { [number]: boolean } }
type HullPoint = { id: number, x: number, y: number }
type HullFace = { [number]: number, normal: Vector3, plane: number }
type WorldShape = {
	vertices: { Vector3 },
	faces: { { vertices: { number }, normal: Vector3 } },
	edges: { ConvexEdge },
}
type Feature = { kind: string, owner: string?, directionA: Vector3?, directionB: Vector3? }
local C = {}
local function optionsFor(options: ShapeOptions?, scale: number?): number
	local options: ShapeOptions = options or {}
	local tolerance = options.tolerance or math.max(scale or 1, 1) * 1e-6
	assert(tolerance > 0 and U.finite(tolerance), "Positive finite tolerance required")
	return tolerance
end
local function polygonHull(
	ids: { number },
	vertices: { Vector3 },
	normal: Vector3,
	epsilon: number
): { number }
	local x, y = U.frame(normal)
	local points: { HullPoint } = {}
	for _, id in ids do
		table.insert(points, { id = id, x = vertices[id]:Dot(x), y = vertices[id]:Dot(y) })
	end
	table.sort(points, function(a, b)
		return a.x == b.x and (a.y == b.y and a.id < b.id or a.y < b.y) or a.x < b.x
	end)
	local function turn(a: HullPoint, b: HullPoint, c: HullPoint): number
		return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	end
	local ring: { HullPoint } = {}
	for _, p in points do
		while #ring >= 2 and turn(ring[#ring - 1], ring[#ring], p) <= epsilon * epsilon do
			table.remove(ring)
		end
		table.insert(ring, p)
	end
	local lower = #ring
	for i = #points - 1, 1, -1 do
		local p = points[i]
		while #ring > lower and turn(ring[#ring - 1], ring[#ring], p) <= epsilon * epsilon do
			table.remove(ring)
		end
		table.insert(ring, p)
	end
	table.remove(ring)
	local result: { number } = {}
	for _, p in ring do
		table.insert(result, p.id)
	end
	assert(#result >= 3, "Degenerate planar face")
	return result
end
function C.fromMesh(mesh: Mesh, options: ShapeOptions?): Shape
	local report = mesh:validate()
	assert(report.closed, "Convex shape requires a closed consistently wound manifold")
	local lo, hi = mesh:bounds()
	local epsilon = optionsFor(options, (hi - lo).Magnitude)
	local origin = (lo + hi) * 0.5
	local signedVolume = 0
	for _, triangle in mesh:triangles() do
		local a, b, c =
			mesh.vertices[triangle[1]] - origin,
			mesh.vertices[triangle[2]] - origin,
			mesh.vertices[triangle[3]] - origin
		signedVolume += a:Dot(b:Cross(c)) / 6
	end
	local sign = signedVolume >= 0 and 1 or -1
	local vertices: { Vector3 }, map: { [number]: number } = {}, {}
	for _, id in U.keys(mesh.vertices) do
		map[id] = #vertices + 1
		table.insert(vertices, mesh.vertices[id])
	end
	local groups: { PlaneGroup } = {}
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		local normal = mesh:faceNormal(fid) * sign
		local plane = normal:Dot(mesh.vertices[f.vertices[1]])
		for _, p in vertices do
			assert(normal:Dot(p) - plane <= epsilon, "Mesh is concave or contains an interior face")
		end
		for _, id in f.vertices do
			assert(math.abs(normal:Dot(mesh.vertices[id]) - plane) <= epsilon, "Faces must be planar")
		end
		local group: PlaneGroup?
		for _, candidate in groups do
			if normal:Dot(candidate.normal) > 1 - 1e-8 and math.abs(plane - candidate.plane) <= epsilon then
				group = candidate
				break
			end
		end
		if not group then
			group = { normal = normal, plane = plane, ids = {} }
			table.insert(groups, group :: any) -- analyzer keeps the `not group` nil refinement
		end
		for _, id in f.vertices do
			(group :: PlaneGroup).ids[map[id]] = true
		end
	end
	local faces: { ConvexFace }, edgeMap: { [string]: boolean }, edges: { ConvexEdge } = {}, {}, {}
	for _, g in groups do
		local ids = polygonHull(U.keys(g.ids), vertices, g.normal, epsilon)
		table.insert(faces, { vertices = ids, normal = g.normal, plane = g.plane })
		for i, a in ids do
			local b = ids[i % #ids + 1]
			local key = U.edge(a, b)
			if not edgeMap[key] then
				edgeMap[key] = true
				table.insert(edges, { a = a, b = b, direction = (vertices[b] - vertices[a]).Unit })
			end
		end
	end
	local shape: Shape =
		{ vertices = vertices, faces = faces, edges = edges, tolerance = epsilon, lower = lo, upper = hi }
	local volume = C.massProperties(shape, 1).volume
	assert(volume > epsilon ^ 3, "Shape must enclose positive volume")
	return shape
end
function C.box(size: Vector3): Shape
	return C.fromMesh(Primitives.box(size))
end
function C.toMesh(shape: Shape): Mesh
	local mesh = Mesh.new()
	for _, p in shape.vertices do
		mesh:addVertex(p)
	end
	for _, f in shape.faces do
		mesh:addFace(f.vertices)
	end
	mesh:removeUnused()
	return mesh:recalculateNormals(0)
end
-- Incremental 3D hull; interior and coplanar input points are discarded.
function C.hull(points: { Vector3 }, options: HullOptions?): Shape
	local options: HullOptions = options or {}
	assert(
		#points >= 4 and #points <= (options.maxPoints or 512),
		"Hull point budget exceeded or fewer than four points"
	)
	local lo, hi =
		Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, p in points do
		assert(U.vector(p), "Hull points must be finite")
		lo = lo:Min(p)
		hi = hi:Max(p)
	end
	local epsilon = optionsFor(options, (hi - lo).Magnitude)
	local vertices: { Vector3 } = {}
	for _, p in points do
		local duplicate = false
		for _, q in vertices do
			if (p - q).Magnitude <= epsilon then
				duplicate = true
				break
			end
		end
		if not duplicate then
			table.insert(vertices, p)
		end
	end
	assert(#vertices >= 4, "Hull points are degenerate")
	local a: number, b: number?, c: number?, d: number?, best: number = 1, nil, nil, nil, 0
	for i = 2, #vertices do
		local dist = (vertices[i] - vertices[a]).Magnitude
		if dist > best then
			b, best = i, dist
		end
	end
	assert(b and best > epsilon, "Hull points coincide")
	local ab = (vertices[b] - vertices[a]).Unit
	best = 0
	for i, p in vertices do
		local dist = (p - vertices[a]):Cross(ab).Magnitude
		if dist > best then
			c, best = i, dist
		end
	end
	assert(c and best > epsilon, "Hull points are collinear")
	local normal = (vertices[b] - vertices[a]):Cross(vertices[c] - vertices[a]).Unit
	best = 0
	for i, p in vertices do
		local dist = math.abs((p - vertices[a]):Dot(normal))
		if dist > best then
			d, best = i, dist
		end
	end
	assert(d and best > epsilon, "Hull points are coplanar")
	local inside = (vertices[a] + vertices[b] + vertices[c] + vertices[d]) / 4
	local function face(i: number, j: number, k: number): HullFace
		local n = (vertices[j] - vertices[i]):Cross(vertices[k] - vertices[i])
		assert(n.Magnitude > epsilon * epsilon, "Degenerate hull horizon")
		if n:Dot(inside - vertices[i]) > 0 then
			j, k = k, j
			n = -n
		end
		return { i, j, k, normal = n.Unit, plane = n.Unit:Dot(vertices[i]) }
	end
	local faces = { face(a, b, c), face(a, d, b), face(a, c, d), face(b, d, c) }
	local initial = { [a] = true, [b] = true, [c] = true, [d] = true }
	for id, p in vertices do
		if initial[id] then
			continue
		end
		local horizon: { [string]: { number } }, remaining: { HullFace }, visible = {}, {}, false
		for _, f in faces do
			if f.normal:Dot(p) - f.plane > epsilon then
				visible = true
				for i = 1, 3 do
					local u, v = f[i], f[i % 3 + 1]
					local key = U.edge(u, v)
					if horizon[key] then
						horizon[key] = nil
					else
						horizon[key] = { u, v }
					end
				end
			else
				table.insert(remaining, f)
			end
		end
		if visible then
			for _, key in U.keys(horizon) do
				local edge = horizon[key]
				table.insert(remaining, face(edge[1], edge[2], id))
			end
			faces = remaining
			assert(#faces <= (options.maxFaces or 4096), "Hull face budget exceeded")
		end
	end
	local mesh = Mesh.new()
	for _, p in vertices do
		mesh:addVertex(p)
	end
	for _, f in faces do
		mesh:addFace({ f[1], f[2], f[3] })
	end
	mesh:removeUnused()
	return C.fromMesh(mesh, { tolerance = epsilon })
end
function C.support(shape: Shape, direction: Vector3, frame: CFrame?): (Vector3, number)
	assert(U.vector(direction) and direction.Magnitude > 0)
	local frame: CFrame = frame or CFrame.identity
	local localDirection = frame:VectorToObjectSpace(direction)
	local best, id: number? = -math.huge, nil
	for i, p in shape.vertices do
		local projection = p:Dot(localDirection)
		if projection > best then
			best, id = projection, i
		end
	end
	return frame:PointToWorldSpace(shape.vertices[id :: number]), id :: number
end
function C.bounds(shape: Shape, frame: CFrame?): (Vector3, Vector3)
	local frame: CFrame = frame or CFrame.identity
	local lo, hi =
		Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, p in shape.vertices do
		local q = frame:PointToWorldSpace(p)
		lo = lo:Min(q)
		hi = hi:Max(q)
	end
	return lo, hi
end
function C.tensorMultiply(t: Tensor, v: Vector3): Vector3
	return Vector3.new(
		t.xx * v.X + t.xy * v.Y + t.xz * v.Z,
		t.xy * v.X + t.yy * v.Y + t.yz * v.Z,
		t.xz * v.X + t.yz * v.Y + t.zz * v.Z
	)
end
function C.tensorInverse(t: Tensor): Tensor
	for _, key in { "xx", "yy", "zz", "xy", "xz", "yz" } do
		assert(U.finite((t :: any)[key]), "Inertia must be finite")
	end
	assert(t.xx > 0 and t.xx * t.yy - t.xy * t.xy > 0, "Inertia tensor is not positive definite")
	local a, b, c = t.yy * t.zz - t.yz * t.yz, t.xz * t.yz - t.xy * t.zz, t.xy * t.yz - t.xz * t.yy
	local determinant = t.xx * a + t.xy * b + t.xz * c
	assert(determinant > 0 and U.finite(determinant), "Inertia tensor is not positive definite")
	return {
		xx = a / determinant,
		xy = b / determinant,
		xz = c / determinant,
		yy = (t.xx * t.zz - t.xz * t.xz) / determinant,
		yz = (t.xy * t.xz - t.xx * t.yz) / determinant,
		zz = (t.xx * t.yy - t.xy * t.xy) / determinant,
	}
end
function C.massProperties(shape: Shape, mass: number): MassProperties
	assert(mass >= 0 and U.finite(mass), "Finite nonnegative mass required")
	local volume, first = 0, Vector3.zero
	local q: { [string]: number } = { xx = 0, yy = 0, zz = 0, xy = 0, xz = 0, yz = 0 }
	-- Shift the tetrahedron origin near the shape to reduce cancellation after authoring translations.
	local origin = (shape.lower + shape.upper) * 0.5
	for _, f in shape.faces do
		local a = shape.vertices[f.vertices[1]] - origin
		for i = 2, #f.vertices - 1 do
			local b, c = shape.vertices[f.vertices[i]] - origin, shape.vertices[f.vertices[i + 1]] - origin
			local v = a:Dot(b:Cross(c)) / 6
			volume += v
			first += (a + b + c) * (v / 4)
			for _, pair in
				{
					{ "xx", "X", "X" },
					{ "yy", "Y", "Y" },
					{ "zz", "Z", "Z" },
					{ "xy", "X", "Y" },
					{ "xz", "X", "Z" },
					{ "yz", "Y", "Z" },
				}
			do
				local x, y = pair[2], pair[3]
				-- Vector3 components are read by axis name.
				local av: any, bv: any, cv: any = a, b, c
				q[pair[1]] += v / 20 * ((av[x] + bv[x] + cv[x]) * (av[y] + bv[y] + cv[y]) + av[x] * av[y] + bv[x] * bv[y] + cv[x] * cv[y])
			end
		end
	end
	assert(volume > 0, "Positive volume required")
	local center = first / volume
	local density = mass / volume
	local t: Tensor = {
		xx = (q.yy + q.zz) * density - mass * (center.Y ^ 2 + center.Z ^ 2),
		yy = (q.xx + q.zz) * density - mass * (center.X ^ 2 + center.Z ^ 2),
		zz = (q.xx + q.yy) * density - mass * (center.X ^ 2 + center.Y ^ 2),
		xy = -q.xy * density + mass * center.X * center.Y,
		xz = -q.xz * density + mass * center.X * center.Z,
		yz = -q.yz * density + mass * center.Y * center.Z,
	}
	return {
		volume = volume,
		mass = mass,
		center = center + origin,
		inertia = t,
		inverseInertia = mass > 0 and C.tensorInverse(t) or table.clone(t),
	}
end
local function transformed(shape: Shape, frame: CFrame): WorldShape
	local result: WorldShape = { vertices = {}, faces = {}, edges = {} }
	for i, p in shape.vertices do
		result.vertices[i] = frame:PointToWorldSpace(p)
	end
	for i, f in shape.faces do
		result.faces[i] = { vertices = f.vertices, normal = frame:VectorToWorldSpace(f.normal).Unit }
	end
	for i, e in shape.edges do
		result.edges[i] = { a = e.a, b = e.b, direction = frame:VectorToWorldSpace(e.direction).Unit }
	end
	return result
end
local function interval(vertices: { Vector3 }, axis: Vector3): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, p in vertices do
		local v = p:Dot(axis)
		lo, hi = math.min(lo, v), math.max(hi, v)
	end
	return lo, hi
end
local function closestSegments(a: Vector3, b: Vector3, c: Vector3, d: Vector3): (Vector3, Vector3)
	local u, v, w = b - a, d - c, a - c
	local aa, bb, cc, dd, ee = u:Dot(u), u:Dot(v), v:Dot(v), u:Dot(w), v:Dot(w)
	local determinant = aa * cc - bb * bb
	local s = determinant > 1e-15 and math.clamp((bb * ee - cc * dd) / determinant, 0, 1) or 0
	local t = (bb * s + ee) / cc
	if t < 0 then
		t = 0
		s = math.clamp(-dd / aa, 0, 1)
	elseif t > 1 then
		t = 1
		s = math.clamp((bb - dd) / aa, 0, 1)
	end
	return a + u * s, c + v * t
end
local function clipped(polygon: { Vector3 }, origin: Vector3, normal: Vector3, epsilon: number): { Vector3 }
	local out: { Vector3 } = {}
	if #polygon == 0 then
		return out
	end
	local a = polygon[#polygon]
	local da = normal:Dot(a - origin)
	for _, b in polygon do
		local db = normal:Dot(b - origin)
		if (da <= epsilon) ~= (db <= epsilon) then
			local t = (epsilon - da) / (db - da)
			table.insert(out, a + (b - a) * t)
		end
		if db <= epsilon then
			table.insert(out, b)
		end
		a, da = b, db
	end
	return out
end
local function reduceContacts(contacts: { ContactPoint }, maximum: number): { ContactPoint }
	if #contacts <= maximum then
		return contacts
	end
	local selected: { ContactPoint }, used: { [number]: boolean } = {}, {}
	for step = 1, maximum do
		local best: number?, score = nil, -math.huge
		for i, contact in contacts do
			if used[i] then
				continue
			end
			local value = contact.penetration
			if step > 1 then
				value = math.huge
				for _, chosen in selected do
					value = math.min(value, (chosen.position - contact.position).Magnitude ^ 2)
				end
			end
			if value > score then
				best, score = i, value
			end
		end
		used[best :: number] = true
		table.insert(selected, contacts[best :: number])
	end
	return selected
end
function C.contact(
	shapeA: Shape,
	frameA: CFrame?,
	shapeB: Shape,
	frameB: CFrame?,
	options: ContactOptions?
): Contact
	local options: ContactOptions = options or {}
	local epsilon = options.tolerance or math.max(shapeA.tolerance, shapeB.tolerance)
	assert(epsilon > 0 and U.finite(epsilon))
	local maxAxes = U.integer(options.maxAxes or 100000, 1)
	local maxContacts = U.integer(options.maxContacts or 4, 1)
	local parallelTolerance = options.parallelTolerance or 1e-6
	assert(
		U.finite(parallelTolerance) and parallelTolerance > 0 and parallelTolerance < 1,
		"Parallel tolerance must be in (0,1)"
	)
	local a, b =
		transformed(shapeA, frameA or CFrame.identity), transformed(shapeB, frameB or CFrame.identity)
	-- normal and feature are always set by the first passing axis test before use.
	local depth: number, normal: Vector3, feature: Feature, count: number =
		math.huge, nil :: any, nil :: any, 0
	local separated: SeparatedContact = nil :: any
	local function axisTest(axis: Vector3, info: Feature): boolean
		if axis.Magnitude < parallelTolerance then
			return true
		end
		count += 1
		assert(count <= maxAxes, "SAT axis budget exceeded")
		axis = axis.Unit
		local amin, amax = interval(a.vertices, axis)
		local bmin, bmax = interval(b.vertices, axis)
		local positive, negative = amax - bmin, bmax - amin
		if positive < -epsilon or negative < -epsilon then
			separated = {
				overlap = false,
				normal = positive < negative and axis or -axis,
				separation = -math.min(positive, negative),
				axisCount = count,
			}
			return false
		end
		local distance = math.min(positive, negative)
		if distance < depth - epsilon * 0.1 then
			depth, normal, feature = distance, positive <= negative and axis or -axis, info
		end
		return true
	end
	for _, f in a.faces do
		if not axisTest(f.normal, { kind = "face", owner = "a" }) then
			return separated
		end
	end
	for _, f in b.faces do
		if not axisTest(f.normal, { kind = "face", owner = "b" }) then
			return separated
		end
	end
	local function directions(edges: { ConvexEdge }): { Vector3 }
		local out: { Vector3 } = {}
		for _, edge in edges do
			local duplicate = false
			for _, d in out do
				if d:Cross(edge.direction).Magnitude < 1e-6 then
					duplicate = true
					break
				end
			end
			if not duplicate then
				table.insert(out, edge.direction)
			end
		end
		return out
	end
	for _, da in directions(a.edges) do
		for _, db in directions(b.edges) do
			if not axisTest(da:Cross(db), { kind = "edge", directionA = da, directionB = db }) then
				return separated
			end
		end
	end
	local contacts: { ContactPoint } = {}
	local function add(pa: Vector3, pb: Vector3, penetration: number)
		local p = (pa + pb) * 0.5
		for _, existing in contacts do
			if (p - existing.position).Magnitude <= epsilon * 2 then
				return
			end
		end
		table.insert(
			contacts,
			{ position = p, pointA = pa, pointB = pb, penetration = math.max(0, penetration) }
		)
	end
	if feature.kind == "edge" then
		local function supportEdge(shape: WorldShape, direction: Vector3, axis: Vector3): ConvexEdge
			local chosen: ConvexEdge?, best = nil, -math.huge
			for _, e in shape.edges do
				if e.direction:Cross(direction).Magnitude < 1e-5 then
					local score = axis:Dot(shape.vertices[e.a] + shape.vertices[e.b])
					if score > best then
						chosen, best = e, score
					end
				end
			end
			return chosen :: ConvexEdge
		end
		local ea, eb =
			supportEdge(a, feature.directionA :: Vector3, normal),
			supportEdge(b, feature.directionB :: Vector3, -normal)
		local pa, pb = closestSegments(a.vertices[ea.a], a.vertices[ea.b], b.vertices[eb.a], b.vertices[eb.b])
		add(pa, pb, depth)
	else
		local ref, inc, outward = a, b, normal
		if feature.owner == "b" then
			ref, inc, outward = b, a, -normal
		end
		local reference: { vertices: { number }, normal: Vector3 }, incident: { vertices: { number }, normal: Vector3 }, best =
			nil :: any, nil :: any, -math.huge
		for _, f in ref.faces do
			local score = f.normal:Dot(outward)
			if score > best then
				reference, best = f, score
			end
		end
		best = math.huge
		for _, f in inc.faces do
			local score = f.normal:Dot(outward)
			if score < best then
				incident, best = f, score
			end
		end
		local polygon: { Vector3 } = {}
		for _, id in incident.vertices do
			table.insert(polygon, inc.vertices[id])
		end
		for i, id in reference.vertices do
			local p = ref.vertices[id]
			local q = ref.vertices[reference.vertices[i % #reference.vertices + 1]]
			polygon = clipped(polygon, p, (q - p):Cross(outward).Unit, epsilon)
		end
		local plane = ref.vertices[reference.vertices[1]]:Dot(outward)
		for _, p in polygon do
			local distance = plane - p:Dot(outward)
			if distance >= -epsilon then
				local q = p + outward * distance
				if feature.owner == "a" then
					add(q, p, distance)
				else
					add(p, q, distance)
				end
			end
		end
	end
	assert(
		#contacts > 0,
		"SAT overlap found but no manifold; reduce tolerance or inspect near-degenerate geometry"
	)
	return {
		overlap = true,
		normal = normal,
		penetration = math.max(0, depth),
		contacts = reduceContacts(contacts, maxContacts),
		feature = feature.kind,
		axisCount = count,
	}
end
return C
