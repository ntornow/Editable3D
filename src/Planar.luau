--!strict
-- Validated simple polygon domains with holes. Exact predicate decisions, original ear clipping.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local Mesh = require(script.Parent.Mesh)
-- Deferred require breaks a load-order cycle; the analyzer does not follow it.
local deferredRequire = require :: any
export type Loop = { Vector2 }
export type Options = {
	maxWork: number?,
	maxVertices: number?,
	maxIntersections: number?,
	checkpoint: ((fraction: number) -> ())?,
	_visit: (() -> ())?,
}
export type Hit = {
	loopA: number,
	edgeA: number,
	loopB: number,
	edgeB: number,
	intersection: P.Intersection,
}
export type HitStatus = { complete: boolean, reason: string? }
-- Points indexed by triangle and boundary-loop corner ids; outer loop first.
export type Domain = {
	points: { Vector2 },
	triangles: { { number } },
	boundaryLoops: { { number } },
	area: number,
	holes: number,
}
type Edge = { loop: number, index: number, a: Vector2, b: Vector2 }
type Node = { id: number, previous: number, next: number, active: boolean }
local D = {}

local function context(options: Options?): () -> ()
	local options: Options = options or {}
	local maximum = options.maxWork or 5000000
	U.integer(maximum, 1)
	local work = 0
	return function()
		work += 1
		assert(work <= maximum, "Planar operation work budget exceeded")
		if options._visit then
			options._visit()
		end
		if work % 256 == 0 and options.checkpoint then
			options.checkpoint(work / maximum)
		end
	end
