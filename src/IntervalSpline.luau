-- Private positive homogeneous spline snapshots with outward-rounded extraction.
-- Raw input knot values are retained; no native Vector3 intermediates are formed.
local I = require(script.Parent.DirectedInterval)
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local B = {}
local function mix(a, b, t, ctx)
	local out, one = {}, I.sub({ 1, 1 }, t)
	for k, x in a do
		out[k] = I.add(I.mul(x, one), I.mul(b[k], t))
	end
	ctx.visit(#a * 4 + 1)
	return out
end
local function split(data, t, ctx)
	local n = #data
	local left, right = { data[1] }, { [n] = data[n] }
	for length = n - 1, 1, -1 do
		local nextValues = {}
		for i = 1, length do
			nextValues[i] = mix(data[i], data[i + 1], t, ctx)
		end
		left[n - length + 1], right[length] = nextValues[1], nextValues[length]
		data = nextValues
	end
	return left, right
end
local function restrict(data, range, ctx)
	local lo, hi = range[1], range[2]
	if lo == hi then
		if lo == 0 then
			return { data[1] }
		end
		if lo == 1 then
			return { data[#data] }
		end
		local left = split(data, { lo, lo }, ctx)
		return { left[#left] }
	end
	if hi < 1 then
		data = split(data, { hi, hi }, ctx)
	end
	if lo > 0 then
		local _, right = split(data, I.div({ lo, lo }, { hi, hi }), ctx)
		data = right
	end
	return data
end
local function transpose(rows)
	local out = {}
	for j = 1, #rows[1] / 4 do
		out[j] = {}
		for i, row in rows do
			for k = 1, 4 do
				out[j][(i - 1) * 4 + k] = row[(j - 1) * 4 + k]
			end
		end
	end
	return out
end
local function extract(rows, p, sourceKnots, ctx)
	local knots = table.clone(sourceKnots)
	for i, knot in knots do
		assert(I.isNormal(knot), "Spline intersection knot is subnormal")
		if i > 1 and knot > knots[i - 1] then
			assert(
				I.sub({ knot, knot }, { knots[i - 1], knots[i - 1] })[1] > 0,
				"Spline intersection knot interval underflow"
			)
		end
	end
	local start, finish = knots[p + 1], knots[#rows + 1]
	local breaks = { start }
	for _, k in knots do
		if k > breaks[#breaks] and k < finish then
			table.insert(breaks, k)
		end
	end
	table.insert(breaks, finish)
	assert(#breaks - 1 <= ctx.maxPieces, "Spline intersection span budget exceeded")
	for _, knot in breaks do
		local multiplicity = 0
		for _, k in knots do
			if k == knot then
				multiplicity += 1
			end
		end
		for _ = multiplicity + 1, (knot == start or knot == finish) and p + 1 or p do
			local span
			for j = 1, #knots - 1 do
				if knots[j] <= knot and knot < knots[j + 1] then
					span = j
				end
			end
			assert(span, "Interval spline extraction lost a knot span")
			ctx.allocate((#rows + 1) * #rows[1])
			local out = {}
			for j = 1, span - p do
				out[j] = rows[j]
			end
			for j = span - multiplicity, #rows do
				out[j + 1] = rows[j]
			end
			for j = span - p + 1, span - multiplicity do
				local alpha = I.div(
					I.sub({ knot, knot }, { knots[j], knots[j] }),
					I.sub({ knots[j + p], knots[j + p] }, { knots[j], knots[j] })
				)
				out[j] = mix(rows[j - 1], rows[j], alpha, ctx)
			end
			rows = out
			table.insert(knots, span + 1, knot)
			multiplicity += 1
			ctx.visit(#rows + #knots)
		end
	end
	local first = 1
	while knots[first] < start do
		first += 1
	end
	local spans = {}
	for i = 1, #breaks - 1 do
		local data = {}
		for j = 1, p + 1 do
			data[j] = rows[first + (i - 1) * p + j - 1]
		end
		table.insert(spans, { rows = data, raw = { breaks[i], breaks[i + 1] } })
	end
	return spans, { start, finish }
end
local function derivative(rows, scale, ctx)
	local out = {}
	local degree = #rows - 1
	for i = 1, degree do
		out[i] = {}
		for k, x in rows[i] do
			out[i][k] = I.mul(I.mul(I.sub(rows[i + 1][k], x), { degree, degree }), scale)
		end
		ctx.visit(#rows[i] * 3)
	end
	return out
end
local function spanScale(domain, span)
	return I.div(
		I.sub({ domain[2], domain[2] }, { domain[1], domain[1] }),
		I.sub({ span[2], span[2] }, { span[1], span[1] })
	)
end
function B.prepare(input, surface, origin, ctx)
	assert(type(input) == "table", "Spline intersection descriptor required")
	local s
	if surface then
		assert(input.kind == "surface" or input.kind == "cyclicSurface", "Intersection surface required")
		local config = table.clone(input)
		config.maxControls = ctx.maxControls
		s = input.kind == "cyclicSurface"
				and C.surfaceToNURBS(C.surface(input.control, input.degreeU, input.degreeV, config))
			or N.surface(input.control, input.degreeU, input.degreeV, config)
	else
		assert(input.kind == "curve" or input.kind == "cyclicCurve", "Intersection curve required")
		local config = table.clone(input)
		config.maxControls = ctx.maxControls
		s = input.kind == "cyclicCurve" and C.toNURBS(C.curve(input.points, input.degree, config))
			or N.curve(input.points, input.degree, config)
	end
	local maximum = 0
	local function spanCount(knots, degree, count)
		local spans = 0
		for i = degree + 1, count do
			if knots[i + 1] > knots[i] then
				spans += 1
			end
		end
		return spans
	end
	if surface then
		local count = spanCount(s.knotsU, s.degreeU, #s.control)
			* spanCount(s.knotsV, s.degreeV, #s.control[1])
		assert(count <= ctx.maxPieces, "Spline intersection patch budget exceeded")
		ctx.allocate(
			count
				* 4
				* (
					(s.degreeU + 1) * (s.degreeV + 1)
					+ s.degreeU * (s.degreeV + 1)
					+ (s.degreeU + 1) * s.degreeV
				)
		)
	else
		local count = spanCount(s.knots, s.degree, #s.points)
		assert(count <= ctx.maxPieces, "Spline intersection span budget exceeded")
		ctx.allocate(count * 4 * (2 * s.degree + 1))
	end
	if surface then
		for _, row in s.weights do
			for _, w in row do
				maximum = math.max(maximum, w)
			end
		end
	else
		for _, w in s.weights do
			maximum = math.max(maximum, w)
		end
	end
	local function homogeneous(p, w)
		local weight = I.div({ w, w }, { maximum, maximum })
		assert(weight[1] > 0, "Spline intersection weight normalization underflow")
		local h = {}
		for k, axis in { "X", "Y", "Z" } do
			h[k] = I.mul(I.sub({ p[axis], p[axis] }, { origin[axis], origin[axis] }), weight)
		end
		h[4] = weight
		ctx.visit(8)
		return h
	end
	local rows = {}
	if surface then
		ctx.allocate(#s.control * #s.control[1] * 4)
		for i, row in s.control do
			rows[i] = {}
			for j, p in row do
				local h = homogeneous(p, s.weights[i][j])
				for k = 1, 4 do
					rows[i][(j - 1) * 4 + k] = h[k]
				end
			end
		end
	else
		ctx.allocate(#s.points * 4)
		for i, p in s.points do
			rows[i] = homogeneous(p, s.weights[i])
		end
	end
	local pieces, domains = {}, {}
	local first, domain =
		extract(rows, surface and s.degreeU or s.degree, surface and s.knotsU or s.knots, ctx)
	domains[1] = domain
	for _, span in first do
		if surface then
			local second, domainV = extract(transpose(span.rows), s.degreeV, s.knotsV, ctx)
			domains[2] = domainV
			for _, other in second do
				table.insert(pieces, { rows = transpose(other.rows), raw = { span.raw, other.raw } })
			end
		else
			table.insert(pieces, { rows = span.rows, raw = { span.raw } })
		end
	end
	assert(#pieces <= ctx.maxPieces, "Spline intersection patch budget exceeded")
	local stored = 0
	for _, piece in pieces do
		piece.derivatives = { derivative(piece.rows, spanScale(domains[1], piece.raw[1]), ctx) }
		if surface then
			piece.derivatives[2] =
				transpose(derivative(transpose(piece.rows), spanScale(domains[2], piece.raw[2]), ctx))
		end
		stored += #piece.rows * #piece.rows[1]
		for _, d in piece.derivatives do
			stored += #d * #d[1]
		end
	end
	ctx.allocate(stored)
	return { pieces = pieces, domains = domains, surface = surface, source = s }
end
local function hull(rows, position)
	local values, box = {}, position and {} or nil
	for _, row in rows do
		for j = 1, #row, 4 do
			for k = 1, 4 do
				local x = row[j + k - 1]
				values[k] = values[k] and I.hull(values[k], x) or x
			end
			if box then
				for k = 1, 3 do
					local x = I.div(row[j + k - 1], row[j + 3])
					box[k] = box[k] and I.hull(box[k], x) or x
				end
			end
		end
	end
	return values, box
end
function B.evaluate(model, parameters, ctx)
	local raw = {}
	for axis, domain in model.domains do
		raw[axis] = I.intersect(
			I.add(
				{ domain[1], domain[1] },
				I.mul(I.sub({ domain[2], domain[2] }, { domain[1], domain[1] }), parameters[axis])
			),
			domain
		)
		assert(raw[axis], "Spline parameter box outside active domain")
	end
	local values, derivatives, box = {}, {}, {}
	for _, piece in model.pieces do
		ctx.visit()
		local ranges, active = {}, true
		for axis, span in piece.raw do
			local intersection = I.intersect(raw[axis], span)
			if not intersection then
				active = false
				break
			end
			ranges[axis] = I.intersect(
				I.div(
					I.sub(intersection, { span[1], span[1] }),
					I.sub({ span[2], span[2] }, { span[1], span[1] })
				),
				{ 0, 1 }
			)
			if not ranges[axis] then
				active = false
				break
			end
		end
		if not active then
			continue
		end
		local function restricted(data)
			data = restrict(data, ranges[1], ctx)
			if model.surface then
				data = restrict(transpose(data), ranges[2], ctx)
			end
			return data
		end
		local h, bbox = hull(restricted(piece.rows), true)
		for k = 1, 4 do
			values[k] = values[k] and I.hull(values[k], h[k]) or h[k]
		end
		for k = 1, 3 do
			box[k] = box[k] and I.hull(box[k], bbox[k]) or bbox[k]
		end
		for axis, data in piece.derivatives do
			local d = hull(restricted(data))
			derivatives[axis] = derivatives[axis] or {}
			for k = 1, 4 do
				derivatives[axis][k] = derivatives[axis][k] and I.hull(derivatives[axis][k], d[k]) or d[k]
			end
		end
	end
	assert(values[1], "Interval spline query lost its parameter coverage")
	return { value = values, derivatives = derivatives, box = box }
end
return B
