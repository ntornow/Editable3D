-- Exact rational construction and homogeneous section interpolation.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local QR = require(script.Parent.DenseQR)
local S = {}

function S.join(surfaceA, boundaryA, surfaceB, boundaryB, options)
	return require(script.Parent.SurfaceJoin)(surfaceA, boundaryA, surfaceB, boundaryB, options)
end

function S.arc(frame, radius, startAngle, endAngle)
	assert(
		typeof(frame) == "CFrame" and U.finite(radius) and radius > 0,
		"Frame and positive radius required"
	)
	assert(U.finite(startAngle) and U.finite(endAngle), "Finite angles required")
	local angle = endAngle - startAngle
	assert(
		math.abs(angle) > 1e-12 and math.abs(angle) <= 2 * math.pi + 1e-12,
		"Arc sweep must be nonzero and at most one turn"
	)
	local segments = math.ceil(math.abs(angle) / (math.pi / 2))
	local points, weights, knots = {}, {}, { 0, 0, 0 }
	for i = 0, segments do
		local a = startAngle + angle * i / segments
		local endpoint = frame:PointToWorldSpace(Vector3.new(radius * math.cos(a), radius * math.sin(a), 0))
		if i == segments and math.abs(math.abs(angle) - 2 * math.pi) < 1e-12 then
			endpoint = points[1]
		end
		table.insert(points, endpoint)
		table.insert(weights, 1)
		if i < segments then
			local middle = a + angle / (2 * segments)
			local w = math.cos(angle / (2 * segments))
			table.insert(
				points,
				frame:PointToWorldSpace(
					Vector3.new(radius * math.cos(middle) / w, radius * math.sin(middle) / w, 0)
				)
			)
			table.insert(weights, w)
			if i > 0 then
				table.insert(knots, i / segments)
				table.insert(knots, i / segments)
			end
		end
	end
	for _ = 1, 3 do
		table.insert(knots, 1)
	end
	return N.curve(points, 2, { weights = weights, knots = knots })
end

