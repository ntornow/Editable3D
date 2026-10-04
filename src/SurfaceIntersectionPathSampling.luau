-- Sample arcs with algebraic shared endpoints. Endpoint free parameters may be
-- intervals: their outer span still bounds the h/4 derivative chord estimate.
local I = require(script.Parent.DirectedInterval)
local G = require(script.Parent.SurfaceIntersectionGraph)
return function(result, graphs, evaluate, _origin, ctx, limits, stats, point, refine, budget, originalCount)
	local path = {
		closed = result.closed,
		topologyCertified = true,
		complete = true,
		anchors = {},
		arcs = {},
		charts = {},
		joins = {},
		samples = {},
		segments = {},
		errorBound = 0,
	}
	local anchorIndices, sampleIndices = {}, {}
	local chartIndices = {}
	local function chartIndex(index)
		if chartIndices[index] then
			return chartIndices[index]
		end
		local graph = graphs[index]
		local connection
		if graph.source then
			connection =
				{ sourceChart = chartIndex(graph.source), parameterBox = graph.witness, certified = true }
		end
		local record = {
			sourceCurve = index <= originalCount and index or nil,
			parameterAxis = graph.free,
			parameterRange = graph.box[graph.free],
			parameterBox = graph.box,
			isolatingBox = graph.domain,
			contractionNorm = graph.norm,
			connection = connection,
			certified = true,
		}
		table.insert(path.charts, record)
		chartIndices[index] = #path.charts
		return #path.charts
	end
	local function anchorIndex(p)
		if not anchorIndices[p] then
			local copy = table.clone(p)
			copy.chartIndex = chartIndex(p.chartIndex)
			copy.transition = nil
			table.insert(path.anchors, copy)
			anchorIndices[p] = #path.anchors
		end
		return anchorIndices[p]
	end
	local function sampleIndex(p)
		if not sampleIndices[p] then
			local copy = table.clone(p)
			copy.chartIndex = chartIndex(p.chartIndex)
			copy.transition = nil
			table.insert(path.samples, copy)
			sampleIndices[p] = #path.samples
		end
		return sampleIndices[p]
	end
	for _, arc in result.arcs do
		local record = {
			chartIndex = chartIndex(arc.curveIndex),
			direction = arc.direction,
			parameterRange = arc.parameterRange,
			firstAnchor = anchorIndex(arc.first),
			lastAnchor = anchorIndex(arc.last),
			neighborhoods = arc.neighborhoods,
			certified = true,
		}
		table.insert(path.arcs, record)
		local graph = graphs[arc.curveIndex]
		local stack = { { first = arc.first, last = arc.last, depth = 0 } }
		while #stack > 0 do
			ctx.check("orderSample")
			if stats.segments >= limits.maxOrderedSegments then
				path.complete = false
				path.reason = "segments"
				path.errorBound = math.huge
				break
			end
			local node = table.remove(stack)
			local a, b = node.first.parameterBox[graph.free], node.last.parameterBox[graph.free]
			local range = { math.min(a[1], b[1]), math.max(a[2], b[2]) }
			local box = refine(arc.curveIndex, range)
			local tangent
			if box and budget() then
				tangent = G.tangent(graph, box, evaluate, ctx)
			end
			local bound = math.huge
			if tangent then
				local squared = { 0, 0 }
				local h = I.mul(I.sub(I.new(range[2]), I.new(range[1])), { 0.25, 0.25 })
				for axis = 1, 3 do
					squared = I.add(squared, I.square(I.mul(h, { 0, I.width(tangent[axis]) })))
				end
				bound = I.add(
					I.sqrt({ 0, squared[2] }),
					I.new(math.max(node.first.errorBound, node.last.errorBound))
				)[2]
			end
			local accurate = node.first.accurate and node.last.accurate and bound <= limits.tolerance
			local failure
			if not accurate then
				local gap = arc.direction == 1 and { a[2], b[1] } or { b[2], a[1] }
				local middle = I.mid(gap)
				if not box or not tangent then
					failure = "nodes"
				elseif not node.first.accurate or not node.last.accurate then
					failure = "precision"
				elseif node.depth >= limits.maxOrderDepth then
					failure = "depth"
				elseif stats.segments + #stack + 2 > limits.maxOrderedSegments then
					failure = "segments"
				elseif middle <= gap[1] or middle >= gap[2] then
					failure = "precision"
				else
					local p = point(arc.curveIndex, middle)
					if p then
						table.insert(stack, { first = p, last = node.last, depth = node.depth + 1 })
						table.insert(stack, { first = node.first, last = p, depth = node.depth + 1 })
						continue
					end
					failure = "nodes"
				end
			end
			stats.segments += 1
			path.complete = path.complete and accurate
			path.reason = path.reason or failure
			path.errorBound = math.max(path.errorBound, bound)
			table.insert(path.segments, {
				first = sampleIndex(node.first),
				last = sampleIndex(node.last),
				arc = #path.arcs,
				parameterRange = range,
				parameterBox = box,
				tangentBox = tangent,
				errorBound = bound,
				certified = tangent ~= nil,
				accurate = accurate,
				reason = failure,
			})
		end
	end
	local count = #result.arcs
	for i = 1, (result.closed and count or count - 1) do
		local from, to = result.arcs[i], result.arcs[i % count + 1]
		assert(from.last == to.first, "Ordered intersection lost shared endpoint identity")
		local d
		if from.curveIndex == to.curveIndex then
			d = { 1, 1 }
		else
			local transition = assert(from.last.transition, "Ordered intersection lost transition proof")
			if transition.fromChart == from.curveIndex and transition.toChart == to.curveIndex then
				d = transition.parameterDerivative
			else
				assert(transition.fromChart == to.curveIndex and transition.toChart == from.curveIndex)
				d = I.div({ 1, 1 }, transition.parameterDerivative)
			end
		end
		local sign = d[1] > 0 and 1 or d[2] < 0 and -1 or nil
		assert(sign and sign * from.direction == to.direction, "Ordered intersection direction reversal")
		table.insert(path.joins, {
			anchor = anchorIndex(from.last),
			fromArc = i,
			toArc = i % count + 1,
			fromChart = chartIndex(from.curveIndex),
			toChart = chartIndex(to.curveIndex),
			parameterDerivative = d,
			certified = true,
		})
	end
	if result.endpoints then
		path.endpoints = { anchorIndex(result.endpoints[1]), anchorIndex(result.endpoints[2]) }
	end
	return path
end
