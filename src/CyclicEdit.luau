-- Private periodic degree/removal edits through homogeneous Bernstein coefficients.
-- Dense QR recovers unique controls; acceptance compares the returned native controls.
local U = require(script.Parent.Util)
local C = require(script.Parent.Cyclic)
local QR = require(script.Parent.DenseQR)
local X = {}
local function context(options)
	options = options or {}
	local ctx = { options = options, work = 0, peakMatrixEntries = 0 }
	ctx.maxControls = U.integer(options.maxControls or 256, 2)
	ctx.maxWork = U.integer(options.maxWork or 50000000, 1)
	ctx.maxMatrix = U.integer(options.maxMatrixEntries or 1000000, 1)
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Cyclic edit cancelled")
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = ctx.work })
		end
	end
	ctx.charge = function(count, stage)
		ctx.work += count
		assert(ctx.work <= ctx.maxWork, "Cyclic edit work budget exceeded")
		ctx.check(stage)
	end
	ctx.allocate = function(rows, columns)
		local count = rows * columns
		assert(count <= ctx.maxMatrix, "Cyclic coefficient matrix budget exceeded")
		ctx.peakMatrixEntries = math.max(ctx.peakMatrixEntries, count)
	end
	ctx.check("begin")
	return ctx
end
local function cloneRows(rows)
	local out = {}
	for i, row in rows do
		out[i] = table.clone(row)
	end
	return out
