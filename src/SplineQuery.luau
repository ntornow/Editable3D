-- Bounded geometric queries. Positive rational control hulls supply search bounds.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local Bounds = require(script.Parent.CurveBounds)
local Q = {}

function Q.intersectCurveSurface(curve, surface, options)
	return require(script.Parent.CurveSurfaceIntersections)(curve, surface, options)
end

function Q.intersectSurfaces(surfaceA, surfaceB, options)
	return require(script.Parent.SurfaceIntersections)(surfaceA, surfaceB, options)
end

local function push(heap, node)
	local i = #heap + 1
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent].priority <= node.priority then
			break
		end
		heap[i] = heap[parent]
		i = parent
	end
	heap[i] = node
end
local function pop(heap)
	local result = heap[1]
	local tail = table.remove(heap)
	if #heap > 0 then
		local i = 1
		while i * 2 <= #heap do
			local child = i * 2
			if child < #heap and heap[child + 1].priority < heap[child].priority then
				child += 1
			end
			if heap[child].priority >= tail.priority then
				break
			end
			heap[i] = heap[child]
			i = child
		end
		heap[i] = tail
	end
	return result
end
local function limits(options)
	local tolerance = options.tolerance or 1e-4
	local nodes, depth = options.maxNodes or 10000, options.maxDepth or 24
	assert(U.finite(tolerance) and tolerance > 0, "Positive query tolerance required")
	U.integer(nodes, 1)
	U.integer(depth, 1)
	assert(depth <= 52, "Query depth exceeds floating-point parameter resolution")
	return tolerance, nodes, depth
