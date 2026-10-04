--!strict
-- Filtered signs with exact floating-point expansion fallback for native float32 coordinates.
-- Original Luau implementation of error-free transforms; no third-party source incorporated.
local U = require(script.Parent.Util)
local P = {}
local X = require(script.Parent.ExpansionArithmetic)
-- Nonoverlapping floating-point expansion, least significant component first.
type Expansion = { number }
export type Intersection = {
	kind: string, -- "none", "point" or "overlap"
	point: Vector2?,
	coordinates: { x: number, y: number }?,
	t: number?,
	u: number?,
	proper: boolean?,
	points: { Vector2 }?,
	rangeA: { number }?,
	rangeB: { number }?,
}
local add: (Expansion, Expansion) -> Expansion = X.add
local subtract: (Expansion, Expansion) -> Expansion = X.subtract
local multiply: (Expansion, Expansion) -> Expansion = X.multiply
local difference: (number, number) -> Expansion = X.difference
local negate: (Expansion) -> Expansion = X.negate
local estimate: (Expansion) -> number = X.estimate
local epsilon = 2 ^ -52
local function sign(x: number): number
	return x > 0 and 1 or x < 0 and -1 or 0
end

-- Validators accept any value and reject non-coordinates.
local function check2(p: any)
	assert(
		typeof(p) == "Vector2" and U.finite(p.X) and U.finite(p.Y),
		"Finite native Vector2 coordinates required"
	)
end
local function check3(p: any)
	assert(U.vector(p), "Finite native Vector3 coordinates required")
end
-- Entries are numbers, or expansions when exact; the result has the same kind.
local function determinant(matrix: { { any } }, exact: boolean): (any, ...number)
	local n = #matrix
	if n == 1 then
		if exact then
			return matrix[1][1]
		end
		return matrix[1][1], math.abs(matrix[1][1])
	end
	local result: any = exact and { 0 } or 0
	local permanent = 0
	for column = 1, n do
		local minor: { { any } } = {}
		for i = 2, n do
			minor[i - 1] = {}
			for j = 1, n do
				if j ~= column then
					table.insert(minor[i - 1], matrix[i][j])
				end
			end
		end
		local value, bound = determinant(minor, exact)
		if exact then
			local product = multiply(matrix[1][column], value)
			result = add(result, column % 2 == 1 and product or negate(product))
		else
			local product = matrix[1][column] * value
			result += column % 2 == 1 and product or -product
			permanent += math.abs(matrix[1][column]) * bound
		end
	end
	return result, permanent
end
-- Points are Vector2 or Vector3, read by axis name; entries follow determinant's kinds.
local function orientedMatrix(
	points: { any },
	origin: any,
	dimensions: number,
	lift: boolean,
	exact: boolean
): { { any } }
	local matrix: { { any } } = {}
	for i, p in points do
		local row: { any } = {}
		local squared: any = exact and { 0 } or 0
		for axis = 1, dimensions do
			local key = axis == 1 and "X" or axis == 2 and "Y" or "Z"
			local d: any = exact and difference(p[key], origin[key]) or p[key] - origin[key]
			row[axis] = d
			if lift then
				squared = exact and add(squared, multiply(d, d)) or squared + d * d
			end
		end
		if lift then
			row[dimensions + 1] = squared
		end
		matrix[i] = row
	end
	return matrix
