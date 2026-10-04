--!strict
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
type Mesh = Mesh.Mesh
-- Curve evaluators map a parameter in [0,1] to a point.
export type Curve<T> = (t: number) -> T
export type SweepOptions = { up: Vector3?, scale: ((fraction: number) -> number)?, caps: boolean? }
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
function C.loft(rings: { { Vector3 } }, caps: boolean?): Mesh
	assert(#rings >= 2 and #rings[1] >= 3)
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
	for i = 1, #rings - 1 do
		for j = 1, n do
			local k = j % n + 1
			m:addFace({ ids[i][j], ids[i][k], ids[i + 1][k], ids[i + 1][j] }, {
				{ uv = Vector2.new((j - 1) / n, (i - 1) / (#rings - 1)) },
				{ uv = Vector2.new(j / n, (i - 1) / (#rings - 1)) },
				{ uv = Vector2.new(j / n, i / (#rings - 1)) },
				{ uv = Vector2.new((j - 1) / n, i / (#rings - 1)) },
			})
		end
	end
	if caps then
		local first: { number } = {}
		for j = n, 1, -1 do
			table.insert(first, ids[1][j])
		end
		m:addFace(first)
		m:addFace(ids[#ids])
	end
	return m:recalculateNormals()
end
function C.sweep(profile: { Vector2 }, path: { Vector3 }, options: SweepOptions?): Mesh
	local options: SweepOptions = options or {}
	assert(#profile >= 3 and #path >= 2)
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
		rings[i] = {}
		local scale = options.scale and options.scale((i - 1) / (#path - 1)) or 1
		for j, q in profile do
			rings[i][j] = p + (x * q.X + y * q.Y) * scale
		end
	end
	return C.loft(rings, options.caps ~= false)
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
