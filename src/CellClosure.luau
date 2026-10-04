-- Exact closure incidence via a bounded first-order formula. Internal prototype.
local tower = require(script.Parent.GuardedTowerCAD)
local function closure(C, D, cad, R, ctx, options)
	if C == D then
		return true, { method = "identity" }
	end
	if C.dimension == 0 then
		return false, { method = "closedPoint" }
	end
	options = options or {}
	if D.dimension > 0 and not options.fixedTarget then
		local pointOptions = table.clone(options)
		pointOptions.fixedTarget = true
		local inside, proof = closure(C, D, cad, R, ctx, pointOptions)
		if inside then
			proof.sampleWitness = true
			return true, proof
		end
	end
	local dimension = cad.polynomial.dimension
	local originalField = R
	local fixed = D.dimension == 0 or options.fixedTarget == true
	if fixed then
		R = D.field
	end
	local epsilonAxis = fixed and 1 or dimension + 1
	local offset = epsilonAxis
	local count = offset + dimension
	local M = require(script.Parent.ExactSparsePolynomial)(R, count, ctx)
	local polynomials, signs, targets, origins = {}, {}, {}, {}
	local function push(p, sign, list)
		polynomials[#polynomials + 1] = p
		signs[#polynomials] = sign
		if list then
			list[#list + 1] = #polynomials
		end
		return #polynomials
	end
	local function relabel(p, shift)
		local out = {}
		for _, term in p do
			local powers = table.create(count, 0)
			for axis, n in term.powers do
				powers[axis + shift] = n
			end
			out[#out + 1] = { powers = powers, value = fixed and D.embed(term.value) or term.value }
		end
		return M.make(out)
	end
	local function conditions(cell, shift, list)
		for _, condition in require(script.Parent.CellSignFormula)(cad, cell, ctx) do
			push(relabel(condition.polynomial, shift), condition.sign, list)
		end
	end
	if not fixed then
		conditions(D, 0, targets)
	end
	local epsilon = push(M.variable(epsilonAxis), 1)
	conditions(C, offset, origins)
	local distance = {}
	for axis = 1, dimension do
		local target = fixed and M.constant(D.values[axis]) or M.variable(axis)
		local delta = M.sub(M.variable(offset + axis), target)
		distance = M.add(distance, M.product(delta, delta))
	end
	local e = polynomials[epsilon]
	local radius = push(M.sub(M.product(e, e), distance), 1, origins)
	if fixed then
		local equations, indices = {}, {}
		for _, index in origins do
			if signs[index] == 0 then
				equations[#equations + 1] = polynomials[index]
				indices[#indices + 1] = index
			end
		end
		if #equations > 0 then
			local _, witness, reduce = require(script.Parent.EquationReduction)(equations, M, R, ctx, options)
			for i, index in indices do
				polynomials[index] = witness.equations[i]
			end
			for _, index in origins do
				if signs[index] ~= 0 then
					polynomials[index] = reduce(polynomials[index])
				end
			end
		end
	end
	local graphProof
	if fixed then
		local point = { R.number(0) }
		for _, value in D.values do
			point[#point + 1] = value
		end
		local eliminated, proof = require(script.Parent.FunctionalCellClosure)(
			polynomials,
			signs,
			origins,
			M,
			R,
			point,
			offset,
			ctx
		)
		if not eliminated then
			return false, proof
		end
		graphProof = proof
		local retained = {}
		for axis = 1, dimension do
			if not eliminated[offset + axis] then
				retained[#retained + 1] = offset + axis
			end
		end
		local cartesianDecision, cartesianProof = require(script.Parent.CartesianCellClosure)(
			polynomials,
			signs,
			origins,
			radius,
			retained,
			D,
			offset,
			originalField,
			ctx,
			options
		)
		if cartesianDecision ~= nil then
			cartesianProof.graphProof = graphProof
			return cartesianDecision, cartesianProof
		end
		local planarDecision, planarProof = require(script.Parent.PlanarCellClosure)(
			polynomials,
			signs,
			origins,
			radius,
			retained,
			D,
			offset,
			originalField,
			ctx,
			options
		)
		if planarDecision ~= nil then
			planarProof.graphProof = graphProof
			return planarDecision, planarProof
		end

		local projectedDistance = {}
		for axis = 1, dimension do
			if not eliminated[offset + axis] then
				local delta = M.sub(M.variable(offset + axis), M.constant(D.values[axis]))
				projectedDistance = M.add(projectedDistance, M.product(delta, delta))
			end
		end
		polynomials[radius] = M.sub(M.product(e, e), projectedDistance)
		local equations = {}
		for _, index in origins do
			if signs[index] == 0 and #polynomials[index] > 0 then
				equations[#equations + 1] = polynomials[index]
			end
		end
		if #equations > 0 then
			local _, _, reduce = require(script.Parent.EquationReduction)(equations, M, R, ctx, options)
			polynomials[radius] = reduce(polynomials[radius])
		end
	end
	local function check(values, indices)
		local unknown = false
		for _, i in indices do
			if values[i] == nil then
				unknown = true
			elseif signs[i] == 2 and values[i] < 0 or signs[i] ~= 2 and values[i] ~= signs[i] then
				return false
			end
		end
		if unknown then
			return nil
		end
		return true
	end
	local function truth(values)
		local target = check(values, targets)
		if target == false then
			return false
		end
		if values[epsilon] == nil then
			return nil
		end
		if values[epsilon] <= 0 then
			return target
		end
		local origin = check(values, origins)
		if origin == false then
			return false
		end
		if target and origin and values[epsilon] ~= nil then
			return true
		end
		return nil
	end
	local quantifiers = table.create(count, "exists")
	quantifiers[epsilonAxis] = "forall"
	local settings = table.clone(options or {})
	settings.quantifiers = quantifiers
	settings.requiredZero = function(values)
		local zero = {}
		for _, i in targets do
			if signs[i] == 0 then
				zero[#zero + 1] = i
			end
		end
		if values[epsilon] == 1 then
			for _, i in origins do
				if signs[i] == 0 then
					zero[#zero + 1] = i
				end
			end
		end
		return zero
	end
	local result = tower(polynomials, count, R, ctx, settings, truth)
	return result.result,
		{
			method = fixed and (originalField == R and "rationalPointQE" or "algebraicPointQE") or "cellQE",
			nodes = result.nodes,
			roots = result.roots,
			projection = result.projectionMethod,
			radius = radius,
			graphProof = graphProof,
			decision = {
				cad = result,
				polynomials = polynomials,
				relations = signs,
				targets = targets,
				origins = origins,
				epsilon = epsilon,
				quantifiers = quantifiers,
				fixed = fixed,
			},
		}
end

return closure
