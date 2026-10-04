-- Periodic rational splines store each control exactly once. Expanded NURBS are copies.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local C = {}

local function periodicKnots(count, degree, intervals)
	U.integer(degree, 1)
	assert(degree <= 8 and count > degree, "Periodic degree must be 1..8 and below unique control count")
	intervals = intervals or table.create(count, 1)
	assert(#intervals == count, "One knot interval per unique control required")
	local sum, zeroRun = 0, 0
	for i = 1, count + degree do
		local value = intervals[(i - 1) % count + 1]
		assert(U.finite(value) and value >= 0, "Finite nonnegative periodic intervals required")
		zeroRun = value == 0 and zeroRun + 1 or 0
		assert(zeroRun < degree, "Periodic knot multiplicity exceeds degree")
		if i <= count then
			sum += value
		end
	end
	assert(sum > 0 and U.finite(sum), "Nonempty periodic domain required")
	local knots = { [degree + 1] = 0 }
	for i = 1, count + degree do
		knots[degree + 1 + i] = knots[degree + i] + intervals[(i - 1) % count + 1]
	end
	for i = 1, degree do
		knots[degree + 1 - i] = knots[degree + 2 - i] - intervals[(count - i) % count + 1]
	end
	return knots, table.clone(intervals)
end

function C.curve(points, degree, options)
	options = options or {}
	local knots, intervals = periodicKnots(#points, degree, options.intervals)
	local p, w = {}, {}
	local weights = options.weights or table.create(#points, 1)
	assert(#weights == #points, "Weight count mismatch")
	assert(#points + degree <= (options.maxControls or 10000), "Expanded periodic control budget exceeded")
	for i = 1, #points + degree do
		local j = (i - 1) % #points + 1
		p[i], w[i] = points[j], weights[j]
	end
	N.curve(p, degree, { knots = knots, weights = w, clamped = false, maxControls = options.maxControls })
	return {
		kind = "cyclicCurve",
		points = table.clone(points),
		weights = table.clone(weights),
		degree = degree,
		intervals = intervals,
	}
end

function C.toNURBS(curve)
	assert(curve.kind == "cyclicCurve", "Cyclic curve required")
	local c = C.curve(curve.points, curve.degree, curve)
	local points, weights = {}, {}
	for i = 1, #c.points + c.degree do
		local j = (i - 1) % #c.points + 1
		points[i], weights[i] = c.points[j], c.weights[j]
	end
	return N.curve(
		points,
		c.degree,
		{ weights = weights, knots = periodicKnots(#c.points, c.degree, c.intervals), clamped = false }
	)
end

function C.evaluate(curve, t)
	return N.evaluate(C.toNURBS(curve), t)
end
function C.derivatives(curve, t)
	return N.derivatives(C.toNURBS(curve), t)
end

function C.rotateSeam(curve, offset)
	local c = C.curve(curve.points, curve.degree, curve)
	assert(U.finite(offset) and offset % 1 == 0, "Integer control offset required")
	local p, w, d = {}, {}, {}
	for i = 1, #c.points do
		local j = (i + offset - 1) % #c.points + 1
		p[i], w[i], d[i] = c.points[j], c.weights[j], c.intervals[j]
	end
	return C.curve(p, c.degree, { weights = w, intervals = d })
end

function C.reverse(curve)
	local c = C.curve(curve.points, curve.degree, curve)
	local p, w, d = {}, {}, {}
	for i = 1, #c.points do
		local j = (c.degree - i) % #c.points + 1
		p[i], w[i], d[i] = c.points[j], c.weights[j], c.intervals[#c.points - i + 1]
	end
	return C.curve(p, c.degree, { weights = w, intervals = d })
end

function C.insertKnot(curve, t, count)
	local c = C.curve(curve.points, curve.degree, curve)
	assert(
		U.finite(t) and t > 0 and t < 1,
		"Insert strictly within one period; rotate the seam for boundary edits"
	)
	count = count or 1
	U.integer(count, 0)
	assert(count <= c.degree)
	for _ = 1, count do
		local n, p, w, d = #c.points, {}, {}, {}
		-- Insert corresponding knots over three periods, then retain the middle control cycle.
		for i = 1, 3 * n + c.degree do
			local j = (i - 1) % n + 1
			p[i], w[i] = c.points[j], c.weights[j]
		end
		for i = 1, 3 * n do
			d[i] = c.intervals[(i - 1) % n + 1]
		end
		local long =
			N.curve(p, c.degree, { weights = w, knots = periodicKnots(3 * n, c.degree, d), clamped = false })
		for period = 0, 2 do
			long = N.insertKnot(long, (period + t) / 3)
		end
		local points, weights = {}, {}
		for i = 1, n + 1 do
			points[i], weights[i] = long.points[n + 1 + i], long.weights[n + 1 + i]
		end
		local total = 0
		for _, v in c.intervals do
			total += v
		end
		local u, accumulated, split = t * total, 0, nil
		for i, v in c.intervals do
			if u >= accumulated and u < accumulated + v then
				split = i
				break
			end
			accumulated += v
		end
		assert(split, "Periodic knot interval below numerical resolution")
		local intervals = table.clone(c.intervals)
		intervals[split] = u - accumulated
		table.insert(intervals, split + 1, c.intervals[split] - (u - accumulated))
		c = C.curve(points, c.degree, { weights = weights, intervals = intervals })
	end
	return c
end

function C.surface(control, degreeU, degreeV, options)
	options = options or {}
	local nu, nv = #control, #control > 0 and #control[1] or 0
	local cyclicU, cyclicV = options.cyclicU ~= false, options.cyclicV ~= false
	assert(cyclicU or cyclicV, "Use NURBS.surface for two open directions")
	local ku, kv, iu, iv = options.knotsU, options.knotsV, nil, nil
	if cyclicU then
		ku, iu = periodicKnots(nu, degreeU, options.intervalsU)
	end
	if cyclicV then
		kv, iv = periodicKnots(nv, degreeV, options.intervalsV)
	end
	local points, weights = {}, {}
	local eu, ev = nu + (cyclicU and degreeU or 0), nv + (cyclicV and degreeV or 0)
	assert(eu * ev <= (options.maxControls or 10000), "Expanded periodic surface control budget exceeded")
	if options.weights then
		assert(#options.weights == nu, "Weight rows mismatch")
	end
	for i, row in control do
		assert(#row == nv, "Rectangular control grid required")
		if options.weights then
			assert(#options.weights[i] == nv, "Weight columns mismatch")
		end
	end
	for i = 1, eu do
		points[i], weights[i] = {}, {}
		local a = (i - 1) % nu + 1
		for j = 1, ev do
			local b = (j - 1) % nv + 1
			points[i][j] = control[a][b]
			weights[i][j] = options.weights and options.weights[a][b] or 1
		end
	end
	local expanded = N.surface(points, degreeU, degreeV, {
		weights = weights,
		knotsU = ku,
		knotsV = kv,
		clampedU = not cyclicU and options.clampedU ~= false,
		clampedV = not cyclicV and options.clampedV ~= false,
		maxControls = options.maxControls,
	})
	local p, w = {}, {}
	for i = 1, nu do
		p[i], w[i] = {}, {}
		for j = 1, nv do
			p[i][j], w[i][j] = expanded.control[i][j], expanded.weights[i][j]
		end
	end
	return {
		kind = "cyclicSurface",
		control = p,
		weights = w,
		degreeU = degreeU,
		degreeV = degreeV,
		cyclicU = cyclicU,
		cyclicV = cyclicV,
		intervalsU = iu,
		intervalsV = iv,
		knotsU = not cyclicU and expanded.knotsU or nil,
		knotsV = not cyclicV and expanded.knotsV or nil,
		clampedU = expanded.clampedU,
		clampedV = expanded.clampedV,
	}
end

function C.surfaceToNURBS(surface)
	assert(surface.kind == "cyclicSurface", "Cyclic surface required")
	local s = C.surface(surface.control, surface.degreeU, surface.degreeV, surface)
	local p, w = {}, {}
	local nu, nv = #s.control, #s.control[1]
	for i = 1, nu + (s.cyclicU and s.degreeU or 0) do
		p[i], w[i] = {}, {}
		for j = 1, nv + (s.cyclicV and s.degreeV or 0) do
			local a, b = (i - 1) % nu + 1, (j - 1) % nv + 1
			p[i][j], w[i][j] = s.control[a][b], s.weights[a][b]
		end
	end
	return N.surface(p, s.degreeU, s.degreeV, {
		weights = w,
		knotsU = s.cyclicU and periodicKnots(nu, s.degreeU, s.intervalsU) or s.knotsU,
		knotsV = s.cyclicV and periodicKnots(nv, s.degreeV, s.intervalsV) or s.knotsV,
		clampedU = s.clampedU,
		clampedV = s.clampedV,
	})
end
function C.evaluateSurface(surface, u, v)
	return N.evaluateSurface(C.surfaceToNURBS(surface), u, v)
end
function C.surfaceDerivatives(surface, u, v)
	return N.surfaceDerivatives(C.surfaceToNURBS(surface), u, v)
end

local function editDirection(surface, axis, operation, argument, count)
	local s = C.surface(surface.control, surface.degreeU, surface.degreeV, surface)
	assert(axis == "U" or axis == "V", "Axis must be U or V")
	local alongU = axis == "U"
	local periodic = if alongU then s.cyclicU else s.cyclicV
	local curves = {}
	for j = 1, (alongU and #s.control[1] or #s.control) do
		local p, w = {}, {}
		for i = 1, (alongU and #s.control or #s.control[1]) do
			p[i], w[i] =
				if alongU then s.control[i][j] else s.control[j][i],
				if alongU then s.weights[i][j] else s.weights[j][i]
		end
		local degree = alongU and s.degreeU or s.degreeV
		local c
		if periodic then
			c = C.curve(p, degree, { weights = w, intervals = alongU and s.intervalsU or s.intervalsV })
			c = C[operation](c, argument, count)
		else
			assert(operation ~= "rotateSeam", "Cannot rotate the seam of an open direction")
			c = N.curve(p, degree, {
				weights = w,
				knots = alongU and s.knotsU or s.knotsV,
				clamped = if alongU then s.clampedU else s.clampedV,
			})
			c = N[operation](c, argument, count)
		end
		curves[j] = c
	end
	local p, w = {}, {}
	if alongU then
		for i = 1, #curves[1].points do
			p[i], w[i] = {}, {}
			for j, c in curves do
				p[i][j], w[i][j] = c.points[i], c.weights[i]
			end
		end
	else
		for j, c in curves do
			p[j], w[j] = c.points, c.weights
		end
	end
	local options = table.clone(s)
	options.weights = w
	options[alongU and "intervalsU" or "intervalsV"] = curves[1].intervals
	options[alongU and "knotsU" or "knotsV"] = curves[1].knots
	return C.surface(p, s.degreeU, s.degreeV, options)
end
function C.insertSurfaceKnot(surface, axis, t, count)
	return editDirection(surface, axis, "insertKnot", t, count)
end
function C.reverseSurface(surface, axis)
	return editDirection(surface, axis, "reverse")
end
function C.rotateSurfaceSeam(surface, axis, offset)
	return editDirection(surface, axis, "rotateSeam", offset)
end
function C.elevateDegree(curve, count, options)
	return require(script.Parent.CyclicEdit).curve(curve, "elevate", nil, count or 1, options)
end
function C.removeKnot(curve, t, count, options)
	return require(script.Parent.CyclicEdit).curve(curve, "remove", t, count or 1, options)
end
function C.elevateSurfaceDegree(surface, axis, count, options)
	return require(script.Parent.CyclicEdit).surface(surface, axis, "elevate", nil, count or 1, options)
end
function C.removeSurfaceKnot(surface, axis, t, count, options)
	return require(script.Parent.CyclicEdit).surface(surface, axis, "remove", t, count or 1, options)
end
return C
