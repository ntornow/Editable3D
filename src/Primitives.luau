--!strict
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
local P = {}
function P.grid(nx: number, nz: number, size: Vector2?): Mesh
	U.integer(nx, 1)
	U.integer(nz, 1)
	local size: Vector2 = size or Vector2.new(2, 2)
	local m = Mesh.new()
	local rows: { [number]: { [number]: number } } = {}
	for z = 0, nz do
		rows[z] = {}
		for x = 0, nx do
			rows[z][x] = m:addVertex(Vector3.new((x / nx - 0.5) * size.X, 0, (z / nz - 0.5) * size.Y))
		end
	end
	for z = 0, nz - 1 do
		for x = 0, nx - 1 do
			m:addFace({ rows[z][x], rows[z + 1][x], rows[z + 1][x + 1], rows[z][x + 1] }, {
				{ uv = Vector2.new(x / nx, z / nz) },
				{ uv = Vector2.new(x / nx, (z + 1) / nz) },
				{ uv = Vector2.new((x + 1) / nx, (z + 1) / nz) },
				{ uv = Vector2.new((x + 1) / nx, z / nz) },
			})
		end
	end
	return m:recalculateNormals()
end
function P.box(size: Vector3?): Mesh
	local size: Vector3 = size or Vector3.new(2, 2, 2)
	assert(size.X > 0 and size.Y > 0 and size.Z > 0, "Positive size required")
	local m = Mesh.new()
	for _, p in
		{
			Vector3.new(-1, -1, -1),
			Vector3.new(1, -1, -1),
			Vector3.new(1, 1, -1),
			Vector3.new(-1, 1, -1),
			Vector3.new(-1, -1, 1),
			Vector3.new(1, -1, 1),
			Vector3.new(1, 1, 1),
			Vector3.new(-1, 1, 1),
		}
	do
		m:addVertex(p * size * 0.5)
	end
	for _, f in
		{ { 4, 3, 2, 1 }, { 5, 6, 7, 8 }, { 1, 2, 6, 5 }, { 2, 3, 7, 6 }, { 3, 4, 8, 7 }, { 4, 1, 5, 8 } }
	do
		m:addFace(f, {
			{ uv = Vector2.new(0, 0) },
			{ uv = Vector2.new(1, 0) },
			{ uv = Vector2.new(1, 1) },
			{
				uv = Vector2.new(0, 1),
			},
		})
	end
	return m:recalculateNormals(0)
end
function P.sphere(radius: number?, segments: number?, rings: number?): Mesh
	local radius: number = radius or 1
	local segments: number = segments or 32
	local rings: number = rings or 16
	assert(radius > 0)
	U.integer(segments, 3)
	U.integer(rings, 2)
	local m = Mesh.new()
	local north = m:addVertex(Vector3.new(0, radius, 0))
	local rows: { [number]: { [number]: number } } = {}
	for j = 1, rings - 1 do
		rows[j] = {}
		local a = math.pi * j / rings
		for i = 0, segments - 1 do
			local b = 2 * math.pi * i / segments
			rows[j][i] = m:addVertex(
				Vector3.new(math.sin(a) * math.cos(b), math.cos(a), math.sin(a) * math.sin(b)) * radius
			)
		end
	end
	local south = m:addVertex(Vector3.new(0, -radius, 0))
	for i = 0, segments - 1 do
		local k = (i + 1) % segments
		m:addFace({ north, rows[1][k], rows[1][i] })
		m:addFace({ rows[rings - 1][i], rows[rings - 1][k], south })
	end
	for j = 1, rings - 2 do
		for i = 0, segments - 1 do
			local k = (i + 1) % segments
			m:addFace({ rows[j][i], rows[j][k], rows[j + 1][k], rows[j + 1][i] })
		end
	end
	return m:recalculateNormals()
end
function P.cylinder(radius: number?, height: number?, segments: number?, topRadius: number?): Mesh
	local radius: number = radius or 1
	local height: number = height or 2
	local segments: number = segments or 32
	local topRadius: number = topRadius or radius
	assert(radius > 0 and topRadius > 0 and height > 0)
	U.integer(segments, 3)
	local m = Mesh.new()
	local bottom: { number }, top: { number } = {}, {}
	for i = 1, segments do
		local a = 2 * math.pi * (i - 1) / segments
		bottom[i] = m:addVertex(Vector3.new(radius * math.cos(a), -height / 2, radius * math.sin(a)))
		top[i] = m:addVertex(Vector3.new(topRadius * math.cos(a), height / 2, topRadius * math.sin(a)))
	end
	for i = 1, segments do
		local j = i % segments + 1
		m:addFace({ bottom[i], top[i], top[j], bottom[j] })
	end
	m:addFace(bottom)
	local rev: { number } = {}
	for i = segments, 1, -1 do
		table.insert(rev, top[i])
	end
	m:addFace(rev)
	return m:recalculateNormals(math.pi / 3)
