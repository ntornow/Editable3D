-- Reusable length intervals and bounded inverse queries on positive NURBS curves.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local Bounds = require(script.Parent.CurveBounds)
local A = {}
local function push(heap, node)
	local i = #heap + 1
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent].gap >= node.gap then
			break
		end
		heap[i], i = heap[parent], parent
	end
	heap[i] = node
end
local function pop(heap)
	local first, last = heap[1], table.remove(heap)
	if #heap > 0 then
		local i = 1
		while i * 2 <= #heap do
			local child = i * 2
			if child < #heap and heap[child + 1].gap > heap[child].gap then
				child += 1
			end
			if heap[child].gap <= last.gap then
				break
			end
			heap[i], i = heap[child], child
		end
		heap[i] = last
	end
	return first
end
function A.prepare(curve, options)
	options = table.clone(options or {})
	local tolerance = options.tolerance or 1e-4
	assert(
		type(tolerance) == "number" and U.finite(tolerance) and tolerance > 0,
		"Positive arc length tolerance required"
	)
	local maxNodes = U.integer(options.maxNodes or 10000, 1)
	local maxLeaves = U.integer(options.maxLeaves or 20000, 1)
	local maxDepth = U.integer(options.maxDepth or 24, 1)
	local maxIterations = U.integer(options.maxIterations or 48, 1)
	local maxSamples = U.integer(options.maxSamples or 10000, 2)
	local maxWork = U.integer(options.maxWork or 1000000, 1)
	assert(maxDepth <= 52 and maxIterations <= 64, "Arc length parameter resolution budget exceeded")
	local prepared = N.compileCurve(curve)
	if options.checkpoint then
		options.checkpoint({ stage = "prepare", visited = 0 })
	end
	local heap, blocked, visited = {}, {}, 0
	local lower, upper = 0, 0
	local pieces = N.bezierSegments(curve)
	assert(#pieces <= maxLeaves, "Initial length segment budget exceeded")
	local function add(node)
		node.lower, node.upper = Bounds.length(node.curve)
		node.gap = node.upper - node.lower
		lower += node.lower
		upper += node.upper
		push(heap, node)
	end
	for _, piece in pieces do
		piece.depth = 0
		add(piece)
	end
	while
		upper - lower > tolerance / 4
		and #heap > 0
		and visited < maxNodes
		and #heap + #blocked < maxLeaves
	do
		local node = pop(heap)
		if node.depth >= maxDepth then
			table.insert(blocked, node)
		else
			local a, b = N.split(node.curve, 0.5)
			local mid = (node.first + node.last) * 0.5
			lower -= node.lower
			upper -= node.upper
			add({ curve = a, first = node.first, last = mid, depth = node.depth + 1 })
			add({ curve = b, first = mid, last = node.last, depth = node.depth + 1 })
			visited += 1
		end
		if options.checkpoint then
			options.checkpoint({ stage = "prepare", visited = visited })
		end
	end
	local leaves = table.clone(blocked)
	for _, leaf in heap do
		table.insert(leaves, leaf)
	end
	table.sort(leaves, function(a, b)
		return a.first < b.first
	end)
	lower, upper = 0, 0
	for _, leaf in leaves do
		leaf.beforeLower, leaf.beforeUpper = lower, upper
		lower += leaf.lower
		upper += leaf.upper
	end
	local total = (lower + upper) / 2
	local lengthConverged = upper - lower <= tolerance / 4
	local function prefix(t)
		if t == 0 then
			return 0, 0
		end
		if t == 1 then
			return lower, upper
		end
		local lo, hi = 1, #leaves
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if leaves[mid].last < t then
				lo = mid + 1
			else
				hi = mid
			end
		end
		local leaf = leaves[lo]
		if t == leaf.first then
			return leaf.beforeLower, leaf.beforeUpper
		end
		if t == leaf.last then
			return leaf.beforeLower + leaf.lower, leaf.beforeUpper + leaf.upper
		end
		local left = N.split(leaf.curve, (t - leaf.first) / (leaf.last - leaf.first))
		local a, b = Bounds.length(left)
		return leaf.beforeLower + a, leaf.beforeUpper + b
	end
	local function inverse(value, normalized)
		if options.checkpoint then
			options.checkpoint({ stage = "inverse", iteration = 0 })
		end
		assert(
			type(value) == "number" and U.finite(value) and value >= 0,
			"Nonnegative finite length required"
		)
		assert(value <= (normalized and 1 or upper), "Requested length exceeds curve interval")
		local targetLo, targetHi =
			normalized and value * lower or value, normalized and value * upper or value
		local lo, hi, iterations = 0, 1, 0
		local t = value == 0 and 0 or (normalized and value == 1 and 1 or 0.5)
		local pLo, pHi, errorBound
		while true do
			pLo, pHi = prefix(t)
			errorBound = math.max(math.abs(pLo - targetHi), math.abs(pHi - targetLo))
			if normalized and (value == 0 or value == 1) then
				errorBound = 0
			end
			if errorBound <= tolerance or iterations >= maxIterations then
				break
			end
			if pHi < targetLo then
				lo = t
			elseif pLo > targetHi then
				hi = t
			else
				break
			end -- Interval uncertainty prevents a justified bracket update.
			local nextT = (lo + hi) / 2
			if nextT == t then
				break
			end
			t = nextT
			iterations += 1
			if options.checkpoint then
				options.checkpoint({ stage = "inverse", iteration = iterations })
			end
		end
		local derivative = prepared.derivatives(t)
		return {
			parameter = t,
			position = derivative.position,
			tangent = derivative.first,
			lowerBound = pLo,
			upperBound = pHi,
			length = (pLo + pHi) / 2,
			targetLowerBound = targetLo,
			targetUpperBound = targetHi,
			errorBound = errorBound,
			converged = errorBound <= tolerance,
			iterations = iterations,
			parameterLowerBound = lo,
			parameterUpperBound = hi,
			reason = errorBound > tolerance
					and (iterations >= maxIterations and "Iteration budget exhausted" or "Length interval unresolved")
				or nil,
		}
	end
	local function sample(count)
		U.integer(count, 2)
		assert(
			count <= maxSamples and count * (maxIterations + 1) <= maxWork,
			"Arc length sampling budget exceeded"
		)
		local points, parameters, results = {}, {}, {}
		local maximum, converged = 0, true
		for i = 0, count - 1 do
			local r = inverse(i / (count - 1), true)
			points[i + 1], parameters[i + 1], results[i + 1] = r.position, r.parameter, r
			maximum = math.max(maximum, r.errorBound)
			converged = converged and r.converged
		end
		return points,
			{
				parameters = parameters,
				results = results,
				errorBound = maximum,
				converged = converged,
				length = total,
			}
	end
	return table.freeze({
		length = total,
		lowerBound = lower,
		upperBound = upper,
		errorBound = (upper - lower) / 2,
		converged = lengthConverged,
		reason = not lengthConverged
				and (visited >= maxNodes and "Node budget exhausted" or (#leaves >= maxLeaves and "Leaf budget exhausted" or "Depth limit reached"))
			or nil,
		segments = #leaves,
		visited = visited,
		atLength = function(distance)
			return inverse(distance, false)
		end,
		atFraction = function(fraction)
			return inverse(fraction, true)
		end,
		sample = sample,
	})
end
function A.parameter(curve, distance, options)
	return A.prepare(curve, options).atLength(distance)
end
function A.sample(curve, count, options)
	return A.prepare(curve, options).sample(count)
end
return A
