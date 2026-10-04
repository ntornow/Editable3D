--!strict
-- Positive-weight rational B-spline curves and tensor-product surfaces.
-- Original implementation; no services, scene mutation or network access.
local U = require(script.Parent.Util)
local Mesh = require(script.Parent.Mesh)
local Types = require(script.Parent.Types)
local N = {}

-- Descriptors are plain tables; every public operation revalidates and copies them.
export type Curve = {
	kind: string, -- "curve"
	clamped: boolean,
	points: { Vector3 },
	degree: number,
	knots: { number },
	weights: { number },
}
export type Surface = {
	kind: string, -- "surface"
	clampedU: boolean,
	clampedV: boolean,
	control: { { Vector3 } },
	weights: { { number } },
	degreeU: number,
	degreeV: number,
	knotsU: { number },
	knotsV: { number },
}
export type CurveOptions = {
	knots: { number }?,
	weights: { number }?,
	clamped: boolean?,
	maxControls: number?,
}
export type SurfaceOptions = {
	knotsU: { number }?,
	knotsV: { number }?,
	weights: { { number } }?,
	clampedU: boolean?,
	clampedV: boolean?,
	maxControls: number?,
}
export type CurveDerivatives = {
	position: Vector3,
	first: Vector3,
	second: Vector3,
	regular: boolean,
	curvature: number?,
}
export type SurfaceDerivatives = {
	position: Vector3,
	du: Vector3,
	dv: Vector3,
	duu: Vector3,
	duv: Vector3,
	dvv: Vector3,
	normal: Vector3?,
	regular: boolean,
	meanCurvature: number?,
	gaussianCurvature: number?,
}
export type CurveEvaluator = {
	evaluate: (t: number) -> Vector3,
	derivatives: (t: number) -> CurveDerivatives,
}
export type SurfaceEvaluator = {
	evaluate: (u: number, v: number) -> Vector3,
	derivatives: (u: number, v: number) -> SurfaceDerivatives,
}
export type BezierSegment = { curve: Curve, first: number, last: number }
export type BezierPatch = { surface: Surface, u0: number, u1: number, v0: number, v1: number }
export type RemovalOptions = {
	tolerance: number?,
	checkpoint: ((fraction: number) -> ())?,
}
export type RemovalReport = {
	requested: number,
	removed: number,
	errorBound: number,
	tolerance: number,
	reason: string?,
	rejectedErrorBound: number?,
	complete: boolean?,
}
export type TessellateOptions = {
	maxVertices: number?,
	closedU: boolean?,
	closedV: boolean?,
	seamTolerance: number?,
	collapsePoles: boolean?,
	map: ((position: Vector3, uv: Vector2, derivatives: SurfaceDerivatives) -> Vector3)?,
	checkpoint: ((fraction: number) -> ())?,
	material: number?,
}
export type TessellateReport = {
	poles: { [string]: boolean },
	collapsedQuads: number,
	closedU: boolean,
	closedV: boolean,
}
type Homogeneous = { number }
type TessellateRecord = { position: Vector3, normal: Vector3, uv: Vector2 }
-- SplineBasis is not strict yet: basis(n, p, knots, t) -> (values, first, second).
type BasisFn = (n: number, p: number, knots: { number }, t: number) -> ({ number }, { number }, { number })