end
function P.torus(major: number?, minor: number?, segments: number?, sides: number?): Mesh
	local major: number = major or 2
	local minor: number = minor or 0.5
	local segments: number = segments or 32
	local sides: number = sides or 12
	assert(major > minor and minor > 0)
	U.integer(segments, 3)
	U.integer(sides, 3)
	local m = Mesh.new()
	local rows: { [number]: { [number]: number } } = {}
	for i = 0, segments - 1 do
		rows[i] = {}
		local a = 2 * math.pi * i / segments
		for j = 0, sides - 1 do
			local b = 2 * math.pi * j / sides
			rows[i][j] = m:addVertex(
				Vector3.new(
					(major + minor * math.cos(b)) * math.cos(a),
					minor * math.sin(b),
					(major + minor * math.cos(b)) * math.sin(a)
				)
			)
		end
	end
	for i = 0, segments - 1 do
		for j = 0, sides - 1 do
			m:addFace({
				rows[i][j],
				rows[i][(j + 1) % sides],
				rows[(i + 1) % segments][(j + 1) % sides],
				rows[(i + 1) % segments][j],
			})
		end
	end
	return m:recalculateNormals()
end
-- Straight prism over a polygon in the XZ plane (Vector2(x, z), convex or concave, either winding),
-- from y0 to y1. Faces point outward, side faces are flat-shaded (unshared vertices), and caps are
-- single polygons (concave caps triangulate by ear clipping). bottomScale > 1 widens the base
-- about the polygon centroid for battered walls. UVs: sides (perimeter length, y), caps (x, z).
function P.prism(polygon: { Vector2 }, y0: number, y1: number, options: { bottomScale: number? }?): Mesh
	assert(#polygon >= 3, "Prism needs at least three points")
	assert(y1 > y0, "Prism needs y1 > y0")
	local scale = (options and options.bottomScale) or 1
	assert(scale > 0, "Positive bottomScale required")
	local n = #polygon
	local area, centroid = 0, Vector2.zero
	for i = 1, n do
		local a, b = polygon[i], polygon[i % n + 1]
		area += a.X * b.Y - b.X * a.Y
		centroid += a
	end
	centroid /= n
	-- walk the polygon in the winding that makes the side quads face outward (positive signed
	-- volume, the same convention as P.box)
	local pts = table.clone(polygon)
	if area < 0 then
		local r = {}
		for i = n, 1, -1 do
			table.insert(r, pts[i])
		end
		pts = r
	end
	local function bottom(p: Vector2): Vector3
		local q = centroid + (p - centroid) * scale
		return Vector3.new(q.X, y0, q.Y)
	end
	local function top(p: Vector2): Vector3
		return Vector3.new(p.X, y1, p.Y)
	end
	local m = Mesh.new()
	local run = 0
	for i = 1, n do
		local a, b = pts[i], pts[i % n + 1]
		local len = (b - a).Magnitude
		local ids =
			{ m:addVertex(bottom(a)), m:addVertex(top(a)), m:addVertex(top(b)), m:addVertex(bottom(b)) }
		m:addFace(ids, {
			{ uv = Vector2.new(run, y0) },
			{ uv = Vector2.new(run, y1) },
			{ uv = Vector2.new(run + len, y1) },
			{ uv = Vector2.new(run + len, y0) },
		})
		run += len
	end
	local topIds, topCorners, bottomIds, bottomCorners = {}, {}, {}, {}
	for i = n, 1, -1 do
		table.insert(topIds, m:addVertex(top(pts[i])))
		table.insert(topCorners, { uv = pts[i] })
	end
	for i = 1, n do
		local b = bottom(pts[i])
		table.insert(bottomIds, m:addVertex(b))
		table.insert(bottomCorners, { uv = Vector2.new(b.X, b.Z) })
	end
	m:addFace(topIds, topCorners)
	m:addFace(bottomIds, bottomCorners)
	return m:recalculateNormals()
end
-- A flight of `steps` steps, `width` wide (x centred on 0), climbing `height` over `depth` toward +Z:
-- the first step's front is at z = -depth and the top step ends at z = 0. Built as stacked blocks
-- that each run back to z = 0, so the flight is solid. Place it with Deform.transform.
function P.stairs(width: number, depth: number, height: number, steps: number): Mesh
	U.integer(steps, 1)
	assert(width > 0 and depth > 0 and height > 0, "Positive stair size required")
	local rise, tread = height / steps, depth / steps
	local m = Mesh.new()
	for k = 1, steps do
		local z0, y1 = -depth + (k - 1) * tread, rise * k
		local block = P.prism({
			Vector2.new(-width / 2, z0),
			Vector2.new(width / 2, z0),
			Vector2.new(width / 2, 0),
			Vector2.new(-width / 2, 0),
		}, rise * (k - 1), y1)
		local map = {}
		for id, v in block.vertices do
			map[id] = m:addVertex(v)
		end
		for _, f in block.faces do
			local ids = {}
			for i, v in f.vertices do
				ids[i] = map[v]
			end
			m:addFace(ids, f.corners)
		end
	end
	return m:recalculateNormals()
end
return P
