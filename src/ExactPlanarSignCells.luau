-- projection and lifting for closed bivariate sign conditions.
local polynomial = require(script.Parent.ExactPolynomialRoots)
local bivariate = require(script.Parent.ExactBivariatePolynomial)
local resultant = require(script.Parent.BivariateResultant)
local union = require(script.Parent.ExactRootUnion)
local algebraic = require(script.Parent.ExactAlgebraicValue)
local coefficientField = require(script.Parent.ExactAlgebraicField)
return function(source, ranges, R, P, B, isolation, ctx, options, truth, arithmetic)
	options = options or {}
	local makeAlgebraic = arithmetic and arithmetic.algebraic or algebraic
	local makeField = arithmetic and arithmetic.field or coefficientField
	ctx.liftedRoots = ctx.liftedRoots or 0
	local T = bivariate(R, P, ctx)
	local one, minus = R.number(1), R.number(-1)
	local original, polynomials = {}, {}
	for i, constraint in source do
		local p = constraint.p
		original[i] = { p = p, relation = constraint.relation }
		assert(
			(truth and constraint.relation == "measure")
				or constraint.relation == "eq"
				or constraint.relation == "ge"
		)
		table.insert(polynomials, p)
	end
	table.insert(polynomials, { P.trim({ R.neg(ranges[2][1]) }), { one } })
	table.insert(polynomials, { P.trim({ ranges[2][2] }), { minus } })
	local basis, contents = T.basis(polynomials)
	local projection = {}
	for _, content in contents do
		table.insert(projection, content)
	end
	for i, p in basis do
		for _, coefficient in p do
			table.insert(projection, coefficient)
		end
		table.insert(
			projection,
			resultant(p, T.derivative(p), R, P, ctx.visit, options.maxMatrixEntries or 4096, ctx.allocate)
		)
		for j = 1, i - 1 do
			table.insert(
				projection,
				resultant(p, basis[j], R, P, ctx.visit, options.maxMatrixEntries or 4096, ctx.allocate)
			)
		end
	end
	local function settings(K)
		if K == R then
			return isolation
		end
		return setmetatable({
			tolerance = K.rational(isolation.tolerance),
			maxDepth = isolation.maxDepth,
			maxNodes = isolation.maxNodes,
		}, {
			__index = function(_, key)
				if key == "nodes" then
					return isolation.nodes
				end
				return nil
			end,
			__newindex = function(self, key, value)
				if key == "nodes" then
					isolation.nodes = value
				else
					rawset(self, key, value)
				end
			end,
		})
	end
	local roots = union(projection, ranges[1][1], ranges[1][2], R, P, isolation, ctx)
	local function lift(root)
		local K, Q, convert, constant, asRational
		if root.exact then
			K, Q = R, P
			convert = function(p)
				return P.evaluate(p, root.low)
			end
			constant = function(value)
				return value
			end
			asRational = function(value)
				return value
			end
		else
			local F = makeAlgebraic(R, P, B, root, isolation)
			K = makeField(R, P, F, ctx.allocate)
			Q = polynomial(K, ctx.visit, ctx.maxDegree, ctx.allocate)
			convert = K.fromPolynomial
			constant = K.rational
			asRational = K.toRational
		end
		local function specialize(p)
			local out = {}
			ctx.allocate(#p)
			for i, coefficient in p do
				out[i] = convert(coefficient)
			end
			return Q.trim(out)
		end
		local sources = {}
		for i, p in basis do
			sources[i] = specialize(p)
		end
		local lifted = union(sources, constant(ranges[2][1]), constant(ranges[2][2]), K, Q, settings(K), ctx)
		ctx.liftedRoots += #lifted
		assert(ctx.liftedRoots <= (options.maxLiftedRoots or 20000), "Lifted root allocation budget exceeded")
		local analysis = {}
		for i, constraint in original do
			analysis[i] = Q.analyze(specialize(constraint.p))
		end
		local function feasible(signs)
			if truth then
				return truth(signs)
			end
			for i, sign in signs do
				local relation = original[i].relation
				if relation == "eq" and sign ~= 0 or relation == "ge" and sign < 0 then
					return false
				end
			end
			return true
		end
		local points, sectors = {}, {}
		for i, event in lifted do
			local signs = {}
			for j, a in analysis do
				signs[j] = Q.atRoot(a, event)
			end
			points[i] = { root = event, signs = signs, feasible = feasible(signs) }
			if i > 1 then
				local previous = lifted[i - 1]
				local x = K.div(K.add(previous.high, event.low), K.number(2))
				local intervalSigns = {}
				for j, a in analysis do
					intervalSigns[j] = Q.evaluate(a.polynomial, x).sign
				end
				sectors[i - 1] =
					{ sample = asRational(x), signs = intervalSigns, feasible = feasible(intervalSigns) }
			end
		end
		local components = {}
		local i = 1
		while i <= #points do
			if points[i].feasible then
				local first = i
				while i < #points and sectors[i].feasible do
					assert(points[i + 1].feasible, "Closed feasible vertical interval lost an endpoint")
					i += 1
				end
				table.insert(components, { first = first, last = i, dimension = i == first and 0 or 1 })
			elseif i < #points then
				assert(not sectors[i].feasible, "Closed feasible sector has an excluded endpoint")
			end
			i += 1
		end
		return {
			points = points,
			sectors = sectors,
			components = components,
			scalar = K,
			polynomial = Q,
			asRational = asRational,
			sources = sources,
			analysis = analysis,
			isolation = settings(K),
			constant = constant,
		}
	end
	local events, slabs = {}, {}
	for i, root in roots do
		events[i] = { root = root, lift = lift(root) }
	end
	for i = 1, #events - 1 do
		local x = R.div(R.add(events[i].root.high, events[i + 1].root.low), R.number(2))
		slabs[i] = {
			first = i,
			last = i + 1,
			sample = x,
			lift = lift({ low = x, high = x, exact = true, depth = 0 }),
		}
	end
	local out = {
		events = events,
		slabs = slabs,
		basis = basis,
		projection = projection,
		original = original,
		domain = ranges,
		ctx = ctx,
		R = R,
		P = P,
		B = B,
		lift = lift,
		isolation = isolation,
	}
	return require(script.Parent.ExactPlanarAdjacency)(out, options)
end