function S.compatible(curves, options)
	options = options or {}
	assert(#curves >= 2 and #curves <= (options.maxSections or 128), "Two or more bounded sections required")
	local out, degree = {}, 1
	for i, c in curves do
		out[i] = N.clamp(c)
		degree = math.max(degree, c.degree)
	end
	local multiplicities = {}
	for i, c in out do
		c = N.elevateDegree(c, degree - c.degree)
		local a, b = c.knots[1], c.knots[#c.knots]
		local k, w, maximum = {}, {}, 0
		for j, knot in c.knots do
			k[j] = (knot - a) / (b - a)
		end
		for _, weight in c.weights do
			maximum = math.max(maximum, weight)
		end
		for j, weight in c.weights do
			w[j] = weight / maximum
		end
		c = N.curve(c.points, degree, { knots = k, weights = w })
		out[i] = c
		local seen = {}
		for _, knot in k do
			if knot > 0 and knot < 1 then
				seen[knot] = (seen[knot] or 0) + 1
			end
		end
		for knot, count in seen do
			multiplicities[knot] = math.max(multiplicities[knot] or 0, count)
		end
	end
	local keys = U.keys(multiplicities)
	for i, c in out do
		for _, knot in keys do
			local count = 0
			for _, v in c.knots do
				if v == knot then
					count += 1
				end
			end
			if count < multiplicities[knot] then
				c = N.insertKnot(c, knot, multiplicities[knot] - count)
			end
		end
		assert(
			#c.points * #out <= (options.maxControls or 10000),
			"Compatible section control budget exceeded"
		)
		out[i] = c
		if options.checkpoint then
			options.checkpoint(i / #out)
		end
	end
	return out
end

function S.extrude(curve, displacement)
	assert(U.vector(displacement) and displacement.Magnitude > 0, "Nonzero finite extrusion vector required")
	local c = N.clamp(curve)
	local p, w = {}, {}
	for i, q in c.points do
		p[i] = { q, q + displacement }
		w[i] = { c.weights[i], c.weights[i] }
	end
	return N.surface(p, c.degree, 1, { weights = w, knotsU = c.knots })
end

function S.ruled(first, second, options)
	local curves = S.compatible({ first, second }, options)
	local a, b = curves[1], curves[2]
	local p, w = {}, {}
	for i, q in a.points do
		p[i] = { q, b.points[i] }
		w[i] = { a.weights[i], b.weights[i] }
	end
	return N.surface(p, a.degree, 1, { weights = w, knotsU = a.knots })
end

function S.loft(sections, degree, options)
	options = options or {}
	local curves = S.compatible(sections, options)
	local n, nu = #curves, #curves[1].points
	degree = degree or math.min(3, n - 1)
	U.integer(degree, 1)
	assert(degree <= 8 and degree < n)
	assert(n * nu <= (options.maxControls or 10000), "Loft control budget exceeded")
	assert(
		n * n + n * nu * 4 <= (options.maxMatrixEntries or 1000000),
		"Loft matrix allocation budget exceeded"
	)
	assert(n * n * (n + nu * 4) <= (options.maxWork or 50000000), "Loft solve work budget exceeded")
	local params = options.parameters or {}
	if not options.parameters then
		for i = 1, n do
			params[i] = (i - 1) / (n - 1)
		end
	end
	assert(#params == n and params[1] == 0 and params[n] == 1, "Loft parameters must span [0,1]")
	for i, t in params do
		assert(U.finite(t) and (i == 1 or t > params[i - 1]), "Strictly increasing loft parameters required")
	end
	local knots = {}
	for _ = 1, degree + 1 do
		table.insert(knots, 0)
	end
	for j = 1, n - degree - 1 do
		local sum = 0
		for i = j + 1, j + degree do
			sum += params[i]
		end
		table.insert(knots, sum / degree)
	end
	for _ = 1, degree + 1 do
		table.insert(knots, 1)
	end
	local basis = N.curve(table.create(n, Vector3.zero), degree, { knots = knots })
	local matrix, rhs = {}, {}
	local origin = curves[1].points[1]
	for j, c in curves do
		matrix[j] = N.basisWeights(basis, params[j])
		rhs[j] = {}
		for i, p in c.points do
			local w = c.weights[i]
			rhs[j][(i - 1) * 4 + 1] = (p.X - origin.X) * w
			rhs[j][(i - 1) * 4 + 2] = (p.Y - origin.Y) * w
			rhs[j][(i - 1) * 4 + 3] = (p.Z - origin.Z) * w
			rhs[j][(i - 1) * 4 + 4] = w
		end
	end
	if options.rankTolerance then
		assert(
			U.finite(options.rankTolerance) and options.rankTolerance > 0,
			"Positive rank tolerance required"
		)
	end
	local solved, report = QR(matrix, rhs, n, options)
	assert(solved, "Loft interpolation is rank deficient")
	local p, w = {}, {}
	for i = 1, nu do
		p[i], w[i] = {}, {}
		for j = 1, n do
			local h = solved[j]
			local weight = h[(i - 1) * 4 + 4]
			assert(
				U.finite(weight) and weight > 0,
				"Loft requires nonpositive control weights; lower the degree or change sections"
			)
			p[i][j] = origin
				+ Vector3.new(
					h[(i - 1) * 4 + 1] / weight,
					h[(i - 1) * 4 + 2] / weight,
					h[(i - 1) * 4 + 3] / weight
				)
			w[i][j] = weight
		end
	end
	report.parameters = table.clone(params)
	return N.surface(p, curves[1].degree, degree, { weights = w, knotsU = curves[1].knots, knotsV = knots }),
		report
end

function S.revolve(curve, origin, axis, angle, options)
	options = options or {}
	assert(
		U.vector(origin) and U.vector(axis) and axis.Magnitude > 1e-12,
		"Finite origin and nonzero axis required"
	)
	axis = axis.Unit
	local c = N.clamp(curve)
	local arc = S.arc(CFrame.identity, 1, options.startAngle or 0, (options.startAngle or 0) + angle)
	local points, weights = {}, {}
	assert(#c.points * #arc.points <= (options.maxControls or 10000), "Revolution control budget exceeded")
	for i, p in c.points do
		points[i], weights[i] = {}, {}
		local d = p - origin
		local center = origin + axis * d:Dot(axis)
		local radial = p - center
		local tangent = axis:Cross(radial)
		for j, q in arc.points do
			points[i][j] = center + radial * q.X + tangent * q.Y
			weights[i][j] = c.weights[i] * arc.weights[j]
		end
		if options.checkpoint then
			options.checkpoint(i / #c.points)
		end
	end
	return N.surface(points, c.degree, 2, { weights = weights, knotsU = c.knots, knotsV = arc.knots })
end

function S.coons(bottom, top, left, right, options)
	options = table.clone(options or {})
	local surface, report = require(script.Parent.CoonsSurface)(bottom, top, left, right, options)
	if options.returnReport then
		return surface, report
	end
	return surface
end

function S.plane(frame, size)
	assert(
		typeof(frame) == "CFrame"
			and typeof(size) == "Vector2"
			and U.finite(size.X)
			and U.finite(size.Y)
			and size.X > 0
			and size.Y > 0
	)
	local p = {}
	for i = 1, 2 do
		p[i] = {}
		for j = 1, 2 do
			p[i][j] = frame:PointToWorldSpace(Vector3.new((i - 1.5) * size.X, (j - 1.5) * size.Y, 0))
		end
	end
	return N.surface(p, 1, 1)
end
function S.cylinder(frame, radius, height)
	assert(U.finite(height) and height > 0)
	return S.extrude(
		S.arc(frame, radius, 0, 2 * math.pi),
		frame:VectorToWorldSpace(Vector3.new(0, 0, height))
	)
end
function S.cone(frame, radius, height)
	assert(U.finite(radius) and radius > 0 and U.finite(height) and height > 0)
	local c = N.curve({
		frame:PointToWorldSpace(Vector3.new(radius, 0, 0)),
		frame:PointToWorldSpace(Vector3.new(0, 0, height)),
	}, 1)
	return S.revolve(N.reverse(c), frame.Position, frame:VectorToWorldSpace(Vector3.zAxis), 2 * math.pi)
end
function S.sphere(frame, radius)
	local meridian = frame * CFrame.fromMatrix(Vector3.zero, Vector3.zAxis, Vector3.xAxis, Vector3.yAxis)
	return S.revolve(
		S.arc(meridian, radius, 0, math.pi),
		frame.Position,
		frame:VectorToWorldSpace(Vector3.zAxis),
		2 * math.pi
	)
end
function S.torus(frame, majorRadius, minorRadius)
	assert(
		U.finite(majorRadius) and U.finite(minorRadius) and majorRadius > minorRadius and minorRadius > 0,
		"Ring torus radii required"
	)
	local section = frame
		* CFrame.fromMatrix(Vector3.new(majorRadius, 0, 0), Vector3.xAxis, -Vector3.zAxis, Vector3.yAxis)
	return S.revolve(
		S.arc(section, minorRadius, 0, 2 * math.pi),
		frame.Position,
		frame:VectorToWorldSpace(Vector3.zAxis),
		2 * math.pi
	)
end
return S
