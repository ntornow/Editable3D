-- complete incidence for compact closed planar sign cells.
-- Primitive basis polynomials cannot nullify at an algebraic profile value.
-- Horizontal separators and root-free profile neighborhoods identify every
-- finite branch limit without approximating a curved branch by a segment.
return function(data, options)
	options = options or {}
	local R, P, B, ctx = data.R, data.P, data.B, data.ctx
	local two = R.number(2)
	local cells, connections, parents = {}, {}, {}
	ctx.cellsAllocated = ctx.cellsAllocated or 0
	ctx.connectionsAllocated = ctx.connectionsAllocated or 0
	local function addCell(cell)
		ctx.cellsAllocated += 1
		assert(ctx.cellsAllocated <= (options.maxCells or 8192), "Planar cell allocation budget exceeded")
		cell.index = #cells + 1
		table.insert(cells, cell)
		parents[cell.index] = cell.index
		return cell.index
	end
	local function find(x)
		while parents[x] ~= x do
			parents[x] = parents[parents[x]]
			x = parents[x]
		end
		return x
	end
	for i, event in data.events do
		for j, c in event.lift.components do
			c.cell = addCell({ kind = "event", event = i, fiber = j, dimension = c.dimension })
		end
	end
	for i, slab in data.slabs do
		for j, c in slab.lift.components do
			c.cell = addCell({
				kind = c.dimension == 0 and "graph" or "band",
				slab = i,
				fiber = j,
				dimension = c.dimension + 1,
			})
		end
	end
	local function midpoint(a, b)
		return R.div(R.add(a, b), two)
	end
	local function separatorPolynomial(p, q)
		local out = {}
		for i = #p, 1, -1 do
			out = P.add(P.scale(out, q), p[i])
		end
		return out
	end
	local function eventNeighborhood(index)
		local event = data.events[index]
		local lifted = event.lift
		local cuts = {}
		for i = 1, #lifted.points - 1 do
			local first, second = lifted.points[i].root, lifted.points[i + 1].root
			cuts[i] = midpoint(lifted.asRational(first.high), lifted.asRational(second.low))
		end
		local crossing = {}
		for _, cut in cuts do
			for _, p in data.basis do
				local q = separatorPolynomial(p, cut)
				assert(#q > 0, "Horizontal separator lies on a basis branch")
				table.insert(crossing, q)
			end
		end
		local root = event.root
		local lo, hi, depth
		depth = 0
		while true do
			if not root.exact then
				lo, hi = root.low, root.high
			elseif lo == nil or R.compare(lo, root.low) > 0 or R.compare(hi, root.low) < 0 then
				lo = index > 1 and midpoint(data.slabs[index - 1].sample, root.low) or root.low
				hi = index <= #data.slabs and midpoint(root.low, data.slabs[index].sample) or root.low
			end
			local clear = true
			for _, p in crossing do
				local enclosure = B.evaluate(p, { lo, hi })
				if enclosure[1].sign <= 0 and enclosure[2].sign >= 0 then
					clear = false
					break
				end
			end
			if clear then
				break
			end
			if root.exact then
				assert(depth < data.isolation.maxDepth, "Planar adjacency depth budget exceeded")
				data.isolation.nodes += 1
				assert(
					data.isolation.nodes <= data.isolation.maxNodes,
					"Planar adjacency node budget exceeded"
				)
				lo, hi = midpoint(lo, root.low), midpoint(hi, root.low)
				depth += 1
			else
				P.refine(root.analysis, root, data.isolation)
				if root.exact then
					lo, hi = nil, nil
				end
			end
			ctx.visit(1)
		end
		return { cuts = cuts, low = lo, high = hi, crossing = crossing, depth = depth }
	end
	local function attach(slabIndex, eventIndex, nearValue, proof)
		local slab, event = data.slabs[slabIndex], data.events[eventIndex]
		local near = data.lift({ low = nearValue, high = nearValue, exact = true, depth = 0 })
		assert(#near.points == #slab.lift.points, "Root count changed inside a projected slab")
		local mapping = {}
		for i, point in near.points do
			assert(
				point.feasible == slab.lift.points[i].feasible,
				"Root feasibility changed inside a projected slab"
			)
			if i < #near.points then
				assert(
					near.sectors[i].feasible == slab.lift.sectors[i].feasible,
					"Sector feasibility changed inside a projected slab"
				)
			end
			local root = point.root
			local bin = 1
			for _, q in proof.cuts do
				while R.compare(root.low, q) <= 0 and R.compare(root.high, q) >= 0 do
					assert(not root.exact, "A branch crossed a certified horizontal separator")
					P.refine(root.analysis, root, data.isolation)
				end
				if R.compare(root.high, q) < 0 then
					break
				end
				bin += 1
			end
			mapping[i] = bin
		end
		for _, c in slab.lift.components do
			local first, last = mapping[c.first], mapping[c.last]
			assert(first <= last, "Branch limits changed vertical order")
			local owner
			for _, target in event.lift.components do
				if target.first <= first and target.last >= last then
					assert(not owner, "Event fiber ownership is not unique")
					owner = target
				end
			end
			assert(owner, "Closed feasible cell has an uncovered endpoint interval")
			ctx.connectionsAllocated += 1
			assert(
				ctx.connectionsAllocated <= (options.maxConnections or 16384),
				"Planar connection allocation budget exceeded"
			)
			table.insert(
				connections,
				{ cell = c.cell, eventCell = owner.cell, first = first, last = last, event = eventIndex }
			)
			parents[find(c.cell)] = find(owner.cell)
		end
		return { sample = nearValue, rootMap = mapping }
	end
	local neighborhoods = {}
	for i, event in data.events do
		if
			i > 1 and #data.slabs[i - 1].lift.components > 0
			or i <= #data.slabs and #data.slabs[i].lift.components > 0
		then
			local proof = eventNeighborhood(i)
			neighborhoods[i] = proof
			if i > 1 and #data.slabs[i - 1].lift.components > 0 then
				proof.left = attach(i - 1, i, proof.low, proof)
			end
			if i <= #data.slabs and #data.slabs[i].lift.components > 0 then
				proof.right = attach(i, i, proof.high, proof)
			end
		end
	end
	local groups, components = {}, {}
	for i, cell in cells do
		local root = find(i)
		local group = groups[root]
		if not group then
			group = { index = #components + 1, cells = {}, dimension = 0 }
			groups[root] = group
			table.insert(components, group)
		end
		table.insert(group.cells, i)
		group.dimension = math.max(group.dimension, cell.dimension)
		cell.component = group.index
	end
	data.cells, data.connections, data.components, data.neighborhoods =
		cells, connections, components, neighborhoods
	return data
end
