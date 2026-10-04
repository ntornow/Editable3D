-- Scalar-double measurements; exact projected convexity is checked separately.
local G = require(script.Parent.PlanarReduceGeometry)
local P = require(script.Parent.Predicates)
local Q = {}
function Q.mean(mesh, ids)
	local x, y, z = 0, 0, 0
	for _, id in ids do
		local p = mesh.vertices[id]
		x += p.X / #ids
		y += p.Y / #ids
		z += p.Z / #ids
	end
	return Vector3.new(x, y, z)
end
function Q.length(a, b)
	return math.sqrt((b.X - a.X) ^ 2 + (b.Y - a.Y) ^ 2 + (b.Z - a.Z) ^ 2)
end
function Q.angle(a, b)
	local x, y, z = a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x
	return math.atan2(math.sqrt(x * x + y * y + z * z), a.x * b.x + a.y * b.y + a.z * b.z)
end
function Q.shape(mesh, ids, visit)
	local plane = G.plane(mesh, ids, visit)
	if not plane then
		return nil, "degenerateFace"
	end
	local valid, sign = G.polygon(mesh, ids, plane, visit)
	if not valid then
		return nil, "faceProjection"
	end
	local minimum, maximum, jacobian, short, long = math.pi, 0, 1, math.huge, 0
	for i, id in ids do
		visit(1)
		local a, p, b =
			mesh.vertices[ids[(i - 2) % #ids + 1]], mesh.vertices[id], mesh.vertices[ids[i % #ids + 1]]
		if
			P.orient2D(G.project(a, plane.axis), G.project(p, plane.axis), G.project(b, plane.axis))
				* sign
			<= 0
		then
			return nil, "nonconvexFace"
		end
		local ax, ay, az, bx, by, bz = a.X - p.X, a.Y - p.Y, a.Z - p.Z, b.X - p.X, b.Y - p.Y, b.Z - p.Z
		local al, bl = Q.length(a, p), Q.length(b, p)
		if al == 0 or bl == 0 then
			return nil, "zeroEdge"
		end
		local dot = math.clamp((ax * bx + ay * by + az * bz) / (al * bl), -1, 1)
		local angle = math.acos(dot)
		minimum, maximum = math.min(minimum, angle), math.max(maximum, angle)
		-- next cross previous agrees with the polygon's oriented Newell normal.
		local cx, cy, cz = by * az - bz * ay, bz * ax - bx * az, bx * ay - by * ax
		jacobian = math.min(jacobian, (cx * plane.x + cy * plane.y + cz * plane.z) / (al * bl))
		short, long = math.min(short, bl), math.max(long, bl)
	end
	return {
		minimumAngle = minimum,
		maximumAngle = maximum,
		minimumScaledJacobian = jacobian,
		aspectRatio = long / short,
		plane = plane,
	}
end
function Q.triangles(mesh, faces, uv, visit)
	local result = {}
	for _, fid in faces do
		local face = mesh.faces[fid]
		for _, t in mesh:faceTriangles(fid, { validateSimple = true, _visit = visit }) do
			visit(1)
			local ids = { face.vertices[t[1]], face.vertices[t[2]], face.vertices[t[3]] }
			table.insert(result, { ids = ids, uv = { uv[ids[1]], uv[ids[2]], uv[ids[3]] } })
		end
	end
	return result
end
function Q.normalChange(source, target, pairs, positions, visit)
	local mesh = { vertices = positions }
	local maximum = 0
	for _, pair in pairs do
		local a = G.plane(mesh, source[pair[1]].ids, visit)
		local b = G.plane(mesh, target[pair[2]].ids, visit)
		if not a or not b then
			return nil
		end
		maximum = math.max(maximum, Q.angle(a, b))
	end
	return maximum
end
return Q
