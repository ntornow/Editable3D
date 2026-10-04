-- Private structural edits. Changed grid directions rebuild their basis explicitly.
local Core = require(script.Parent.SurfaceEditCore)
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local G = {}
local function finishPieces(pieces, maps, ctx, extra)
	local report = extra or {}
	report.complete, report.regularityChecked = true, false
	report.sourceControls = ctx.nu * ctx.nv
	report.controls = 0
	for _, piece in pieces do
		report.controls += #piece.control * #piece.control[1]
	end
	report.sourceRefs = maps
	report.work = ctx.work
	report.basisChanged = true
	ctx.check("finish")
	return pieces, report
end
function G.duplicate(surface, uRange, vRange, options)
	local s, ctx = Core.prepare(surface, options)
	local a, b = Core.range(uRange, ctx.nu)
	local c, d = Core.range(vRange, ctx.nv)
	local result, map = Core.pick(s, Core.sequence(a, b), Core.sequence(c, d), ctx, options)
	return Core.finish(result, ctx, map, {
		basisChanged = a ~= 1
			or b ~= ctx.nu
			or c ~= 1
			or d ~= ctx.nv
			or result.degreeU ~= s.degreeU
			or result.degreeV ~= s.degreeV,
	})
end
function G.transpose(surface, options)
	local s, ctx = Core.prepare(surface, options)
	local p, w, map = {}, {}, {}
	for j = 1, ctx.nv do
		p[j], w[j] = {}, {}
		for i = 1, ctx.nu do
			ctx.visit()
			p[j][i], w[j][i] = s.control[i][j], s.weights[i][j]
			map[Core.key(j, i)] = Core.key(i, j)
		end
	end
	local changes = { resetU = true, resetV = true }
	for _, name in { "degree", "cyclic", "clamped", "knots", "intervals" } do
		changes[name .. "U"], changes[name .. "V"] = s[name .. "V"], s[name .. "U"]
	end
	return Core.finish(
		Core.build(s, p, w, ctx, changes),
		ctx,
		map,
		{ parametersSwapped = true, basisChanged = false }
	)
end
function G.setCyclic(surface, axis, enabled, options)
	local s, ctx = Core.prepare(surface, options)
	Core.axis(axis)
	assert(type(enabled) == "boolean", "Cyclic state must be boolean")
	options = options or {}
	local changes = {}
	if s["cyclic" .. axis] ~= enabled then
		changes["reset" .. axis] = true
		changes["cyclic" .. axis] = enabled
		changes["intervals" .. axis] = options.intervals
		changes["knots" .. axis] = options.knots
		changes["clamped" .. axis] = options.clamped ~= false
	end
	return Core.finish(
		Core.build(s, s.control, s.weights, ctx, changes),
		ctx,
		Core.identity(s),
		{ basisChanged = s["cyclic" .. axis] ~= enabled }
	)
