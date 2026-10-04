-- Map a certified cell sample into the source CAD without approximating roots.
return function(cad, cell, fixed, ctx)
	local K = cell.field
	local values = table.clone(cell.values)
	for axis, number in fixed do
		values[axis] = K.number(number)
	end
	local current = cad.tree
	local proof = { signs = {}, fixed = {} }
	for axis = 1, cad.polynomial.dimension do
		if fixed[axis] ~= nil then
			proof.fixed[#proof.fixed + 1] = { axis = axis, value = fixed[axis] }
		end
	end
	for axis = 1, cad.polynomial.dimension do
		local signs = {}
		for i, p in cad.labels[axis] do
			signs[i] = cad.polynomial.evaluate(p, values, K, cell.embed).sign
		end
		proof.signs[axis] = signs
		local selected
		for _, node in current.children do
			ctx.visit(1)
			local equal = true
			for i, sign in signs do
				if node.signs[i] ~= sign then
					equal = false
					break
				end
			end
			if equal then
				assert(not selected, "CAD seam sample has ambiguous ownership")
				selected = node
			end
		end
		current = assert(selected, "Mapped seam sample has no CAD owner")
	end
	assert(current.feasible, "Certified periodic boundary transport left the contact set")
	return current, values, proof
end
