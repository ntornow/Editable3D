-- Complete closed-domain contact complex for a rational curve and a rank-two
-- affine patch. Exact algebraic endpoints and rational arcs are authoritative.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
return function(curve, surface, settings)
	assert(type(settings) == "table", "Exact plane query options required")
	local entries, active = 0, {}
	local maximum = U.integer(settings.maxSnapshotEntries or 4000000, 1)
	local function copy(value, depth)
		if type(value) ~= "table" then
			return value
		end
		assert(depth <= 64 and not active[value], "Spline snapshot has cyclic or excessively nested data")
		active[value] = true
		local out = {}
		for key, item in value do
			entries += 1
			assert(entries <= maximum, "Spline snapshot entry budget exceeded")
			out[key] = copy(item, depth + 1)
		end
		active[value] = nil
		return out
	end
	local options = copy(settings, 1)
	curve, surface = copy(curve, 1), copy(surface, 1)
	local function positive(value, default)
		value = value == nil and default or value
		assert(
			type(value) == "number" and U.finite(value) and value > 0,
			"Positive finite intersection tolerance required"
		)
		return value
	end
	local tolerance = positive(options.tolerance, 1e-5)
	local parameterTolerance = positive(options.parameterTolerance, 1e-7)
	local maxDepth = U.integer(options.maxDepth or 128, 0)
	local iterations = U.integer(options.maxIterations or 24, 0)
	assert(maxDepth <= 512 and iterations <= 128, "Exact plane refinement limit exceeded")
	local maxRoots = U.integer(options.maxRoots or 1024, 1)
	local maxWork = U.integer(options.maxWork or 50000000, 1)
	local maxCoefficients = U.integer(options.maxCoefficients or 1000000, 1)
	local maxDegree = U.integer(options.maxPolynomialDegree or 96, 1)
	assert(maxDegree <= 256, "Exact polynomial degree limit exceeds 256")
	for _, name in { "cancelled", "checkpoint" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Intersection callback must be a function"
		)
	end
	assert(
		options.requireComplete == nil or type(options.requireComplete) == "boolean",
		"Intersection completion flag must be boolean"
	)
	local initial = options.parameterBox or { { 0, 1 }, { 0, 1 }, { 0, 1 } }
	assert(type(initial) == "table" and #initial == 3, "Intersection parameterBox requires t/u/v ranges")
	for _, range in initial do
		assert(
			type(range) == "table"
				and #range == 2
				and type(range[1]) == "number"
				and type(range[2]) == "number"
				and U.finite(range[1])
				and U.finite(range[2])
				and range[1] >= 0
				and range[2] <= 1
				and range[1] < range[2],
			"Nonempty normalized intersection range required"
		)
		assert(
			I.isNormal(range[1]) and I.isNormal(range[2]),
			"Subnormal intersection parameter endpoints are unsupported"
		)
	end
	local report = {
		algorithm = "exactPlane",
		method = "Exact homogeneous powers, square-free Sturm isolation and closed polynomial sign cells",
		complete = false,
		roots = {},
		vertices = {},
		overlaps = {},
		components = {},
		unresolved = {},
		work = 0,
		visited = 0,
		excluded = 0,
		covered = 0,
		coefficientsAllocated = 0,
		coverageCertified = true,
		rootCoverageComplete = true,
		parameterTopologyCertified = true,
		parameterComponentsCertified = true,
		periodicQuotient = { requested = false },
		boundaryOwnership = "Closed t/u/v domain; shared knot vertices merged by exact normalized parameter",
		componentSpace = "Three-dimensional parameter domain, including t; no spatial or periodic identification",
		arcRepresentation = "Exact rational parameterizations restricted by algebraic endpoints; no polyline approximation",
	}
	report.parameterBox = initial
	local ctx = { maxPieces = U.integer(options.maxPieces or 2048, 1) }
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Spline intersection query cancelled")
		if options.checkpoint then
			options.checkpoint({
				stage = stage,
				work = report.work,
				visited = report.visited,
				roots = #report.roots,
			})
		end
	end
	ctx.visit = function(n)
		local before = report.work
		report.work += n or 1
		assert(report.work <= maxWork, "Spline intersection work budget exceeded")
		if math.floor(before / 256) ~= math.floor(report.work / 256) then
			ctx.check("work")
		end
	end
	ctx.allocate = function(n)
		report.coefficientsAllocated += n
		assert(
			report.coefficientsAllocated <= maxCoefficients,
			"Exact spline cumulative coefficient budget exceeded"
		)
	end
	ctx.check("begin")
	local maxControls = U.integer(options.maxControls or 10000, 1)
	assert(
		type(curve) == "table" and (curve.kind == "curve" or curve.kind == "cyclicCurve"),
		"Curve representation required"
	)
	assert(
		type(surface) == "table" and surface.kind == "surface",
		"Exact plane query requires a single affine surface patch"
	)
	curve.maxControls, surface.maxControls = maxControls, maxControls
	curve = curve.kind == "cyclicCurve" and C.toNURBS(C.curve(curve.points, curve.degree, curve))
		or N.curve(curve.points, curve.degree, curve)
	surface = N.surface(surface.control, surface.degreeU, surface.degreeV, surface)
	assert(
		surface.degreeU == 1 and surface.degreeV == 1 and #surface.control == 2 and #surface.control[1] == 2,
		"Exact plane query requires a degree-one 2x2 affine patch"
	)
	for _, row in surface.weights do
		for _, w in row do
			assert(w == surface.weights[1][1], "Exact plane patch requires constant weights")
		end
	end
	local R = require(script.Parent.ExactRational)(ctx.visit, U.integer(options.maxExactBits or 8192, 1))
	local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, maxDegree, ctx.allocate)
	local B = require(script.Parent.ExactPolynomialBounds)(R, P, ctx.visit)
	local enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local zero, one, two = R.number(0), R.number(1), R.number(2)
	local bounds = {}
	for axis, range in initial do
		bounds[axis] = { R.number(range[1]), R.number(range[2]) }
	end
	local origin, du, dv = {}, {}, {}
	for axis, name in { "X", "Y", "Z" } do
		local a, b, c, d =
			R.number(surface.control[1][1][name]),
			R.number(surface.control[2][1][name]),
			R.number(surface.control[1][2][name]),
			R.number(surface.control[2][2][name])
		assert(
			R.equal(R.add(a, d), R.add(b, c)),
			"Surface controls do not form an exact affine parallelogram"
		)
		origin[axis], du[axis], dv[axis] = a, R.sub(b, a), R.sub(c, a)
	end
	local normal = {
		R.sub(R.mul(du[2], dv[3]), R.mul(du[3], dv[2])),
		R.sub(R.mul(du[3], dv[1]), R.mul(du[1], dv[3])),
		R.sub(R.mul(du[1], dv[2]), R.mul(du[2], dv[1])),
	}
	local x, y, det
	for _, axes in { { 1, 2 }, { 1, 3 }, { 2, 3 } } do
		local a, b = axes[1], axes[2]
		local d = R.sub(R.mul(du[a], dv[b]), R.mul(du[b], dv[a]))
		if d.sign ~= 0 then
			x, y, det = a, b, d
			break
		end
	end
	assert(det, "Exact plane patch must have rank two")
	local spans = require(script.Parent.ExactCurvePower)(curve, R, P, ctx)
	report.curvePieces, report.surfacePieces = #spans, 1
	local isolation = {
		tolerance = R.number(parameterTolerance),
		maxDepth = maxDepth,
		maxNodes = U.integer(options.maxNodes or 10000, 1),
		nodes = 0,
	}
	local function subtract(a, b)
		return P.add(a, P.scale(b, R.number(-1)))
	end
	local function floatRange(range)
		return { enclose(range[1])[1], enclose(range[2])[2] }
	end
	local function globalParameter(span, value)
		return R.add(span.offset, R.mul(span.scale, value))
	end
	local allAccurate = true
	local lastVertex
	for spanIndex, span in spans do
		ctx.check("span")
		local lo = R.div(R.sub(bounds[1][1], span.offset), span.scale)
		local hi = R.div(R.sub(bounds[1][2], span.offset), span.scale)
		if R.compare(lo, zero) < 0 then
			lo = zero
		end
		if R.compare(hi, one) > 0 then
			hi = one
		end
		if R.compare(lo, hi) >= 0 then
			continue
		end
		local h, delta = span.h, {}
		for axis = 1, 3 do
			delta[axis] = subtract(h[axis], P.scale(h[4], origin[axis]))
		end
		local plane = {}
		for axis = 1, 3 do
			plane = P.add(plane, P.scale(delta[axis], normal[axis]))
		end
		local u = P.scale(subtract(P.scale(delta[x], dv[y]), P.scale(delta[y], dv[x])), R.div(one, det))
		local v = P.scale(subtract(P.scale(delta[y], du[x]), P.scale(delta[x], du[y])), R.div(one, det))
		local polynomials = {
			plane,
			subtract(u, P.scale(h[4], bounds[2][1])),
			subtract(P.scale(h[4], bounds[2][2]), u),
			subtract(v, P.scale(h[4], bounds[3][1])),
			subtract(P.scale(h[4], bounds[3][2]), v),
		}
		local analyses = { P.analyze(plane) }
		local union = plane
		if analyses[1].identity then
			union = { one }
			for i = 2, 5 do
				local p = polynomials[i]
				-- Positive weights prove that their nonzero constant multiples
				-- have no roots on this span, without factoring the weight.
				if #p > 1 and #p == #h[4] then
					local q, remainder = P.divide(p, h[4])
					if #remainder == 0 and #q == 1 then
						analyses[i] = {
							polynomial = p,
							identity = false,
							squarefree = { one },
							sequence = { { one } },
							factors = {},
						}
					end
				end
				analyses[i] = analyses[i] or P.analyze(p)
				local factor = analyses[i].squarefree
				if #factor > 1 and (P.count(analyses[i], lo, hi) > 0 or P.evaluate(factor, lo).sign == 0) then
					union = P.product(union, P.quotient(factor, P.gcd(union, factor)))
				end
			end
		end
		-- Coplanar spans require the complete boundary sign arrangement.
		-- Otherwise only roots of the plane equation can be contacts.
		local isolated = P.isolate(union, lo, hi, isolation)
		assert(#isolated.roots <= maxRoots, "Exact plane critical root budget exceeded")
		local nodes = isolated.roots
		if #nodes == 0 or not (nodes[1].exact and R.equal(nodes[1].low, lo)) then
			table.insert(nodes, 1, { low = lo, high = lo, exact = true, depth = 0 })
		end
		if not (nodes[#nodes].exact and R.equal(nodes[#nodes].high, hi)) then
			table.insert(nodes, { low = hi, high = hi, exact = true, depth = 0 })
		end
		for _, root in nodes do
			root.analysis = isolated.analysis
		end
		require(script.Parent.ExactRootSeparation)(nodes, R, P, isolation)
		local commonFactors = {}
		local function signsAt(root)
			local signs, order = {}, 0
			if analyses[1].identity then
				for i, analysis in analyses do
					signs[i] = P.atRoot(analysis, root)
				end
				return signs, 0
			end
			signs[1], order = P.atRoot(analyses[1], root)
			for i = 2, 5 do
				local p = polynomials[i]
				while true do
					if root.exact then
						signs[i] = P.evaluate(p, root.low).sign
						break
					end
					local range = B.evaluate(p, { root.low, root.high })
					if range[1].sign > 0 then
						signs[i] = 1
						break
					end
					if range[2].sign < 0 then
						signs[i] = -1
						break
					end
					if #p == 0 then
						signs[i] = 0
						break
					end
					-- An exact common factor decides vanishing at an algebraic
					-- root. A nonzero value eventually gets a strict range sign.
					if not commonFactors[i] then
						commonFactors[i] = P.analyze(P.gcd(analyses[1].squarefree, p))
					end
					if P.count(commonFactors[i], root.low, root.high) == 1 then
						signs[i] = 0
						break
					end
					P.refine(isolated.analysis, root, isolation)
				end
			end
			return signs, order
		end
		local function feasible(signs)
			if signs[1] ~= 0 then
				return false
			end
			for i = 2, 5 do
				if signs[i] < 0 then
					return false
				end
			end
			return true
		end
		local function pointData(root, signs)
			local localBox = { root.low, root.high }
			local weight = B.intersect(B.evaluate(h[4], localBox), span.weightBounds)
			local exactRanges = {}
			for axis = 1, 3 do
				exactRanges[axis] = B.divide(B.evaluate(h[axis], localBox), weight)
			end
			local parameterRanges = {
				{ globalParameter(span, root.low), globalParameter(span, root.high) },
				B.divide(B.evaluate(u, localBox), weight),
				B.divide(B.evaluate(v, localBox), weight),
			}
			for axis = 2, 3 do
				if signs[axis * 2 - 2] == 0 then
					parameterRanges[axis] = { bounds[axis][1], bounds[axis][1] }
				elseif signs[axis * 2 - 1] == 0 then
					parameterRanges[axis] = { bounds[axis][2], bounds[axis][2] }
				end
			end
			local out = { positionBox = {}, parameterBox = {}, parameters = {}, parameterErrorBound = 0 }
			for axis, range in parameterRanges do
				local box = floatRange(B.intersect(range, bounds[axis]))
				box = assert(I.intersect(box, initial[axis]))
				out.parameterBox[axis], out.parameters[axis] = box, I.mid(box)
				local d = I.sub(box, { I.mid(box), I.mid(box) })
				out.parameterErrorBound = math.max(out.parameterErrorBound, math.abs(d[1]), math.abs(d[2]))
			end
			local coordinates = {}
			for axis, range in exactRanges do
				out.positionBox[axis] = floatRange(range)
				coordinates[axis] = I.mid(out.positionBox[axis])
			end
			out.position = Vector3.new(table.unpack(coordinates))
			assert(U.vector(out.position), "Exact plane native position is not finite")
			local square = { 0, 0 }
			for axis, name in { "X", "Y", "Z" } do
				square = I.add(
					square,
					I.square(I.sub(out.positionBox[axis], { out.position[name], out.position[name] }))
				)
			end
			-- The sum is mathematically nonnegative even if outward addition
			-- widened a zero lower endpoint below zero.
			square[1] = math.max(0, square[1])
			out.errorBound = I.sqrt(square)[2]
			out.accurate = out.errorBound <= tolerance and out.parameterErrorBound <= parameterTolerance
			out.parameter = { t = out.parameters[1], u = out.parameters[2], v = out.parameters[3] }
			out.curveParameter, out.u, out.v = out.parameters[1], out.parameters[2], out.parameters[3]
			if root.exact then
				out.positionExact = { exactRanges[1][1], exactRanges[2][1], exactRanges[3][1] }
				out.parametersExact = { parameterRanges[1][1], parameterRanges[2][1], parameterRanges[3][1] }
			end
			return out
		end
		for _, root in nodes do
			local signs, order = signsAt(root)
			if not feasible(signs) then
				report.excluded += 1
				continue
			end
			local data = pointData(root, signs)
			for _ = 1, iterations do
				if data.accurate or root.exact or root.depth >= maxDepth then
					break
				end
				P.refine(isolated.analysis, root, isolation)
				data = pointData(root, signs)
			end
			allAccurate = allAccurate and data.accurate
			local contact = {
				span = spanIndex,
				knotSpan = span.index,
				planeIdentity = analyses[1].identity,
				order = order,
			}
			if
				root.exact
				and lastVertex
				and lastVertex.parametersExact
				and R.equal(data.parametersExact[1], lastVertex.parametersExact[1])
			then
				for axis = 1, 3 do
					assert(
						R.equal(data.positionExact[axis], lastVertex.positionExact[axis]),
						"Shared knot contact is discontinuous"
					)
				end
				table.insert(lastVertex.contacts, contact)
				root.vertex = lastVertex.index
			else
				assert(#report.vertices < maxRoots, "Exact plane vertex budget exceeded")
				data.index = #report.vertices + 1
				data.certified, data.unique, data.contacts = true, true, { contact }
				data.algebraic = {
					polynomial = isolated.analysis.squarefree,
					low = root.low,
					high = root.high,
					exact = root.exact,
					offset = span.offset,
					scale = span.scale,
				}
				data.activeBounds = {}
				for i = 2, 5 do
					if signs[i] == 0 then
						table.insert(data.activeBounds, ({ "uMin", "uMax", "vMin", "vMax" })[i - 1])
					end
				end
				data.edgeIndices = {}
				table.insert(report.vertices, data)
				lastVertex = data
				root.vertex = data.index
			end
		end
		if analyses[1].identity then
			for i = 1, #nodes - 1 do
				local a, b = nodes[i], nodes[i + 1]
				local sample = R.div(R.add(a.high, b.low), two)
				local signs = {}
				for j, p in polynomials do
					signs[j] = P.evaluate(p, sample).sign
				end
				if feasible(signs) then
					assert(a.vertex and b.vertex, "Closed feasible arc has missing endpoint")
					local edge = {
						index = #report.overlaps + 1,
						first = a.vertex,
						last = b.vertex,
						span = spanIndex,
						knotSpan = span.index,
						certified = true,
						parameterDimension = 1,
						homogeneousExact = h,
						surfaceParametersExact = { u, v, h[4] },
						parameterMap = { offset = span.offset, scale = span.scale },
						localEndpoints = {
							{ low = a.low, high = a.high, exact = a.exact },
							{ low = b.low, high = b.high, exact = b.exact },
						},
						endpointPolynomial = isolated.analysis.squarefree,
					}
					table.insert(report.overlaps, edge)
					table.insert(report.vertices[a.vertex].edgeIndices, edge.index)
					table.insert(report.vertices[b.vertex].edgeIndices, edge.index)
				else
					report.excluded += 1
				end
			end
		end
	end
	local owners = {}
	local function owner(i)
		while owners[i] ~= i do
			i = owners[i]
		end
		return i
	end
	for i in report.vertices do
		owners[i] = i
	end
	for _, edge in report.overlaps do
		owners[owner(edge.last)] = owner(edge.first)
	end
	local groups = {}
	for i, vertex in report.vertices do
		local id = owner(i)
		if not groups[id] then
			groups[id] = {
				vertexIndices = {},
				overlapIndices = {},
				certified = true,
				connected = true,
				parameterDimension = 0,
			}
			table.insert(report.components, groups[id])
		end
		table.insert(groups[id].vertexIndices, i)
		if #vertex.edgeIndices == 0 then
			vertex.isolated = true
			vertex.classification = "isolated"
			table.insert(report.roots, vertex)
		else
			vertex.isolated = false
			vertex.classification = "overlapVertex"
		end
	end
	for i, edge in report.overlaps do
		local group = groups[owner(edge.first)]
		table.insert(group.overlapIndices, i)
		group.parameterDimension = 1
	end
	report.componentCount = #report.components
	report.visited = isolation.nodes
	report.covered = #report.vertices + #report.overlaps
	report.complete, report.success, report.converged = allAccurate, allAccurate, allAccurate
	report.reason = allAccurate and "complete" or "approximation"
	ctx.check("finish")
	assert(not options.cancelled or not options.cancelled(), "Spline intersection query cancelled")
	assert(
		report.complete or not options.requireComplete,
		"Exact plane native endpoint approximation exceeds tolerance"
	)
	return report
end