end
function G.extrude(surface, boundary, steps, operation, options)
	local s, ctx = Core.prepare(surface, options)
	options = options or {}
	local along, low = Core.boundary(s, boundary)
	steps = U.integer(steps or 1, 0)
	assert(steps <= U.integer(options.maxSteps or 128, 0), "Surface extrusion step budget exceeded")
	if typeof(operation) == "Vector3" then
		assert(U.vector(operation))
		operation = CFrame.new(operation)
	end
	operation = operation or CFrame.identity
	assert(
		typeof(operation) == "CFrame" or type(operation) == "function",
		"Extrusion requires a displacement, CFrame or callback"
	)
	if typeof(operation) == "CFrame" then
		for _, v in { operation:GetComponents() } do
			Core.scalar(v)
		end
	end
	if steps == 0 then
		return Core.finish(
			s,
			ctx,
			Core.identity(s),
			{ createdControls = 0, created = {}, basisChanged = false }
		)
	end
	local count, width = along and ctx.nu or ctx.nv, along and ctx.nv or ctx.nu
	local degree = options.degree or (along and s.degreeU or s.degreeV)
	local du, dv = along and degree or s.degreeU, along and s.degreeV or degree
	ctx.budget(ctx.nu + (along and steps or 0), ctx.nv + (along and 0 or steps), du, dv, s.cyclicU, s.cyclicV)
	local border = low and 1 or count
	local newP, newW = {}, {}
	for k = 1, steps do
		newP[k], newW[k] = {}, {}
		for j = 1, width do
			ctx.visit()
			local i0, j0 = along and border or j, along and j or border
			local p = k == 1 and s.control[i0][j0] or newP[k - 1][j]
			local w = k == 1 and s.weights[i0][j0] or newW[k - 1][j]
			local q, nw
			if type(operation) == "function" then
				q, nw = (operation :: any)(p, w, k, j)
			else
				q = operation:PointToWorldSpace(p)
			end
			nw = nw == nil and w or nw
			assert(
				U.vector(q) and type(nw) == "number" and U.finite(nw) and nw > 0,
				"Extrusion returned invalid controls or weights"
			)
			newP[k][j], newW[k][j] = q, nw
		end
	end
	local p, w, map, created = {}, {}, {}, {}
	for i = 1, ctx.nu + (along and steps or 0) do
		p[i], w[i] = {}, {}
		for j = 1, ctx.nv + (along and 0 or steps) do
			ctx.visit()
			local q, r = along and i or j, along and j or i
			local added = low and q <= steps or not low and q > count
			local a, b
			if added then
				local k = low and steps - q + 1 or q - count
				p[i][j], w[i][j] = newP[k][r], newW[k][r]
				a, b = along and border or r, along and r or border
				created[Core.key(i, j)] = true
			else
				local old = q - (low and steps or 0)
				a, b = along and old or r, along and r or old
				p[i][j], w[i][j] = s.control[a][b], s.weights[a][b]
			end
			map[Core.key(i, j)] = Core.key(a, b)
		end
	end
	local axis = along and "U" or "V"
	local changes = {
		["reset" .. axis] = true,
		["degree" .. axis] = degree,
		["knots" .. axis] = options.knots,
		["clamped" .. axis] = if options.clamped == nil then s["clamped" .. axis] else options.clamped,
	}
	return Core.finish(
		Core.build(s, p, w, ctx, changes),
		ctx,
		map,
		{ created = created, createdControls = steps * width, basisChanged = true }
	)
end
function G.split(surface, axis, index, options)
	local s, ctx = Core.prepare(surface, options)
	local along = Core.axis(axis)
	local count = along and ctx.nu or ctx.nv
	U.integer(index, 2)
	assert(index <= (s["cyclic" .. axis] and count or count - 1), "Control split must leave two grid pieces")
	local lists = { Core.sequence(1, index), Core.sequence(index, count) }
	if s["cyclic" .. axis] then
		table.insert(lists[2], 1)
	end
	local pieces, maps = {}, {}
	for k, list in lists do
		pieces[k], maps[k] = Core.pick(
			s,
			along and list or Core.sequence(1, ctx.nu),
			along and Core.sequence(1, ctx.nv) or list,
			ctx,
			options,
			s["cyclic" .. axis] and axis or nil
		)
	end
	return finishPieces(pieces, maps, ctx, { sharedRows = s["cyclic" .. axis] and { 1, index } or { index } })
