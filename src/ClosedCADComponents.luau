-- Internal connectivity proof for a closed feasible union of CAD cells.
local closure = require(script.Parent.CellClosure)
return function(cad, R, ctx, options)
	options = options or {}
	local cells, paths, parent, proofs = {}, {}, {}, {}
	for _, cell in cad.leaves do
		if cell.feasible then
			cells[#cells + 1] = cell
			parent[#cells] = #cells
			local path = {}
			local node = cell
			while node.axis do
				path[node.axis] = node
				node = node.parent
			end
			paths[#cells] = path
		end
	end
	local function find(i)
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end
	local function possible(i, j)
		if cells[i].dimension == 0 then
			return false
		end
		for axis, path in paths[i] do
			for k, sign in path.signs do
				local other = paths[j][axis].signs[k]
				if sign == 0 and other ~= 0 or sign ~= 0 and other ~= 0 and sign ~= other then
					return false
				end
			end
		end
		return true
	end
	local pairs, queries, skipped = 0, 0, 0
	local audits = {}
	for i = 1, #cells do
		for j = i + 1, #cells do
			ctx.visit(1)
			pairs += 1
			assert(pairs <= (options.maxComponentPairs or 65536), "CAD component pair budget exceeded")
			if find(i) == find(j) then
				skipped += 1
				continue
			end
			local audit = { first = i, second = j, directions = {} }
			audits[#audits + 1] = audit
			local connected, proof = false, nil
			for _, order in { { i, j }, { j, i } } do
				local a, b = order[1], order[2]
				if not possible(a, b) then
					audit.directions[#audit.directions + 1] = {
						from = a,
						to = b,
						connected = false,
						method = cells[a].dimension == 0 and "closedPoint" or "incompatibleSigns",
					}
					continue
				end
				if
					cells[a].parent == cells[b].parent
					and cells[a].kind == "sector"
					and cells[b].kind == "section"
					and math.abs(cells[a].index - cells[b].index) == 1
				then
					connected = true
					proof = { method = "verticalFiberBoundary" }
				else
					queries += 1
					if options.trace then
						options.trace(a, b, cells[a], cells[b])
					end
					connected, proof = closure(cells[a], cells[b], cad, R, ctx, options)
				end
				proof.from = a
				proof.to = b
				proof.connected = connected
				audit.directions[#audit.directions + 1] = proof
				if connected then
					break
				end
			end
			if connected then
				parent[find(j)] = find(i)
				proofs[#proofs + 1] = proof
			end
		end
	end
	local groups, components = {}, {}
	for i, cell in cells do
		local key = find(i)
		local component = groups[key]
		if not component then
			component = { cells = {}, dimension = 0 }
			groups[key] = component
			components[#components + 1] = component
		end
		component.cells[#component.cells + 1] = i
		component.dimension = math.max(component.dimension, cell.dimension)
	end
	return {
		components = components,
		cells = cells,
		connections = proofs,
		pairs = pairs,
		queries = queries,
		audits = audits,
		skippedConnected = skipped,
		prototype = true,
		parameterComponentsCertified = false,
	}
end
