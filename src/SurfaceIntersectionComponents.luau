-- Connected components of the finite union of certified parameter graphs.
-- Spatial proximity and overlapping interval boxes never prove a connection.
local I = require(script.Parent.DirectedInterval)
local G = require(script.Parent.SurfaceIntersectionGraph)
local function intersection(a, b)
	local out = {}
	for axis = 1, 4 do
		out[axis] = I.intersect(a[axis], b[axis])
		if not out[axis] then
			return nil
		end
	end
	return out
end
local function subset(a, b)
	for axis = 1, 4 do
		if a[axis][1] < b[axis][1] or a[axis][2] > b[axis][2] then
			return false
		end
	end
	return true
end
return function(graphs, curves, evaluate, ctx, limits, rootCoverageComplete)
	ctx.check("connect")
	local n, parent, cache = #graphs, {}, {}
	local stats = { complete = false, pairs = 0, visited = 0, excludedPairs = 0, witnessTests = 0 }
	local connections, unknown, groupsLeft = {}, {}, n
	for i, curve in curves do
		parent[i], cache[i] = i, {}
		for _, sample in curve.samples do
			cache[i][sample.parameter] = sample.parameterBox
		end
	end
	local function find(i)
		local root = i
		while parent[root] ~= root do
			root = parent[root]
		end
		while parent[i] ~= i do
			local nextIndex = parent[i]
			parent[i], i = root, nextIndex
		end
		return root
	end
	local function witness(source, target, box)
		ctx.visit(4)
		stats.witnessTests += 1
		if not subset(box, graphs[target].domain) then
			return nil
		end
		return {
			sourceCurve = source,
			targetCurve = target,
			parameterBox = box,
			parameterAxis = graphs[source].free,
			parameterRange = box[graphs[source].free],
			certified = true,
			proof = "Existing graph roots contained in the other isolating domain",
		}
	end
	local function restrict(index, range)
		if range[1] == range[2] and cache[index][range[1]] then
			return cache[index][range[1]]
		end
		if stats.visited >= limits.maxConnectionNodes then
			return nil
		end
		stats.visited += 1
		ctx.check("connect")
		local box = G.refine(graphs[index], range, evaluate, ctx, limits.maxIterations)
		if range[1] == range[2] then
			cache[index][range[1]] = box
		end
		return box
	end
	local function pair(first, last, overlap)
		-- Whole-graph inclusion is also a valid nonempty shared-root witness.
		local proof = witness(first, last, graphs[first].box) or witness(last, first, graphs[last].box)
		if proof then
			return proof
		end
		for _, direction in { { first, last }, { last, first } } do
			local source, target = direction[1], direction[2]
			local range = overlap[graphs[source].free]
			for _, t in { I.mid(range), range[1], range[2] } do
				local box = restrict(source, { t, t })
				if box then
					proof = witness(source, target, box)
					if proof then
						return proof
					end
				end
			end
		end
		-- Only A's free projection of the overlap can intersect B. Its restricted
		-- boxes cover every such A-root, so excluding every leaf proves disjointness.
		local free = graphs[first].free
		local stack = { { range = overlap[free], depth = 0 } }
		local reason
		while #stack > 0 do
			local node = table.remove(stack)
			local box = restrict(first, node.range)
			if not box then
				return nil, "nodes"
			end
			ctx.visit(4)
			if not intersection(box, graphs[last].box) then
				continue
			end
			proof = witness(first, last, box)
			if proof then
				return proof
			end
			local middle = I.mid(node.range)
			local point = restrict(first, { middle, middle })
			if point then
				proof = witness(first, last, point)
				if proof then
					return proof
				end
			end
			if node.depth >= limits.maxConnectionDepth then
				reason = reason or "depth"
			elseif middle <= node.range[1] or middle >= node.range[2] then
				reason = reason or "precision"
			else
				table.insert(stack, { range = { middle, node.range[2] }, depth = node.depth + 1 })
				table.insert(stack, { range = { node.range[1], middle }, depth = node.depth + 1 })
			end
		end
		return nil, reason
	end
	local frontier
	for i = 1, n do
		if groupsLeft <= 1 or frontier then
			break
		end
		for j = i + 1, n do
			if groupsLeft <= 1 then
				break
			end
			local a, b = find(i), find(j)
			if a == b then
				continue
			end
			if stats.pairs >= limits.maxConnectionPairs then
				frontier = { firstCurve = i, secondCurve = j, reason = "pairs" }
				break
			end
			stats.pairs += 1
			ctx.visit(4)
			ctx.check("connect")
			local overlap = intersection(graphs[i].box, graphs[j].box)
			if not overlap then
				stats.excludedPairs += 1
				continue
			end
			local proof, reason = pair(i, j, overlap)
			if proof then
				parent[math.max(a, b)] = math.min(a, b)
				groupsLeft -= 1
				proof.firstCurve, proof.secondCurve = i, j
				table.insert(connections, proof)
			elseif reason then
				table.insert(unknown, {
					firstCurve = i,
					secondCurve = j,
					parameterBox = overlap,
					reason = reason,
					certified = false,
				})
			else
				stats.excludedPairs += 1
			end
		end
	end
	local retained = {}
	for _, candidate in unknown do
		if find(candidate.firstCurve) ~= find(candidate.secondCurve) then
			table.insert(retained, candidate)
		end
	end
	stats.complete = #retained == 0 and not frontier
	stats.reason = stats.complete and "complete" or frontier and "pairs" or "unresolved"
	stats.frontier = frontier
	local certified = stats.complete and rootCoverageComplete
	local components, indices = {}, {}
	for i, graph in graphs do
		local root = find(i)
		local index = indices[root]
		if not index then
			index = #components + 1
			indices[root] = index
			table.insert(components, {
				curveIndices = {},
				connectionIndices = {},
				parameterBox = {},
				connected = true,
				isolated = certified,
				certified = certified,
			})
		end
		local component = components[index]
		table.insert(component.curveIndices, i)
		for axis = 1, 4 do
			component.parameterBox[axis] = component.parameterBox[axis]
					and I.hull(component.parameterBox[axis], graph.box[axis])
				or graph.box[axis]
		end
		curves[i].component = index
	end
	for i, connection in connections do
		table.insert(components[curves[connection.firstCurve].component].connectionIndices, i)
	end
	stats.connections, stats.unresolvedPairs = #connections, #retained
	return {
		components = components,
		connections = connections,
		unresolvedConnections = retained,
		connectivity = stats,
		parameterComponentsCertified = certified,
		componentCount = certified and #components or nil,
		componentSpace = "Original closed four-dimensional parameter domain; periodic seams are distinct",
	}
end