end
local function normalizedKnots(curve)
	local knots = table.clone(curve.knots)
	local a, b = knots[curve.degree + 1], knots[#curve.points + 1]
	for i, value in knots do
		knots[i] = (value - a) / (b - a)
	end
	return knots
end
local function breaksFor(a, b)
	local set, breaks = { [0] = true, [1] = true }, {}
	for _, curve in { a, b } do
		for _, knot in normalizedKnots(curve) do
			if knot > 0 and knot < 1 then
				set[knot] = true
			end
		end
	end
	for knot in set do
		table.insert(breaks, knot)
	end
	table.sort(breaks)
	return breaks
end
local function blend(a, b, t)
	local out = {}
	for j, value in a do
		out[j] = (1 - t) * value + t * b[j]
	end
	return out
end
-- Apply exact-basis scalar knot insertion to data rows, then raise each Bezier span.
local function coefficients(curve, rows, breaks, degree, ctx)
	local knots, p = normalizedKnots(curve), curve.degree
	rows = table.clone(rows)
	local columns = #rows[1]
	local function insert(knot)
		local span, multiplicity
		multiplicity = 0
		for i, value in knots do
			if value == knot then
				multiplicity += 1
			end
			if i < #knots and value <= knot and knot < knots[i + 1] then
				span = i
			end
		end
		assert(span, "Cyclic refinement lost its knot span")
		local out = {}
		for i = 1, span - p do
			out[i] = rows[i]
		end
		for i = span - multiplicity, #rows do
			out[i + 1] = rows[i]
		end
		for i = span - p + 1, span - multiplicity do
			local t = (knot - knots[i]) / (knots[i + p] - knots[i])
			assert(U.finite(t) and t >= 0 and t <= 1, "Unresolved cyclic knot refinement")
			out[i] = blend(rows[i - 1], rows[i], t)
		end
		table.insert(knots, span + 1, knot)
		rows = out
		ctx.allocate(#rows, columns)
		ctx.charge((#rows + p) * columns, "coefficients")
	end
	for _, knot in breaks do
		local count = 0
		for _, value in knots do
			if value == knot then
				count += 1
			end
		end
		local target = (knot == 0 or knot == 1) and p + 1 or p
		for _ = count + 1, target do
			insert(knot)
		end
	end
	local first = 1
	while knots[first] < 0 do
		first += 1
	end
	local out = {}
	ctx.allocate((#breaks - 1) * (degree + 1), columns)
	for segment = 1, #breaks - 1 do
		local values = {}
		for i = 1, p + 1 do
			values[i] = rows[first + (segment - 1) * p + i - 1]
		end
		for d = p, degree - 1 do
			local raised = { values[1] }
			for i = 1, d do
				raised[i + 1] = blend(values[i], values[i + 1], 1 - i / (d + 1))
			end
			raised[d + 2] = values[d + 1]
			values = raised
		end
		for _, row in values do
			table.insert(out, row)
		end
		ctx.charge((degree + 1) * columns * (degree - p + 1), "coefficients")
	end
	return out
end
local function expandedRows(c, values)
	local rows = {}
	for i = 1, #c.points + c.degree do
		rows[i] = values[(i - 1) % #c.points + 1]
	end
	return rows
end
local function homogeneous(points, weights, origin, maximum)
	local out = {}
	for i, p in points do
		local w = weights[i] / maximum
		out[i] = { (p.X - origin.X) * w, (p.Y - origin.Y) * w, (p.Z - origin.Z) * w, w }
	end
	return out
end
local function bound(a, b)
	local deltaH, deltaW, radius, minimum = 0, 0, 0, math.huge
	for i, row in a do
		local other = b[i]
		local dx, dy, dz = row[1] - other[1], row[2] - other[2], row[3] - other[3]
		deltaH = math.max(deltaH, math.sqrt(dx * dx + dy * dy + dz * dz))
		deltaW = math.max(deltaW, math.abs(row[4] - other[4]))
		minimum = math.min(minimum, row[4])
		radius = math.max(radius, math.sqrt(other[1] ^ 2 + other[2] ^ 2 + other[3] ^ 2) / other[4])
	end
	return minimum > 0 and (deltaH + radius * deltaW) / minimum or math.huge
end
local function intervalTarget(c, operation, argument)
	local intervals = {}
	if operation == "elevate" then
		for _, v in c.intervals do
			table.insert(intervals, v)
			if v > 0 then
				for _ = 1, argument do
					table.insert(intervals, 0)
				end
			end
		end
		return intervals, c.degree + argument
	end
	local total = 0
	for _, value in c.intervals do
		total += value
	end
	local knot, accumulated, occurrence = argument * total, 0, nil
	-- Remove the final occurrence at that raw knot, keeping the parameter origin.
	for i, value in c.intervals do
		if accumulated == knot then
			occurrence = i
		end
		accumulated += value
	end
	if not occurrence or occurrence == 1 then
		return nil, "Knot is not present inside the period"
	end
	if #c.points - 1 <= c.degree then
		return nil, "Removal would leave too few unique controls"
	end
	intervals = table.clone(c.intervals)
	intervals[occurrence - 1] += intervals[occurrence]
	table.remove(intervals, occurrence)
	return intervals, c.degree
end
local function solve(c, intervals, degree, origin, maximum, ctx)
	assert(
		#c.points <= ctx.maxControls and #intervals <= ctx.maxControls,
		"Cyclic unique-control budget exceeded"
	)
	local dummy = C.curve(table.create(#intervals, Vector3.zero), degree, { intervals = intervals })
	local source, target = C.toNURBS(c), C.toNURBS(dummy)
	local breaks = breaksFor(source, target)
	local identities = {}
	ctx.allocate(#target.points, #intervals)
	for i = 1, #intervals do
		identities[i] = table.create(#intervals, 0)
		identities[i][i] = 1
	end
	local matrix = coefficients(target, expandedRows(dummy, identities), breaks, degree, ctx)
	local rhs = coefficients(
		source,
		expandedRows(c, homogeneous(c.points, c.weights, origin, maximum)),
		breaks,
		degree,
		ctx
	)
	ctx.charge(#matrix * #intervals * (#intervals + 4), "solve")
	local solution, diagnostics = QR(cloneRows(matrix), cloneRows(rhs), #intervals, {
		maxWork = ctx.maxWork,
		maxMatrixEntries = ctx.maxMatrix,
		rankTolerance = ctx.options.rankTolerance,
		checkpoint = function()
			ctx.check("solve")
		end,
	})
	if not solution then
		return nil, diagnostics.reason
	end
	local points, weights = {}, {}
	for i, row in solution do
		local w = row[4] * maximum
		if not U.finite(w) or w <= 0 then
			return nil, "Cyclic edit requires nonpositive or nonfinite weights"
		end
		points[i] = origin + Vector3.new(row[1] / row[4], row[2] / row[4], row[3] / row[4])
		if not U.vector(points[i]) then
			return nil, "Cyclic control exceeds native coordinate range"
		end
		weights[i] = w
	end
	local candidate = C.curve(points, degree, { intervals = intervals, weights = weights })
	local h = homogeneous(points, weights, origin, maximum)
	local reconstructed = {}
	for i, row in matrix do
		local value = { 0, 0, 0, 0 }
		for j, coefficient in row do
			for channel = 1, 4 do
				value[channel] += coefficient * h[j][channel]
			end
		end
		reconstructed[i] = value
	end
	ctx.charge(#matrix * #intervals * 4, "verify")
	return candidate, { reference = rhs, reconstructed = reconstructed, diagnostics = diagnostics }
end
local function tolerance(options)
	local value = options.tolerance == nil and 1e-5 or options.tolerance
	assert(U.finite(value) and value >= 0, "Finite nonnegative cyclic error tolerance required")
	if options.rankTolerance then
		assert(
			U.finite(options.rankTolerance) and options.rankTolerance > 0,
			"Positive rank tolerance required"
		)
	end
	return value
end
local function edit(lines, operation, argument, count, ctx)
	U.integer(count, 0)
	if operation == "remove" then
		assert(
			U.finite(argument) and argument > 0 and argument < 1,
			"Remove knots strictly inside a period; rotate the seam for boundary edits"
		)
	else
		assert(lines[1].degree + count <= 8, "Elevated degree exceeds supported degree 8")
	end
	local report = {
		complete = false,
		requested = count,
		removed = 0,
		errorBound = 0,
		tolerance = tolerance(ctx.options),
		method = "Homogeneous Bernstein coefficients and Givens QR",
	}
	local origin, maximum = lines[1].points[1], 0
	for _, c in lines do
		assert(#c.points <= ctx.maxControls, "Cyclic unique-control budget exceeded")
		for _, w in c.weights do
			maximum = math.max(maximum, w)
		end
	end
	for _ = 1, operation == "elevate" and (count > 0 and 1 or 0) or count do
		local intervals, degree =
			intervalTarget(lines[1], operation, operation == "elevate" and count or argument)
		if not intervals then
			report.reason = degree
			break
		end
		assert(
			#intervals * #lines <= (ctx.options.maxSurfaceControls or 10000),
			"Cyclic output control budget exceeded"
		)
		local candidates, reference, reconstructed = {}, {}, {}
		for i, c in lines do
			local candidate, info = solve(c, intervals, degree, origin, maximum, ctx)
			if not candidate then
				report.reason = info
				break
			end
			candidates[i] = candidate
			for j, row in info.reference do
				table.insert(reference, row)
				table.insert(reconstructed, info.reconstructed[j])
			end
		end
		if report.reason then
			break
		end
		local errorBound = bound(reference, reconstructed)
		if report.errorBound + errorBound > report.tolerance then
			report.reason, report.rejectedErrorBound =
				"Conservative cyclic error bound exceeds tolerance", errorBound
			break
		end
		lines = candidates
		report.errorBound += errorBound
		report.removed += 1
	end
	if operation == "elevate" then
		report.elevated = report.removed == 1 and count or 0
		report.removed = nil
		report.complete = report.elevated == count
	else
		report.complete = report.removed == count
	end
	report.work, report.peakMatrixEntries = ctx.work, ctx.peakMatrixEntries
	ctx.check("finish")
	return lines, report
end
function X.curve(curve, operation, argument, count, options)
	local ctx = context(options)
	assert(curve.kind == "cyclicCurve", "Cyclic curve required")
	local c = C.curve(curve.points, curve.degree, curve)
	local lines, report = edit({ c }, operation, argument, count, ctx)
	return lines[1], report
end
function X.surface(surface, axis, operation, argument, count, options)
	local ctx = context(options)
	assert(
		surface.kind == "cyclicSurface" and (axis == "U" or axis == "V"),
		"Cyclic surface and U/V axis required"
	)
	local s = C.surface(surface.control, surface.degreeU, surface.degreeV, surface)
	local along = axis == "U"
	local periodic = if along then s.cyclicU else s.cyclicV
	assert(
		periodic,
		"Cyclic degree/removal edits require a periodic direction; use NURBS edits for an open direction"
	)
	assert(
		#s.control * #s.control[1] <= U.integer(ctx.options.maxSurfaceControls or 10000, 1),
		"Cyclic surface control budget exceeded"
	)
	local lines = {}
	for j = 1, along and #s.control[1] or #s.control do
		local p, w = {}, {}
		for i = 1, along and #s.control or #s.control[1] do
			p[i] = along and s.control[i][j] or s.control[j][i]
			w[i] = along and s.weights[i][j] or s.weights[j][i]
		end
		lines[j] = C.curve(
			p,
			along and s.degreeU or s.degreeV,
			{ weights = w, intervals = along and s.intervalsU or s.intervalsV }
		)
	end
	local report
	lines, report = edit(lines, operation, argument, count, ctx)
	local p, w = {}, {}
	for i = 1, along and #lines[1].points or #lines do
		p[i], w[i] = {}, {}
		for j = 1, along and #lines or #lines[1].points do
			p[i][j] = along and lines[j].points[i] or lines[i].points[j]
			w[i][j] = along and lines[j].weights[i] or lines[i].weights[j]
		end
	end
	local opts = table.clone(s)
	opts.weights = w
	opts[along and "intervalsU" or "intervalsV"] = lines[1].intervals
	return C.surface(p, along and lines[1].degree or s.degreeU, along and s.degreeV or lines[1].degree, opts),
		report
end
return X