end
local function cleanLoops(loops: { Loop }, options: Options): { Loop }
	local result: { Loop }, total = {}, 0
	for i, loop in loops do
		assert(
			total + #loop - ((#loop > 1 and loop[1] == loop[#loop]) and 1 or 0)
				<= (options.maxVertices or 2000),
			"Planar input vertex budget exceeded"
		)
		local points = table.clone(loop)
		if #points > 1 and points[1] == points[#points] then
			table.remove(points)
		end
		assert(#points >= 3, "Polygon loops require at least three distinct consecutive points")
		P.polygonOrientation(points)
		for j, p in points do
			assert(p ~= points[j % #points + 1], "Zero-length polygon boundary edge")
		end
		result[i] = points
		total += #points
	end
	assert(total <= (options.maxVertices or 2000), "Planar input vertex budget exceeded")
	return result
end
local function intersections(loops: { Loop }, work: () -> (), maxHits: number): ({ Hit }, HitStatus)
	local edges: { Edge } = {}
	for loop, points in loops do
		for i, p in points do
			table.insert(edges, { loop = loop, index = i, a = p, b = points[i % #points + 1] })
		end
	end
	local hits: { Hit } = {}
	for i, a in edges do
		for j = i + 1, #edges do
			work()
			local b = edges[j]
			local r = P.intersectSegments2D(a.a, a.b, b.a, b.b)
			local adjacent = a.loop == b.loop
				and (a.index % #loops[a.loop] + 1 == b.index or b.index % #loops[b.loop] + 1 == a.index)
			if r.kind ~= "none" and not (adjacent and r.kind == "point" and not r.proper) then
				table.insert(
					hits,
					{ loopA = a.loop, edgeA = a.index, loopB = b.loop, edgeB = b.index, intersection = r }
				)
				if #hits >= maxHits then
					return hits, { complete = false, reason = "Intersection report budget reached" }
				end
			end
		end
	end
	return hits, { complete = true }
end

function D.intersections(loops: { Loop }, options: Options?): ({ Hit }, HitStatus)
	local options: Options = options or {}
	local maximum = options.maxIntersections or 10000
	U.integer(maximum, 1)
	return intersections(cleanLoops(loops, options), context(options), maximum)
end

local function reversed(points: Loop): Loop
	local out: Loop = {}
	for i = #points, 1, -1 do
		table.insert(out, points[i])
	end
	return out
end
local function strictlyInTriangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2): boolean
	return P.orient2D(a, b, p) >= 0 and P.orient2D(b, c, p) >= 0 and P.orient2D(c, a, p) >= 0
end
function D.triangulate(outer: Loop, holes: { Loop }?, options: Options?): Domain
	local options: Options = options or {}
	local holes: { Loop } = holes or {}
	local input: { Loop } = { outer }
	for _, hole in holes do
		table.insert(input, hole)
	end
	local loops = cleanLoops(input, options)
	local work = context(options)
	assert(
		#intersections(loops, work, 1) == 0,
		"Polygon boundaries intersect or touch; inspect Planar.intersections"
	)
	for i, loop in loops do
		local orientation = P.polygonOrientation(loop)
		assert(orientation ~= 0, "Zero-area polygon loop")
		if orientation ~= (i == 1 and 1 or -1) then
			loops[i] = reversed(loop)
		end
	end
	for i = 2, #loops do
		assert(P.pointInPolygon2D(loops[i][1], loops[1]) == "inside", "Hole lies outside its outer boundary")
		for j = 2, #loops do
			if i ~= j then
				assert(
					P.pointInPolygon2D(loops[i][1], loops[j]) == "outside",
					"Nested hole loops require separate domains"
				)
			end
		end
	end
	local points: { Vector2 }, rings: { { number } } = {}, {}
	for i, loop in loops do
		rings[i] = {}
		for _, p in loop do
			table.insert(points, p)
			table.insert(rings[i], #points)
		end
	end
	local contour = table.clone(rings[1])
	local bridges: { { number } } = {}
	local order: { { ring: number, start: number, point: Vector2 } } = {}
	for i = 2, #rings do
		local right = 1
		for j, id in rings[i] do
			local p, q = points[id], points[rings[i][right]]
			if p.X > q.X or p.X == q.X and p.Y < q.Y then
				right = j
			end
		end
		table.insert(order, { ring = i, start = right, point = points[rings[i][right]] })
	end
	table.sort(order, function(a, b)
		return a.point.X > b.point.X or a.point.X == b.point.X and a.point.Y < b.point.Y
	end)
	local function visible(a: number, b: number): boolean
		local pa, pb = points[a], points[b]
		if pa == pb then
			return false
		end
		for _, ring in rings do
			for i, id in ring do
				work()
				local nextId = ring[i % #ring + 1]
				local r = P.intersectSegments2D(pa, pb, points[id], points[nextId])
				if
					r.kind == "overlap"
					or r.kind == "point" and (r.proper or r.point ~= pa and r.point ~= pb)
				then
					return false
				end
			end
		end
		for _, edge in bridges do
			work()
			local r = P.intersectSegments2D(pa, pb, points[edge[1]], points[edge[2]])
			if r.kind == "overlap" or r.kind == "point" and (r.proper or r.point ~= pa and r.point ~= pb) then
				return false
			end
		end
		local midpoint = Vector2.new((pa.X + pb.X) * 0.5, (pa.Y + pb.Y) * 0.5)
		if P.pointInPolygon2D(midpoint, loops[1]) ~= "inside" then
			return false
		end
		for i = 2, #loops do
			if P.pointInPolygon2D(midpoint, loops[i]) ~= "outside" then
				return false
			end
		end
		return true
	end
	for _, hole in order do
		local ring = rings[hole.ring]
		local h = ring[hole.start]
		local best: number?, distance = nil, math.huge
		for i, id in contour do
			local x, y = points[h].X - points[id].X, points[h].Y - points[id].Y
			local length = x * x + y * y
			if length < distance and visible(h, id) then
				best, distance = i, length
			end
		end
		assert(best, "No representable nonintersecting hole bridge found")
		local merged: { number } = {}
		for i = 1, best do
			table.insert(merged, contour[i])
		end
		for j = 0, #ring - 1 do
			table.insert(merged, ring[(hole.start + j - 1) % #ring + 1])
		end
		table.insert(merged, h)
		table.insert(merged, contour[best])
		for i = best + 1, #contour do
			table.insert(merged, contour[i])
		end
		table.insert(bridges, { h, contour[best] })
		contour = merged
	end
	local nodes: { Node } = {}
	for i, id in contour do
		nodes[i] = { id = id, previous = (i - 2) % #contour + 1, next = i % #contour + 1, active = true }
	end
	local remaining, head, triangles: { { number } } = #nodes, 1, {}
	local removed: { [number]: boolean } = {}
	local function remove(index: number)
		local node = nodes[index]
		nodes[node.previous].next = node.next
		nodes[node.next].previous = node.previous
		node.active = false
		remaining -= 1
		if head == index then
			head = node.next
		end
	end
	while remaining > 3 do
		local current, found = head, false
		repeat
			work()
			local node = nodes[current]
			local prev, nextNode = nodes[node.previous], nodes[node.next]
			local a, b, c = points[prev.id], points[node.id], points[nextNode.id]
			local orientation = P.orient2D(a, b, c)
			if
				prev.id == node.id
				or nextNode.id == node.id
				or prev.id == nextNode.id
				or orientation == 0 and P.onSegment2D(b, a, c)
			then
				removed[node.id] = true
				remove(current)
				found = true
				break
			end
			if orientation > 0 then
				local ear = true
				local index = nodes[node.next].next
				while index ~= node.previous do
					work()
					local candidate = nodes[index]
					if
						candidate.id ~= prev.id
						and candidate.id ~= node.id
						and candidate.id ~= nextNode.id
						and strictlyInTriangle(points[candidate.id], a, b, c)
					then
						ear = false
						break
					end
					index = candidate.next
				end
				if ear then
					table.insert(triangles, { prev.id, node.id, nextNode.id })
					remove(current)
					found = true
					break
				end
			end
			current = node.next
		until current == head
		assert(found, "Polygon ear clipping stalled on a degenerate bridge or boundary")
	end
	local finalA, finalB, finalC = head, nodes[head].next, nodes[nodes[head].next].next
	if P.orient2D(points[nodes[finalA].id], points[nodes[finalB].id], points[nodes[finalC].id]) > 0 then
		table.insert(triangles, { nodes[finalA].id, nodes[finalB].id, nodes[finalC].id })
	end
	-- Reinsert removed collinear original vertices into all incident spanning edges.
	for id in removed do
		local result: { { number } } = {}
		for _, triangle in triangles do
			local split = false
			for i = 1, 3 do
				work()
				local a, b, c = triangle[i], triangle[i % 3 + 1], triangle[(i + 1) % 3 + 1]
				if id ~= a and id ~= b and id ~= c and P.onSegment2D(points[id], points[a], points[b]) then
					table.insert(result, { a, id, c })
					table.insert(result, { id, b, c })
					split = true
					break
				end
			end
			if not split then
				table.insert(result, triangle)
			end
		end
		triangles = result
	end
	local edges: { [string]: { count: number, balance: number } }, area = {}, 0
	for _, triangle in triangles do
		local orientation, det = P.orient2D(points[triangle[1]], points[triangle[2]], points[triangle[3]])
		assert(orientation > 0, "Triangulation contains a zero or reversed triangle")
		area += det * 0.5
		for i, id in triangle do
			local b = triangle[i % 3 + 1]
			local key = U.edge(id, b)
			edges[key] = edges[key] or { count = 0, balance = 0 }
			edges[key].count += 1
			edges[key].balance += id < b and 1 or -1
		end
	end
	local boundaries: { [string]: boolean } = {}
	for _, ring in rings do
		for i, id in ring do
			local b = ring[i % #ring + 1]
			local key = U.edge(id, b)
			boundaries[key] = true
			assert(
				edges[key] and edges[key].count == 1 and edges[key].balance == (id < b and 1 or -1),
				"Triangulation does not retain an input boundary edge"
			)
		end
	end
	for key, edge in edges do
		if not boundaries[key] then
			assert(
				edge.count == 2 and edge.balance == 0,
				"Triangulation has an interior crack or overlapping edge"
			)
		end
	end
	assert(#triangles == #points + 2 * (#rings - 1) - 2, "Triangulation Euler count mismatch")
	return { points = points, triangles = triangles, boundaryLoops = rings, area = area, holes = #rings - 1 }
end

function D.toMesh(domain: Domain, frame: CFrame?): Mesh.Mesh
	local frame: CFrame = frame or CFrame.identity
	assert(typeof(frame) == "CFrame")
	local mesh = Mesh.new()
	for _, p in domain.points do
		mesh:addVertex(frame:PointToWorldSpace(Vector3.new(p.X, p.Y, 0)))
	end
	local normal = frame:VectorToWorldSpace(Vector3.zAxis)
	for _, triangle in domain.triangles do
		local corners: { Mesh.Corner } = {}
		for i, id in triangle do
			corners[i] = { uv = domain.points[id], normal = normal }
		end
		mesh:addFace(triangle, corners)
	end
	return mesh
end
-- Paths and options are forwarded to the non-strict PlanarConstrain module.
function D.constrain(outer: Loop, holes: { Loop }?, paths: any, options: any?)
	return deferredRequire(script.Parent.PlanarConstrain)(outer, holes, paths, options)
end
-- Simple polygon outlines as plain Vector2 lists (either winding): point-in-outline (even-odd),
-- distance to the outline, and an outward offset (positive grows the outline whatever its winding).
-- Use them for site work such as terrain fills and walls that follow an island or plaza edge.
function D.outlineContains(points: { Vector2 }, p: Vector2): boolean
	local inside, j = false, #points
	for i = 1, #points do
		local a, b = points[i], points[j]
		if (a.Y > p.Y) ~= (b.Y > p.Y) and p.X < (b.X - a.X) * (p.Y - a.Y) / (b.Y - a.Y) + a.X then
			inside = not inside
		end
		j = i
	end
	return inside
end
function D.outlineDistance(points: { Vector2 }, p: Vector2): number
	local best = math.huge
	for i = 1, #points do
		local a, b = points[i], points[i % #points + 1]
		local ab = b - a
		local len2 = ab:Dot(ab)
		local t = if len2 > 0 then math.clamp((p - a):Dot(ab) / len2, 0, 1) else 0
		best = math.min(best, (a + ab * t - p).Magnitude)
	end
	return best
end
function D.offsetOutline(points: { Vector2 }, distance: number): ({ Vector2 }, { Vector2 })
	local n = #points
	assert(n >= 3, "Outline needs at least three points")
	local area = 0
	for i = 1, n do
		local a, b = points[i], points[i % n + 1]
		area += a.X * b.Y - b.X * a.Y
	end
	local sign = area > 0 and 1 or -1
	local out, normals = {}, {}
	for i = 1, n do
		local prev, cur, nxt = points[(i - 2) % n + 1], points[i], points[i % n + 1]
		local e1, e2 = (cur - prev), (nxt - cur)
		local n1 = Vector2.new(e1.Y, -e1.X).Unit * sign
		local n2 = Vector2.new(e2.Y, -e2.X).Unit * sign
		local bis = n1 + n2
		local normal = if bis.Magnitude > 1e-9 then bis.Unit else n1
		-- miter length, limited to 4x at sharp corners
		local cosHalf = math.max(normal:Dot(n1), 0.25)
		normals[i] = normal
		out[i] = cur + normal * (distance / cosHalf)
	end
	return out, normals
end
return D
