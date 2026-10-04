-- Closure of a product of univariate sign sets, after local graph elimination.
local polynomial = require(script.Parent.ExactPolynomialRoots)
local union = require(script.Parent.ExactRootUnion)
return function(polys, relations, origins, radius, axes, D, offset, Q, ctx, options)
	local grouped = {}
	for _, axis in axes do
		grouped[axis] = { polynomials = {}, relations = {} }
	end
	local function rational(value)
		local model = D.model
		while model.parent do
			if #value.n > 1 or #value.d ~= 1 then
				return nil
			end
			value = model.field.toRational(value)
			model = model.parent
		end
		return value
	end
	local function matches(value, relation)
		return relation == 2 and value >= 0 or relation ~= 2 and value == relation
	end
	for _, index in origins do
		if index == radius then
			continue
		end
		local axis, degree = nil, 0
		for _, term in polys[index] do
			for i, n in term.powers do
				if n ~= 0 then
					if axis and axis ~= i then
						return nil
					end
					axis = i
					degree = math.max(degree, n)
				end
			end
		end
		if not axis then
			local sign = #polys[index] == 0 and 0 or polys[index][1].value.sign
			if not matches(sign, relations[index]) then
				return false, { method = "emptyCartesianFactor" }
			end
			continue
		end
		if not grouped[axis] then
			return nil
		end
		local p = table.create(degree + 1, Q.number(0))
		for _, term in polys[index] do
			local value = rational(term.value)
			if not value then
				return nil
			end
			p[term.powers[axis] + 1] = value
		end
		local group = grouped[axis]
		group.polynomials[#group.polynomials + 1] = p
		group.relations[#group.relations + 1] = relations[index]
	end
	local P = polynomial(Q, ctx.visit, ctx.maxDegree or 96, ctx.allocate)
	local K = D.field
	local function evaluate(p, x)
		local out = K.number(0)
		for i = #p, 1, -1 do
			out = K.add(K.mul(out, x), D.embed(p[i]))
		end
		return out
	end
	local function compare(root, x)
		if root.exact then
			return K.compare(x, D.embed(root.low))
		end
		local low, high = D.embed(root.low), D.embed(root.high)
		if K.compare(x, low) <= 0 then
			return -1
		end
		if K.compare(x, high) >= 0 then
			return 1
		end
		if evaluate(root.analysis.squarefree, x).sign == 0 then
			return 0
		end
		local function variation(t)
			local n, previous = 0, 0
			for _, p in root.analysis.sequence do
				local sign = evaluate(p, t).sign
				if sign ~= 0 then
					if previous ~= 0 and previous ~= sign then
						n += 1
					end
					previous = sign
				end
			end
			return n
		end
		local count = variation(low) - variation(x)
		assert(count == 0 or count == 1)
		return count == 1 and 1 or -1
	end
	local proof = { method = "cartesianClosure", factors = {} }
	for _, axis in axes do
		local group = grouped[axis]
		if #group.polynomials == 0 then
			continue
		end
		local settings = ctx.isolation
			or {
				maxDepth = options.maxDepth or 256,
				maxNodes = options.maxNodes or 20000,
				nodes = 0,
				tolerance = Q.number(options.parameterTolerance or 1e-7),
			}
		ctx.isolation = settings
		local roots = union(group.polynomials, Q.number(0), Q.number(1), Q, P, settings, ctx)
		ctx.liftedRoots = (ctx.liftedRoots or 0) + #roots
		assert(ctx.liftedRoots <= (options.maxLiftedRoots or 20000), "Lifted root allocation budget exceeded")
		local analyses = {}
		for i, p in group.polynomials do
			analyses[i] = P.analyze(p)
		end
		local points, sectors = {}, {}
		for i, root in roots do
			local signs = {}
			for j, a in analyses do
				signs[j] = P.atRoot(a, root)
			end
			points[i] = signs
			if i < #roots then
				local sample = Q.div(Q.add(root.high, roots[i + 1].low), Q.number(2))
				local s = {}
				for j, a in analyses do
					s[j] = P.evaluate(a.polynomial, sample).sign
				end
				sectors[i] = s
			end
		end
		local function feasible(signs)
			for i, s in signs do
				if not matches(s, group.relations[i]) then
					return false
				end
			end
			return true
		end
		local target = D.values[axis - offset]
		local found = false
		for i, root in roots do
			local order = compare(root, target)
			if order == 0 and feasible(points[i]) then
				found = true
				break
			end
			if i < #roots and feasible(sectors[i]) and order >= 0 and compare(roots[i + 1], target) <= 0 then
				found = true
				break
			end
		end
		proof.factors[#proof.factors + 1] = {
			axis = axis,
			polynomials = group.polynomials,
			relations = group.relations,
			roots = roots,
			pointSigns = points,
			sectorSigns = sectors,
			contains = found,
		}
		if not found then
			return false, proof
		end
	end
	return true, proof
end
