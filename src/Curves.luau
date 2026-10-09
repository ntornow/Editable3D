--!strict
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
type Mesh = Mesh.Mesh
-- Curve evaluators map a parameter in [0,1] to a point.
export type Curve<T> = (t: number) -> T
-- closed=false lofts open rows (a sheet, e.g. a curtain); triangles=true emits two triangles per
-- quad and drops zero-area ones (robust for strongly deformed or pinched rings).
-- outward: for a capped closed loft, reverse the winding when the enclosed volume is negative, so
-- the normals face out whichever way the rings run (rings stacked along -axis wind inward).
-- capFan: close each end with a triangle fan around the ring's centroid instead of one polygon,
-- skipping zero-area triangles. End rings that are collinear, repeat points or self-intersect cannot
-- be triangulated as one polygon; fans always can. Fan corners carry the ring's UVs (v = 0 or 1).
export type LoftOptions = { closed: boolean?, triangles: boolean?, outward: boolean?, capFan: boolean? }
-- The frame a sweep places each profile in: point on the path, unit tangent, and the profile's
-- x and y axes (parallel-transported along the path).
export type SweepFrame = { point: Vector3, tangent: Vector3, x: Vector3, y: Vector3 }
-- profile functions return the ring for one path sample; every ring needs the same point count.
export type SweepProfile = { Vector2 } | (fraction: number, frame: SweepFrame) -> { Vector2 }
export type SweepOptions = {
	up: Vector3?,
	scale: ((fraction: number) -> number)?,
	caps: boolean?,
	closed: boolean?,
	triangles: boolean?,
}
export type Stroke2DOptions = { closed: boolean?, cap: string?, miterLimit: number?, material: number? }
local C = {}
-- Points are polymorphic: any value with :Lerp (Vector2, Vector3, CFrame, Color3).
function C.bezier<T>(points: { T }): Curve<T>
	assert(#points >= 2)
	return function(t: number): T
		t = math.clamp(t, 0, 1)
		local p: { any } = table.clone(points)
		for n = #p - 1, 1, -1 do
			for i = 1, n do
				p[i] = p[i]:Lerp(p[i + 1], t)
			end
		end
		return p[1]
	end
end
-- Points are Vector2 or Vector3 (anything supporting vector arithmetic).
function C.catmullRom<T>(points: { T }, closed: boolean?): Curve<T>
	assert(#points >= 2)
	local count = closed and #points or #points - 1
	local function at(i: number): any
		return points[closed and (i - 1) % #points + 1 or math.clamp(i, 1, #points)]
	end
	return function(t: number): T
		t = math.clamp(t, 0, 1) * count
		local i = math.min(math.floor(t), count - 1) + 1
		local f = t - (i - 1)
		local a, b, c, d = at(i - 1), at(i), at(i + 1), at(i + 2)
		return (
			2 * b
			+ (c - a) * f
			+ (2 * a - 5 * b + 4 * c - d) * f * f
			+ (-a + 3 * b - 3 * c + d) * f * f * f
		) * 0.5
	end
end
function C.nurbs(
	points: { Vector3 },
	degree: number,
	knots: { number }?,
	weights: { number }?
): Curve<Vector3>
	U.integer(degree, 1)
	assert(#points > degree)
	local n = #points
	if not knots then
		knots = {}
		for i = 1, n + degree + 1 do
			(knots :: any)[i] = i <= degree + 1 and 0 or i >= n + 1 and 1 or (i - degree - 1) / (n - degree)
		end
	end
	-- Either supplied or generated above; the solver does not narrow after assignment.
	local knots = knots :: { number }
	assert(#knots == n + degree + 1)
	for i = 2, #knots do
		assert(knots[i] >= knots[i - 1])
	end
	local weights: { number } = weights or table.create(n, 1)
	assert(#weights == n)
	for _, w in weights do
		assert(w > 0)
	end
	return function(t: number): Vector3
		local u = knots[degree + 1] + math.clamp(t, 0, 1) * (knots[n + 1] - knots[degree + 1])
		if t >= 1 then
			u = knots[n + 1] - 1e-12
		end
		local basis: { number } = {}
		for i = 1, n + degree do
			basis[i] = (u >= knots[i] and u < knots[i + 1]) and 1 or 0
		end
		for d = 1, degree do
			local nextBasis: { number } = {}
			for i = 1, n + degree - d do
				local a, b = knots[i + d] - knots[i], knots[i + d + 1] - knots[i + 1]
				nextBasis[i] = (a > 0 and (u - knots[i]) / a * basis[i] or 0)
					+ (b > 0 and (knots[i + d + 1] - u) / b * basis[i + 1] or 0)
			end
			basis = nextBasis
		end
		local p = Vector3.zero
		local sum = 0
		for i = 1, n do
			local w = basis[i] * weights[i]
			sum += w
			p += points[i] * w
		end
		assert(sum > 0, "Invalid knot domain")
		return p / sum
	end
end
function C.sample<T>(curve: Curve<T>, segments: number): { T }
	U.integer(segments, 1)
	local r: { T } = {}
	for i = 0, segments do
		r[i + 1] = curve(i / segments)
	end
	return r
end
-- Points are Vector2 or Vector3 (arithmetic, .Magnitude and :Lerp).
function C.resample<T>(points: { T }, count: number): { T }
	U.integer(count, 2)
	assert(#points >= 2)
	local lengths = { 0 }
	for i = 2, #points do
		lengths[i] = lengths[i - 1] + ((points[i] :: any) - points[i - 1]).Magnitude
	end
	assert(lengths[#points] > 0)
	local result: { T } = {}
	local j = 2
	for i = 0, count - 1 do
		local s = lengths[#points] * i / (count - 1)
		while j < #points and lengths[j] < s do
			j += 1
		end
		local d = lengths[j] - lengths[j - 1]
		table.insert(
			result,
			d > 0 and (points[j - 1] :: any):Lerp(points[j], (s - lengths[j - 1]) / d) or points[j]
		)
	end
	return result
end
function C.circle(radius: number, segments: number): { Vector2 }
	assert(radius > 0)
	U.integer(segments, 3)
	local r: { Vector2 } = {}
	for i = 0, segments - 1 do
		r[i + 1] = Vector2.new(math.cos(2 * math.pi * i / segments), math.sin(2 * math.pi * i / segments))
			* radius
	end
	return r
end
function C.loft(rings: { { Vector3 } }, caps: boolean?, options: LoftOptions?): Mesh
	assert(#rings >= 2 and #rings[1] >= 3)
	local closed = not (options and options.closed == false)
	local triangles = options ~= nil and options.triangles == true
	local m = Mesh.new()
	local ids: { { number } } = {}
	local n = #rings[1]
	for i, ring in rings do
		assert(#ring == n, "Loft loops must have matching sample counts")
		ids[i] = {}
		for j, p in ring do
			ids[i][j] = m:addVertex(p)
		end
	end
	local columns = if closed then n else n - 1
	local function uv(j: number, i: number): Vector2
		return Vector2.new((j - 1) / columns, (i - 1) / (#rings - 1))
	end
	local function triangle(a: number, b: number, c: number, ua: Vector2, ub: Vector2, uc: Vector2)
		local pa = m.vertices[a]
		if (m.vertices[b] - pa):Cross(m.vertices[c] - pa).Magnitude > 1e-12 then
			m:addFace({ a, b, c }, { { uv = ua }, { uv = ub }, { uv = uc } })
		end
	end
	for i = 1, #rings - 1 do
		for j = 1, columns do
			local k = j % n + 1
			local a, b, c, d = ids[i][j], ids[i][k], ids[i + 1][k], ids[i + 1][j]
			local ua, ub, uc, ud = uv(j, i), uv(j + 1, i), uv(j + 1, i + 1), uv(j, i + 1)
			if triangles then
				triangle(a, b, c, ua, ub, uc)
				triangle(a, c, d, ua, uc, ud)
			else
				m:addFace({ a, b, c, d }, { { uv = ua }, { uv = ub }, { uv = uc }, { uv = ud } })
			end
		end
	end
	if caps and closed and options and options.capFan then
		local function fan(i: number, flip: boolean)
			local centre = Vector3.zero
			for j = 1, n do
				centre += m.vertices[ids[i][j]]
			end
			centre /= n
			local c = m:addVertex(centre)
			local v = (i - 1) / (#rings - 1)
			for j = 1, n do
				local k = j % n + 1
				local a, b = ids[i][j], ids[i][k]
				if (m.vertices[a] - centre):Cross(m.vertices[b] - centre).Magnitude > 1e-12 then
					local ua, ub = Vector2.new((j - 1) / columns, v), Vector2.new(j / columns, v)
					local uc = Vector2.new((j - 0.5) / columns, v)
					if flip then
						m:addFace({ c, b, a }, { { uv = uc }, { uv = ub }, { uv = ua } })
					else
						m:addFace({ c, a, b }, { { uv = uc }, { uv = ua }, { uv = ub } })
					end
				end
			end
		end
		fan(1, true)
		fan(#rings, false)
	elseif caps and closed then
		local first: { number } = {}
		for j = n, 1, -1 do
			table.insert(first, ids[1][j])
		end
		m:addFace(first)
		m:addFace(ids[#ids])
	end
	if caps and closed then
		if options and options.outward then
			local volume = 0
			for _, f in m.faces do
				local a = m.vertices[f.vertices[1]]
				for k = 2, #f.vertices - 1 do
					volume += a:Dot(m.vertices[f.vertices[k]]:Cross(m.vertices[f.vertices[k + 1]]))
				end
			end
			if volume < 0 then
				for _, f in m.faces do
					local v, c = {}, {}
					for k = #f.vertices, 1, -1 do
						table.insert(v, f.vertices[k])
						table.insert(c, f.corners[k])
					end
					f.vertices, f.corners = v, c
				end
			end
		end
	end
	return m:recalculateNormals()
end
function C.sweep(profile: SweepProfile, path: { Vector3 }, options: SweepOptions?): Mesh
	local options: SweepOptions = options or {}
	assert(#path >= 2)
	if type(profile) == "table" then
		assert(#profile >= 3)
	end
	local rings: { { Vector3 } } = {}
	local previousX: Vector3?
	for i, p in path do
		local tangent = U.unit(path[math.min(i + 1, #path)] - path[math.max(i - 1, 1)])
		local x, y = U.frame(tangent, options.up)
		if previousX then
			local projected = previousX - tangent * previousX:Dot(tangent)
			if projected.Magnitude > 1e-8 then
				x = projected.Unit
				y = tangent:Cross(x)
			end
		end
		previousX = x
		local fraction = (i - 1) / (#path - 1)
		local ring: { Vector2 }
		if type(profile) == "function" then
			ring = profile(fraction, { point = p, tangent = tangent, x = x, y = y })
			assert(
				type(ring) == "table" and #ring >= 3,
				"Sweep profile function must return at least 3 points"
			)
		else
			ring = profile
		end
		rings[i] = {}
		local scale = options.scale and options.scale(fraction) or 1
		for j, q in ring do
			rings[i][j] = p + (x * q.X + y * q.Y) * scale
		end
	end
	return C.loft(rings, options.caps ~= false, { closed = options.closed, triangles = options.triangles })
end
export type EllipseLevel = { y: number, x0: number, x1: number, z0: number, z1: number }
export type EllipseStackOptions = {
	columns: number?,
	exponent: number?,
	step: number?,
	capBottom: number?,
	capTop: number?,
}
-- Rows of rings for a closed form measured from two orthographic elevations: at each level y the front (or back)
-- elevation gives the x range [x0, x1] and the side elevation the z range [z0, z1], and the ring is the superellipse
-- (exponent, default 2 = ellipse; larger is boxier) inscribed in that rectangle. Both outlines then match by
-- construction: a sleeve's hanging bag, a sack, a rounded mass on a figure. Levels are interpolated linearly every
-- step studs (default: the levels as given); capBottom / capTop shrink the semi-axes as a quarter ellipse over that
-- many studs so the form closes round. Each row has columns + 1 points (default 64; the last repeats the first),
-- column 1 at +x, advancing toward +z. Use with Topology.gridSheet or Roblox.gridModel.
function C.ellipseStack(levels: { EllipseLevel }, options: EllipseStackOptions?): { { Vector3 } }
	local o: EllipseStackOptions = options or {}
	assert(#levels >= 2, "ellipseStack needs at least two levels")
	for i = 2, #levels do
		assert(levels[i].y > levels[i - 1].y, "ellipseStack levels must ascend in y")
	end
	local columns = o.columns or 64
	U.integer(columns, 3)
	local n = o.exponent or 2
	assert(n > 0, "ellipseStack exponent must be positive")
	local y0, y1 = levels[1].y, levels[#levels].y
	local ys: { number } = {}
	if o.step then
		assert(o.step > 0, "ellipseStack step must be positive")
		local count = math.max(1, math.ceil((y1 - y0) / o.step))
		for i = 0, count do
			table.insert(ys, y0 + (y1 - y0) * i / count)
		end
	else
		for _, l in levels do
			table.insert(ys, l.y)
		end
	end
	local function at(y: number): (number, number, number, number)
		local k = 1
		while k < #levels - 1 and levels[k + 1].y < y do
			k += 1
		end
		local a, b = levels[k], levels[k + 1]
		local t = math.clamp((y - a.y) / (b.y - a.y), 0, 1)
		return a.x0 + (b.x0 - a.x0) * t,
			a.x1 + (b.x1 - a.x1) * t,
			a.z0 + (b.z0 - a.z0) * t,
			a.z1 + (b.z1 - a.z1) * t
	end
	local rows: { { Vector3 } } = {}
	for _, y in ys do
		local x0, x1, z0, z1 = at(y)
		local cx, cz, ax, az = (x0 + x1) / 2, (z0 + z1) / 2, (x1 - x0) / 2, (z1 - z0) / 2
		local shrink = 1
		if o.capBottom and o.capBottom > 0 then
			local h = math.clamp((y - y0) / o.capBottom, 0, 1)
			shrink *= math.sqrt(1 - (1 - h) ^ 2)
		end
		if o.capTop and o.capTop > 0 then
			local h = math.clamp((y1 - y) / o.capTop, 0, 1)
			shrink *= math.sqrt(1 - (1 - h) ^ 2)
		end
		shrink = math.max(shrink, 1e-3)
		local row: { Vector3 } = table.create(columns + 1)
		for j = 0, columns do
			local a = 2 * math.pi * (j % columns) / columns
			local c, sn = math.cos(a), math.sin(a)
			local ex = math.sign(c) * math.abs(c) ^ (2 / n)
			local ez = math.sign(sn) * math.abs(sn) ^ (2 / n)
			row[j + 1] = Vector3.new(cx + ax * shrink * ex, y, cz + az * shrink * ez)
		end
		table.insert(rows, row)
	end
	return rows
end
function C.lathe(profile: { Vector2 }, segments: number): Mesh
	U.integer(segments, 3)
	assert(#profile >= 2)
	local m = Mesh.new()
	local rows: { [number]: { [number]: number } } = {}
	for i, p in profile do
		assert(p.X >= 0)
		rows[i] = {}
		if p.X < 1e-10 then
			local pole = m:addVertex(Vector3.new(0, p.Y, 0))
			for j = 0, segments - 1 do
				rows[i][j] = pole
			end
		else
			for j = 0, segments - 1 do
				local a = 2 * math.pi * j / segments
				rows[i][j] = m:addVertex(Vector3.new(p.X * math.cos(a), p.Y, p.X * math.sin(a)))
			end
		end
	end
	for i = 1, #rows - 1 do
		for j = 0, segments - 1 do
			local k = (j + 1) % segments
			local v = { rows[i][j], rows[i + 1][j], rows[i + 1][k], rows[i][k] }
			local unique: { number }, seen: { [number]: boolean } = {}, {}
			for _, id in v do
				if not seen[id] then
					seen[id] = true
					table.insert(unique, id)
				end
			end
			if #unique >= 3 then
				m:addFace(unique)
			end
		end
	end
	return m:recalculateNormals()
end
function C.bezierSurface(control: { { Vector3 } }, uSegments: number, vSegments: number): Mesh
	assert(#control >= 2)
	local rowCurves: { Curve<Vector3> } = {}
	for i, row in control do
		rowCurves[i] = C.bezier(row)
	end
	local m = Mesh.new()
	local rows: { [number]: { [number]: number } } = {}
	U.integer(uSegments, 1)
	U.integer(vSegments, 1)
	for i = 0, uSegments do
		rows[i] = {}
		local points: { Vector3 } = {}
		for j, curve in rowCurves do
			points[j] = curve(i / uSegments)
		end
		local vCurve = C.bezier(points)
		for j = 0, vSegments do
			rows[i][j] = m:addVertex(vCurve(j / vSegments))
		end
	end
	for i = 0, uSegments - 1 do
		for j = 0, vSegments - 1 do
			m:addFace({ rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1] })
		end
	end
	return m:recalculateNormals()
end
-- Connected planar ribbon around an open or closed polyline in XY (+Z normal).
-- Miter joins are bounded by an explicit limit; oversized joins reject.
function C.stroke2D(points: { Vector2 }, width: number, options: Stroke2DOptions?): Mesh
	local options: Stroke2DOptions = options or {}
	assert(U.finite(width) and width > 0, "Positive stroke width required")
	local closed = options.closed == true
	assert(#points >= (closed and 3 or 2), "Insufficient stroke points")
	local cap = options.cap or "BUTT"
	assert(cap == "BUTT" or cap == "SQUARE", "Stroke cap must be BUTT or SQUARE")
	local limit = options.miterLimit or 4
	assert(U.finite(limit) and limit >= 1, "Miter limit must be at least one")
	local directions: { Vector2 }, normals: { Vector2 }, lengths = {}, {}, { 0 }
	for i, p in points do
		assert(
			typeof(p) == "Vector2" and U.finite(p.X) and U.finite(p.Y),
			"Finite Vector2 stroke points required"
		)
		if closed or i < #points then
			local d = points[i % #points + 1] - p
			assert(d.Magnitude > 1e-8, "Repeated stroke point")
			directions[i] = d.Unit
			normals[i] = Vector2.new(-d.Unit.Y, d.Unit.X)
			lengths[i + 1] = lengths[i] + d.Magnitude
		end
	end
	local mesh, pairs: { { number } } = Mesh.new(), {}
	for i, p in points do
		local offset: Vector2
		if not closed and i == 1 then
			offset = normals[1] * width / 2
			if cap == "SQUARE" then
				p -= directions[1] * width / 2
			end
		elseif not closed and i == #points then
			offset = normals[i - 1] * width / 2
			if cap == "SQUARE" then
				p += directions[i - 1] * width / 2
			end
		else
			local previous = (i - 2) % #points + 1
			local bisector = normals[previous] + normals[i]
			assert(bisector.Magnitude > 1e-8, "Stroke reverses direction")
			bisector = bisector.Unit
			local denominator = bisector:Dot(normals[i])
			assert(denominator >= 1 / limit - 1e-8, "Stroke miter exceeds limit; subdivide or reshape corner")
			offset = bisector * (width / 2 / denominator)
		end
		local a, b = p + offset, p - offset
		pairs[i] = { mesh:addVertex(Vector3.new(a.X, a.Y, 0)), mesh:addVertex(Vector3.new(b.X, b.Y, 0)) }
	end
	local total = lengths[#lengths]
	for i = 1, closed and #points or #points - 1 do
		local j = i % #points + 1
		local u, v = lengths[i] / total, lengths[i + 1] / total
		mesh:addFace({ pairs[i][2], pairs[j][2], pairs[j][1], pairs[i][1] }, {
			{ uv = Vector2.new(u, 1) },
			{ uv = Vector2.new(v, 1) },
			{ uv = Vector2.new(v, 0) },
			{ uv = Vector2.new(u, 0) },
		}, options.material)
	end
	return mesh:recalculateNormals(0)
end
return C
