-- Private exact native-coordinate classification with homogeneous constructions.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local X = require(script.Parent.ExpansionArithmetic)
local axes = { "X", "Y", "Z" }
local add, sub, mul, diff = X.add, X.subtract, X.multiply, X.difference
local function determinant3(a, b, c)
	return add(
		sub(
			mul(a[1], sub(mul(b[2], c[3]), mul(b[3], c[2]))),
			mul(a[2], sub(mul(b[1], c[3]), mul(b[3], c[1])))
		),
		mul(a[3], sub(mul(b[1], c[2]), mul(b[2], c[1])))
	)
end
local function plane(tri, p)
	local rows = {}
	for i, q in { tri[2], tri[3], p } do
		rows[i] = { diff(q.X, tri[1].X), diff(q.Y, tri[1].Y), diff(q.Z, tri[1].Z) }
	end
	return determinant3(rows[1], rows[2], rows[3])
end
local function projection(tri)
	assert(type(tri) == "table" and #tri == 3, "Three triangle vertices required")
	for _, p in tri do
		assert(U.vector(p), "Finite native Vector3 triangle vertices required")
	end
	local best, magnitude, orientation, projected = nil, -1, nil, nil
	for axis = 1, 3 do
		local a, b = axis % 3 + 1, (axis + 1) % 3 + 1
		local points = {}
		for i, p in tri do
			points[i] = Vector2.new(p[axes[a]], p[axes[b]])
		end
		local sign, value = P.orient2D(points[1], points[2], points[3])
		if sign ~= 0 and math.abs(value) > magnitude then
			best, magnitude, orientation, projected = axis, math.abs(value), sign, points
		end
	end
	assert(best, "Intersection requires nondegenerate triangles")
	return { axis = best, a = best % 3 + 1, b = (best + 1) % 3 + 1, sign = orientation, points = projected }
end
local function homogeneous(numerators, denominator)
	if X.sign(denominator) < 0 then
		denominator = X.negate(denominator)
		for i, value in numerators do
			numerators[i] = X.negate(value)
		end
	end
	assert(X.sign(denominator) > 0, "Intersection construction denominator is zero")
	local d, coordinates = X.estimate(denominator), {}
	for i, n in numerators do
		coordinates[i] = X.estimate(n) / d
	end
	local p = Vector3.new(coordinates[1], coordinates[2], coordinates[3])
	assert(U.vector(p), "Intersection position exceeds native range")
	local rounding = 0
	for i, axis in axes do
		rounding += (p[axis] - coordinates[i]) ^ 2
	end
	return {
		n = numerators,
		d = denominator,
		position = p,
		coordinates = coordinates,
		rounding = math.sqrt(rounding),
	}
end
local function native(p)
	return homogeneous({ { p.X }, { p.Y }, { p.Z } }, { 1 })
end
local function compare(a, b, axis)
	return X.sign(sub(mul(a.n[axis], b.d), mul(b.n[axis], a.d)))
end
local function same(a, b)
	return compare(a, b, 1) == 0 and compare(a, b, 2) == 0 and compare(a, b, 3) == 0
end
local function append(points, p)
	for i, old in points do
		if same(old, p) then
			return i
		end
	end
	table.insert(points, p)
	return #points
end
local function lexicographic(a, b)
	for i = 1, 3 do
		local order = compare(a, b, i)
		if order ~= 0 then
			return order < 0
		end
	end
	return false
end
local function inside(point, tri, pr)
	local p = Vector2.new(point[axes[pr.a]], point[axes[pr.b]])
	for i, a in pr.points do
		if P.orient2D(a, pr.points[i % 3 + 1], p) * pr.sign < 0 then
			return false
		end
	end
	return true
end
local function cross2(ax, ay, bx, by)
	return sub(mul(ax, by), mul(ay, bx))
end
local function planarIntersection(a, b, c, d, pr)
	local x, y = axes[pr.a], axes[pr.b]
	local denominator = cross2(diff(b[x], a[x]), diff(b[y], a[y]), diff(d[x], c[x]), diff(d[y], c[y]))
	local numerator = cross2(diff(c[x], a[x]), diff(c[y], a[y]), diff(d[x], c[x]), diff(d[y], c[y]))
	local coordinates = {}
	for i, axis in axes do
		coordinates[i] = add(mul({ a[axis] }, denominator), mul(diff(b[axis], a[axis]), numerator))
	end
	return homogeneous(coordinates, denominator)
end
local function segment(a, b, tri, pr)
	assert(U.vector(a) and U.vector(b), "Finite native segment endpoints required")
	pr = pr or projection(tri)
	local sa = P.orient3D(tri[1], tri[2], tri[3], a)
	local sb = P.orient3D(tri[1], tri[2], tri[3], b)
	local points = {}
	if sa * sb > 0 then
		return points, false
	end
	if sa == 0 and inside(a, tri, pr) then
		append(points, native(a))
	end
	if sb == 0 and inside(b, tri, pr) then
		append(points, native(b))
	end
	if sa == 0 and sb == 0 then
		local aa = Vector2.new(a[axes[pr.a]], a[axes[pr.b]])
		local bb = Vector2.new(b[axes[pr.a]], b[axes[pr.b]])
		for i, c in tri do
			local j = i % 3 + 1
			local d = tri[j]
			local hit = P.intersectSegments2D(aa, bb, pr.points[i], pr.points[j])
			if hit.kind == "point" and hit.proper then
				append(points, planarIntersection(a, b, c, d, pr))
			elseif hit.kind ~= "none" then
				local ps = hit.kind == "point" and { hit.point } or hit.points
				for _, p in ps do
					if p == aa then
						append(points, native(a))
					elseif p == bb then
						append(points, native(b))
					elseif p == pr.points[i] then
						append(points, native(c))
					elseif p == pr.points[j] then
						append(points, native(d))
					else
						error("Coplanar endpoint classification lost its source")
					end
				end
			end
		end
		return points, true
	end
	if sa == 0 or sb == 0 then
		return points, false
	end
	local positive, negative = false, false
	for i, p in tri do
		local sign = P.orient3D(a, b, p, tri[i % 3 + 1])
		positive = positive or sign > 0
		negative = negative or sign < 0
	end
	if positive and negative then
		return points, false
	end
	local da, db = plane(tri, a), plane(tri, b)
	local denominator, numerators = sub(da, db), {}
	for i, axis in axes do
		numerators[i] = sub(mul({ b[axis] }, da), mul({ a[axis] }, db))
	end
	append(points, homogeneous(numerators, denominator))
	return points, false
end

local function barycentric(p, tri, pr)
	local coordinates, denominator = {}, nil
	local ax, ay = pr.a, pr.b
	for i = 1, 3 do
		local a, b = tri[i % 3 + 1], tri[(i + 1) % 3 + 1]
		local constant = cross2({ a[axes[ax]] }, { a[axes[ay]] }, { b[axes[ax]] }, { b[axes[ay]] })
		local value = add(
			mul(constant, p.d),
			add(mul(diff(a[axes[ay]], b[axes[ay]]), p.n[ax]), mul(diff(b[axes[ax]], a[axes[ax]]), p.n[ay]))
		)
		coordinates[i] = value
		denominator = denominator and add(denominator, value) or value
	end
	local d, result = X.estimate(denominator), {}
	assert(d ~= 0, "Triangle barycentric construction denominator is zero")
	for i, value in coordinates do
		result[i] = X.estimate(value) / d
	end
	return result
end
local function export(points, dimension, coplanar, classification, a, b, pa, pb)
	if #points == 0 then
		return {
			kind = "none",
			dimension = -1,
			classification = "none",
			coplanar = coplanar,
			points = {},
			coordinates = {},
			pointData = {},
			maxRoundingError = 0,
			exactVertices = 0,
			constructionComplete = true,
		}
	end
	if dimension < 2 then
		table.sort(points, lexicographic)
	end
	if dimension < 2 and #points > 2 then
		points = { points[1], points[#points] }
	end
	local positions, coordinates, data, seen, rounding = {}, {}, {}, {}, 0
	for i, p in points do
		positions[i], coordinates[i] = p.position, p.coordinates
		data[i] = { position = p.position, coordinates = p.coordinates }
		if a then
			data[i].barycentricA = barycentric(p, a, pa)
		end
		if b then
			data[i].barycentricB = barycentric(p, b, pb)
		end
		seen[p.position] = true
		rounding = math.max(rounding, p.rounding)
	end
	local represented = U.count(seen)
	local complete = represented == #positions
	if dimension == 2 then
		local polygon = {}
		for i, p in positions do
			polygon[i] = Vector2.new(p[axes[pa.a]], p[axes[pa.b]])
		end
		complete = complete and P.polygonOrientation(polygon) > 0
		for i, p in polygon do
			complete = complete
				and P.orient2D(polygon[(i - 2) % #polygon + 1], p, polygon[i % #polygon + 1]) >= 0
		end
	end
	return {
		kind = dimension == 0 and "point" or dimension == 1 and "segment" or "polygon",
		dimension = dimension,
		coplanar = coplanar,
		classification = classification,
		points = positions,
		coordinates = coordinates,
		pointData = data,
		maxRoundingError = rounding,
		constructionComplete = complete,
		exactVertices = #positions,
	}
end
local function segmentTriangle(a, b, tri)
	local pr = projection(tri)
	local points, coplanar = segment(a, b, tri, pr)
	local dimension = #points == 0 and -1 or #points == 1 and 0 or 1
	local result = export(points, dimension, coplanar, "contact", tri, nil, pr)
	if dimension == 0 and not coplanar then
		local sa = P.orient3D(tri[1], tri[2], tri[3], a)
		local sb = P.orient3D(tri[1], tri[2], tri[3], b)
		local interior = sa * sb < 0
		for i, p in tri do
			interior = interior and P.orient3D(a, b, p, tri[i % 3 + 1]) ~= 0
		end
		result.classification = interior and "crossing" or "contact"
	end
	return result
end
local function triangles(a, b, pa, pb)
	pa, pb = pa or projection(a), pb or projection(b)
	local sa, sb, posA, negA, posB, negB = {}, {}, false, false, false, false
	for i = 1, 3 do
		sa[i] = P.orient3D(b[1], b[2], b[3], a[i])
		sb[i] = P.orient3D(a[1], a[2], a[3], b[i])
		posA, negA = posA or sa[i] > 0, negA or sa[i] < 0
		posB, negB = posB or sb[i] > 0, negB or sb[i] < 0
	end
	if
		sa[1] == sa[2] and sa[2] == sa[3] and sa[1] ~= 0
		or sb[1] == sb[2] and sb[2] == sb[3] and sb[1] ~= 0
	then
		return export({}, -1, false)
	end
	local coplanar = not posA and not negA
	local area = coplanar
	if coplanar then
		for _, pair in { { a, b, pa }, { b, a, pb } } do
			local other, pr = pair[2], pair[3]
			for i = 1, 3 do
				local maximum = -1
				for _, p in other do
					local uv = Vector2.new(p[axes[pr.a]], p[axes[pr.b]])
					maximum = math.max(maximum, P.orient2D(pr.points[i], pr.points[i % 3 + 1], uv) * pr.sign)
				end
				if maximum < 0 then
					return export({}, -1, true)
				end
				if maximum == 0 then
					area = false
				end
			end
		end
	end
	local points, nextVertex = {}, {}
	local function boundary(cuts, first, last, orientation)
		if not area or #cuts < 2 then
			return
		end
		table.sort(cuts, lexicographic)
		local a, b = cuts[1], cuts[#cuts]
		if not lexicographic(native(first), native(last)) then
			a, b = b, a
		end
		if orientation < 0 then
			a, b = b, a
		end
		local x, y = append(points, a), append(points, b)
		assert(not nextVertex[x] or nextVertex[x] == y, "Coplanar intersection boundary branches")
		nextVertex[x] = y
	end
	local orientationB
	if area then
		local projected = {}
		for i, p in b do
			projected[i] = Vector2.new(p[axes[pa.a]], p[axes[pa.b]])
		end
		orientationB = P.orient2D(projected[1], projected[2], projected[3])
	end
	for i = 1, 3 do
		local x = segment(a[i], a[i % 3 + 1], b, pb)
		for _, p in x do
			append(points, p)
		end
		boundary(x, a[i], a[i % 3 + 1], pa.sign)
		local y = segment(b[i], b[i % 3 + 1], a, pa)
		for _, p in y do
			append(points, p)
		end
		boundary(y, b[i], b[i % 3 + 1], orientationB)
	end
	if area then
		local ordered, seen, cursor = {}, {}, 1
		repeat
			assert(cursor and not seen[cursor], "Coplanar intersection boundary did not close")
			seen[cursor] = true
			table.insert(ordered, points[cursor])
			cursor = nextVertex[cursor]
		until cursor == 1
		assert(#ordered == #points, "Coplanar intersection has disconnected boundary records")
		points = ordered
	end
	local dimension = #points == 0 and -1 or area and 2 or #points == 1 and 0 or 1
	local classification = area and "overlap"
		or dimension == 1 and posA and negA and posB and negB and "crossing"
		or "contact"
	return export(points, dimension, coplanar, classification, a, b, pa, pb)
end
return { segmentTriangle = segmentTriangle, triangles = triangles, prepare = projection }
