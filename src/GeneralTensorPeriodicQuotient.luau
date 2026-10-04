local transport = require(script.Parent.GeneralSeamTransport)
local pointFormula = require(script.Parent.GeneralPointFormula)
return function(prepared, cad, components)
	local data = prepared.data
	local R, ctx, options, M = data.R, data.ctx, data.options, prepared.polynomial
	local out = {
		axes = {},
		joins = {},
		decisions = {},
		unresolved = {},
		components = {},
		nodes = 0,
		pairs = 0,
		certified = false,
	}
	local function node()
		out.nodes += 1
		assert(out.nodes <= (options.maxSeamNodes or 20000), "General tensor seam node budget exceeded")
		ctx.visit(1)
	end
	local function pair()
		out.pairs += 1
		assert(out.pairs <= (options.maxSeamPairs or 100000), "General tensor seam pair budget exceeded")
		ctx.visit(1)
	end
	local function at(p, axis, value)
		local terms = {}
		for _, term in p do
			if value == 0 and term.powers[axis] > 0 then
				continue
			end
			local powers = table.clone(term.powers)
			powers[axis] = 0
			terms[#terms + 1] = { powers = powers, value = term.value }
		end
		return M.make(terms)
	end
	local active = {}
	for operand, input in data.sources do
		for axis = 1, 2 do
			if input.kind ~= "cyclicSurface" or input[axis == 1 and "cyclicU" or "cyclicV"] == false then
				continue
			end
			local original = (operand - 1) * 2 + axis
			local parameter = prepared.inverseOrder[original]
			local range = data.report.parameterBox[original]
			local entry = {
				surface = operand,
				axis = axis,
				parameterAxis = original,
				cadAxis = parameter,
				enabled = range[1] == 0 and range[2] == 1,
				identities = {},
			}
			out.axes[#out.axes + 1] = entry
			if not entry.enabled then
				entry.reason = "restrictedRange"
				continue
			end
			local low, high
			for _, span in prepared.spans[operand] do
				low = math.min(low or span.indices[axis], span.indices[axis])
				high = math.max(high or span.indices[axis], span.indices[axis])
			end
			local first, last = {}, {}
			for i, span in prepared.spans[operand] do
				if span.indices[axis] == low then
					first[span.indices[3 - axis]] = i
				end
				if span.indices[axis] == high then
					last[span.indices[3 - axis]] = i
				end
			end
			ctx.check("generalSeamGeometry")
			for other, i in first do
				node()
				local j = assert(last[other])
				local a, b = prepared.spans[operand][i], prepared.spans[operand][j]
				local identity = { firstSpan = i, secondSpan = j, equal = true, differences = {} }
				for coordinate = 1, 3 do
					node()
					local difference = M.sub(
						M.product(at(a.h[coordinate], parameter, 0), at(b.h[4], parameter, 1)),
						M.product(at(b.h[coordinate], parameter, 1), at(a.h[4], parameter, 0))
					)
					identity.differences[coordinate] = difference
					if #difference > 0 then
						identity.equal = false
					end
				end
				entry.identities[#entry.identities + 1] = identity
				if not identity.equal then
					entry.reason = "differentBoundaryCurves"
					out.unresolved[#out.unresolved + 1] = { parameterAxis = original, identity = identity }
					out.reason = "seamGeometry"
					return out
				end
			end
			entry.certified = true
			entry.reason = "exactBoundaryIdentity"
			active[parameter] = entry
		end
	end
	local parents, cellComponents = {}, {}
	for i, component in components.components do
		parents[i] = i
		for _, cell in component.cells do
			cellComponents[cell] = i
		end
	end
	local function find(i)
		while parents[i] ~= i do
			parents[i] = parents[parents[i]]
			i = parents[i]
		end
		return i
	end
	local cellIndices = {}
	for i, cell in components.cells do
		cellIndices[cell] = i
	end
	local boundary = {}
	for i, cell in components.cells do
		boundary[i] = {}
		for axis in active do
			local x = cell.values[axis]
			if cell.field.equal(x, cell.field.number(0)) then
				boundary[i][axis] = 0
			end
			if cell.field.equal(x, cell.field.number(1)) then
				boundary[i][axis] = 1
			end
		end
	end
	for axis, entry in active do
		ctx.check("generalSeamContacts")
		for i, cell in components.cells do
			if boundary[i][axis] ~= 0 then
				continue
			end
			pair()
			node()
			local target, _, proof = transport(cad, cell, { [axis] = 1 }, ctx)
			local j = assert(cellIndices[target])
			local a, b = cellComponents[i], cellComponents[j]
			local join = {
				firstCell = i,
				secondCell = j,
				parameterAxis = entry.parameterAxis,
				connected = true,
				proof = proof,
				method = "connectedSeamImage",
				joinsComponents = find(a) ~= find(b),
			}
			out.decisions[#out.decisions + 1] = join
			out.joins[#out.joins + 1] = join
			parents[find(a)] = find(b)
		end
	end
	-- Every connected source seam cell has a connected image in the contact set.
	-- Its exact transported sample therefore determines its image's component.
	-- Iterate every lower-side cell; upper-to-lower maps introduce no new edges.
	local pointFormulas = {}
	local vertexParents = {}
	for i in components.cells do
		vertexParents[i] = i
	end
	local function vertexFind(i)
		while vertexParents[i] ~= i do
			vertexParents[i] = vertexParents[vertexParents[i]]
			i = vertexParents[i]
		end
		return i
	end
	out.vertexProofs = {}
	for i, cell in components.cells do
		local axes = {}
		for axis in boundary[i] do
			axes[#axes + 1] = axis
		end
		table.sort(axes)
		for mask = 1, 2 ^ #axes - 1 do
			pair()
			node()
			local fixed = {}
			for bit, axis in axes do
				if math.floor(mask / 2 ^ (bit - 1)) % 2 == 1 then
					fixed[axis] = 1 - boundary[i][axis]
				end
			end
			local target, values, proof = transport(cad, cell, fixed, ctx)
			local j = assert(cellIndices[target])
			if j <= i or vertexFind(i) == vertexFind(j) then
				continue
			end
			if not pointFormulas[j] then
				pointFormulas[j] = pointFormula(cad, target, R, ctx)
			end
			local equal = true
			local signs = {}
			for k, condition in pointFormulas[j] do
				signs[k] = M.evaluate(condition.polynomial, values, cell.field, cell.embed).sign
				if signs[k] ~= condition.sign then
					equal = false
					break
				end
			end
			if equal then
				vertexParents[vertexFind(j)] = vertexFind(i)
			end
			out.vertexProofs[#out.vertexProofs + 1] = {
				first = i,
				second = j,
				equal = equal,
				transport = proof,
				signs = signs,
				formula = pointFormulas[j],
			}
		end
	end
	out.vertexClasses = {}
	out.vertexMap = {}
	local classes = {}
	for i in components.cells do
		local root = vertexFind(i)
		local class = classes[root]
		if not class then
			class = { index = #out.vertexClasses + 1, representative = i, vertexIndices = {} }
			classes[root] = class
			out.vertexClasses[#out.vertexClasses + 1] = class
		end
		class.vertexIndices[#class.vertexIndices + 1] = i
		out.vertexMap[i] = class.index
	end
	local groups = {}
	for i, c in components.components do
		local root = find(i)
		local g = groups[root]
		if not g then
			g = {
				index = #out.components + 1,
				parameterComponentIndices = {},
				cellIndices = {},
				parameterDimension = 0,
			}
			out.components[#out.components + 1] = g
			groups[root] = g
		end
		g.parameterComponentIndices[#g.parameterComponentIndices + 1] = i
		g.parameterDimension = math.max(g.parameterDimension, c.dimension)
		for _, cell in c.cells do
			g.cellIndices[#g.cellIndices + 1] = cell
		end
	end
	out.certified = true
	out.reason = "complete"
	return out
end