local function knotsFor(n: number, degree: number, knots: { number }?, clamped: boolean?): { number }
	U.integer(degree, 1)
	assert(degree <= 17 and n > degree, "Degree must be 1..17 and below control count")
	if not knots then
		knots = {}
		for i = 1, n + degree + 1 do
			((knots :: any) :: { number })[i] = if clamped == false
				then (i - degree - 1) / (n - degree)
				else i <= degree + 1 and 0 or i >= n + 1 and 1 or (i - degree - 1) / (n - degree)
		end
	end
	local knots = knots :: { number }
	assert(#knots == n + degree + 1, "Knot count mismatch")
	local a, b = knots[degree + 1], knots[n + 1]
	assert(U.finite(a) and U.finite(b) and b > a and U.finite(b - a), "Nonempty finite knot domain required")
	local run = 0
	for i, v in knots do
		assert(U.finite(v) and (i == 1 or v >= knots[i - 1]), "Knots must be finite and nondecreasing")
		assert(clamped == false or (v >= a and v <= b), "Clamped knots must stay in the active domain")
		run = i > 1 and v == knots[i - 1] and run + 1 or 1
		assert(run <= ((v <= a or v >= b) and degree + 1 or degree), "Excessive knot multiplicity")
	end
	if clamped ~= false then
		for i = 1, degree + 1 do
			assert(knots[i] == a and knots[#knots - i + 1] == b, "Clamped endpoint knots required")
		end
	end
	return table.clone(knots)
end

local function parameter(t: number): number
	assert(U.finite(t) and t >= 0 and t <= 1, "Normalized parameter must be in [0,1]")
	return t
end

local basis: BasisFn = require(script.Parent.SplineBasis) :: any

function N.curve(points: { Vector3 }, degree: number, options: CurveOptions?): Curve
	local options: CurveOptions = options or {}
	assert(#points <= (options.maxControls or 10000), "Curve control budget exceeded")
	local knots = knotsFor(#points, degree, options.knots, options.clamped)
	local weights = options.weights or table.create(#points, 1)
	assert(#weights == #points, "Weight count mismatch")
	for i, p in points do
		assert(
			U.vector(p) and U.finite(weights[i]) and weights[i] > 0,
			"Finite controls and positive finite weights required"
		)
	end
	return {
		kind = "curve",
		clamped = options.clamped ~= false,
		points = table.clone(points),
		degree = degree,
		knots = knots,
		weights = table.clone(weights),
	}
end

function N.surface(
	control: { { Vector3 } },
	degreeU: number,
	degreeV: number,
	options: SurfaceOptions?
): Surface
	local options: SurfaceOptions = options or {}
	local nu, nv = #control, #control > 0 and #control[1] or 0
	assert(nu * nv <= (options.maxControls or 10000), "Surface control budget exceeded")
	local ku, kv =
		knotsFor(nu, degreeU, options.knotsU, options.clampedU),
		knotsFor(nv, degreeV, options.knotsV, options.clampedV)
	local weights: { { number } }, points: { { Vector3 } } = {}, {}
	if options.weights then
		assert(#options.weights == nu, "Surface weight rows mismatch")
	end
	for i, row in control do
		assert(#row == nv, "Rectangular control grid required")
		points[i], weights[i] = table.clone(row), {}
		if options.weights then
			assert(#options.weights[i] == nv, "Surface weight columns mismatch")
		end
		for j, p in row do
			local w = options.weights and options.weights[i][j] or 1
			assert(
				U.vector(p) and U.finite(w) and w > 0,
				"Finite controls and positive finite weights required"
			)
			weights[i][j] = w
		end
	end
	return {
		kind = "surface",
		clampedU = options.clampedU ~= false,
		clampedV = options.clampedV ~= false,
		control = points,
		weights = weights,
		degreeU = degreeU,
		degreeV = degreeV,
		knotsU = ku,
		knotsV = kv,
	}
end

local function checkedCurve(c: Curve): Curve
	assert(c.kind == "curve", "NURBS curve required")
	return N.curve(c.points, c.degree, { knots = c.knots, weights = c.weights, clamped = c.clamped })
end
local function checkedSurface(s: Surface): Surface
	assert(s.kind == "surface", "NURBS surface required")
	return N.surface(s.control, s.degreeU, s.degreeV, {
		knotsU = s.knotsU,
		knotsV = s.knotsV,
		weights = s.weights,
		clampedU = s.clampedU,
		clampedV = s.clampedV,
	})
end
local function accum(h: Homogeneous, p: Vector3, weight: number, origin: Vector3)
	h[1] += (p.X - origin.X) * weight
	h[2] += (p.Y - origin.Y) * weight
	h[3] += (p.Z - origin.Z) * weight
	h[4] += weight
end
local function xyz(h: Homogeneous): Vector3
	return Vector3.new(h[1], h[2], h[3])
end
local function zero(): Homogeneous
	return { 0, 0, 0, 0 }
end

local function curveDerivatives(c: Curve, t: number): CurveDerivatives
	local b, d, dd = basis(#c.points, c.degree, c.knots, t)
	local h, hd, hdd = zero(), zero(), zero()
	local origin, maximum = c.points[1], 0
	for _, w in c.weights do
		maximum = math.max(maximum, w)
	end
	for i, p in c.points do
		local w = c.weights[i] / maximum
		accum(h, p, b[i] * w, origin)
		accum(hd, p, d[i] * w, origin)
		accum(hdd, p, dd[i] * w, origin)
	end
	assert(h[4] > 0 and U.finite(h[4]), "Rational denominator is outside numerical range")
	local localP = xyz(h) / h[4]
	local first = (xyz(hd) - localP * hd[4]) / h[4]
	local second = (xyz(hdd) - first * (2 * hd[4]) - localP * hdd[4]) / h[4]
	local p = origin + localP
	assert(U.vector(p) and U.vector(first) and U.vector(second), "Evaluation exceeded Vector3 range")
	local speed = first.Magnitude
	return {
		position = p,
		first = first,
		second = second,
		regular = speed > 1e-12,
		curvature = speed > 1e-12 and first:Cross(second).Magnitude / (speed ^ 3) or nil,
	}
end
function N.evaluate(curve: Curve, t: number): Vector3
	return curveDerivatives(checkedCurve(curve), t).position
end
function N.derivatives(curve: Curve, t: number): CurveDerivatives
	return curveDerivatives(checkedCurve(curve), t)
end

-- Prepared evaluators own a validated snapshot; repeated calls avoid copying controls.
function N.compileCurve(curve: Curve): CurveEvaluator
	local c = checkedCurve(curve)
	return table.freeze({
		evaluate = function(t)
			return curveDerivatives(c, t).position
		end,
		derivatives = function(t)
			return curveDerivatives(c, t)
		end,
	})
end

function N.basisWeights(curve: Curve, t: number): { number }
	local c = checkedCurve(curve)
	local values = basis(#c.points, c.degree, c.knots, t)
	local maximum, denominator = 0, 0
	for _, weight in c.weights do
		maximum = math.max(maximum, weight)
	end
	for i, value in values do
		values[i] = value * (c.weights[i] / maximum)
		denominator += values[i]
	end
	assert(denominator > 0 and U.finite(denominator), "Rational basis denominator is outside numerical range")
	for i, value in values do
		values[i] = value / denominator
	end
	return values
end

local function insertOnce(c: Curve, t: number, rawParameter: number?, boundary: boolean?): Curve
	parameter(t)
	assert(boundary or (t > 0 and t < 1), "Insert knots strictly inside the domain")
	local n, p, k, s = #c.points, c.degree, nil :: number?, 0
	local u = rawParameter or (c.knots[p + 1] + t * (c.knots[n + 1] - c.knots[p + 1]))
	assert(
		boundary or (u > c.knots[p + 1] and u < c.knots[n + 1]),
		"Knot interval is below numerical resolution"
	)
	for i, v in c.knots do
		if v == u then
			s += 1
		end
		if i < #c.knots and v <= u and u < c.knots[i + 1] then
			k = i
		end
	end
	assert(k and s < (boundary and p + 1 or p), "Knot multiplicity cannot exceed its limit")
	local points: { Vector3 }, weights: { number } = {}, {}
	for i = 1, k - p do
		points[i], weights[i] = c.points[i], c.weights[i]
	end
	for i = k - s, n do
		points[i + 1], weights[i + 1] = c.points[i], c.weights[i]
	end
	for i = k - p + 1, k - s do
		local a = (u - c.knots[i]) / (c.knots[i + p] - c.knots[i])
		local w = (1 - a) * c.weights[i - 1] + a * c.weights[i]
		local fraction = a * c.weights[i] / w
		local left, right = c.points[i - 1], c.points[i]
		points[i] = Vector3.new(
			left.X + (right.X - left.X) * fraction,
			left.Y + (right.Y - left.Y) * fraction,
			left.Z + (right.Z - left.Z) * fraction
		)
		weights[i] = w
	end
	local knots = table.clone(c.knots)
	table.insert(knots, k + 1, u)
	return N.curve(points, p, { knots = knots, weights = weights, clamped = c.clamped })
end
-- Extract the active knot domain without moving it or changing its parameterization.
function N.clamp(curve: Curve): Curve
	local c = checkedCurve(curve)
	if c.clamped then
		return c
	end
	local a, b = c.knots[c.degree + 1], c.knots[#c.points + 1]
	for _, endpoint in { { 0, a }, { 1, b } } do
		local count = 0
		for _, knot in c.knots do
			if knot == endpoint[2] then
				count += 1
			end
		end
		for _ = count + 1, c.degree + 1 do
			c = insertOnce(c, endpoint[1], endpoint[2], true)
		end
	end
	local first, last = 1, #c.knots
	while c.knots[first] < a do
		first += 1
	end
	while c.knots[last] > b do
		last -= 1
	end
	local knots: { number }, points: { Vector3 }, weights: { number } = {}, {}, {}
	for i = first, last do
		table.insert(knots, c.knots[i])
	end
	for i = first, last - c.degree - 1 do
		table.insert(points, c.points[i])
		table.insert(weights, c.weights[i])
	end
	return N.curve(points, c.degree, { knots = knots, weights = weights })
end

function N.insertKnot(curve: Curve, t: number, count: number?): Curve
	local c = checkedCurve(curve)
	local count: number = count or 1
	U.integer(count, 0)
	assert(count <= 17)
	parameter(t)
	assert(t > 0 and t < 1, "Insert knots strictly inside the domain")
	for _ = 1, count do
		c = insertOnce(c, t)
	end
	return c
end
function N.split(curve: Curve, t: number): (Curve, Curve)
	local c = checkedCurve(curve)
	parameter(t)
	assert(t > 0 and t < 1, "Split strictly inside the domain")
	local u = c.knots[c.degree + 1] + t * (c.knots[#c.points + 1] - c.knots[c.degree + 1])
	local multiplicity = 0
	for _, v in c.knots do
		if v == u then
			multiplicity += 1
		end
	end
	c = N.insertKnot(c, t, c.degree - multiplicity)
	local k: number?
	for i, v in c.knots do
		if v == u then
			k = i
		end
	end
	assert(k, "Split knot missing")
	local shared = k - c.degree
	local ap: { Vector3 }, aw: { number }, bp: { Vector3 }, bw: { number }, ak: { number }, bk: { number } =
		{}, {}, {}, {}, {}, { u }
	for i = 1, shared do
		table.insert(ap, c.points[i])
		table.insert(aw, c.weights[i])
	end
	for i = shared, #c.points do
		table.insert(bp, c.points[i])
		table.insert(bw, c.weights[i])
	end
	for i = 1, k do
		table.insert(ak, c.knots[i])
	end
	table.insert(ak, u)
	for i = k - c.degree + 1, #c.knots do
		table.insert(bk, c.knots[i])
	end
	return N.curve(ap, c.degree, { knots = ak, weights = aw, clamped = c.clamped }),
		N.curve(bp, c.degree, { knots = bk, weights = bw, clamped = c.clamped })
end
function N.reverse(curve: Curve): Curve
	local c = checkedCurve(curve)
	local points: { Vector3 }, weights: { number }, knots: { number } = {}, {}, {}
	for i = #c.points, 1, -1 do
		table.insert(points, c.points[i])
		table.insert(weights, c.weights[i])
	end
	local a, b = c.knots[1], c.knots[#c.knots]
	for i = #c.knots, 1, -1 do
		table.insert(knots, a + (b - c.knots[i]))
	end
	return N.curve(points, c.degree, { knots = knots, weights = weights, clamped = c.clamped })
end

local function surfaceDerivatives(s: Surface, u: number, v: number): SurfaceDerivatives
	local a, ad, add = basis(#s.control, s.degreeU, s.knotsU, u)
	local b, bd, bdd = basis(#s.control[1], s.degreeV, s.knotsV, v)
	local h, hu, hv, huu, huv, hvv = zero(), zero(), zero(), zero(), zero(), zero()
	local origin, maximum = s.control[1][1], 0
	for _, row in s.weights do
		for _, w in row do
			maximum = math.max(maximum, w)
		end
	end
	for i, row in s.control do
		for j, p in row do
			local w = s.weights[i][j] / maximum
			accum(h, p, a[i] * b[j] * w, origin)
			accum(hu, p, ad[i] * b[j] * w, origin)
			accum(hv, p, a[i] * bd[j] * w, origin)
			accum(huu, p, add[i] * b[j] * w, origin)
			accum(huv, p, ad[i] * bd[j] * w, origin)
			accum(hvv, p, a[i] * bdd[j] * w, origin)
		end
	end
	assert(h[4] > 0 and U.finite(h[4]), "Rational denominator is outside numerical range")
	local p = xyz(h) / h[4]
	local du, dv = (xyz(hu) - p * hu[4]) / h[4], (xyz(hv) - p * hv[4]) / h[4]
	local duu = (xyz(huu) - du * (2 * hu[4]) - p * huu[4]) / h[4]
	local duv = (xyz(huv) - du * hv[4] - dv * hu[4] - p * huv[4]) / h[4]
	local dvv = (xyz(hvv) - dv * (2 * hv[4]) - p * hvv[4]) / h[4]
	for _, q in { p + origin, du, dv, duu, duv, dvv } do
		assert(U.vector(q), "Evaluation exceeded Vector3 range")
	end
	local cross = du:Cross(dv)
	local regular = cross.Magnitude > 1e-12
	local normal = regular and cross.Unit or nil
	local mean: number?, gaussian: number?
	if regular then
		local e, f, g = du:Dot(du), du:Dot(dv), dv:Dot(dv)
		local determinant = cross:Dot(cross)
		local l, m, n =
			(normal :: Vector3):Dot(duu), (normal :: Vector3):Dot(duv), (normal :: Vector3):Dot(dvv)
		mean = (e * n - 2 * f * m + g * l) / (2 * determinant)
		gaussian = (l * n - m * m) / determinant
	end
	return {
		position = p + origin,
		du = du,
		dv = dv,
		duu = duu,
		duv = duv,
		dvv = dvv,
		normal = normal,
		regular = regular,
		meanCurvature = mean,
		gaussianCurvature = gaussian,
	}
end
function N.evaluateSurface(surface: Surface, u: number, v: number): Vector3
	return surfaceDerivatives(checkedSurface(surface), u, v).position
end
function N.surfaceDerivatives(surface: Surface, u: number, v: number): SurfaceDerivatives
	return surfaceDerivatives(checkedSurface(surface), u, v)
end

function N.compileSurface(surface: Surface): SurfaceEvaluator
	local s = checkedSurface(surface)
	return table.freeze({
		evaluate = function(u, v)
			return surfaceDerivatives(s, u, v).position
		end,
		derivatives = function(u, v)
			return surfaceDerivatives(s, u, v)
		end,
	})
end

local function lines(s: Surface, axis: string): { Curve }
	assert(axis == "U" or axis == "V", "Axis must be U or V")
	local out: { Curve } = {}
	for j = 1, (axis == "U" and #s.control[1] or #s.control) do
		local p: { Vector3 }, w: { number } = {}, {}
		for i = 1, (axis == "U" and #s.control or #s.control[1]) do
			p[i] = axis == "U" and s.control[i][j] or s.control[j][i]
			w[i] = axis == "U" and s.weights[i][j] or s.weights[j][i]
		end
		out[j] = N.curve(p, axis == "U" and s.degreeU or s.degreeV, {
			knots = axis == "U" and s.knotsU or s.knotsV,
			weights = w,
			clamped = if axis == "U" then s.clampedU else s.clampedV,
		})
	end
	return out
end
local function fromLines(s: Surface, axis: string, curves: { Curve }): Surface
	local p: { { Vector3 } }, w: { { number } } = {}, {}
	if axis == "U" then
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
	return N.surface(
		p,
		axis == "U" and curves[1].degree or s.degreeU,
		axis == "V" and curves[1].degree or s.degreeV,
		{
			weights = w,
			knotsU = axis == "U" and curves[1].knots or s.knotsU,
			knotsV = axis == "V" and curves[1].knots or s.knotsV,
			clampedU = if axis == "U" then curves[1].clamped else s.clampedU,
			clampedV = if axis == "V" then curves[1].clamped else s.clampedV,
		}
	)
end
function N.clampSurface(surface: Surface, axis: string): Surface
	local s = checkedSurface(surface)
	local curves = lines(s, axis)
	for i, c in curves do
		curves[i] = N.clamp(c)
	end
	return fromLines(s, axis, curves)
end

function N.insertSurfaceKnot(surface: Surface, axis: string, t: number, count: number?): Surface
	local s = checkedSurface(surface)
	local curves = lines(s, axis)
	for i, c in curves do
		curves[i] = N.insertKnot(c, t, count)
	end
	return fromLines(s, axis, curves)
end
function N.splitSurface(surface: Surface, axis: string, t: number): (Surface, Surface)
	local s = checkedSurface(surface)
	local a: { Curve }, b: { Curve } = {}, {}
	for i, c in lines(s, axis) do
		a[i], b[i] = N.split(c, t)
	end
	return fromLines(s, axis, a), fromLines(s, axis, b)
end
function N.reverseSurface(surface: Surface, axis: string): Surface
	local s = checkedSurface(surface)
	local curves = lines(s, axis)
	for i, c in curves do
		curves[i] = N.reverse(c)
	end
	return fromLines(s, axis, curves)
end
function N.isoCurve(surface: Surface, axis: string, t: number): Curve
	-- Axis selects the varying coordinate; t fixes the other coordinate.
	local s = checkedSurface(surface)
	assert(axis == "U" or axis == "V", "Axis must be U or V")
	local opposite = axis == "U" and "V" or "U"
	local p: { Vector3 }, w: { number } = {}, {}
	local maximum = 0
	for _, row in s.weights do
		for _, weight in row do
			maximum = math.max(maximum, weight)
		end
	end
	for i, c in lines(s, opposite) do
		local b = basis(#c.points, c.degree, c.knots, t)
		local h = zero()
		local origin = c.points[1]
		for j, q in c.points do
			accum(h, q, b[j] * c.weights[j] / maximum, origin)
		end
		assert(h[4] > 0, "Rational denominator is outside numerical range")
		p[i], w[i] = origin + xyz(h) / h[4], h[4]
	end
	return N.curve(p, axis == "U" and s.degreeU or s.degreeV, {
		weights = w,
		knots = axis == "U" and s.knotsU or s.knotsV,
		clamped = if axis == "U" then s.clampedU else s.clampedV,
	})
end
-- Convert each knot span to a Bezier segment using homogeneous insertion.
local function bezierPieces(curve: Curve): ({ BezierSegment }, { number })
	local c = N.clamp(curve)
	local a, b = c.knots[c.degree + 1], c.knots[#c.points + 1]
	local breaks: { number }, multiplicities: { [number]: number } = { a }, {}
	for _, knot in c.knots do
		if knot > a and knot < b then
			if not multiplicities[knot] then
				table.insert(breaks, knot)
				multiplicities[knot] = 0
			end
			multiplicities[knot] += 1
		end
	end
	table.insert(breaks, b)
	for _, knot in breaks do
		if knot > a and knot < b then
			for _ = multiplicities[knot] + 1, c.degree do
				c = insertOnce(c, (knot - a) / (b - a), knot)
			end
		end
	end
	local segments: { BezierSegment } = {}
	for k = 1, #breaks - 1 do
		local p: { Vector3 }, w: { number } = {}, {}
		for i = 1, c.degree + 1 do
			local index = (k - 1) * c.degree + i
			p[i], w[i] = c.points[index], c.weights[index]
		end
		table.insert(segments, {
			curve = N.curve(p, c.degree, { weights = w }),
			first = (breaks[k] - a) / (b - a),
			last = (breaks[k + 1] - a) / (b - a),
		})
	end
	return segments, breaks
end

function N.bezierSegments(curve: Curve): { BezierSegment }
	local segments = bezierPieces(curve)
	return segments
end

function N.bezierPatches(surface: Surface): { BezierPatch }
	local s = N.clampSurface(N.clampSurface(surface, "U"), "V")
	local breaks: { [string]: { number } } = {}
	for _, axis in { "U", "V" } do
		local knots = axis == "U" and s.knotsU or s.knotsV
		local degree = axis == "U" and s.degreeU or s.degreeV
		local a, b = knots[1], knots[#knots]
		local values: { number }, counts: { [number]: number } = { a }, {}
		for _, knot in knots do
			if knot > a and knot < b then
				if not counts[knot] then
					table.insert(values, knot)
					counts[knot] = 0
				end
				counts[knot] += 1
			end
		end
		table.insert(values, b)
		for _, knot in values do
			if knot > a and knot < b then
				local curves = lines(s, axis)
				for i, c in curves do
					for _ = counts[knot] + 1, degree do
						c = insertOnce(c, (knot - a) / (b - a), knot)
					end
					curves[i] = c
				end
				s = fromLines(s, axis, curves)
			end
		end
		for i, knot in values do
			values[i] = (knot - a) / (b - a)
		end
		breaks[axis] = values
	end
	local patches: { BezierPatch } = {}
	for i = 1, #breaks.U - 1 do
		for j = 1, #breaks.V - 1 do
			local points: { { Vector3 } }, weights: { { number } } = {}, {}
			for a = 1, s.degreeU + 1 do
				points[a], weights[a] = {}, {}
				for b = 1, s.degreeV + 1 do
					local u, v = (i - 1) * s.degreeU + a, (j - 1) * s.degreeV + b
					points[a][b], weights[a][b] = s.control[u][v], s.weights[u][v]
				end
			end
			table.insert(patches, {
				surface = N.surface(points, s.degreeU, s.degreeV, { weights = weights }),
				u0 = breaks.U[i],
				u1 = breaks.U[i + 1],
				v0 = breaks.V[j],
				v1 = breaks.V[j + 1],
			})
		end
	end
	return patches
end

function N.elevateDegree(curve: Curve, count: number?): Curve
	local c = checkedCurve(curve)
	local count: number = count or 1
	U.integer(count, 0)
	assert(c.degree + count <= 17, "Elevated degree exceeds supported degree 17")
	if count == 0 then
		return c
	end
	local segments, breaks = bezierPieces(c)
	local points: { Vector3 }, weights: { number }, knots: { number } = {}, {}, {}
	for k, segment in segments do
		local p, w, degree = segment.curve.points, segment.curve.weights, c.degree
		for _ = 1, count do
			local np, nw = { p[1] }, { w[1] }
			for i = 1, degree do
				local alpha = i / (degree + 1)
				local weight = alpha * w[i] + (1 - alpha) * w[i + 1]
				local fraction = (1 - alpha) * w[i + 1] / weight
				np[i + 1], nw[i + 1] = p[i]:Lerp(p[i + 1], fraction), weight
			end
			np[degree + 2], nw[degree + 2] = p[degree + 1], w[degree + 1]
			p, w, degree = np, nw, degree + 1
		end
		for i = k == 1 and 1 or 2, #p do
			table.insert(points, p[i])
			table.insert(weights, w[i])
		end
	end
	local degree = c.degree + count
	for i, knot in breaks do
		for _ = 1, (i == 1 or i == #breaks) and degree + 1 or degree do
			table.insert(knots, knot)
		end
	end
	return N.curve(points, degree, { knots = knots, weights = weights })
end

function N.elevateSurfaceDegree(surface: Surface, axis: string, count: number?): Surface
	local s = checkedSurface(surface)
	local curves = lines(s, axis)
	for i, c in curves do
		curves[i] = N.elevateDegree(c, count)
	end
	return fromLines(s, axis, curves)
end

-- Small overdetermined four-RHS solve used to invert a knot insertion.
-- Givens QR avoids squaring the condition number through normal equations.
local function smallQR(matrix: { { number } }, rhs: { Homogeneous }, columns: number): { Homogeneous }?
	for column = 1, columns do
		for row = #matrix, column + 1, -1 do
			local a, b = matrix[row - 1][column], matrix[row][column]
			if b ~= 0 then
				local radius = math.sqrt(a * a + b * b)
				local c, s = a / radius, b / radius
				for j = column, columns do
					local x, y = matrix[row - 1][j], matrix[row][j]
					matrix[row - 1][j], matrix[row][j] = c * x + s * y, -s * x + c * y
				end
				for j = 1, 4 do
					local x, y = rhs[row - 1][j], rhs[row][j]
					rhs[row - 1][j], rhs[row][j] = c * x + s * y, -s * x + c * y
				end
			end
		end
		if math.abs(matrix[column][column]) < 1e-13 then
			return nil
		end
	end
	local solution: { Homogeneous } = {}
	for i = columns, 1, -1 do
		solution[i] = {}
		for channel = 1, 4 do
			local value = rhs[i][channel]
			for j = i + 1, columns do
				value -= matrix[i][j] * solution[j][channel]
			end
			solution[i][channel] = value / matrix[i][i]
		end
	end
	return solution
end

local function removalCandidate(c: Curve, knot: number): (Curve?, string?)
	local knots, occurrence = table.clone(c.knots), nil :: number?
	for i, v in knots do
		if v == knot then
			occurrence = i
		end
	end
	if not occurrence then
		return nil, "Knot is not present"
	end
	table.remove(knots, occurrence)
	local n, p, span, multiplicity = #c.points - 1, c.degree, nil :: number?, 0
	if n <= p then
		return nil, "Removal would leave too few controls"
	end
	for i, v in knots do
		if v == knot then
			multiplicity += 1
		end
		if i < #knots and v <= knot and knot < knots[i + 1] then
			span = i
		end
	end
	assert(span, "Interior knot span missing")
	local first, last = span - p, span - multiplicity
	local points: { Vector3 }, weights: { number } = {}, {}
	for i = 1, first do
		points[i], weights[i] = c.points[i], c.weights[i]
	end
	for i = last, n do
		points[i], weights[i] = c.points[i + 1], c.weights[i + 1]
	end
	local maximum = 0
	for _, w in c.weights do
		maximum = math.max(maximum, w)
	end
	local origin = c.points[1]
	local function homogeneous(point: Vector3, weight: number): Homogeneous
		local w = weight / maximum
		return { (point.X - origin.X) * w, (point.Y - origin.Y) * w, (point.Z - origin.Z) * w, w }
	end
	local unknowns = last - first - 1
	if unknowns > 0 then
		local matrix: { { number } }, rhs: { Homogeneous } = {}, {}
		for i = first + 1, last do
			local row = i - first
			matrix[row] = table.create(unknowns, 0)
			rhs[row] = homogeneous(c.points[i], c.weights[i])
			local alpha = (knot - knots[i]) / (knots[i + p] - knots[i])
			for _, term in { { i - 1, 1 - alpha }, { i, alpha } } do
				local id, coefficient = term[1], term[2]
				if id > first and id < last then
					matrix[row][id - first] = coefficient
				else
					local h = homogeneous(points[id], weights[id])
					for j = 1, 4 do
						rhs[row][j] -= h[j] * coefficient
					end
				end
			end
		end
		local solution = smallQR(matrix, rhs, unknowns)
		if not solution then
			return nil, "Inverse insertion is ill-conditioned"
		end
		for i, h in solution do
			local weight = h[4] * maximum
			if not U.finite(weight) or weight <= 0 then
				return nil, "Removal requires nonpositive or nonfinite weights"
			end
			local point = origin + Vector3.new(h[1] / h[4], h[2] / h[4], h[3] / h[4])
			if not U.vector(point) then
				return nil, "Removal exceeds coordinate range"
			end
			points[first + i], weights[first + i] = point, weight
		end
	end
	return N.curve(points, p, { knots = knots, weights = weights, clamped = c.clamped })
end

-- A conservative uniform rational error bound for two equal-basis control nets.
-- Positive basis functions form a partition of unity, so this applies between samples.
local function controlError(
	pointsA: { Vector3 },
	weightsA: { number },
	pointsB: { Vector3 },
	weightsB: { number }
): number
	local maximum, radius = 0, 0
	for i, w in weightsA do
		maximum = math.max(maximum, w, weightsB[i])
	end
	local origin = pointsA[1]
	local deltaH, deltaW, minimum = 0, 0, math.huge
	for i, pa in pointsA do
		local pb, wa, wb = pointsB[i], weightsA[i] / maximum, weightsB[i] / maximum
		local ax, ay, az = pa.X - origin.X, pa.Y - origin.Y, pa.Z - origin.Z
		local bx, by, bz = pb.X - origin.X, pb.Y - origin.Y, pb.Z - origin.Z
		local x, y, z = ax * wa - bx * wb, ay * wa - by * wb, az * wa - bz * wb
		deltaH = math.max(deltaH, math.sqrt(x * x + y * y + z * z))
		deltaW = math.max(deltaW, math.abs(wa - wb))
		radius = math.max(radius, math.sqrt(bx * bx + by * by + bz * bz))
		minimum = math.min(minimum, wa)
	end
	return minimum > 0 and (deltaH + radius * deltaW) / minimum or math.huge
end

local function removalOptions(t: number, count: number?, options: RemovalOptions?): (number, number)
	parameter(t)
	assert(t > 0 and t < 1, "Remove knots strictly inside the domain")
	local count: number = count or 1
	U.integer(count, 0)
	local tolerance = ((options or {}) :: RemovalOptions).tolerance or 1e-5
	assert(U.finite(tolerance) and tolerance >= 0, "Finite nonnegative removal tolerance required")
	return count, tolerance
end

function N.removeKnot(
	curve: Curve,
	t: number,
	count: number?,
	options: RemovalOptions?
): (Curve, RemovalReport)
	local c = checkedCurve(curve)
	local requested, tolerance = removalOptions(t, count, options)
	local knot = c.knots[c.degree + 1] + t * (c.knots[#c.points + 1] - c.knots[c.degree + 1])
	local report: RemovalReport =
		{ requested = requested, removed = 0, errorBound = 0, tolerance = tolerance }
	for _ = 1, requested do
		if options and options.checkpoint then
			options.checkpoint(report.removed / requested)
		end
		local candidate, reason = removalCandidate(c, knot)
		if not candidate then
			report.reason = reason
			break
		end
		local reconstructed = insertOnce(candidate, t, knot)
		local bound = controlError(c.points, c.weights, reconstructed.points, reconstructed.weights)
		if report.errorBound + bound > tolerance then
			report.rejectedErrorBound = bound
			report.reason = "Conservative error bound exceeds tolerance"
			break
		end
		c, report.errorBound, report.removed = candidate, report.errorBound + bound, report.removed + 1
	end
	report.complete = report.removed == requested
	return c, report
end

function N.removeSurfaceKnot(
	surface: Surface,
	axis: string,
	t: number,
	count: number?,
	options: RemovalOptions?
): (Surface, RemovalReport)
	local s = checkedSurface(surface)
	local requested, tolerance = removalOptions(t, count, options)
	local initialLines = lines(s, axis)
	local c = initialLines[1]
	local knot = c.knots[c.degree + 1] + t * (c.knots[#c.points + 1] - c.knots[c.degree + 1])
	local report: RemovalReport =
		{ requested = requested, removed = 0, errorBound = 0, tolerance = tolerance }
	for _ = 1, requested do
		if options and options.checkpoint then
			options.checkpoint(report.removed / requested)
		end
		local candidates: { Curve }, a: { Vector3 }, aw: { number }, b: { Vector3 }, bw: { number } =
			{}, {}, {}, {}, {}
		for i, line in lines(s, axis) do
			local candidate, reason = removalCandidate(line, knot)
			if not candidate then
				report.reason = reason
				break
			end
			candidates[i] = candidate
			local reconstructed = insertOnce(candidate, t, knot)
			for j, point in line.points do
				table.insert(a, point)
				table.insert(aw, line.weights[j])
				table.insert(b, reconstructed.points[j])
				table.insert(bw, reconstructed.weights[j])
			end
		end
		if report.reason then
			break
		end
		local bound = controlError(a, aw, b, bw)
		if report.errorBound + bound > tolerance then
			report.rejectedErrorBound = bound
			report.reason = "Conservative surface error bound exceeds tolerance"
			break
		end
		s = fromLines(s, axis, candidates)
		report.errorBound += bound
		report.removed += 1
	end
	report.complete = report.removed == requested
	return s, report
end

function N.tessellate(
	surface: Surface,
	uSegments: number,
	vSegments: number,
	options: TessellateOptions?
): (Types.Mesh, TessellateReport)
	local options: TessellateOptions = options or {}
	local s = checkedSurface(surface)
	U.integer(uSegments, 1)
	U.integer(vSegments, 1)
	assert(
		(uSegments + 1) * (vSegments + 1) <= (options.maxVertices or 100000),
		"Tessellation vertex budget exceeded"
	)
	assert(not options.closedU or uSegments >= 3, "Closed U direction needs at least three segments")
	assert(not options.closedV or vSegments >= 3, "Closed V direction needs at least three segments")
	local tolerance = options.seamTolerance or 1e-6
	assert(U.finite(tolerance) and tolerance >= 0, "Finite nonnegative seam tolerance required")
	local poles: { [string]: boolean } = {}
	if options.collapsePoles then
		-- Rows mix names, axes and fractions: { pole, varying axis, fixed parameter }.
		for _, edge in
			{ { "U0", "V", 0 }, { "U1", "V", 1 }, { "V0", "U", 0 }, { "V1", "U", 1 } } :: { { any } }
		do
			local curve = N.isoCurve(s, edge[2], edge[3])
			local collapsed = true
			for _, p in curve.points do
				if (p - curve.points[1]).Magnitude > tolerance then
					collapsed = false
					break
				end
			end
			poles[edge[1]] = collapsed
		end
	end
	local records: { TessellateRecord }, parents: { number }, rows: { [number]: { [number]: number } } =
		{}, {}, {}
	for i = 0, uSegments do
		rows[i] = {}
		for j = 0, vSegments do
			local u, v = i / uSegments, j / vSegments
			local d = surfaceDerivatives(s, u, v)
			local p, normal = d.position, d.normal
			if not d.regular then
				local pu, pv = u, v
				if i == 0 and poles.U0 then
					pu = 1e-5
				elseif i == uSegments and poles.U1 then
					pu = 1 - 1e-5
				end
				if j == 0 and poles.V0 then
					pv = 1e-5
				elseif j == vSegments and poles.V1 then
					pv = 1 - 1e-5
				end
				assert(pu ~= u or pv ~= v, "Singular surface sample; subdivide or repair control net")
				local limit = surfaceDerivatives(s, pu, pv)
				assert(limit.regular, "Pole normal has no regular interior limit")
				normal = limit.normal
			end
			if options.map then
				p = options.map(p, Vector2.new(u, v), d)
				assert(U.vector(p))
			end
			local id = #records + 1
			rows[i][j] = id
			parents[id] = id
			records[id] = { position = p, normal = normal :: Vector3, uv = Vector2.new(u, v) }
		end
		if options.checkpoint then
			options.checkpoint(i / uSegments)
		end
	end
	local function root(id: number): number
		while parents[id] ~= id do
			parents[id] = parents[parents[id]]
			id = parents[id]
		end
		return id
	end
	local function merge(a: number, b: number)
		assert(
			(records[a].position - records[b].position).Magnitude <= tolerance,
			"Requested seam or pole positions do not coincide"
		)
		a, b = root(a), root(b)
		if a ~= b then
			parents[math.max(a, b)] = math.min(a, b)
		end
	end
	if options.closedU then
		for j = 0, vSegments do
			merge(rows[0][j], rows[uSegments][j])
		end
	end
	if options.closedV then
		for i = 0, uSegments do
			merge(rows[i][0], rows[i][vSegments])
		end
	end
	for _, i in { 0, uSegments } do
		if poles[i == 0 and "U0" or "U1"] then
			for j = 1, vSegments do
				merge(rows[i][0], rows[i][j])
			end
		end
	end
	for _, j in { 0, vSegments } do
		if poles[j == 0 and "V0" or "V1"] then
			for i = 1, uSegments do
				merge(rows[0][j], rows[i][j])
			end
		end
	end
	local mesh, vertexIds: { [number]: number } = Mesh.new(), {}
	for id, r in records do
		local representative = root(id)
		if not vertexIds[representative] then
			vertexIds[representative] = mesh:addVertex(records[representative].position)
		end
	end
	local report: TessellateReport = {
		poles = poles,
		collapsedQuads = 0,
		closedU = options.closedU == true,
		closedV = options.closedV == true,
	}
	local function mergedCorner(a: Types.Corner, b: Types.Corner): Types.Corner
		local normal = (a.normal :: Vector3) + (b.normal :: Vector3)
		return {
			uv = ((a.uv :: Vector2) + (b.uv :: Vector2)) * 0.5,
			normal = normal.Magnitude > 1e-12 and normal.Unit or a.normal,
		}
	end
	for i = 0, uSegments - 1 do
		for j = 0, vSegments - 1 do
			local vertices: { number }, corners: { Types.Corner } = {}, {}
			for _, id in { rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1] } do
				local vertex = vertexIds[root(id)]
				local r = records[id]
				local corner = { uv = r.uv, normal = r.normal }
				if vertices[#vertices] == vertex then
					corners[#corners] = mergedCorner(corners[#corners], corner)
				else
					table.insert(vertices, vertex)
					table.insert(corners, corner)
				end
			end
			if #vertices > 1 and vertices[1] == vertices[#vertices] then
				corners[1] = mergedCorner(corners[1], corners[#corners])
				table.remove(vertices)
				table.remove(corners)
			end
			if #vertices < 4 then
				report.collapsedQuads += 1
			end
			if #vertices >= 3 then
				mesh:addFace(vertices, corners, options.material)
			end
		end
	end
	assert(next(mesh.faces), "Surface tessellation collapsed to no faces")
	if options.map then
		mesh:recalculateNormals()
	end
	return mesh, report
end
return N
