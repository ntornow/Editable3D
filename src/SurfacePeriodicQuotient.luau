-- Quotient of certified parameter paths by exact source-periodic seam identities.
-- All seam contacts must be isolated transverse endpoints in the rectangle.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
local G = require(script.Parent.SurfaceIntersectionGraph)
local geometry = require(script.Parent.SurfacePeriodicGeometry)
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
return function(report, inputs, models, evaluate, initial, ctx, limits)
	local stats = {
		requested = true,
		complete = false,
		topologyCertified = false,
		axes = {},
		joins = {},
		paths = {},
		unresolved = {},
		nodes = 0,
		pairs = 0,
	}
	report.periodicQuotient = stats
	report.quotientTopologyCertified, report.quotientComplete = false, false
	ctx.check("seamGeometry")
	local active, geometryComplete = {}, true
	for surfaceIndex, input in inputs do
		if input.kind ~= "cyclicSurface" then
			continue
		end
		for direction, flag in { "cyclicU", "cyclicV" } do
			if input[flag] == false then
				continue
			end
			local axis = (surfaceIndex - 1) * 2 + direction
			local enabled = initial[axis][1] == 0 and initial[axis][2] == 1
			local certified, reason, identity = false, "restrictedRange", nil
			if enabled then
				certified, reason, identity = geometry(input, models[surfaceIndex].source, direction, ctx)
				active[axis] = true
				geometryComplete = geometryComplete and certified
			end
			table.insert(stats.axes, {
				axis = axis,
				enabled = enabled,
				certified = certified,
				reason = reason,
				identity = identity,
			})
		end
	end
	if not report.parameterTopologyCertified then
		stats.reason = "parameterTopology"
		return
	end
	if #report.components > 0 and not geometryComplete then
		stats.reason = "seamGeometry"
		return
	end
	local reason
	local function budget()
		if stats.nodes >= limits.maxSeamNodes then
			reason = "nodes"
			return false
		end
		stats.nodes += 1
		ctx.check("seamContacts")
		ctx.visit()
		return true
	end
	local endpoints, graphs = {}, {}
	local function graph(component, chart)
		graphs[component] = graphs[component] or {}
		if not graphs[component][chart] then
			if not budget() then
				return nil
			end
			local c = report.components[component].ordered.charts[chart]
			local g = G.step(c.isolatingBox, c.parameterAxis, evaluate(c.isolatingBox), evaluate, ctx)
			assert(g.unique, "Quotient could not reproduce its source graph certificate")
			g.domain = c.isolatingBox
			graphs[component][chart] = g
		end
		return graphs[component][chart]
	end
	for componentIndex, component in report.components do
		local path = component.ordered
		if path.endpoints then
			for side, anchor in path.endpoints do
				local p = path.anchors[anchor]
				table.insert(endpoints, {
					component = componentIndex,
					side = side,
					anchor = anchor,
					point = p,
					axis = p.boundary.axis,
					seam = active[p.boundary.axis] == true,
				})
			end
		end
		for arcIndex, arc in path.arcs do
			local chart = path.charts[arc.chartIndex]
			for axis in active do
				local function allowedEnd(value)
					if not path.endpoints then
						return false
					end
					for _, anchor in path.endpoints do
						if anchor == arc.firstAnchor or anchor == arc.lastAnchor then
							local p = path.anchors[anchor]
							if p.boundary.axis == axis and p.boundary.parameter == value then
								return true
							end
						end
					end
					return false
				end
				local stack = {}
				for _, n in arc.neighborhoods do
					table.insert(stack, { range = n.parameterRange, box = n.parameterBox, depth = 0 })
				end
				while #stack > 0 do
					local node = table.remove(stack)
					if not budget() then
						table.insert(stats.unresolved, {
							component = componentIndex,
							arc = arcIndex,
							axis = axis,
							parameterBox = node.box,
							reason = reason,
						})
						stats.reason = reason
						return
					end
					local range = node.box[axis]
					if range[1] > 0 and range[2] < 1 then
						continue
					end
					if
						axis == chart.parameterAxis
						and (range[1] > 0 or allowedEnd(0))
						and (range[2] < 1 or allowedEnd(1))
					then
						continue
					end
					local middle = I.mid(node.range)
					if
						node.depth >= limits.maxSeamDepth
						or middle <= node.range[1]
						or middle >= node.range[2]
					then
						table.insert(stats.unresolved, {
							component = componentIndex,
							arc = arcIndex,
							axis = axis,
							parameterBox = node.box,
							reason = "seamContact",
						})
						stats.reason = "seamContact"
						return
					end
					local g = graph(componentIndex, arc.chartIndex)
					if not g then
						stats.reason = reason
						return
					end
					for _, subrange in { { node.range[1], middle }, { middle, node.range[2] } } do
						if not budget() then
							stats.reason = reason
							return
						end
						local box = G.refine(g, subrange, evaluate, ctx, limits.maxIterations)
						table.insert(stack, { range = subrange, box = box, depth = node.depth + 1 })
					end
				end
			end
		end
	end
	stats.contactsCertified = true
	local paired, links = {}, {}
	for i, endpoint in endpoints do
		if not endpoint.seam or paired[i] then
			continue
		end
		local p = endpoint.point
		local translated = U.copy(p.parameterBox)
		local targetValue = 1 - p.boundary.parameter
		translated[endpoint.axis] = { targetValue, targetValue }
		local found
		for j, other in endpoints do
			ctx.check("seamPairs")
			if stats.pairs >= limits.maxSeamPairs then
				stats.frontier = {
					component = endpoint.component,
					endpoint = endpoint.side,
					axis = endpoint.axis,
					parameterBox = translated,
					nextCandidate = j,
				}
				stats.reason = "pairs"
				return
			end
			stats.pairs += 1
			ctx.visit(4)
			if
				i == j
				or paired[j]
				or other.axis ~= endpoint.axis
				or not other.seam
				or other.point.boundary.parameter ~= targetValue
			then
				continue
			end
			if disjoint(translated, other.point.parameterBox) then
				continue
			end
			local chart = report.components[other.component].ordered.charts[other.point.chartIndex]
			if subset(translated, chart.isolatingBox) then
				found = j
				local join = {
					fromComponent = endpoint.component,
					fromEndpoint = endpoint.side,
					toComponent = other.component,
					toEndpoint = other.side,
					axis = endpoint.axis,
					shift = targetValue - p.boundary.parameter,
					parameterBox = translated,
					targetChart = other.point.chartIndex,
					certified = true,
				}
				table.insert(stats.joins, join)
				paired[i], paired[j], links[i], links[j] = j, i, #stats.joins, #stats.joins
				break
			end
		end
		if not found then
			table.insert(stats.unresolved, {
				component = endpoint.component,
				endpoint = endpoint.side,
				axis = endpoint.axis,
				parameterBox = translated,
				reason = "endpointIdentity",
			})
			stats.reason = "endpointIdentity"
			return
		end
	end
	local endpointIndex = {}
	for i, e in endpoints do
		endpointIndex[e.component] = endpointIndex[e.component] or {}
		endpointIndex[e.component][e.side] = i
	end
	local used = {}
	local function append(startComponent, startSide)
		local path = { sections = {}, seamJoins = {}, topologyCertified = true, closed = false }
		local component, side = startComponent, startSide
		while true do
			ctx.visit()
			assert(not used[component], "Quotient revisited a path before closure")
			used[component] = true
			table.insert(path.sections, { componentIndex = component, direction = side == 1 and 1 or -1 })
			local original = report.components[component].ordered
			if original.closed then
				path.closed = true
				break
			end
			local exitIndex = endpointIndex[component][3 - side]
			local nextIndex = paired[exitIndex]
			if not nextIndex then
				path.endpoints = {
					{ componentIndex = startComponent, endpoint = startSide },
					{ componentIndex = component, endpoint = 3 - side },
				}
				break
			end
			local nextEndpoint = endpoints[nextIndex]
			local proof = stats.joins[links[exitIndex]]
			table.insert(path.seamJoins, {
				fromComponent = component,
				fromEndpoint = 3 - side,
				toComponent = nextEndpoint.component,
				toEndpoint = nextEndpoint.side,
				axis = proof.axis,
				shift = nextEndpoint.point.boundary.parameter - endpoints[exitIndex].point.boundary.parameter,
				proof = links[exitIndex],
				certified = true,
			})
			component, side = nextEndpoint.component, nextEndpoint.side
			if component == startComponent and side == startSide then
				path.closed = true
				break
			end
		end
		require(script.Parent.SurfaceQuotientSampling)(path, report.components, ctx, limits.tolerance)
		table.insert(stats.paths, path)
	end
	-- Start interval chains at an unpaired (nonperiodic) boundary. Remaining
	-- graph components have degree two everywhere and therefore are circles.
	for i, endpoint in endpoints do
		if not paired[i] and not used[endpoint.component] then
			append(endpoint.component, endpoint.side)
		end
	end
	for i in report.components do
		if not used[i] then
			append(i, 1)
		end
	end
	stats.topologyCertified, stats.complete = true, true
	for _, path in stats.paths do
		stats.complete = stats.complete and path.complete
	end
	stats.componentCount = #stats.paths
	stats.reason = stats.complete and "complete" or "approximation"
	report.quotientTopologyCertified, report.quotientComplete = true, stats.complete
end
