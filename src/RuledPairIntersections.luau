-- Bounded exact contacts of two positive rational ruled surfaces.
local setup = require(script.Parent.ExactIntersectionSetup)
local powers = require(script.Parent.ExactRuledPairPowers)
local project = require(script.Parent.ExactConvexFiberProjection)
local decompose = require(script.Parent.ExactPlanarSignCells)
return function(surfaceA, surfaceB, options)
	local data = setup({ surfaceA, surfaceB }, options or {})
	local R, P, B, ctx = data.R, data.P, data.B, data.ctx
	options = data.options
	local U = require(script.Parent.Util)
	for _, name in
		{
			"maxPolynomials",
			"maxFiberPolynomials",
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
	ctx.maxDegree, ctx.maxPolynomials =
		options and options.maxPolynomialDegree or 96, options and options.maxPolynomials or 128
	local T = require(script.Parent.ExactBivariatePolynomial)(R, P, ctx)
	data.enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local first =
		powers(data.sources[1], options and options.linearAxisA, { data.bounds[1], data.bounds[2] }, data)
	local second =
		powers(data.sources[2], options and options.linearAxisB, { data.bounds[3], data.bounds[4] }, data)
	local zero, one = R.number(0), R.number(1)
	local spans, internals = {}, {}
	for i, a in first.spans do
		for j, b in second.spans do
			assert((i - 1) * #second.spans + j <= ctx.maxPieces, "Ruled pair span budget exceeded")
			local originals = { a, b }
			local domain = {}
			local active = true
			for axis, profile in { first.profileAxis, second.profileAxis + 2 } do
				local span = originals[axis]
				local lo = R.div(R.sub(data.bounds[profile][1], span.offset), span.scale)
				local hi = R.div(R.sub(data.bounds[profile][2], span.offset), span.scale)
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
			local equations = require(script.Parent.ExactRuledPairEquations)(a, b, R, P, T, ctx)
			local projection = project(equations, R, P, T, ctx, options)
			local cad =
				decompose(projection.sources, domain, R, P, B, data.isolation, ctx, options, projection.truth)
			local index = (i - 1) * #second.spans + j
			spans[index] = {
				index = index,
				indices = { i, j },
				offset = { a.offset, b.offset },
				scale = { a.scale, b.scale },
				sources = originals,
				equations = equations,
				projection = projection,
				cad = cad,
			}
			internals[index] = cad
			for _, component in cad.components do
				component.fullDimension = 0
			end
			for _, cell in cad.cells do
				cell.fullDimension = 0
				cell.fiberDimensionRange = { 2, 0 }
			end
			local function classify(lift, baseDimension)
				local function group(index)
					for _, c in lift.components do
						if c.first <= index and c.last >= index then
							return cad.cells[c.cell]
						end
					end
					error("Missing base component")
				end
				local function atom(k, p, dimension)
					if not p.feasible then
						return
					end
					local cell = group(k)
					local fiberDimension = projection.dimension(p.signs)
					p.fiberDimension, p.fullDimension = fiberDimension, dimension + fiberDimension
					p.cell = cell.index
					cell.fiberDimensionRange[1] = math.min(cell.fiberDimensionRange[1], fiberDimension)
					cell.fiberDimensionRange[2] = math.max(cell.fiberDimensionRange[2], fiberDimension)
					cell.fullDimension = math.max(cell.fullDimension, p.fullDimension)
					local c = cad.components[cell.component]
					c.fullDimension = math.max(c.fullDimension, p.fullDimension)
				end
				for k, p in lift.points do
					atom(k, p, baseDimension)
				end
				for k, p in lift.sectors do
					atom(k, p, baseDimension + 1)
				end
			end
			for _, event in cad.events do
				classify(event.lift, 0)
			end
			for _, slab in cad.slabs do
				classify(slab.lift, 1)
			end
		end
	end
	local function boundary(spanIndex, axis, side)
		local span = spans[spanIndex]
		local x = span.cad.domain[axis][side]
		local endpoints = span.sources[axis].endpoints
		local out = {}
		for coordinate = 1, 4 do
			local a, b = P.evaluate(endpoints[1][coordinate], x), P.evaluate(endpoints[2][coordinate], x)
			out[coordinate] = P.trim({ a, R.sub(b, a) })
		end
		return out
	end
	local gluing = require(script.Parent.ExactRuledBaseGluing)(data, spans, internals, boundary)
	local anchors = {}
	local sample = require(script.Parent.ExactRuledPairSample)
	for spanIndex, span in spans do
		local cad = span.cad
		span.anchorIndices = {}
		local function anchor(sRoot, lift, tRoot, atom)
			local signs = atom.signs
			atom.vertexIndices = {}
			for _, caseIndex in span.projection.vertices(signs) do
				assert(#anchors < data.limits.maxVertices, "Ruled pair anchor budget exceeded")
				local out =
					sample(span, sRoot, lift, tRoot, span.projection.cases[caseIndex], data, first, second)
				out.span, out.case = spanIndex, caseIndex
				out.boundaryMask = span.projection.pattern(caseIndex, signs)
				out.base = { s = sRoot, t = tRoot, lift = lift }
				table.insert(anchors, out)
				table.insert(span.anchorIndices, #anchors)
				table.insert(atom.vertexIndices, #anchors)
			end
		end
		local function fiber(sRoot, lift)
			for _, point in lift.points do
				if point.feasible then
					anchor(sRoot, lift, point.root, point)
				end
			end
			for _, sector in lift.sectors do
				if sector.feasible then
					local t = lift.constant(sector.sample)
					anchor(sRoot, lift, { low = t, high = t, exact = true, depth = 0 }, sector)
				end
			end
		end
		for _, event in cad.events do
			fiber(event.root, event.lift)
		end
		for _, slab in cad.slabs do
			fiber({ low = slab.sample, high = slab.sample, exact = true, depth = 0 }, slab.lift)
		end
	end
	local pairs = gluing.pairs
	local parameterVertices = require(script.Parent.ExactRuledPairVertexClasses)(
		data,
		spans,
		anchors,
		gluing.joins,
		nil,
		function()
			pairs += 1
			assert(
				pairs <= (data.options.maxConnectionPairs or 100000),
				"Ruled pair anchor pair budget exceeded"
			)
			ctx.visit(1)
		end,
		function()
			ctx.visit(1)
		end
	)
	local result = {
		data = data,
		spans = spans,
		internals = internals,
		first = first,
		second = second,
		gluing = gluing,
		anchors = anchors,
		parameterVertices = parameterVertices,
	}
	if data.options.identifyPeriodicSeams or data.options.requireQuotient then
		result.quotient = require(script.Parent.ExactRuledPairQuotient)(result)
	end
	return require(script.Parent.ExactRuledPairReport)(result)
end
