-- Exact incidences between closed local contact complexes on tensor knot tiles.
local rootCompare = require(script.Parent.ExactRootCompare)
local intervalContacts = require(script.Parent.ExactIntervalContacts)
return function(data, spans, internals)
	local R, P, ctx = data.R, data.P, data.ctx
	local options = data.options
	local compare = rootCompare(R, P, data.isolation)
	local parents, entries = {}, {}
	for spanIndex, cad in internals do
		for _, component in cad.components do
			component.global = #parents + 1
			parents[component.global] = component.global
			entries[component.global] = { span = spanIndex, component = component }
		end
	end
	local function owner(i)
		while parents[i] ~= i do
			parents[i] = parents[parents[i]]
			i = parents[i]
		end
		return i
	end
	local function boundary(spanIndex, axis, side)
		local cad = internals[spanIndex]
		local out = {}
		if axis == 1 then
			local event = cad.events[side == 1 and 1 or #cad.events]
			assert(event.root.exact, "Tensor tile endpoint must be rational")
			for _, c in event.lift.components do
				table.insert(out, {
					low = event.lift.points[c.first].root,
					high = event.lift.points[c.last].root,
					open = false,
					cell = c.cell,
					component = cad.components[cad.cells[c.cell].component].global,
				})
			end
		else
			local function owned(lift)
				local point = side == 1 and 1 or #lift.points
				for _, c in lift.components do
					if c.first <= point and c.last >= point then
						return c.cell
					end
				end
				return nil
			end
			for _, event in cad.events do
				local cell = owned(event.lift)
				if cell then
					table.insert(out, {
						low = event.root,
						high = event.root,
						open = false,
						cell = cell,
						component = cad.components[cad.cells[cell].component].global,
					})
				end
			end
			for _, slab in cad.slabs do
				local cell = owned(slab.lift)
				if cell then
					table.insert(out, {
						low = cad.events[slab.first].root,
						high = cad.events[slab.last].root,
						open = true,
						cell = cell,
						component = cad.components[cad.cells[cell].component].global,
					})
				end
			end
		end
		return out
	end
	local function curve(spanIndex, axis, side)
		local span, cad = spans[spanIndex], internals[spanIndex]
		local parameter = cad.domain[axis][side]
		local h = {}
		for coordinate, p in span.h do
			local out = {}
			if axis == 1 then
				for i, c in p do
					out[i] = P.evaluate(c, parameter)
				end
				P.trim(out)
			else
				for i = #p, 1, -1 do
					out = P.add(P.scale(out, parameter), p[i])
				end
			end
			h[coordinate] = out
		end
		return h
	end
	local joins, pairs = {}, 0
	local function join(first, second, axis)
		ctx.check("tensorSpanJoin")
		local x, y = spans[first], spans[second]
		assert(
			R.equal(R.add(x.offset[axis], x.scale[axis]), y.offset[axis]),
			"Adjacent tensor tile maps differ"
		)
		assert(
			R.equal(x.offset[3 - axis], y.offset[3 - axis]) and R.equal(x.scale[3 - axis], y.scale[3 - axis]),
			"Adjacent tensor edge coordinates differ"
		)
		local left, right = curve(first, axis, 2), curve(second, axis, 1)
		for coordinate = 1, 3 do
			local difference = P.add(
				P.product(left[coordinate], right[4]),
				P.scale(P.product(right[coordinate], left[4]), R.number(-1))
			)
			assert(#difference == 0, "Adjacent tensor tile boundary geometry differs")
		end
		local a, b = boundary(first, axis, 2), boundary(second, axis, 1)
		local contacts = intervalContacts(a, b, compare, function()
			pairs += 1
			assert(pairs <= (options.maxConnectionPairs or 100000), "Tensor span comparison budget exceeded")
			ctx.visit(1)
		end, function()
			ctx.connectionsAllocated += 1
			assert(
				ctx.connectionsAllocated <= (options.maxConnections or 16384),
				"Tensor span contact budget exceeded"
			)
		end)
		for _, contact in contacts do
			parents[owner(contact.first.component)] = owner(contact.second.component)
		end
		table.insert(
			joins,
			{ firstSpan = first, secondSpan = second, axis = axis, contacts = contacts, certified = true }
		)
	end
	local grid = {}
	for index, span in spans do
		grid[span.indices[1]] = grid[span.indices[1]] or {}
		grid[span.indices[1]][span.indices[2]] = index
	end
	for index, span in spans do
		local i, j = span.indices[1], span.indices[2]
		if grid[i + 1] and grid[i + 1][j] then
			join(index, grid[i + 1][j], 1)
		end
		if grid[i][j + 1] then
			join(index, grid[i][j + 1], 2)
		end
	end
	local groups, components = {}, {}
	for i, entry in entries do
		local root = owner(i)
		local group = groups[root]
		if not group then
			group = { index = #components + 1, parts = {}, dimension = 0 }
			groups[root] = group
			table.insert(components, group)
		end
		table.insert(group.parts, entry)
		group.dimension = math.max(group.dimension, entry.component.dimension)
		entry.component.parameterComponent = group.index
	end
	return {
		joins = joins,
		components = components,
		pairs = pairs,
		boundary = boundary,
		curve = curve,
		grid = grid,
		entries = entries,
	}
end
