-- Private planar-region union and geometry checks.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local G = {}
function G.plane(mesh, loop, work)
	local origin = mesh.vertices[loop[1]]
	local x, y, z = 0, 0, 0
	for i, id in loop do
		work(1)
		local a, b = mesh.vertices[id], mesh.vertices[loop[i % #loop + 1]]
		local ax, ay, az = a.X - origin.X, a.Y - origin.Y, a.Z - origin.Z
		local bx, by, bz = b.X - origin.X, b.Y - origin.Y, b.Z - origin.Z
		x += ay * bz - az * by
		y += az * bx - ax * bz
		z += ax * by - ay * bx
	end
	local length = math.sqrt(x * x + y * y + z * z)
	if length == 0 or not U.finite(length) then
		return nil
	end
	local axis = math.abs(x) >= math.abs(y) and math.abs(x) >= math.abs(z) and 1
		or math.abs(y) >= math.abs(z) and 2
		or 3
	return { origin = origin, x = x / length, y = y / length, z = z / length, area = length / 2, axis = axis }
end
function G.distance(plane, p)
	return math.abs(
		(p.X - plane.origin.X) * plane.x + (p.Y - plane.origin.Y) * plane.y + (p.Z - plane.origin.Z) * plane.z
	)
end
function G.project(p, axis)
	return axis == 1 and Vector2.new(p.Y, p.Z) or axis == 2 and Vector2.new(p.Z, p.X) or Vector2.new(p.X, p.Y)
end
function G.polygon(mesh, loop, plane, work)
	local projected = {}
	for i, id in loop do
		projected[i] = G.project(mesh.vertices[id], plane.axis)
	end
	local sign = P.polygonOrientation(projected)
	if sign == 0 then
		return false, "degenerate"
	end
	for i, a in projected do
		local b = projected[i % #projected + 1]
		if a == b then
			return false, "projection"
		end
		for j = i + 1, #projected do
			work(1)
			if j ~= i % #projected + 1 and i ~= j % #projected + 1 then
				if
					P.intersectSegments2D(a, b, projected[j], projected[j % #projected + 1]).kind ~= "none"
				then
					return false, "projection"
				end
			end
		end
	end
	return true, sign
end
function G.union(a, b, protected, work)
	local byKey = {}
	for _, region in { a, b } do
		for i, v in region.loop do
			work(1)
			local w = region.loop[i % #region.loop + 1]
			local key = U.edge(v, w)
			local old = byKey[key]
			if old then
				if old.a ~= w or old.b ~= v then
					return nil, "orientation"
				end
				if protected[key] then
					return nil, "seam"
				end
				byKey[key] = false
			else
				byKey[key] = { a = v, b = w, corner = region.corners[i] }
			end
		end
	end
	local successors, predecessors, count, start = {}, {}, 0, nil
	for _, edge in byKey do
		if edge then
			if successors[edge.a] or predecessors[edge.b] then
				return nil, "pinch"
			end
			successors[edge.a], predecessors[edge.b] = edge, edge.a
			count += 1
			start = start and math.min(start, edge.a) or edge.a
		end
	end
	if count < 3 then
		return nil, "degenerate"
	end
	local loop, corners, seen = {}, {}, {}
	local vertex = start
	repeat
		work(1)
		local edge = successors[vertex]
		if not edge or seen[vertex] then
			return nil, "pinch"
		end
		seen[vertex] = true
		table.insert(loop, vertex)
		table.insert(corners, edge.corner)
		vertex = edge.b
	until vertex == start
	if #loop ~= count then
		return nil, "holes"
	end
	local faces = table.clone(a.faces)
	for _, fid in b.faces do
		table.insert(faces, fid)
	end
	table.sort(faces)
	return { loop = loop, corners = corners, faces = faces }
end
function G.accept(mesh, region, normals, angleLimit, maximumDeviation, maxFaceVertices, work, triangles)
	if #region.loop > maxFaceVertices then
		return false, "faceVertices"
	end
	local plane = G.plane(mesh, region.loop, work)
	if not plane then
		return false, "degenerate"
	end
	local valid, sign = G.polygon(mesh, region.loop, plane, work)
	if not valid then
		return false, sign
	end
	local deviation, maximumAngle = 0, 0
	local reference = normals[region.faces[1]]
	local seed = mesh.faces[region.faces[1]]
	local triangle = triangles[region.faces[1]][1]
	local a, b, c =
		mesh.vertices[seed.vertices[triangle[1]]],
		mesh.vertices[seed.vertices[triangle[2]]],
		mesh.vertices[seed.vertices[triangle[3]]]
	local exactPlanar = true
	for _, fid in region.faces do
		for _, id in mesh.faces[fid].vertices do
			work(16)
			if P.orient3D(a, b, c, mesh.vertices[id]) ~= 0 then
				exactPlanar = false
				break
			end
		end
		if not exactPlanar then
			break
		end
	end
	if angleLimit == 0 and not exactPlanar then
		return false, "angle"
	end
	for _, fid in region.faces do
		work(1)
		local normal = normals[fid]
		local dot =
			math.clamp(reference.x * normal.x + reference.y * normal.y + reference.z * normal.z, -1, 1)
		local angle = exactPlanar and dot > 0 and 0 or math.acos(dot)
		maximumAngle = math.max(maximumAngle, angle)
		if angle > angleLimit then
			return false, "angle"
		end
		local f = mesh.faces[fid]
		local projected = {}
		for i, id in f.vertices do
			work(1)
			local p = mesh.vertices[id]
			deviation = math.max(deviation, exactPlanar and 0 or G.distance(plane, p))
			projected[i] = G.project(p, plane.axis)
		end
		if deviation > maximumDeviation then
			return false, "deviation"
		end
		if P.polygonOrientation(projected) ~= sign then
			return false, "fold"
		end
		for _, corners in triangles[fid] do
			work(1)
			if
				P.orient2D(projected[corners[1]], projected[corners[2]], projected[corners[3]]) * sign <= 0
			then
				return false, "fold"
			end
		end
	end
	region.deviation, region.angle, region.plane = deviation, maximumAngle, plane
	return true
end
return G
