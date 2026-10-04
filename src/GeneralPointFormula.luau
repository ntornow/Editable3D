-- Restrict a CAD cell to its exact sample by fixing each open-sector coordinate.
return function(cad, cell, R, ctx)
	local M = cad.polynomial
	local path, axes = {}, {}
	local current = cell
	while current.axis do
		path[current.axis] = current
		if current.model ~= current.parent.model then
			axes[current.model] = current.axis
		end
		current = current.parent
	end
	local one = M.constant(R.number(1))
	local function add(a, b)
		return { n = M.add(M.product(a.n, b.d), M.product(b.n, a.d)), d = M.product(a.d, b.d) }
	end
	local function multiply(a, b)
		return { n = M.product(a.n, b.n), d = M.product(a.d, b.d) }
	end
	local scalar
	scalar = function(value, model)
		if not model.parent then
			return { n = M.constant(value), d = one }
		end
		local axis = assert(axes[model])
		local function evaluate(polynomial)
			local out = { n = {}, d = one }
			local x = { n = M.variable(axis), d = one }
			for i = #polynomial, 1, -1 do
				out = add(multiply(out, x), scalar(polynomial[i], model.parent))
			end
			return out
		end
		local a, b = evaluate(value.n), evaluate(value.d)
		return { n = M.product(a.n, b.d), d = M.product(a.d, b.n) }
	end
	local formula = table.clone(require(script.Parent.CellSignFormula)(cad, cell, ctx))
	for axis, node in path do
		if node.kind == "sector" then
			local q = scalar(node.sample, node.parent.model)
			formula[#formula + 1] = { polynomial = M.sub(M.product(M.variable(axis), q.d), q.n), sign = 0 }
			-- Every denominator originates in a nonzero field element. Retain that guard.
			formula[#formula + 1] = { polynomial = M.product(q.d, q.d), sign = 1 }
		end
	end
	return formula
end
