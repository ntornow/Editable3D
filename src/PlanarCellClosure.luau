-- Exact planar closure after a proved local graph elimination.
-- The planar engine is run on the whole box to retain every atomic sign fiber
-- and every branch-limit map; the open source predicate is evaluated separately.
local decompose = require(script.Parent.ExactPlanarSignCells)
local polynomial = require(script.Parent.ExactPolynomialRoots)
local bounds = require(script.Parent.ExactPolynomialBounds)
local union = require(script.Parent.ExactRootUnion)
return function(polys, relations, origins, radius, axes, D, offset, Q, ctx, options)
	if #axes ~= 2 then
		return nil
	end
	local zero, one = Q.number(0), Q.number(1)
	local source, expected = {}, {}
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
	for _, index in origins do
		if index == radius then
			continue
		end
		local out = {}
		local degreeU, degreeV = 0, 0
		for _, term in polys[index] do
			for axis, n in term.powers do
				if n ~= 0 and axis ~= axes[1] and axis ~= axes[2] then
					return nil
				end
			end
			degreeU = math.max(degreeU, term.powers[axes[1]])
			degreeV = math.max(degreeV, term.powers[axes[2]])
		end
		for v = 1, degreeV + 1 do
			out[v] = table.create(degreeU + 1, zero)
		end
		for _, term in polys[index] do
			local value = rational(term.value)
			if not value then
				return nil
			end
			out[term.powers[axes[2]] + 1][term.powers[axes[1]] + 1] = value
		end
		for _, row in out do
			while #row > 0 and row[#row].sign == 0 do
				table.remove(row)
			end
		end
		while #out > 0 and #out[#out] == 0 do
			table.remove(out)
		end
		source[#source + 1] = { p = out, relation = "measure" }
		expected[#expected + 1] = relations[index]
	end
	ctx.maxPolynomials = ctx.maxPolynomials or options.maxPolynomials or 256
	local P = polynomial(Q, ctx.visit, ctx.maxDegree or 96, ctx.allocate)
	local B = bounds(Q, P, ctx.visit)
	local isolation = ctx.isolation
		or {
			maxDepth = options.maxDepth or 256,
			maxNodes = options.maxNodes or 20000,
			nodes = 0,
			tolerance = Q.number(options.parameterTolerance or 1e-7),
		}
	ctx.isolation = isolation
	local planar = decompose(
		source,
		{ { zero, one }, { zero, one } },
		Q,
		P,
		B,
		isolation,
		ctx,
		options,
		function()
			return true
		end,
		{
			algebraic = require(script.Parent.ExactGeneralAlgebraicValue),
			field = require(script.Parent.ReducedAlgebraicField),
		}
	)
	local K = D.field
	local x, y = D.values[axes[1] - offset], D.values[axes[2] - offset]
	local function evaluate(p, value, convert)
		local out = K.number(0)
		for i = #p, 1, -1 do
			out = K.add(K.mul(out, value), convert(p[i]))
		end
		return out
	end
	local function rootCompare(root, value, convert)
		if root.exact then
			return K.compare(value, convert(root.low))
		end
		local low, high = convert(root.low), convert(root.high)
		if K.compare(value, low) <= 0 then
			return -1
		end
		if K.compare(value, high) >= 0 then
			return 1
		end
		if evaluate(root.analysis.squarefree, value, convert).sign == 0 then
			return 0
		end
		local function variation(t)
			local previous, count = 0, 0
			for _, p in root.analysis.sequence do
				local sign = evaluate(p, t, convert).sign
				if sign ~= 0 then
					if previous ~= 0 and previous ~= sign then
						count += 1
					end
					previous = sign
				end
			end
			return count
		end
		local count = variation(low) - variation(value)
		assert(count == 0 or count == 1, "Planar point comparison requires one root")
		return count == 1 and 1 or -1
	end
	local function feasible(signs)
		for i, value in signs do
			if expected[i] == 2 and value < 0 or expected[i] ~= 2 and value ~= expected[i] then
				return false
			end
		end
		return true
	end
	local function fiberContains(lift, roots, convert)
		for i, point in lift.points do
			if feasible(point.signs) and rootCompare(roots[i], y, convert) == 0 then
				return true
			end
			if
				i < #roots
				and feasible(lift.sectors[i].signs)
				and rootCompare(roots[i], y, convert) >= 0
				and rootCompare(roots[i + 1], y, convert) <= 0
			then
				return true
			end
		end
		return false
	end
	local eventIndex, slabIndex
	for i, event in planar.events do
		local order = rootCompare(event.root, x, D.embed)
		if order == 0 then
			eventIndex = i
			break
		end
		if order < 0 then
			slabIndex = i - 1
			break
		end
	end
	if eventIndex then
		local event = planar.events[eventIndex]
		local convert
		if event.root.exact then
			convert = D.embed
		else
			convert = function(value)
				return K.div(evaluate(value.n, x, D.embed), evaluate(value.d, x, D.embed))
			end
		end
		local roots = {}
		for _, point in event.lift.points do
			roots[#roots + 1] = point.root
		end
		local answer = fiberContains(event.lift, roots, convert)
		local neighborhood = planar.neighborhoods[eventIndex]
		if not answer and neighborhood then
			for _, side in { { neighborhood.left, eventIndex - 1 }, { neighborhood.right, eventIndex } } do
				local near, slab = side[1], planar.slabs[side[2]]
				if not near or not slab then
					continue
				end
				for i, point in slab.lift.points do
					if feasible(point.signs) and rootCompare(roots[near.rootMap[i]], y, convert) == 0 then
						answer = true
						break
					end
					if
						i < #slab.lift.points
						and feasible(slab.lift.sectors[i].signs)
						and rootCompare(roots[near.rootMap[i]], y, convert) >= 0
						and rootCompare(roots[near.rootMap[i + 1]], y, convert) <= 0
					then
						answer = true
						break
					end
				end
				if answer then
					break
				end
			end
		end
		return answer,
			{
				method = "planarEventClosure",
				event = eventIndex,
				planar = planar,
				expected = expected,
				axes = axes,
			}
	end
	assert(slabIndex and planar.slabs[slabIndex], "Target point is outside the planar domain")
	local PK = polynomial(K, ctx.visit, ctx.maxDegree or 96, ctx.allocate)
	local specialized = {}
	for i, p in planar.basis do
		local coefficients = {}
		for _, row in p do
			coefficients[#coefficients + 1] = evaluate(row, x, D.embed)
		end
		specialized[i] = PK.trim(coefficients)
	end
	local settings = setmetatable({
		maxDepth = isolation.maxDepth,
		maxNodes = isolation.maxNodes,
		tolerance = K.number(options.parameterTolerance or 1e-7),
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
	local roots = union(specialized, K.number(0), K.number(1), K, PK, settings, ctx)
	ctx.liftedRoots = (ctx.liftedRoots or 0) + #roots
	assert(ctx.liftedRoots <= (options.maxLiftedRoots or 20000), "Lifted root allocation budget exceeded")
	local slab = planar.slabs[slabIndex]
	assert(#roots == #slab.lift.points, "Planar root count changed inside a slab")
	return fiberContains(slab.lift, roots, function(value)
		return value
	end),
		{ method = "planarSlabClosure", slab = slabIndex, planar = planar, expected = expected, axes = axes }
end
