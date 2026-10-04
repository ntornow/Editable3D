-- Complete bounded exact tensor/affine-plane contacts across original knot spans.
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local U = require(script.Parent.Util)
local setup = require(script.Parent.ExactIntersectionSetup)
local extract = require(script.Parent.ExactSurfacePower)
local decompose = require(script.Parent.ExactPlanarSignCells)
local sample = require(script.Parent.ExactTensorContactSample)
return function(surfaceA, surfaceB, settings)
	local data = setup({ surfaceA, surfaceB }, settings or {})
	local R, P, B, ctx, report = data.R, data.P, data.B, data.ctx, data.report
	local options, limits = data.options, data.limits
	ctx.maxDegree = U.integer(options.maxPolynomialDegree or 96, 1)
	ctx.maxPolynomials = U.integer(options.maxPolynomials or 64, 1)
	for _, name in
		{
			"maxMatrixEntries",
			"maxLiftedRoots",
			"maxConnections",
			"maxConnectionPairs",
			"maxSeamNodes",
			"maxSeamPairs",
		}
	do
		if options[name] ~= nil then
			U.integer(options[name], 0)
		end
	end
	local a, b = data.sources[1], data.sources[2]
	assert(
		type(a) == "table" and (a.kind == "surface" or a.kind == "cyclicSurface"),
		"Tensor first surface required"
	)
	assert(type(b) == "table" and b.kind == "surface", "Ordinary affine second surface required")
	a.maxControls, b.maxControls = limits.maxControls, limits.maxControls
	a = a.kind == "cyclicSurface" and C.surfaceToNURBS(C.surface(a.control, a.degreeU, a.degreeV, a))
		or N.surface(a.control, a.degreeU, a.degreeV, a)
	b = N.surface(b.control, b.degreeU, b.degreeV, b)
	local forms = require(script.Parent.ExactAffineForms)(b, R)
	data.enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local T = require(script.Parent.ExactBivariatePolynomial)(R, P, ctx)
	local zero, one, minus = R.number(0), R.number(1), R.number(-1)
	local function add(a, b)
		local out = {}
		ctx.allocate(math.max(#a, #b))
		for i = 1, math.max(#a, #b) do
			out[i] = P.add(a[i] or {}, b[i] or {})
		end
		return T.trim(out)
	end
	local function scale(a, k)
		local out = {}
		ctx.allocate(#a)
		for i, c in a do
			out[i] = P.scale(c, k)
		end
		return T.trim(out)
	end
	local function form(h, coefficients)
		local out = {}
		for axis = 1, 4 do
			out = add(out, scale(h[axis], coefficients[axis]))
		end
		return out
	end
	report.algorithm = "exactTensorPlane"
	report.spans, report.events, report.cells, report.vertices, report.components = {}, {}, {}, {}, {}
	local internals = {}
	for spanIndex, span in extract(a, R, P, ctx) do
		local domain = {}
		local active = true
		for axis = 1, 2 do
			local lo = R.div(R.sub(data.bounds[axis][1], span.offset[axis]), span.scale[axis])
			local hi = R.div(R.sub(data.bounds[axis][2], span.offset[axis]), span.scale[axis])
			if R.compare(lo, zero) < 0 then
				lo = zero
			end
			if R.compare(hi, one) > 0 then
				hi = one
			end
			if R.compare(lo, hi) >= 0 then
				active = false
				break
			end
			domain[axis] = { lo, hi }
		end
		if not active then
			continue
		end
		ctx.check("tensorSpan")
		span.u, span.v = form(span.h, forms.u), form(span.h, forms.v)
		local constraints = { { p = form(span.h, forms.plane), relation = "eq" } }
		local function controlRange(coefficients)
			local low, high
			for i = span.knotSpans[1] - a.degreeU, span.knotSpans[1] do
				for j = span.knotSpans[2] - a.degreeV, span.knotSpans[2] do
					local value = coefficients[4]
					for axis, name in { "X", "Y", "Z" } do
						value = R.add(value, R.mul(coefficients[axis], R.number(a.control[i][j][name])))
					end
					if not low or R.compare(value, low) < 0 then
						low = value
					end
					if not high or R.compare(value, high) > 0 then
						high = value
					end
				end
			end
			return { low, high }
		end
		span.controlBounds = { plane = controlRange(forms.plane), inequalities = {} }
		local impossible = span.controlBounds.plane[1].sign > 0 or span.controlBounds.plane[2].sign < 0
		for axis, coordinate in { [3] = span.u, [4] = span.v } do
			local coefficients = axis == 3 and forms.u or forms.v
			local lower = table.clone(coefficients)
			lower[4] = R.sub(lower[4], data.bounds[axis][1])
			local upper = {}
			for i, c in coefficients do
				upper[i] = R.neg(c)
			end
			upper[4] = R.add(upper[4], data.bounds[axis][2])
			local lo, hi = controlRange(lower), controlRange(upper)
			table.insert(span.controlBounds.inequalities, lo)
			table.insert(span.controlBounds.inequalities, hi)
			impossible = impossible or lo[2].sign < 0 or hi[2].sign < 0
			if lo[1].sign < 0 then
				table.insert(
					constraints,
					{ p = add(coordinate, scale(span.h[4], R.neg(data.bounds[axis][1]))), relation = "ge" }
				)
			end
			if hi[1].sign < 0 then
				table.insert(constraints, {
					p = add(scale(span.h[4], data.bounds[axis][2]), scale(coordinate, minus)),
					relation = "ge",
				})
			end
		end
		if impossible then
			constraints = { { p = { { minus } }, relation = "ge" } }
		end
		local cad = decompose(constraints, domain, R, P, B, data.isolation, ctx, options)
		internals[spanIndex] = cad
		span.cad = cad
		span.anchors = {}
		report.spans[spanIndex] = span
		for eventIndex, event in cad.events do
			for index, point in event.lift.points do
				if point.feasible then
					assert(
						#report.vertices < limits.maxVertices,
						"Exact tensor vertex allocation budget exceeded"
					)
					local out = sample(span, event, point, data)
					table.insert(report.vertices, out)
					table.insert(
						span.anchors,
						{ event = eventIndex, point = index, vertex = #report.vertices }
					)
				end
			end
		end
		for _, cell in cad.cells do
			table.insert(report.cells, cell)
		end
		for _, component in cad.components do
			table.insert(report.components, component)
		end
	end
	local gluing = require(script.Parent.ExactTensorSpanGluing)(data, report.spans, internals)
	report.components = gluing.components
	report.gluing = gluing
	local pairs = gluing.pairs
	report.parameterVertices = require(script.Parent.ExactTensorVertexClasses)(
		data,
		report.spans,
		internals,
		gluing.joins,
		nil,
		function()
			pairs += 1
			assert(
				pairs <= (options.maxConnectionPairs or 100000),
				"Tensor anchor comparison budget exceeded"
			)
			ctx.visit(1)
		end,
		function()
			ctx.visit(1)
		end
	)
	if options.identifyPeriodicSeams or options.requireQuotient then
		report.periodicQuotient = require(script.Parent.ExactTensorPeriodicQuotient)(
			data,
			report.spans,
			internals,
			gluing,
			report.parameterVertices
		)
	end
	local quotient = (options.identifyPeriodicSeams or options.requireQuotient) and report.periodicQuotient
		or nil
	report = require(script.Parent.ExactTensorContactReport)(
		data,
		report.spans,
		internals,
		gluing,
		report.parameterVertices,
		quotient
	)
	report.gluing, report.parameterVertices = nil, nil
	return report
end
