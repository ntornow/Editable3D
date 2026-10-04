-- Exact closed-domain contacts for a rational ruled surface and an affine patch.
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local setup = require(script.Parent.ExactIntersectionSetup)
local extract = require(script.Parent.ExactCurvePower)
local decompose = require(script.Parent.ExactLinearFiberCAD)
local sample = require(script.Parent.ExactRuledContactSample)
return function(surfaceA, surfaceB, settings)
	local data = setup({ surfaceA, surfaceB }, settings)
	local R, P, B, ctx, report = data.R, data.P, data.B, data.ctx, data.report
	local options, limits, bounds = data.options, data.limits, data.bounds
	local a, b = data.sources[1], data.sources[2]
	assert(
		type(a) == "table" and (a.kind == "surface" or a.kind == "cyclicSurface"),
		"Ruled first surface required"
	)
	assert(type(b) == "table" and b.kind == "surface", "Ordinary affine second surface required")
	a.maxControls, b.maxControls = limits.maxControls, limits.maxControls
	a = a.kind == "cyclicSurface" and C.surfaceToNURBS(C.surface(a.control, a.degreeU, a.degreeV, a))
		or N.surface(a.control, a.degreeU, a.degreeV, a)
	b = N.surface(b.control, b.degreeU, b.degreeV, b)
	local eligibleU = a.degreeU == 1 and #a.control == 2
	local eligibleV = a.degreeV == 1 and #a.control[1] == 2
	assert(
		options.linearAxis == nil or options.linearAxis == "U" or options.linearAxis == "V",
		"linearAxis must be U or V"
	)
	local linearAxis = options.linearAxis and (options.linearAxis == "U" and 1 or 2) or (eligibleV and 2 or 1)
	assert(
		linearAxis == 1 and eligibleU or linearAxis == 2 and eligibleV,
		"First surface needs one degree-one direction with exactly two controls"
	)
	local profileAxis = 3 - linearAxis
	report.linearAxis, report.profileAxis = linearAxis, profileAxis
	local forms = require(script.Parent.ExactAffineForms)(b, R)
	data.enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local zero, one, minus = R.number(0), R.number(1), R.number(-1)
	local function subtract(x, y)
		return P.add(x, P.scale(y, minus))
	end
	local function form(h, coefficients)
		local out = {}
		for axis = 1, 4 do
			out = P.add(out, P.scale(h[axis], coefficients[axis]))
		end
		return out
	end
	local sides = {}
	for side = 1, 2 do
		local points, weights = {}, {}
		local count = profileAxis == 1 and #a.control or #a.control[1]
		for i = 1, count do
			local u, v = profileAxis == 1 and i or side, profileAxis == 1 and side or i
			points[i], weights[i] = a.control[u][v], a.weights[u][v]
		end
		local c = N.curve(points, profileAxis == 1 and a.degreeU or a.degreeV, {
			weights = weights,
			knots = profileAxis == 1 and a.knotsU or a.knotsV,
			clamped = if profileAxis == 1 then a.clampedU else a.clampedV,
			maxControls = limits.maxControls,
		})
		sides[side] = extract(c, R, P, ctx)
	end
	assert(#sides[1] == #sides[2], "Ruled side span mismatch")
	report.spans, report.events = {}, {}
	report.curvePieces, report.surfacePieces = #sides[1], 1
	local verticesByEvent, previousEvent = {}, nil
	local allAccurate = true
	local function addCell(cell)
		assert(#report.cells < limits.maxCells, "Exact intersection cell budget exceeded")
		cell.index = #report.cells + 1
		cell.certified = true
		table.insert(report.cells, cell)
		ctx.visit(1)
		return cell.index
	end
	local function encode(root, span)
		return {
			polynomial = root.analysis and root.analysis.squarefree or {},
			low = root.low,
			high = root.high,
			exact = root.exact,
			offset = span.offset,
			scale = span.scale,
		}
	end
	local function globalValue(span, x)
		return R.add(span.offset, R.mul(span.scale, x))
	end
	for spanIndex, first in sides[1] do
		ctx.check("span")
		local second = sides[2][spanIndex]
		assert(
			R.equal(first.offset, second.offset) and R.equal(first.scale, second.scale),
			"Ruled span maps differ"
		)
		local lo = R.div(R.sub(bounds[profileAxis][1], first.offset), first.scale)
		local hi = R.div(R.sub(bounds[profileAxis][2], first.offset), first.scale)
		if R.compare(lo, zero) < 0 then
			lo = zero
		end
		if R.compare(hi, one) > 0 then
			hi = one
		end
		if R.compare(lo, hi) >= 0 then
			continue
		end
		local span = {
			index = spanIndex,
			knotSpan = first.index,
			a = first.h,
			b = {},
			offset = first.offset,
			scale = first.scale,
		}
		for axis = 1, 4 do
			span.b[axis] = subtract(second.h[axis], first.h[axis])
		end
		span.weightBounds = {
			R.compare(first.weightBounds[1], second.weightBounds[1]) < 0 and first.weightBounds[1]
				or second.weightBounds[1],
			R.compare(first.weightBounds[2], second.weightBounds[2]) > 0 and first.weightBounds[2]
				or second.weightBounds[2],
		}
		span.u, span.v =
			{ form(span.a, forms.u), form(span.b, forms.u) }, { form(span.a, forms.v), form(span.b, forms.v) }
		local f, g = form(span.a, forms.plane), form(span.b, forms.plane)
		span.planeIdentity = #f == 0 and #g == 0
		local inequalities = {
			{ a = f, b = g, label = "planePositive" },
			{ a = P.scale(f, minus), b = P.scale(g, minus), label = "planeNegative" },
		}
		for axis, coordinate in { [3] = span.u, [4] = span.v } do
			table.insert(inequalities, {
				a = subtract(coordinate[1], P.scale(span.a[4], bounds[axis][1])),
				b = subtract(coordinate[2], P.scale(span.b[4], bounds[axis][1])),
				label = axis == 3 and "uBMin" or "vBMin",
			})
			table.insert(inequalities, {
				a = subtract(P.scale(span.a[4], bounds[axis][2]), coordinate[1]),
				b = subtract(P.scale(span.b[4], bounds[axis][2]), coordinate[2]),
				label = axis == 3 and "uBMax" or "vBMax",
			})
		end
		local cells =
			decompose(inequalities, { { lo, hi }, bounds[linearAxis] }, R, P, B, data.isolation, ctx)
		span.constraints = cells.constraints
		report.spans[spanIndex] = span
		local function vertex(event, value)
			local global = event.global
			local cache = verticesByEvent[global.index]
			local exact = event.root.exact and event.field.exact(value) or nil
			for _, entry in cache do
				if exact then
					local other = entry.exact or entry.field.exact(entry.value)
					if R.equal(exact, other) then
						return entry.index
					end
				elseif event.field.compare(value, entry.value) == 0 then
					return entry.index
				end
			end
			assert(#report.vertices < limits.maxVertices, "Exact intersection vertex budget exceeded")
			local out = sample(span, event.field, value, data, linearAxis)
			allAccurate = allAccurate and out.accurate
			out.index = #report.vertices + 1
			out.event = global.index
			out.algebraic = { profile = encode(event.root, span), linear = value, span = spanIndex }
			table.insert(report.vertices, out)
			table.insert(cache, {
				index = out.index,
				value = value,
				field = event.field,
				exact = event.root.exact and event.field.exact(value) or nil,
			})
			return out.index
		end
		for i, event in cells.events do
			local normalized = event.root.exact and globalValue(span, event.root.low) or nil
			local merge = i == 1
				and normalized
				and previousEvent
				and previousEvent.parameterExact
				and R.equal(normalized, previousEvent.parameterExact)
			local global
			if merge then
				global = previousEvent
				assert((event.fiber ~= nil) == global.feasible, "Shared knot fiber feasibility differs")
				if event.fiber then
					assert(
						R.equal(event.field.exact(event.fiber.low), global.linearBoundsExact[1])
							and R.equal(event.field.exact(event.fiber.high), global.linearBoundsExact[2]),
						"Shared knot fiber bounds differ"
					)
				end
				-- Homogeneous continuity verifies the entire shared ruling, not just anchors.
				for axis = 1, 4 do
					assert(
						R.equal(P.evaluate(span.a[axis], event.root.low), global.homogeneousExact[1][axis])
							and R.equal(
								P.evaluate(span.b[axis], event.root.low),
								global.homogeneousExact[2][axis]
							),
						"Shared knot homogeneous ruling is discontinuous"
					)
				end
				table.insert(global.spans, spanIndex)
			else
				assert(#report.events < ctx.maxEvents, "Exact intersection total event budget exceeded")
				global = {
					index = #report.events + 1,
					profile = encode(event.root, span),
					parameterExact = normalized,
					feasible = event.fiber ~= nil,
					spans = { spanIndex },
				}
				if normalized then
					global.homogeneousExact = { {}, {} }
					for axis = 1, 4 do
						global.homogeneousExact[1][axis] = P.evaluate(span.a[axis], event.root.low)
						global.homogeneousExact[2][axis] = P.evaluate(span.b[axis], event.root.low)
					end
					if event.fiber then
						global.linearBoundsExact =
							{ event.field.exact(event.fiber.low), event.field.exact(event.fiber.high) }
					end
				end
				table.insert(report.events, global)
				verticesByEvent[global.index] = {}
			end
			event.global = global
			previousEvent = global
			if event.fiber and not global.cell then
				local firstVertex, lastVertex =
					vertex(event, event.fiber.low), vertex(event, event.fiber.high)
				global.cell = addCell({
					kind = "fiber",
					parameterDimension = event.fiber.dimension,
					span = spanIndex,
					event = global.index,
					profile = encode(event.root, span),
					linearBounds = { event.fiber.low, event.fiber.high },
					first = firstVertex,
					last = lastVertex,
					rulingInPlane = event.field.sign(f) == 0 and event.field.sign(g) == 0,
				})
			elseif not event.fiber then
				report.excluded += 1
			end
		end
		for _, slab in cells.slabs do
			assert(
				slab.dimension == 1 or span.planeIdentity,
				"Noncoplanar span has a two-dimensional contact band"
			)
			local firstEvent, lastEvent = cells.events[slab.first], cells.events[slab.last]
			local boundaryVertices = {}
			for side, event in { firstEvent, lastEvent } do
				boundaryVertices[side] = { vertex(event, slab.low), vertex(event, slab.high) }
			end
			local id = addCell({
				kind = slab.dimension == 1 and "graph" or "band",
				parameterDimension = slab.dimension,
				span = spanIndex,
				firstEvent = firstEvent.global.index,
				lastEvent = lastEvent.global.index,
				profileEndpoints = { encode(firstEvent.root, span), encode(lastEvent.root, span) },
				profileOpen = true,
				linearBounds = { slab.low, slab.high },
				boundaryVertices = boundaryVertices,
				lowConstraint = slab.lowConstraint,
				highConstraint = slab.highConstraint,
			})
			for side, event in { firstEvent, lastEvent } do
				table.insert(report.connections, {
					firstCell = id,
					secondCell = event.global.cell,
					side = side,
					firstVertex = boundaryVertices[side][1],
					lastVertex = boundaryVertices[side][2],
					certified = true,
					proof = "The complete finite rational slab limit is contained in this closed event fiber",
				})
			end
		end
	end
	local owners = {}
	for i in report.cells do
		owners[i] = i
	end
	local function owner(i)
		while owners[i] ~= i do
			i = owners[i]
		end
		return i
	end
	for _, connection in report.connections do
		owners[owner(connection.firstCell)] = owner(connection.secondCell)
	end
	local groups = {}
	for i, cell in report.cells do
		local root = owner(i)
		if not groups[root] then
			groups[root] = {
				index = #report.components + 1,
				cellIndices = {},
				connectionIndices = {},
				parameterDimension = 0,
				connected = true,
				certified = true,
			}
			table.insert(report.components, groups[root])
		end
		local group = groups[root]
		cell.component = group.index
		table.insert(group.cellIndices, i)
		group.parameterDimension = math.max(group.parameterDimension, cell.parameterDimension)
	end
	for i, connection in report.connections do
		table.insert(groups[owner(connection.firstCell)].connectionIndices, i)
	end
	report.componentCount = #report.components
	report.covered = #report.cells
	report.visited = data.isolation.nodes
	report.complete, report.success, report.converged = allAccurate, allAccurate, allAccurate
	report.reason = allAccurate and "complete" or "approximation"
	if options.identifyPeriodicSeams or options.requireQuotient then
		require(script.Parent.RuledPeriodicQuotient)(data)
	else
		report.quotientTopologyCertified, report.quotientComplete = false, false
	end
	ctx.check("finish")
	assert(not options.cancelled or not options.cancelled(), "Surface intersection query cancelled")
	assert(
		report.complete or not options.requireComplete,
		"Exact ruled native anchor approximation exceeds tolerance"
	)
	assert(
		not options.requireQuotient or report.quotientComplete,
		"Exact ruled periodic quotient incomplete: " .. tostring(report.periodicQuotient.reason)
	)
	return report
end
