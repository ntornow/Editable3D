-- Bounded recursive algebraic lifting on a bounded unit cube.
local polynomial = require(script.Parent.ExactPolynomialRoots)
local bounds = require(script.Parent.ExactPolynomialBounds)
local algebraic = require(script.Parent.ExactGeneralAlgebraicValue)
local field = require(script.Parent.ReducedAlgebraicField)
local rootUnion = require(script.Parent.ExactRootUnion)
return function(source, dimension, R, ctx, options, truth)
	options = options or {}
	local M = require(script.Parent.ExactSparsePolynomial)(R, dimension, ctx)
	local input = table.clone(source)
	for axis = 1, dimension do
		local x = M.variable(axis)
		table.insert(input, x)
		table.insert(input, M.sub(M.constant(R.number(1)), x))
	end
	local levels, labels = require(script.Parent.CollinsProjection)(input, dimension, M, R, ctx, options)
	local nodes, rootsAllocated = 0, 0
	local isolation = ctx.isolation
		or {
			maxDepth = options.maxDepth or 256,
			maxNodes = options.maxNodes or 20000,
			nodes = 0,
			tolerance = R.number(options.parameterTolerance or 1e-7),
		}
	ctx.isolation = isolation
	ctx.maxEvents = options.maxEvents or 2048
	local function settings(K)
		return setmetatable({
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
	end
	local leaves = {}
	local lastVariable = {}
	for i, p in source do
		local last = 0
		for _, term in p do
			for axis, power in term.powers do
				if power > 0 then
					last = math.max(last, axis)
				end
			end
		end
		lastVariable[i] = last
	end
	local quantifiers = options.quantifiers
	local function lift(axis, state)
		local K = state.field
		local P = polynomial(K, ctx.visit, ctx.maxDegree or 96, ctx.allocate)
		local ordinaryIsolate = P.isolate
		P.isolate = function(p, low, high, config)
			if #p ~= 2 then
				return ordinaryIsolate(p, low, high, config)
			end
			ctx.visit(1)
			config.nodes += 1
			assert(config.nodes <= config.maxNodes, "Polynomial root node budget exceeded")
			local x = K.div(K.neg(p[1]), p[2])
			local inside = K.compare(low, x) <= 0 and K.compare(x, high) <= 0
			return {
				identity = false,
				complete = true,
				roots = inside and { { low = x, high = x, exact = true, multiplicity = 1, depth = 0 } } or {},
				analysis = P.analyze(p),
				nodes = 1,
			}
		end
		local B = bounds(K, P, ctx.visit)
		local config = settings(K)
		local specialized = {}
		for i, p in levels[axis] do
			specialized[i] = M.specialize(p, axis, state.values, K, state.embed)
			if options.projection == "mccallum" and axis < dimension and M.degree(p, axis) > 0 then
				if #specialized[i] == 0 then
					error(
						options.nullificationFailure
							or "Reduced CAD projection nullification requires full fallback",
						0
					)
				end
			end
		end
		local constrained = false
		local requiredIndex
		if options.requiredZero and (not quantifiers or quantifiers[axis] == "exists") then
			for _, index in options.requiredZero(state.originalSigns or {}) do
				if lastVariable[index] == axis then
					local candidate = M.specialize(source[index], axis, state.values, K, state.embed)
					if #candidate > 0 then
						specialized = { candidate }
						constrained = true
						requiredIndex = index
						break
					end
				end
			end
		end
		local roots = rootUnion(specialized, K.number(0), K.number(1), K, P, config, ctx)
		rootsAllocated += #roots
		ctx.liftedRoots = (ctx.liftedRoots or 0) + #roots
		assert(
			ctx.liftedRoots <= (options.maxLiftedRoots or 20000),
			"CAD lifted root allocation budget exceeded"
		)
		state.stack = { axis = axis, roots = roots, requiredZero = requiredIndex }
		local children = {}
		local aggregate = quantifiers and quantifiers[axis] == "forall" or false
		local function append(root, sample, kind)
			nodes += 1
			ctx.visit(1)
			assert(nodes <= (options.maxCells or 8192), "CAD cell allocation budget exceeded")
			local nextField, embed, values = K, state.embed, table.clone(state.values)
			local model = state.model
			if root and not root.exact then
				root.definingPolynomial = root.definingPolynomial or root.analysis.squarefree
				local F = algebraic(K, P, B, root, config)
				nextField = field(K, P, F, ctx.allocate)
				model = { field = nextField, parent = state.model, value = F, depth = state.model.depth + 1 }
				embed = function(q)
					return nextField.rational(state.embed(q))
				end
				for i, x in values do
					values[i] = nextField.rational(x)
				end
				values[axis] = nextField.fromPolynomial({ K.number(0), K.number(1) })
			else
				values[axis] = root and root.low or sample
			end
			local signs = {}
			if not quantifiers then
				for i, p in labels[axis] do
					signs[i] = M.evaluate(p, values, nextField, embed).sign
				end
			end
			local node = {
				field = nextField,
				model = model,
				embed = embed,
				values = values,
				signs = signs,
				root = root,
				sample = sample,
				kind = kind,
				dimension = state.dimension + (kind == "sector" and 1 or 0),
				parent = state,
				index = #children + 1,
				axis = axis,
			}
			table.insert(children, node)
			node.originalSigns = {}
			for i, p in source do
				if lastVariable[i] <= axis then
					node.originalSigns[i] = M.evaluate(p, values, nextField, embed).sign
				end
			end
			if quantifiers then
				local decided = truth(node.originalSigns)
				if decided ~= nil then
					node.result = decided
					node.early = true
					table.insert(leaves, node)
				else
					assert(axis < dimension, "Complete assignment must decide quantified predicate")
					node.children, node.result = lift(axis + 1, node)
				end
				if quantifiers[axis] == "exists" then
					aggregate = aggregate or node.result
				else
					assert(quantifiers[axis] == "forall")
					aggregate = aggregate and node.result
				end
			elseif axis == dimension then
				node.feasible = truth and truth(node.originalSigns) or false
				table.insert(leaves, node)
			else
				node.children = lift(axis + 1, node)
			end
		end
		for i, root in roots do
			append(root, nil, "section")
			if quantifiers and aggregate == (quantifiers[axis] == "exists") then
				return children, aggregate
			end
			if not constrained and i < #roots then
				local nextRoot = roots[i + 1]
				assert(K.compare(root.high, nextRoot.low) < 0, "CAD sector isolators not separated")
				append(nil, K.div(K.add(root.high, nextRoot.low), K.number(2)), "sector")
				if quantifiers and aggregate == (quantifiers[axis] == "exists") then
					return children, aggregate
				end
			end
		end
		return children, aggregate
	end
	local base = {
		field = R,
		model = { field = R, depth = 0 },
		embed = function(q)
			return q
		end,
		values = {},
		dimension = 0,
	}
	base.children, base.result = lift(1, base)
	return {
		result = base.result,
		tree = base,
		leaves = leaves,
		levels = levels,
		labels = labels,
		polynomial = M,
		nodes = nodes,
		isolationNodes = isolation.nodes,
		roots = rootsAllocated,
		prototype = true,
		coverageCertified = false,
		parameterComponentsCertified = false,
	}
end
