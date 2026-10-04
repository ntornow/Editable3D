-- Private homogeneous integer predicates for rational classification samples.
return function(triangles, R, visit, groups, requestedGroups, attempts)
	local zero, one = R.number(0), R.number(1)
	local directions = {
		{ 13, 7, 3 },
		{ -5, 11, 17 },
		{ 19, -3, 7 },
		{ 7, 17, -11 },
		{ -13, -7, 5 },
		{ 3, -19, -11 },
		{ -17, 5, -7 },
		{ 11, 3, 19 },
		{ 5, -13, 17 },
		{ -7, 19, 3 },
		{ 17, 11, -5 },
		{ -3, -5, -13 },
	}
	local function sub(a, b)
		return { R.sub(a[1], b[1]), R.sub(a[2], b[2]), R.sub(a[3], b[3]) }
	end
	local function dot(a, b)
		local x = zero
		for i = 1, 3 do
			x = R.add(x, R.mul(a[i], b[i]))
		end
		return x
	end
	local function cross(a, b)
		return {
			R.sub(R.mul(a[2], b[3]), R.mul(a[3], b[2])),
			R.sub(R.mul(a[3], b[1]), R.mul(a[1], b[3])),
			R.sub(R.mul(a[1], b[2]), R.mul(a[2], b[1])),
		}
	end
	local function along(p, d, t)
		return { R.add(p[1], R.mul(d[1], t)), R.add(p[2], R.mul(d[2], t)), R.add(p[3], R.mul(d[3], t)) }
	end
	local contexts, lo, hi = {}, {}, {}
	for i, tri in triangles do
		local points = {}
		for j, p in tri do
			local q = {}
			for axis, name in { "X", "Y", "Z" } do
				q[axis] = R.number(p[name])
				if not lo[axis] or R.compare(q[axis], lo[axis]) < 0 then
					lo[axis] = q[axis]
				end
				if not hi[axis] or R.compare(q[axis], hi[axis]) > 0 then
					hi[axis] = q[axis]
				end
			end
			points[j] = q
		end
		local normal = cross(sub(points[2], points[1]), sub(points[3], points[1]))
		local drop
		for axis = 1, 3 do
			if normal[axis].sign ~= 0 then
				drop = axis
				break
			end
		end
		assert(drop, "Degenerate source triangle")
		local axes = drop == 1 and { 2, 3 } or drop == 2 and { 3, 1 } or { 1, 2 }
		local edges = {}
		local flat = {}
		for _, p in points do
			for _, x in p do
				table.insert(flat, x)
			end
		end
		local integers, scale = R.homogeneous(flat)
		local integerPoints = {}
		for j = 1, 3 do
			integerPoints[j] = { integers[j * 3 - 2], integers[j * 3 - 1], integers[j * 3] }
		end
		local integerNormal =
			cross(sub(integerPoints[2], integerPoints[1]), sub(integerPoints[3], integerPoints[1]))
		local planeCoefficients = {
			R.mul(scale, integerNormal[1]),
			R.mul(scale, integerNormal[2]),
			R.mul(scale, integerNormal[3]),
			R.neg(dot(integerNormal, integerPoints[1])),
		}
		for j, p in integerPoints do
			local q = integerPoints[j % 3 + 1]
			local direction = sub(q, p)
			for axis = 1, 3 do
				direction[axis] = R.mul(direction[axis], scale)
			end
			edges[j] = { direction = direction, moment = cross(p, q) }
		end
		contexts[i] = {
			points = points,
			normal = normal,
			constant = dot(normal, points[1]),
			axes = axes,
			sign = normal[drop].sign,
			group = groups and groups[i] or 1,
			edges = edges,
			endpointSigns = {},
			planeCoefficients = planeCoefficients,
		}
	end
	local function plane(c, p)
		return R.sub(dot(c.normal, p), c.constant)
	end
	local function inside(c, p)
		local boundary = false
		local x, y = table.unpack(c.axes)
		for i, a in c.points do
			local b = c.points[i % 3 + 1]
			local value = R.sub(
				R.mul(R.sub(b[x], a[x]), R.sub(p[y], a[y])),
				R.mul(R.sub(b[y], a[y]), R.sub(p[x], a[x]))
			)
			if value.sign * c.sign < 0 then
				return false
			end
			boundary = boundary or value.sign == 0
		end
		return true, boundary
	end
	local extent = one
	for axis = 1, 3 do
		local span = R.sub(hi[axis], lo[axis])
		if R.compare(span, extent) > 0 then
			extent = span
		end
	end
	local endpoints = {}
	for i, d in directions do
		local p = {}
		for axis = 1, 3 do
			-- Every coordinate is outside the source box. No native construction.
			p[axis] = R.add(d[axis] > 0 and hi[axis] or lo[axis], R.mul(extent, R.number(d[axis])))
		end
		endpoints[i] = p
	end
	local groupCount = requestedGroups or 1
	for _, c in contexts do
		groupCount = math.max(groupCount, c.group)
	end
	local report = { rays = 0, ambiguous = 0, triangleTests = 0 }
	local homogeneousEndpoints = {}
	for i, p in endpoints do
		local h, w = R.homogeneous(p)
		h[4] = w
		homogeneousEndpoints[i] = h
	end
	local function homogeneousPlaneSign(c, p)
		local value = zero
		for axis = 1, 4 do
			value = R.add(value, R.mul(c.planeCoefficients[axis], p[axis]))
		end
		return value.sign
	end
	local function lineHits(c, direction, moment)
		local positive, negative, boundary = false, false, false
		for _, edge in c.edges do
			-- det(q-p,a-p,b-p) = (q-p).(a cross b) + (p cross q).(b-a).
			local sign = R.add(dot(direction, edge.moment), dot(moment, edge.direction)).sign
			positive, negative, boundary = positive or sign > 0, negative or sign < 0, boundary or sign == 0
			if positive and negative then
				return false
			end
		end
		return true, boundary
	end
	local function winding(p)
		local accepted, result = 0, nil
		local hp, wp = R.homogeneous(p)
		hp[4] = wp
		local signs = {}
		for i, c in contexts do
			signs[i] = homogeneousPlaneSign(c, hp)
		end
		for endpointIndex, q in endpoints do
			if endpointIndex > (attempts or #endpoints) then
				break
			end
			report.rays += 1
			local number = table.create(groupCount, 0)
			local ambiguous = false
			local hq = homogeneousEndpoints[endpointIndex]
			local direction = {}
			for axis = 1, 3 do
				direction[axis] = R.sub(R.mul(hq[axis], hp[4]), R.mul(hp[axis], hq[4]))
			end
			local moment = cross(hp, hq)
			for index, c in contexts do
				visit(1)
				report.triangleTests += 1
				local a = signs[index]
				local b = c.endpointSigns[endpointIndex]
				if b == nil then
					b = homogeneousPlaneSign(c, hq)
					c.endpointSigns[endpointIndex] = b
				end
				if a * b > 0 then
					continue
				end
				if a == 0 and b == 0 then
					ambiguous = true
					break
				end
				local contained, boundary = lineHits(c, direction, moment)
				if not contained then
					continue
				end
				if boundary or a == 0 or b == 0 then
					ambiguous = true
					break
				end
				number[c.group] += b
			end
			if ambiguous then
				report.ambiguous += 1
			else
				if result then
					for i, value in result do
						assert(value == number[i], "Exact winding rays disagree")
					end
				end
				result, accepted = number, accepted + 1
				if accepted == 2 then
					return number
				end
			end
		end
		error("Exact winding exhausted ray directions")
	end
	local function centerPoint(index, weights)
		local owner = contexts[index]
		local total = zero
		for _, w in weights do
			total = R.add(total, w)
		end
		assert(total.sign > 0)
		local center = { zero, zero, zero }
		for i, p in owner.points do
			center = along(center, p, R.div(weights[i], total))
		end
		assert(plane(owner, center).sign == 0 and inside(owner, center))
		return center
	end
	local function samples(index, weights, maxOffset)
		local owner = contexts[index]
		local center = centerPoint(index, weights)
		local l1 = zero
		for _, value in owner.normal do
			l1 = R.add(l1, value.sign < 0 and R.neg(value) or value)
		end
		local delta = R.div(R.number(maxOffset), l1)
		local moment = cross(center, owner.normal)
		local line = { owner.normal[1], owner.normal[2], owner.normal[3], moment[1], moment[2], moment[3] }
		local homogeneousLine = R.homogeneous(line)
		local directionLine = { homogeneousLine[1], homogeneousLine[2], homogeneousLine[3] }
		local momentLine = { homogeneousLine[4], homogeneousLine[5], homogeneousLine[6] }
		local function constrain(t)
			assert(t.sign ~= 0, "Exact seed lies on a noncoplanar source triangle")
			local distance = R.div(t.sign < 0 and R.neg(t) or t, R.number(4))
			if R.compare(distance, delta) < 0 then
				delta = distance
			end
		end
		local function coplanarLine(c)
			-- The sampling line can lie in a different source plane. Clip it
			-- against all three closed triangle half-planes instead of ignoring it.
			local x, y = table.unpack(c.axes)
			local lower, upper
			for i, p in c.points do
				local q = c.points[i % 3 + 1]
				local dx, dy = R.sub(q[x], p[x]), R.sub(q[y], p[y])
				local a = R.sub(R.mul(dx, R.sub(center[y], p[y])), R.mul(dy, R.sub(center[x], p[x])))
				local b = R.sub(R.mul(dx, owner.normal[y]), R.mul(dy, owner.normal[x]))
				if c.sign < 0 then
					a, b = R.neg(a), R.neg(b)
				end
				if b.sign == 0 then
					if a.sign < 0 then
						return
					end
				else
					local t = R.div(R.neg(a), b)
					if b.sign > 0 then
						if not lower or R.compare(t, lower) > 0 then
							lower = t
						end
					elseif not upper or R.compare(t, upper) < 0 then
						upper = t
					end
				end
				if lower and upper and R.compare(lower, upper) > 0 then
					return
				end
			end
			assert(lower and upper, "Bounded triangle lost its coplanar line range")
			assert(lower.sign > 0 or upper.sign < 0, "Exact seed lies on a noncoplanar source triangle")
			constrain(lower.sign > 0 and lower or upper)
		end
		for j, c in contexts do
			if j == index then
				continue
			end
			local coplanar = true
			for _, p in c.points do
				if plane(owner, p).sign ~= 0 then
					coplanar = false
					break
				end
			end
			if coplanar then
				continue
			end
			local slope = dot(c.normal, owner.normal)
			if slope.sign == 0 then
				if plane(c, center).sign == 0 then
					coplanarLine(c)
				end
				continue
			end
			if lineHits(c, directionLine, momentLine) then
				local t = R.div(R.neg(plane(c, center)), slope)
				constrain(t)
			end
		end
		assert(delta.sign > 0)
		local plus = along(center, owner.normal, delta)
		local minus = along(center, owner.normal, R.neg(delta))
		assert(plane(owner, plus).sign > 0 and plane(owner, minus).sign < 0)
		return minus, plus, delta, center
	end
	return {
		winding = winding,
		samples = samples,
		center = centerPoint,
		contains = function(index, p)
			return inside(contexts[index], p)
		end,
		report = report,
		contexts = contexts,
	}
end