end
local function curveLengthBounds(c)
	local lower = (c.points[#c.points] - c.points[1]).Magnitude
	local upper = 0
	for i = 2, #c.points do
		upper += (c.points[i] - c.points[i - 1]).Magnitude
	end
	return lower, math.max(lower, upper)
end

function Q.length(curve, options)
	options = options or {}
	local tolerance, maxNodes, maxDepth = limits(options)
	local lower, upper, heap, visited, blocked = 0, 0, {}, 0, 0
	for _, piece in N.bezierSegments(curve) do
		local a, b = curveLengthBounds(piece.curve)
		lower += a
		upper += b
		push(heap, { curve = piece.curve, depth = 0, lower = a, upper = b, priority = a - b })
	end
	while upper - lower > 2 * tolerance and #heap > 0 and visited < maxNodes do
		local node = pop(heap)
		visited += 1
		if node.depth >= maxDepth then
			blocked += 1
			continue
		end
		local a, b = N.split(node.curve, 0.5)
		lower -= node.lower
		upper -= node.upper
		for _, c in { a, b } do
			local lo, hi = curveLengthBounds(c)
			lower += lo
			upper += hi
			push(heap, { curve = c, depth = node.depth + 1, lower = lo, upper = hi, priority = lo - hi })
		end
		if options.checkpoint then
			options.checkpoint(visited / maxNodes)
		end
	end
	local gap = math.max(0, upper - lower)
	local converged = gap <= 2 * tolerance
	return {
		length = (lower + upper) * 0.5,
		lowerBound = lower,
		upperBound = upper,
		errorBound = gap * 0.5,
		converged = converged,
		visited = visited,
		segments = #heap + blocked,
		reason = not converged and (visited >= maxNodes and "Node budget exhausted" or "Depth limit reached")
			or nil,
	}
end

local function distanceToSegment(p, a, b)
	local d = b - a
	local denominator = d:Dot(d)
	local t = denominator > 0 and math.clamp((p - a):Dot(d) / denominator, 0, 1) or 0
	return (p - (a + d * t)).Magnitude
end
function Q.sample(curve, options)
	options = options or {}
	local tolerance, maxNodes, maxDepth = limits(options)
	local maxAngle = options.maxAngle
	assert(
		maxAngle == nil
			or (type(maxAngle) == "number" and U.finite(maxAngle) and maxAngle > 0 and maxAngle < math.pi / 2),
		"Tangent tolerance must be in (0,pi/2)"
	)
	local stack, leaves = {}, {}
	local pieces = N.bezierSegments(curve)
	for i = #pieces, 1, -1 do
		local p = pieces[i]
		p.depth = 0
		table.insert(stack, p)
	end
	local visited, maximum, converged = 0, 0, true
	local maximumAngle, stationary = 0, 0
	while #stack > 0 do
		local node = table.remove(stack)
		local c = node.curve
		local error = 0
		local a, b = c.points[1], c.points[#c.points]
		for _, p in c.points do
			error = math.max(error, distanceToSegment(p, a, b))
		end
		local angle, isStationary = 0, false
		if maxAngle then
			angle, isStationary = Bounds.tangent(c)
		end
		local acceptable = error <= tolerance and (not maxAngle or angle <= maxAngle)
		if not acceptable and node.depth < maxDepth and visited < maxNodes then
			visited += 1
			local left, right = N.split(c, 0.5)
			local middle = (node.first + node.last) * 0.5
			table.insert(stack, { curve = right, first = middle, last = node.last, depth = node.depth + 1 })
			table.insert(stack, { curve = left, first = node.first, last = middle, depth = node.depth + 1 })
		else
			maximum = math.max(maximum, error)
			converged = converged and acceptable
			maximumAngle = math.max(maximumAngle, angle)
			if isStationary then
				stationary += 1
			end
			table.insert(leaves, node)
		end
		if options.checkpoint then
			options.checkpoint(math.min(visited / maxNodes, 1))
		end
	end
	local points, parameters = {}, {}
	for _, node in leaves do
		table.insert(points, node.curve.points[1])
		table.insert(parameters, node.first)
	end
	table.insert(points, leaves[#leaves].curve.points[#leaves[#leaves].curve.points])
	table.insert(parameters, 1)
	return points,
		{
			parameters = parameters,
			converged = converged,
			errorBound = maximum,
			tangentErrorBound = maxAngle and maximumAngle or nil,
			stationarySegments = stationary,
			segments = #leaves,
			visited = visited,
			reason = not converged
					and (visited >= maxNodes and "Node budget exhausted" or "Depth limit reached")
				or nil,
		}
end

local function hullDistance(shape, target, surface)
	local points = {}
	if surface then
		for _, row in shape.control do
			for _, p in row do
				table.insert(points, p)
			end
		end
	else
		points = shape.points
	end
	local origin = points[1]
	local function delta(p)
		return { p.X - origin.X, p.Y - origin.Y, p.Z - origin.Z }
	end
	local function dot(a, b)
		return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
	end
	local function cross(a, b)
		return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
	end
	local function normalized(v)
		local length = math.sqrt(dot(v, v))
		return { v[1] / length, v[2] / length, v[3] / length }
	end
	local function boxDistance(axes)
		local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
		for _, p in points do
			local d = delta(p)
			for i, axis in axes do
				local x = dot(d, axis)
				lo[i] = math.min(lo[i], x)
				hi[i] = math.max(hi[i], x)
			end
		end
		local sum = 0
		local d = delta(target)
		for i, axis in axes do
			local x = dot(d, axis)
			local gap = math.max(lo[i] - x, 0, x - hi[i])
			sum += gap * gap
		end
		return math.sqrt(sum)
	end
	local lower = boxDistance({ { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } })
	local a, maximum = nil, 0
	for _, p in points do
		local d = delta(p)
		local size = dot(d, d)
		if size > maximum then
			a, maximum = d, size
		end
	end
	if not a then
		return lower
	end
	a = normalized(a)
	local normal
	maximum = 0
	for _, p in points do
		local c = cross(a, delta(p))
		local size = dot(c, c)
		if size > maximum then
			normal, maximum = c, size
		end
	end
	if normal and maximum > 1e-300 then
		normal = normalized(normal)
		lower = math.max(lower, boxDistance({ a, cross(normal, a), normal }))
	end
	return lower
end

local function closest(shape, target, options, surface)
	assert(U.vector(target), "Finite query position required")
	options = options or {}
	local tolerance, maxNodes, maxDepth = limits(options)
	local root = surface and N.clampSurface(N.clampSurface(shape, "U"), "V") or N.clamp(shape)
	local heap, visited, blocked = {}, 0, math.huge
	local best = { distance = math.huge }
	local function consider(node)
		local evaluator = surface and N.compileSurface(node.shape) or N.compileCurve(node.shape)
		local function point(u, v)
			local d = surface and evaluator.derivatives(u, v) or evaluator.derivatives(u)
			local distance = (d.position - target).Magnitude
			if distance < best.distance then
				best = {
					position = d.position,
					distance = distance,
					parameter = surface and {
						u = node.u0 + (node.u1 - node.u0) * u,
						v = node.v0 + (node.v1 - node.v0) * v,
					} or node.u0 + (node.u1 - node.u0) * u,
				}
			end
			return d, distance
		end
		point(0, 0)
		point(1, 0)
		if surface then
			point(0, 1)
			point(1, 1)
		end
		local u, v = 0.5, 0.5
		local d, distance = point(u, v)
		-- Projected Newton with positive-Hessian fallback supplies candidates; hulls supply global bounds.
		for _ = 1, 8 do
			local residual = d.position - target
			local du, dv
			if surface then
				local a, b, c = d.du:Dot(d.du), d.du:Dot(d.dv), d.dv:Dot(d.dv)
				local ha, hb, hc = a + residual:Dot(d.duu), b + residual:Dot(d.duv), c + residual:Dot(d.dvv)
				if ha > 0 and hc > 0 and ha * hc - hb * hb > ha * hc * 1e-12 then
					a, b, c = ha, hb, hc
				end
				local determinant = a * c - b * b
				if determinant <= math.max(a * c, 1e-300) * 1e-12 then
					break
				end
				local x, y = d.du:Dot(residual), d.dv:Dot(residual)
				du, dv = (c * x - b * y) / determinant, (a * y - b * x) / determinant
			else
				local speed = d.first:Dot(d.first)
				if speed <= 1e-30 then
					break
				end
				local hessian = speed + residual:Dot(d.second)
				du, dv = d.first:Dot(residual) / (hessian > speed * 1e-12 and hessian or speed), 0
			end
			local accepted = false
			for line = 0, 8 do
				local step = 2 ^ -line
				local nu, nv = math.clamp(u - du * step, 0, 1), math.clamp(v - dv * step, 0, 1)
				local nd, ndistance = point(nu, nv)
				if ndistance < distance then
					u, v, d, distance = nu, nv, nd, ndistance
					accepted = true
					break
				end
			end
			if not accepted then
				break
			end
		end
	end
	local function add(node)
		node.priority = hullDistance(node.shape, target, surface)
		if node.priority <= best.distance then
			consider(node)
			push(heap, node)
		end
	end
	add({ shape = root, u0 = 0, u1 = 1, v0 = 0, v1 = 1, depth = 0 })
	while #heap > 0 and visited < maxNodes do
		local lower = math.min(heap[1].priority, blocked)
		if best.distance - lower <= tolerance then
			break
		end
		local node = pop(heap)
		visited += 1
		if node.priority >= best.distance then
			continue
		end
		if node.depth >= maxDepth then
			blocked = math.min(blocked, node.priority)
			continue
		end
		local a, b, axis
		if surface then
			local alongU, alongV = 0, 0
			for i, row in node.shape.control do
				for j, p in row do
					if i > 1 then
						alongU += (p - node.shape.control[i - 1][j]).Magnitude / #row
					end
					if j > 1 then
						alongV += (p - row[j - 1]).Magnitude / #node.shape.control
					end
				end
			end
			axis = alongU >= alongV and "U" or "V"
			a, b = N.splitSurface(node.shape, axis, 0.5)
		else
			a, b = N.split(node.shape, 0.5)
			axis = "U"
		end
		local left, right = table.clone(node), table.clone(node)
		left.shape, right.shape = a, b
		left.depth += 1
		right.depth += 1
		if axis == "U" then
			local mid = (node.u0 + node.u1) * 0.5
			left.u1 = mid
			right.u0 = mid
		else
			local mid = (node.v0 + node.v1) * 0.5
			left.v1 = mid
			right.v0 = mid
		end
		add(left)
		add(right)
		if options.checkpoint then
			options.checkpoint(visited / maxNodes)
		end
	end
	local lower = math.min(best.distance, blocked, #heap > 0 and heap[1].priority or math.huge)
	best.lowerBound = lower
	best.errorBound = math.max(0, best.distance - lower)
	best.converged = best.errorBound <= tolerance
	best.visited = visited
	best.reason = not best.converged
			and (visited >= maxNodes and "Node budget exhausted" or "Depth limit reached")
		or nil
	return best
end
function Q.closestCurve(curve, point, options)
	return closest(curve, point, options, false)
end
function Q.closestSurface(surface, point, options)
	return closest(surface, point, options, true)
end
return Q
