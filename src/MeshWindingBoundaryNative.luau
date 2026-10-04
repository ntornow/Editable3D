-- Private bounded winding classification of arranged source-triangle cells.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local T = require(script.Parent.TriangleIntersectionCore)
local Spatial = require(script.Parent.Spatial)
local directions = {
	Vector3.new(13, 7, 3),
	Vector3.new(-5, 11, 17),
	Vector3.new(19, -3, 7),
	Vector3.new(7, 17, -11),
	Vector3.new(-13, -7, 5),
	Vector3.new(3, -19, -11),
	Vector3.new(-17, 5, -7),
	Vector3.new(11, 3, 19),
	Vector3.new(5, -13, 17),
	Vector3.new(-7, 19, 3),
	Vector3.new(17, 11, -5),
	Vector3.new(-3, -5, -13),
}
local function distance(a, b)
	local x, y, z = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return math.sqrt(x * x + y * y + z * z)
end
local function projectedInside(context, p)
	local q, tri = context.project(p), context.projection.points
	for i, a in tri do
		if P.orient2D(a, tri[i % 3 + 1], q) * context.projection.sign < 0 then
			return false
		end
	end
	return true
end
return function(data, options, regions, precisionFailure)
	options = options or {}
	assert(
		data.validation.closed or #data.triangles == 0,
		"Winding repair requires closed oriented source sheets"
	)
	local rule = options.windingRule or "nonzero"
	assert(
		rule == "nonzero" or rule == "positive" or rule == "odd",
		"Winding rule must be nonzero, positive or odd"
	)
	local attempts = U.integer(options.maxRayDirections or #directions, 2)
	assert(attempts <= #directions, "Too many winding ray directions")
	local requestedOffset = options.classificationOffset or data.extent * 1e-4
	assert(
		U.finite(requestedOffset) and (requestedOffset > 0 or #data.triangles == 0),
		"Positive finite classification offset required"
	)
	local rayLength = math.max(data.extent * 4, 1e-20)
	local groupCount = regions and regions.count or 1
	local function same(a, b)
		for i = 1, groupCount do
			if a[i] ~= b[i] then
				return false
			end
		end
		return true
	end
	local report = {
		windingRule = rule,
		rayTests = 0,
		ambiguousRays = 0,
		classified = 0,
		discarded = 0,
		duplicateFragments = 0,
		reversed = 0,
		minOffset = math.huge,
		maxOffset = 0,
	}
	for _, context in data.triangles do
		local a, b, c = unpack(context.points)
		context.lo, context.hi = a:Min(b):Min(c), a:Max(b):Max(c)
	end
	local function winding(origin)
		local accepted, result = 0, nil
		for attempt = 1, attempts do
			local d = directions[attempt]
			local endpoint = Vector3.new(
				origin.X + d.X * rayLength,
				origin.Y + d.Y * rayLength,
				origin.Z + d.Z * rayLength
			)
			if not U.vector(endpoint) or endpoint == origin then
				return precisionFailure("nativeRayRange")
			end
			local lo, hi = origin:Min(endpoint), origin:Max(endpoint)
			local number, ambiguous = table.create(groupCount, 0), false
			for _, context in data.triangles do
				data.visit("classify")
				if
					hi.X < context.lo.X
					or lo.X > context.hi.X
					or hi.Y < context.lo.Y
					or lo.Y > context.hi.Y
					or hi.Z < context.lo.Z
					or lo.Z > context.hi.Z
				then
					continue
				end
				report.rayTests += 1
				local tri = context.points
				local sa, sb =
					P.orient3D(tri[1], tri[2], tri[3], origin), P.orient3D(tri[1], tri[2], tri[3], endpoint)
				if sa * sb > 0 then
					continue
				end
				if sa == 0 or sb == 0 then
					if T.segmentTriangle(origin, endpoint, tri).kind ~= "none" then
						ambiguous = true
						break
					end
					continue
				end
				local positive, negative, zero = false, false, false
				for i, p in tri do
					local sign = P.orient3D(origin, endpoint, p, tri[i % 3 + 1])
					positive, negative, zero = positive or sign > 0, negative or sign < 0, zero or sign == 0
				end
				if positive and negative then
					continue
				end
				if zero then
					ambiguous = true
					break
				end
				local group = regions and regions.groups[context.face] or 1
				number[group] += sb
			end
			if ambiguous then
				report.ambiguousRays += 1
			else
				if result ~= nil and not same(result, number) then
					return precisionFailure("rayDisagreement")
				end
				result, accepted = number, accepted + 1
				if accepted == 2 then
					return result
				end
			end
		end
		return precisionFailure("rayAmbiguity")
	end
	local function inside(numbers)
		if regions then
			return regions.contains(numbers)
		end
		local number = numbers[1]
		if rule == "positive" then
			return number > 0
		end
		if rule == "odd" then
			return math.abs(number) % 2 == 1
		end
		return number ~= 0
	end
	local selection = {}
	for fi, fragment in data.fragments do
		local context = data.triangles[fragment.triangle]
		local points, weights = {}, { 0, 0, 0 }
		for k, r in fragment.records do
			points[k] = data.nodes[r.node].position
			for j, w in r.weights do
				weights[j] += w / 3
			end
		end
		local x, y, z = 0, 0, 0
		for k, p in context.points do
			x += p.X * weights[k]
			y += p.Y * weights[k]
			z += p.Z * weights[k]
		end
		local center = Vector3.new(x, y, z)
		local owner = true
		for other in context.coplanar do
			data.visit("classify")
			if other < context.index and projectedInside(data.triangles[other], center) then
				owner = false
				break
			end
		end
		if not owner then
			report.duplicateFragments += 1
			continue
		end
		local a, b, c = unpack(points)
		local perimeter = distance(a, b) + distance(b, c) + distance(c, a)
		local radius = (b - a):Cross(c - a).Magnitude / perimeter
		local offset = math.min(requestedOffset, radius / 8)
		for _, other in data.triangles do
			data.visit("classify")
			if other == context or context.coplanar[other.index] then
				continue
			end
			local closest = Spatial.closestTriangle(center, unpack(other.points))
			offset = math.min(offset, distance(center, closest) / 8)
		end
		if not (offset > 0 and U.finite(offset)) then
			return precisionFailure("nativeClearance")
		end
		local n = context.normal
		local minus, plus
		for _, factor in { 1, 0.5 } do
			local h = offset * factor
			local p = Vector3.new(x + n.X * h, y + n.Y * h, z + n.Z * h)
			local q = Vector3.new(x - n.X * h, y - n.Y * h, z - n.Z * h)
			local tri = context.points
			if
				not (P.orient3D(tri[1], tri[2], tri[3], p) > 0 and P.orient3D(tri[1], tri[2], tri[3], q) < 0)
			then
				return precisionFailure("nativeOffset")
			end
			local wp, wm = winding(p), winding(q)
			if plus ~= nil and not (same(plus, wp) and same(minus, wm)) then
				return precisionFailure("clearanceChange")
			end
			plus, minus = wp, wm
		end
		report.minOffset, report.maxOffset =
			math.min(report.minOffset, offset / 2), math.max(report.maxOffset, offset)
		report.classified += 1
		if inside(minus) == inside(plus) then
			report.discarded += 1
			continue
		end
		selection[fi] = inside(minus) and 1 or -1
		if selection[fi] < 0 then
			report.reversed += 1
		end
	end
	if report.minOffset == math.huge then
		report.minOffset = 0
	end
	return selection, report
end
