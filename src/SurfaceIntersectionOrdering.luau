-- Validated continuation in the original closed parameter rectangle.
-- Exact joins are shared root identities, not rounded coordinate welds.
local I = require(script.Parent.DirectedInterval)
local G = require(script.Parent.SurfaceIntersectionGraph)
local function subset(a, b)
	for axis = 1, 4 do
		if a[axis][1] < b[axis][1] or a[axis][2] > b[axis][2] then
			return false
		end
	end
	return true
end
local function disjoint(a, b)
	for axis = 1, 4 do
		if a[axis][2] < b[axis][1] or b[axis][2] < a[axis][1] then
			return true
		end
	end
	return false
end
local function ahead(a, b, direction)
	return direction == 1 and b[1] > a[2] or direction == -1 and b[2] < a[1]
end
return function(graphs, report, evaluate, origin, initial, ctx, limits)
	local originalCount = #graphs
	graphs = table.clone(graphs)
	local stats = { requested = true, complete = false, visited = 0, steps = 0, segments = 0 }
	report.ordering = stats
	report.parameterTopologyCertified = false
	report.orderedComplete = false
	ctx.check("order")
	if not report.parameterComponentsCertified then
		stats.reason = "components"
		return
	end
	local reason: string? = nil
	local frontier: any = nil
	local function budget()
		if stats.visited >= limits.maxOrderNodes then
			reason = "nodes"
			return false
		end
		stats.visited += 1
		ctx.check("order")
		return true
	end
	local function refine(index, range)
		if not budget() then
			return nil
		end
		return G.refine(graphs[index], range, evaluate, ctx, limits.maxIterations)
	end
	local function relativeInterior(box, domain, endpointAxis)
		if not subset(box, domain) then
			return false
		end
		for axis = 1, 4 do
			if
				axis ~= endpointAxis
				and (
					domain[axis][1] > initial[axis][1] and box[axis][1] <= domain[axis][1]
					or domain[axis][2] < initial[axis][2] and box[axis][2] >= domain[axis][2]
				)
			then
				return false
			end
		end
		return true
	end
	local function point(index, t)
		local box = refine(index, { t, t })
		if not box then
			return nil
		end
		local p = G.position(box, evaluate, origin)
		if not p then
			reason = "precision"
			return nil
		end
		p.sourceCurve, p.chartIndex = index <= originalCount and index or nil, index
		p.parameterAxis, p.parameter = graphs[index].free, t
		p.parameterErrorBound = 0
		for axis = 1, 4 do
			local delta = I.sub(box[axis], I.new(p.parameters[axis]))
			p.parameterErrorBound = math.max(p.parameterErrorBound, math.abs(delta[1]), math.abs(delta[2]))
		end
		p.accurate = p.errorBound <= limits.tolerance
		for axis = 1, 4 do
			p.accurate = p.accurate and I.width(box[axis]) <= limits.parameterTolerance
		end
		return p
	end
	local function regular(index, range)
		local leaves, stack = {}, { { range = range, depth = 0 } }
		while #stack > 0 do
			local node = table.remove(stack)
			local box = refine(index, node.range)
			if not box then
				return nil
			end
			-- Strictly ordered endpoints put every arc-interior free value in
			-- the chart interior. A free endpoint may instead use the adjoining
			-- chart's neighborhood (notably the seed chart at loop closure).
			if relativeInterior(box, graphs[index].domain, graphs[index].free) then
				table.insert(leaves, { parameterRange = node.range, parameterBox = box, certified = true })
			else
				local middle = I.mid(node.range)
				if node.depth >= limits.maxOrderDepth then
					reason = "regularity"
					return nil
				end
				if middle <= node.range[1] or middle >= node.range[2] then
					reason = "precision"
					return nil
				end
				table.insert(stack, { range = { middle, node.range[2] }, depth = node.depth + 1 })
				table.insert(stack, { range = { node.range[1], middle }, depth = node.depth + 1 })
			end
		end
		return leaves
	end
	local function piece(index, first, last, direction, seed, closing)
		local graph = graphs[index]
		local a, b = first.parameterBox[graph.free], last.parameterBox[graph.free]
		if
			not subset(first.parameterBox, graph.domain)
			or not subset(last.parameterBox, graph.domain)
			or not ahead(a, b, direction)
		then
			reason = "order"
			return nil
		end
		local range = { math.min(a[1], b[1]), math.max(a[2], b[2]) }
		local proof = regular(index, range)
		if not proof then
			return nil
		end
		-- A first return to the seed is essential: a multiply traversed loop is
		-- not a simple component parameterization. Every earlier piece excludes it.
		if first ~= seed and not closing then
			local knownOutside = subset(seed.parameterBox, graph.domain)
				and (
					seed.parameterBox[graph.free][2] < range[1]
					or seed.parameterBox[graph.free][1] > range[2]
				)
			if not knownOutside then
				knownOutside = true
				for _, leaf in proof do
					knownOutside = knownOutside and disjoint(seed.parameterBox, leaf.parameterBox)
				end
			end
			if not knownOutside then
				reason = "seed"
				return nil
			end
		end
		return {
			curveIndex = index,
			first = first,
			last = last,
			direction = direction,
			parameterRange = range,
			neighborhoods = proof,
			certified = true,
		}
	end
	local function trace(indices, seedIndex, seed, direction)
		local arcs, used, index, current = {}, {}, seedIndex, seed
		while true do
			if stats.steps >= limits.maxOrderSteps then
				reason = "steps"
				return nil, arcs
			end
			stats.steps += 1
			ctx.check("order")
			local graph = graphs[index]
			frontier = {
				sourceCurve = index <= originalCount and index or nil,
				parameterBox = current.parameterBox,
				parameterAxis = graph.free,
				isolatingBox = graph.domain,
				direction = direction,
			}
			local from = current.parameterBox[graph.free]
			if
				current ~= seed
				and subset(seed.parameterBox, graph.domain)
				and ahead(from, seed.parameterBox[graph.free], direction)
			then
				if not budget() then
					return nil, arcs
				end
				local _, derivatives = G.tangent(graph, seed.parameterBox, evaluate, ctx)
				local d = derivatives and derivatives[graphs[seedIndex].free]
				local sign = d and (d[1] > 0 and 1 or d[2] < 0 and -1 or nil)
				if not sign or direction * sign ~= (arcs[1] and arcs[1].direction or direction) then
					reason = "orientation"
					return nil, arcs
				end
				local arc = piece(index, current, seed, direction, seed, true)
				if not arc then
					return nil, arcs
				end
				table.insert(arcs, arc)
				seed.transition =
					{ fromChart = index, toChart = seedIndex, parameterDerivative = d, certified = true }
				return { closed = true, arcs = arcs }
			end
			local far = graph.box[graph.free][direction == 1 and 2 or 1]
			if far == initial[graph.free][direction == 1 and 2 or 1] then
				local endpoint = point(index, far)
				if not endpoint then
					return nil, arcs
				end
				local arc = piece(index, current, endpoint, direction, seed, false)
				if not arc then
					return nil, arcs
				end
				endpoint.boundary = { axis = graph.free, side = direction, parameter = far, certified = true }
				table.insert(arcs, arc)
				return { closed = false, arcs = arcs, endpoint = endpoint }
			end
			local near = from[direction == 1 and 2 or 1]
			local chosen
			for _, fraction in
				{ 0.875, 0.75, 0.9375, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625, 0.0078125, 0.00390625 }
			do
				local t = near + (far - near) * fraction
				if not ahead(from, { t, t }, direction) or t == far then
					continue
				end
				local anchor = point(index, t)
				if not anchor then
					return nil, arcs
				end
				if not relativeInterior(anchor.parameterBox, graph.domain) then
					continue
				end
				if not budget() then
					return nil, arcs
				end
				local _, derivative = G.tangent(graph, anchor.parameterBox, evaluate, ctx)
				if not derivative then
					continue
				end
				local best
				for _, target in indices do
					ctx.visit(4)
					if
						target == index or not relativeInterior(anchor.parameterBox, graphs[target].domain)
					then
						continue
					end
					local axis = graphs[target].free
					local d = derivative[axis]
					local sign = d[1] > 0 and 1 or d[2] < 0 and -1 or nil
					if not sign then
						continue
					end
					local forward = direction * sign
					local previous = used[target]
					if previous then
						local progresses = previous.direction == forward
							and ahead(previous.range, anchor.parameterBox[axis], forward)
						local closes = subset(seed.parameterBox, graphs[target].domain)
							and ahead(anchor.parameterBox[axis], seed.parameterBox[axis], forward)
						if not progresses and not closes then
							continue
						end
					end
					local targetRange = graphs[target].box[axis]
					local room = forward == 1 and targetRange[2] - anchor.parameterBox[axis][2]
						or anchor.parameterBox[axis][1] - targetRange[1]
					if room <= 0 then
						continue
					end
					local closes = subset(seed.parameterBox, graphs[target].domain)
						and ahead(anchor.parameterBox[axis], seed.parameterBox[axis], forward)
					local boundary = targetRange[forward == 1 and 2 or 1]
						== initial[axis][forward == 1 and 2 or 1]
					-- Avoid alternating between nearly exhausted overlapping charts.
					-- A fresh bridge is preferable when neither chart offers room.
					if room < I.width(targetRange) * 0.25 and not closes and not boundary then
						continue
					end
					local score = room / math.max(math.abs(d[1]), math.abs(d[2]), 1e-30)
					if not best or score > best.score then
						best = { target = target, direction = forward, score = score, derivative = d }
					end
				end
				if best then
					chosen = { anchor = anchor, next = best }
					break
				end
			end
			if not chosen then
				-- Closed search charts can meet only at an endpoint. Construct a
				-- fresh parametric existence proof across that point before crossing.
				local center = point(index, far)
				local bridge
				if center and budget() then
					local _, derivative = G.tangent(graph, center.parameterBox, evaluate, ctx)
					if derivative then
						local axes = { 1, 2, 3, 4 }
						table.sort(axes, function(a, b)
							return math.abs(I.mid(derivative[a])) > math.abs(I.mid(derivative[b]))
						end)
						for _, free in axes do
							if I.zero(derivative[free]) then
								continue
							end
							local slopes = {}
							for axis = 1, 4 do
								slopes[axis] = I.div(derivative[axis], derivative[free])
							end
							for trial = 0, 7 do
								if not budget() then
									return nil, arcs
								end
								local h = math.min(
									(initial[free][2] - initial[free][1]) / 16,
									math.max(
										I.width(graph.box[graph.free]) * math.abs(I.mid(derivative[free])) / 4,
										(initial[free][2] - initial[free][1]) / 128
									)
								) / 2 ^ trial
								local domain = {}
								for axis = 1, 4 do
									local slope = slopes[axis]
									local margin = axis == free and h
										or h
											* math.max(0.5, 2 * math.abs(slope[1]), 2 * math.abs(slope[2]))
									domain[axis] = {
										math.max(initial[axis][1], center.parameterBox[axis][1] - margin),
										math.min(initial[axis][2], center.parameterBox[axis][2] + margin),
									}
								end
								local step = G.step(domain, free, evaluate(domain), evaluate, ctx)
								for _ = 1, 3 do
									if step.unique or not step.image or not step.norm or step.norm >= 1 then
										break
									end
									if not budget() then
										return nil, arcs
									end
									for axis = 1, 4 do
										if axis ~= free then
											local hull = I.hull(domain[axis], step.image[axis])
											local pad = math.max(
												I.width(hull) * 0.25,
												(initial[axis][2] - initial[axis][1]) * 1e-12
											)
											domain[axis] = {
												math.max(initial[axis][1], hull[1] - pad),
												math.min(initial[axis][2], hull[2] + pad),
											}
										end
									end
									step = G.step(domain, free, evaluate(domain), evaluate, ctx)
								end
								if step.unique and relativeInterior(center.parameterBox, domain) then
									step.domain, step.source, step.witness =
										domain, index, center.parameterBox
									table.insert(graphs, step)
									table.insert(indices, #graphs)
									stats.addedCharts = (stats.addedCharts or 0) + 1
									bridge = true
									break
								end
							end
							if bridge then
								break
							end
						end
					end
				end
				if bridge then
					continue
				end
				reason = reason or "transition"
				return nil, arcs
			end
			local arc = piece(index, current, chosen.anchor, direction, seed, false)
			if not arc then
				return nil, arcs
			end
			chosen.anchor.transition = {
				fromChart = index,
				toChart = chosen.next.target,
				parameterDerivative = chosen.next.derivative,
				certified = true,
			}
			table.insert(arcs, arc)
			used[index] = { range = chosen.anchor.parameterBox[graph.free], direction = direction }
			current, index, direction = chosen.anchor, chosen.next.target, chosen.next.direction
		end
	end
	local topologyComplete, approximationComplete = true, true
	for _, component in report.components do
		reason, frontier = nil, nil
		local seed, seedIndex
		local candidates = table.clone(component.curveIndices)
		table.sort(candidates, function(a, b)
			local ga, gb = graphs[a], graphs[b]
			local x, y = I.width(ga.box[ga.free]) * (1 - ga.norm), I.width(gb.box[gb.free]) * (1 - gb.norm)
			return x == y and a < b or x > y
		end)
		for _, index in candidates do
			local p = point(index, I.mid(graphs[index].box[graphs[index].free]))
			if not p then
				break
			end
			if relativeInterior(p.parameterBox, graphs[index].domain) then
				seed, seedIndex = p, index
				break
			end
		end
		local result, partial
		if seed then
			result, partial = trace(candidates, seedIndex, seed, 1)
			if result and not result.closed then
				local reverse, back = trace(candidates, seedIndex, seed, -1)
				if not reverse or reverse.closed then
					result = nil
					partial = back
					reason = reason or "continuation"
				else
					local joined = {}
					for i = #reverse.arcs, 1, -1 do
						local arc = reverse.arcs[i]
						arc.first, arc.last, arc.direction = arc.last, arc.first, -arc.direction
						table.insert(joined, arc)
					end
					for _, arc in result.arcs do
						table.insert(joined, arc)
					end
					result.arcs = joined
					result.endpoints = { reverse.endpoint, result.endpoint }
				end
			end
		end
		if not result then
			component.ordered = {
				topologyCertified = false,
				complete = false,
				reason = reason or "regularity",
				partialArcCount = partial and #partial or 0,
				frontier = frontier,
			}
			topologyComplete, approximationComplete = false, false
			continue
		end
		local path = require(script.Parent.SurfaceIntersectionPathSampling)(
			result,
			graphs,
			evaluate,
			origin,
			ctx,
			limits,
			stats,
			point,
			refine,
			budget,
			originalCount
		)
		component.ordered = path
		approximationComplete = approximationComplete and path.complete
	end
	-- Every accepted piece has relative-open root-graph neighborhoods. The
	-- signed joins fill both local sides; boundary endpoints fill their half
	-- neighborhoods. Thus the compact path image is open and closed in its
	-- already certified connected component. It is the whole component. The
	-- first-return seed exclusions and orientation prevent multiple traversal.
	report.parameterTopologyCertified = topologyComplete
	report.componentTopologyCertified = topologyComplete
	report.orderedComplete = topologyComplete and approximationComplete
	stats.complete = report.orderedComplete
	stats.reason = stats.complete and "complete"
		or topologyComplete and "approximation"
		or reason
		or "topology"
end