end
-- The third result reports whether the exact expansion path decided the sign.
local function predicate(
	points: { any },
	origin: any,
	dimensions: number,
	lift: boolean,
	multiplier: number
): (number, number, ...boolean)
	local check = dimensions == 2 and check2 or check3
	check(origin)
	for _, p in points do
		check(p)
	end
	local approximate, permanent = determinant(orientedMatrix(points, origin, dimensions, lift, false), false)
	-- Conservative filter; the exact expansion path handles cancellation and exact zeros.
	local factor = lift and 1024 or dimensions == 3 and 128 or 32
	if math.abs(approximate) > permanent * epsilon * factor then
		return sign(approximate) * multiplier, approximate * multiplier, false
	end
	local expansion = determinant(orientedMatrix(points, origin, dimensions, lift, true), true)
	return sign(expansion[#expansion]) * multiplier, estimate(expansion) * multiplier, true
end

function P.orient2D(a: Vector2, b: Vector2, c: Vector2): (number, number, ...boolean)
	return predicate({ a, b }, c, 2, false, 1)
end
function P.orient3D(a: Vector3, b: Vector3, c: Vector3, d: Vector3): (number, number, ...boolean)
	-- Positive when (b-a,c-a,d-a) forms a right-handed frame.
	return predicate({ b, c, d }, a, 3, false, 1)
end
function P.inCircle(a: Vector2, b: Vector2, c: Vector2, d: Vector2): (number, number, ...boolean)
	-- Positive inside a counter-clockwise oriented circle; reverses with triangle orientation.
	return predicate({ a, b, c }, d, 2, true, 1)
end
function P.inSphere(a: Vector3, b: Vector3, c: Vector3, d: Vector3, e: Vector3): (number, number, ...boolean)
	-- Positive inside a positively oriented tetrahedron's circumsphere.
	return predicate({ a, b, c, d }, e, 3, true, -1)
end

function P.polygonOrientation(points: { Vector2 }): (number, number)
	assert(#points >= 3, "Three or more polygon vertices required")
	local total: Expansion = { 0 }
	for i, p in points do
		check2(p)
		local q = points[i % #points + 1]
		check2(q)
		total = add(total, subtract(multiply({ p.X }, { q.Y }), multiply({ p.Y }, { q.X })))
	end
	return sign(total[#total]), estimate(total) * 0.5
end

function P.onSegment2D(point: Vector2, a: Vector2, b: Vector2): boolean
	check2(point)
	check2(a)
	check2(b)
	return point.X >= math.min(a.X, b.X)
		and point.X <= math.max(a.X, b.X)
		and point.Y >= math.min(a.Y, b.Y)
		and point.Y <= math.max(a.Y, b.Y)
		and P.orient2D(a, b, point) == 0
end
function P.pointInPolygon2D(point: Vector2, points: { Vector2 }): (string, number)
	check2(point)
	assert(#points >= 3, "Three or more polygon vertices required")
	local winding = 0
	for i, a in points do
		local b = points[i % #points + 1]
		check2(a)
		check2(b)
		if P.onSegment2D(point, a, b) then
			return "boundary", 0
		end
		local side = P.orient2D(a, b, point)
		if a.Y <= point.Y and b.Y > point.Y and side > 0 then
			winding += 1
		elseif a.Y > point.Y and b.Y <= point.Y and side < 0 then
			winding -= 1
		end
	end
	return winding ~= 0 and "inside" or "outside", winding
end

local function parameter(point: Vector2, a: Vector2, b: Vector2): number
	local x, y = b.X - a.X, b.Y - a.Y
	if math.abs(x) >= math.abs(y) then
		return x ~= 0 and (point.X - a.X) / x or 0
	end
	return (point.Y - a.Y) / y
end
local function crossCoordinates(a: Vector2, b: Vector2): Expansion
	return subtract(multiply({ a.X }, { b.Y }), multiply({ a.Y }, { b.X }))
end
local function crossDifferences(a: Vector2, b: Vector2, c: Vector2, d: Vector2): Expansion
	return subtract(
		multiply(difference(b.X, a.X), difference(d.Y, c.Y)),
		multiply(difference(b.Y, a.Y), difference(d.X, c.X))
	)
end
function P.intersectSegments2D(a: Vector2, b: Vector2, c: Vector2, d: Vector2): Intersection
	check2(a)
	check2(b)
	check2(c)
	check2(d)
	if
		math.max(a.X, b.X) < math.min(c.X, d.X)
		or math.max(c.X, d.X) < math.min(a.X, b.X)
		or math.max(a.Y, b.Y) < math.min(c.Y, d.Y)
		or math.max(c.Y, d.Y) < math.min(a.Y, b.Y)
	then
		return { kind = "none" }
	end
	local ac, ad, ca, cb = P.orient2D(a, b, c), P.orient2D(a, b, d), P.orient2D(c, d, a), P.orient2D(c, d, b)
	if ac * ad > 0 or ca * cb > 0 then
		return { kind = "none" }
	end
	if ac * ad < 0 and ca * cb < 0 then
		local denominator = estimate(crossDifferences(a, b, c, d))
		assert(denominator ~= 0 and U.finite(denominator), "Intersection denominator outside numerical range")
		local ab, cd = crossCoordinates(a, b), crossCoordinates(c, d)
		local x = estimate(subtract(multiply(ab, difference(c.X, d.X)), multiply(difference(a.X, b.X), cd)))
			/ denominator
		local y = estimate(subtract(multiply(ab, difference(c.Y, d.Y)), multiply(difference(a.Y, b.Y), cd)))
			/ denominator
		local t = estimate(crossDifferences(a, c, c, d)) / denominator
		local u = estimate(crossDifferences(a, c, a, b)) / denominator
		return {
			kind = "point",
			point = Vector2.new(x, y),
			coordinates = { x = x, y = y },
			t = math.clamp(t, 0, 1),
			u = math.clamp(u, 0, 1),
			proper = true,
		}
	end
	local shared: { Vector2 } = {}
	for _, p in { a, b, c, d } do
		if P.onSegment2D(p, a, b) and P.onSegment2D(p, c, d) then
			local duplicate = false
			for _, q in shared do
				if p == q then
					duplicate = true
					break
				end
			end
			if not duplicate then
				table.insert(shared, p)
			end
		end
	end
	if #shared == 0 then
		return { kind = "none" }
	end
	table.sort(shared, function(p, q)
		return p.X < q.X or p.X == q.X and p.Y < q.Y
	end)
	if #shared == 1 then
		local p = shared[1]
		return {
			kind = "point",
			point = p,
			coordinates = { x = p.X, y = p.Y },
			t = parameter(p, a, b),
			u = parameter(p, c, d),
			proper = false,
		}
	end
	local first, last = shared[1], shared[#shared]
	return {
		kind = "overlap",
		points = { first, last },
		rangeA = { parameter(first, a, b), parameter(last, a, b) },
		rangeB = { parameter(first, c, d), parameter(last, c, d) },
	}
end
return P
