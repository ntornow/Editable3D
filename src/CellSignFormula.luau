-- Choose a small sign formula that isolates a cell in its complete CAD stack.
-- Every candidate sign is invariant on every sibling. Distinguishing every
-- sibling therefore proves the selected conjunction defines exactly this cell.
return function(cad, cell, ctx)
	local formula = {}
	local path = {}
	while cell.axis do
		path[cell.axis] = cell
		cell = cell.parent
	end
	for axis, node in path do
		if not node.definingSigns then
			local others = {}
			for _, sibling in node.parent.children do
				if sibling ~= node then
					others[#others + 1] = sibling
				end
			end
			local candidates = {}
			for i, p in cad.labels[axis] do
				local total = 0
				for _, term in p do
					local sum = 0
					for _, power in term.powers do
						sum += power
					end
					total = math.max(total, sum)
				end
				candidates[#candidates + 1] =
					{ index = i, degree = total, terms = #p, zero = node.signs[i] == 0 }
			end
			table.sort(candidates, function(a, b)
				if a.degree ~= b.degree then
					return a.degree < b.degree
				end
				if a.terms ~= b.terms then
					return a.terms < b.terms
				end
				if a.zero ~= b.zero then
					return a.zero
				end
				return a.index < b.index
			end)
			local selected = {}
			for _, candidate in candidates do
				local index = candidate.index
				local remaining = {}
				local excludes = false
				for _, other in others do
					ctx.visit(1)
					if other.signs[index] == node.signs[index] then
						remaining[#remaining + 1] = other
					else
						excludes = true
					end
				end
				if excludes then
					selected[#selected + 1] = index
					others = remaining
				end
				if #others == 0 then
					break
				end
			end
			assert(#others == 0, "Thom sign labels do not distinguish every CAD sibling")
			node.definingSigns = selected
		end
		for _, index in node.definingSigns do
			formula[#formula + 1] =
				{ polynomial = cad.labels[axis][index], sign = node.signs[index], axis = axis, index = index }
		end
	end
	return formula
end
