-- Internal original-span preparation for arbitrary positive tensor pairs.
local N = require(script.Parent.NURBS)
local U = require(script.Parent.Util)
local C = require(script.Parent.Cyclic)
local setup = require(script.Parent.ExactIntersectionSetup)
local extract = require(script.Parent.ExactSurfacePower)
return function(surfaceA, surfaceB, settings)
	local data = setup({ surfaceA, surfaceB }, settings or {})
	local R, P, ctx, options = data.R, data.P, data.ctx, data.options
	ctx.maxDegree = U.integer(options.maxPolynomialDegree or 96, 1)
	ctx.isolation = data.isolation
	assert(
		options.cadProjection == nil or options.cadProjection == "guarded" or options.cadProjection == "full",
		"CAD projection must be guarded or full"
	)
	for _, name in
		{
			"projection",
			"quantifiers",
			"requiredZero",
			"fixedTarget",
			"trace",
			"nullificationFailure",
			"diagnosticErrors",
		}
	do
		assert(options[name] == nil, "Private CAD option is not a public query setting: " .. name)
	end
	options.projection = options.cadProjection == "full" and "collins" or nil
	for _, name in
		{
			"maxGeneralPolynomials",
			"maxPolynomials",
			"maxProjectionPolynomials",
			"maxProjectionCandidates",
			"maxGcdCache",
			"maxEquationPasses",
			"maxEquationRewrites",
			"maxMatrixEntries",
			"maxLiftedRoots",
			"maxComponentPairs",
			"maxSeamNodes",
			"maxSeamPairs",
		}
	do
		if options[name] ~= nil then
			U.integer(options[name], 1)
		end
	end
	data.report.coverageCertified = false
	data.report.parameterComponentsCertified = false
	local M = require(script.Parent.ExactSparsePolynomial)(R, 4, ctx)
	local order = options.parameterOrder or { 1, 2, 3, 4 }
	local inverse = {}
	assert(type(order) == "table" and #order == 4, "Four parameter-order axes required")
	for i, axis in order do
		assert(
			type(axis) == "number" and axis % 1 == 0 and axis >= 1 and axis <= 4 and not inverse[axis],
			"Parameter order must be a permutation"
		)
		inverse[axis] = i
	end
	local polynomials, keys = {}, {}
	local function reference(p)
		if #p == 0 then
			return { constant = 0 }
		end
		local normalized, scale = M.normalize(p)
		local constant = #normalized == 1
		if constant then
			for _, n in normalized[1].powers do
				if n ~= 0 then
					constant = false
					break
				end
			end
		end
		if constant then
			return { constant = scale.sign }
		end
		local key = M.key(normalized)
		local index = keys[key]
		if not index then
			assert(
				#polynomials < (options.maxGeneralPolynomials or 1024),
				"General tensor polynomial budget exceeded"
			)
			index = #polynomials + 1
			keys[key] = index
			polynomials[index] = normalized
		end
		return { index = index, scale = scale.sign }
	end
	local function sign(ref, values)
		return ref.index and ref.scale * values[ref.index] or ref.constant
	end
	local sources, spans = {}, {}
	local function power(p, degree)
		local out = { M.constant(R.number(1)) }
		for i = 1, degree do
			out[i + 1] = M.product(out[i], p)
		end
		return out
	end
	for operand, input in data.sources do
		assert(input.kind == "surface" or input.kind == "cyclicSurface", "Tensor surface required")
		input.maxControls = data.limits.maxControls
		sources[operand] = input.kind == "cyclicSurface"
				and C.surfaceToNURBS(C.surface(input.control, input.degreeU, input.degreeV, input))
			or N.surface(input.control, input.degreeU, input.degreeV, input)
		spans[operand] = extract(sources[operand], R, P, ctx)
		for _, span in spans[operand] do
			span.original = span.h
			span.h = {}
			local localMap = {}
			span.guards = {}
			for axis = 1, 2 do
				local x = M.variable(inverse[(operand - 1) * 2 + axis])
				localMap[axis] =
					M.scale(M.sub(x, M.constant(span.offset[axis])), R.div(R.number(1), span.scale[axis]))
				span.guards[#span.guards + 1] = reference(localMap[axis])
				span.guards[#span.guards + 1] = reference(M.sub(M.constant(R.number(1)), localMap[axis]))
			end
			local up = power(localMap[1], sources[operand].degreeU)
			local vp = power(localMap[2], sources[operand].degreeV)
			for coordinate, h in span.original do
				local out = {}
				for v, row in h do
					for u, value in row do
						out = M.add(out, M.scale(M.product(up[u], vp[v]), value))
					end
				end
				span.h[coordinate] = out
			end
		end
	end
	local domain = {}
	for axis = 1, 4 do
		local x = M.variable(inverse[axis])
		domain[#domain + 1] = reference(M.sub(x, M.constant(data.bounds[axis][1])))
		domain[#domain + 1] = reference(M.sub(M.constant(data.bounds[axis][2]), x))
	end
	assert(#spans[1] * #spans[2] <= ctx.maxPieces, "General tensor span-pair budget exceeded")
	local bernstein = require(script.Parent.GeneralTensorBernstein)(R, ctx)
	local pairs = {}
	for ai, a in spans[1] do
		for bi, b in spans[2] do
			local equations = {}
			for axis = 1, 3 do
				equations[axis] = M.sub(M.product(a.h[axis], b.h[4]), M.product(b.h[axis], a.h[4]))
			end
			local faces, remaining, signProof = bernstein.classify(
				bernstein.prepare(a, sources[1].degreeU, sources[1].degreeV),
				bernstein.prepare(b, sources[2].degreeU, sources[2].degreeV)
			)
			signProof.applied = #remaining == 0 or #faces == 0
			if not signProof.applied then
				-- Keep the original equation ideal when a boundary restriction
				-- would otherwise hide useful mixed-sign elimination equations.
				faces = { {} }
				remaining = { 1, 2, 3 }
			end
			local unresolved = {}
			for _, axis in remaining do
				unresolved[#unresolved + 1] = equations[axis]
			end
			local alternatives = {}
			for _, face in faces do
				local refs = {}
				for axis = 1, 4 do
					if face[axis] ~= nil then
						local span = axis <= 2 and a or b
						local localAxis = (axis - 1) % 2 + 1
						local value = span.offset[localAxis]
						if face[axis] == 1 then
							value = R.add(value, span.scale[localAxis])
						end
						refs[#refs + 1] = reference(M.sub(M.variable(inverse[axis]), M.constant(value)))
					end
				end
				alternatives[#alternatives + 1] = refs
			end
			local reduced, witness = require(script.Parent.EquationReduction)(unresolved, M, R, ctx, options)
			local refs = {}
			for _, p in reduced do
				refs[#refs + 1] = reference(p)
			end
			pairs[#pairs + 1] = {
				a = ai,
				b = bi,
				equations = equations,
				reduced = reduced,
				refs = refs,
				rewrite = witness,
				alternatives = alternatives,
				signProof = signProof,
				remainingCoordinates = remaining,
			}
		end
	end
	local function inside(refs, values)
		for _, ref in refs do
			if sign(ref, values) < 0 then
				return false
			end
		end
		return true
	end
	local function owner(values)
		if not inside(domain, values) then
			return nil
		end
		for i, pair in pairs do
			if not inside(spans[1][pair.a].guards, values) or not inside(spans[2][pair.b].guards, values) then
				continue
			end
			local equal = true
			for _, ref in pair.refs do
				if sign(ref, values) ~= 0 then
					equal = false
					break
				end
			end
			if equal then
				for _, alternative in pair.alternatives do
					local matches = true
					for _, ref in alternative do
						if sign(ref, values) ~= 0 then
							matches = false
							break
						end
					end
					if matches then
						return i
					end
				end
			end
		end
		return nil
	end
	return {
		data = data,
		sources = sources,
		spans = spans,
		pairs = pairs,
		polynomials = polynomials,
		owner = owner,
		domain = domain,
		polynomial = M,
		parameterOrder = order,
		inverseOrder = inverse,
		prototype = true,
	}
end