end
function G.deleteRows(surface, axis, indices, options)
	local s, ctx = Core.prepare(surface, options)
	options = options or {}
	local along = Core.axis(axis)
	local count = along and ctx.nu or ctx.nv
	assert(type(indices) == "table", "Deleted row indices must be an array")
	local removed, kept = {}, {}
	for _, i in indices do
		U.integer(i, 1)
		assert(i <= count and not removed[i], "Missing or duplicate deleted control row")
		removed[i] = true
	end
	for i = 1, count do
		if not removed[i] then
			table.insert(kept, i)
		end
	end
	if #kept == count then
		return Core.finish(s, ctx, Core.identity(s), { deletedControls = 0, basisChanged = false })
	end
	assert(#kept >= 2, "Deletion must leave at least two control rows")
	local degree = options.degree or s["degree" .. axis]
	if options.reduceDegree then
		degree = math.min(degree, #kept - 1)
	end
	local p, w, map = {}, {}, {}
	for i = 1, along and #kept or ctx.nu do
		p[i], w[i] = {}, {}
		for j = 1, along and ctx.nv or #kept do
			ctx.visit()
			local a, b = along and kept[i] or i, along and j or kept[j]
			p[i][j], w[i][j] = s.control[a][b], s.weights[a][b]
			map[Core.key(i, j)] = Core.key(a, b)
		end
	end
	local changes = {
		["reset" .. axis] = true,
		["degree" .. axis] = degree,
		["knots" .. axis] = options.knots,
		["intervals" .. axis] = options.intervals,
		["clamped" .. axis] = if options.clamped == nil then s["clamped" .. axis] else options.clamped,
	}
	return Core.finish(
		Core.build(s, p, w, ctx, changes),
		ctx,
		map,
		{ deletedControls = (count - #kept) * (along and ctx.nv or ctx.nu), basisChanged = true }
	)
end
function G.deleteSegments(surface, axis, first, last, options)
	local s, ctx = Core.prepare(surface, options)
	local along = Core.axis(axis)
	local count = along and ctx.nu or ctx.nv
	U.integer(first, 1)
	U.integer(last, 1)
	assert(first < last and last <= count, "Increasing control segment endpoints required")
	local lists
	if s["cyclic" .. axis] then
		local list = Core.sequence(last, count)
		for i = 1, first do
			table.insert(list, i)
		end
		lists = { list }
	else
		assert(
			first >= 2 and last < count,
			"Segment deletion would leave a curve-only remnant; use boundaryCurve and deleteRows explicitly"
		)
		lists = { Core.sequence(1, first), Core.sequence(last, count) }
	end
	local pieces, maps = {}, {}
	for k, list in lists do
		pieces[k], maps[k] = Core.pick(
			s,
			along and list or Core.sequence(1, ctx.nu),
			along and Core.sequence(1, ctx.nv) or list,
			ctx,
			options
		)
	end
	return finishPieces(pieces, maps, ctx, {
		deletedControls = (last - first - 1) * (along and ctx.nv or ctx.nu),
		removedSegments = last - first,
	})
end
local function boundaryCurve(s, boundary)
	local along, low = Core.boundary(s, boundary)
	local border = low and 1 or (along and #s.control or #s.control[1])
	local points, weights, map = {}, {}, {}
	for k = 1, along and #s.control[1] or #s.control do
		local i, j = along and border or k, along and k or border
		points[k], weights[k], map[k] = s.control[i][j], s.weights[i][j], Core.key(i, j)
	end
	local axis = along and "V" or "U"
	local periodic = s["cyclic" .. axis]
	return periodic and C.curve(
		points,
		s["degree" .. axis],
		{ weights = weights, intervals = s["intervals" .. axis] }
	) or N.curve(
		points,
		s["degree" .. axis],
		{ weights = weights, knots = s["knots" .. axis], clamped = s["clamped" .. axis] }
	),
		map
end
function G.boundaryCurve(surface, boundary, options)
	local s, ctx = Core.prepare(surface, options)
	local curve = boundaryCurve(s, boundary)
	ctx.check("finish")
	return curve
end
function G.spin(surface, boundary, origin, axis, angle, options)
	local s, ctx = Core.prepare(surface, options)
	options = options or {}
	Core.scalar(angle, "Finite surface spin angle required")
	local startAngle = Core.scalar(options.startAngle or 0, "Finite surface spin start angle required")
	assert(
		U.vector(origin) and U.vector(axis) and axis.Magnitude > 0,
		"Finite spin origin and nonzero axis required"
	)
	axis = axis.Unit
	local curve, sourceMap = boundaryCurve(s, boundary)
	local arc = require(script.Parent.Surfaces).arc(CFrame.identity, 1, startAngle, startAngle + angle)
	local closed = math.abs(math.abs(angle) - 2 * math.pi) < 1e-12
	local count = #arc.points - (closed and 1 or 0)
	ctx.budget(#curve.points, count, curve.degree, 2, curve.kind == "cyclicCurve", closed)
	local p, w, map = {}, {}, {}
	for i, point in curve.points do
		p[i], w[i] = {}, {}
		local center = origin + axis * (point - origin):Dot(axis)
		local radial = point - center
		local tangent = axis:Cross(radial)
		for j = 1, count do
			ctx.visit()
			local q = arc.points[j]
			p[i][j] = center + radial * q.X + tangent * q.Y
			w[i][j] = curve.weights[i] * arc.weights[j]
			map[Core.key(i, j)] = sourceMap[i]
		end
	end
	local intervals = closed and {} or nil
	if intervals then
		for j = 1, count do
			intervals[j] = j % 2 == 1 and 0.25 or 0
		end
	end
	local changes = {
		resetU = true,
		resetV = true,
		degreeU = curve.degree,
		degreeV = 2,
		cyclicU = curve.kind == "cyclicCurve",
		cyclicV = closed,
		clampedU = curve.clamped ~= false,
		clampedV = true,
		knotsU = curve.knots,
		intervalsU = curve.intervals,
		knotsV = not closed and arc.knots or nil,
		intervalsV = intervals,
	}
	return Core.finish(
		Core.build(s, p, w, ctx, changes),
		ctx,
		map,
		{ basisChanged = true, spunPatch = true, closedRevolution = closed }
	)
end
return G
