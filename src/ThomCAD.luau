-- Internal quantified CAD over arbitrary ordered coefficient fields.
return function(source, dimension, R, ctx, options, truth)
	options = options or {}
	assert(options.quantifiers and options.projection ~= "mccallum")
	-- Independent positive power maps are bijections of each quantified unit axis.
	local powers = table.create(dimension, 0)
	local function gcd(a, b)
		while b ~= 0 do
			a, b = b, a % b
		end
		return a
	end
	for _, p in source do
		for _, term in p do
			for i, n in term.powers do
				powers[i] = gcd(powers[i], n)
			end
		end
	end
	local reduced = {}
	for j, p in source do
		reduced[j] = {}
		for _, t in p do
			local exponents = table.clone(t.powers)
			for i, n in exponents do
				if powers[i] > 1 then
					exponents[i] = n / powers[i]
				end
			end
			table.insert(reduced[j], { value = t.value, powers = exponents })
		end
	end
	source = reduced
	local M = require(script.Parent.ExactSparsePolynomial)(R, dimension, ctx)
	local input = table.clone(source)
	for axis = 1, dimension do
		local x = M.variable(axis)
		table.insert(input, x)
		table.insert(input, M.sub(M.constant(R.number(1)), x))
	end
	local levels = require(script.Parent.CollinsProjection)(input, dimension, M, R, ctx, options)
	local lastVariable = {}
	for i, p in source do
		local last = 0
		for _, t in p do
			for axis, n in t.powers do
				if n > 0 then
					last = math.max(last, axis)
				end
			end
		end
		lastVariable[i] = last
	end
	local cells = 0
	local function lift(axis, K, values, embed)
		local polys = {}
		for _, p in levels[axis] do
			table.insert(polys, M.specialize(p, axis, values, K, embed))
		end
		local roots = require(script.Parent.ThomRootCells)(K, polys, ctx, options)
		local universal = options.quantifiers[axis] == "forall"
		local aggregate = universal
		local function evaluate(nextK, nextValues, nextEmbed)
			cells += 1
			ctx.thomCells = (ctx.thomCells or 0) + 1
			ctx.visit(1)
			assert(ctx.thomCells <= (options.maxCells or 8192), "Thom CAD cell budget exceeded")
			local signs = {}
			for i, p in source do
				if lastVariable[i] <= axis then
					signs[i] = M.evaluate(p, nextValues, nextK, nextEmbed).sign
				end
			end
			local result = truth(signs)
			if result == nil then
				assert(axis < dimension, "Complete quantified assignment unresolved")
				result = lift(axis + 1, nextK, nextValues, nextEmbed)
			end
			if universal then
				aggregate = aggregate and result
			else
				aggregate = aggregate or result
			end
			return aggregate ~= universal
		end
		for _, root in roots do
			local B = root.field
			local function rootEmbed(q)
				return root.embed(embed(q))
			end
			local rootValues = {}
			for i, v in values do
				rootValues[i] = root.embed(v)
			end
			rootValues[axis] = root.coordinate
			if evaluate(B, rootValues, rootEmbed) then
				return aggregate
			end
			if root.highSign < 0 then
				-- The new positive infinitesimal lies in the next open sign cell.
				local L = require(script.Parent.InfinitesimalField)(B, ctx.visit, ctx.allocate, ctx.maxDegree)
				local sectorValues = {}
				for i, v in rootValues do
					sectorValues[i] = L.rational(v)
				end
				sectorValues[axis] = L.add(sectorValues[axis], L.epsilon)
				local function sectorEmbed(q)
					return L.rational(rootEmbed(q))
				end
				if evaluate(L, sectorValues, sectorEmbed) then
					return aggregate
				end
			end
		end
		return aggregate
	end
	local result = lift(1, R, {}, function(q)
		return q
	end)
	return { result = result, cells = cells }
end
