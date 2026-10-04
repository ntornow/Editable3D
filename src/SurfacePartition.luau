-- Private bounded patch partition, optionally skipping refinement outside a trim.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local bound = require(script.Parent.SurfacePatchBound)
return function(surface, options, active)
	options = options or {}
	local tolerance = options.tolerance or 0.01
	local maxLeaves, maxDepth = options.maxLeaves or 10000, options.maxDepth or 16
	assert(U.finite(tolerance) and tolerance > 0, "Positive tessellation tolerance required")
	U.integer(maxLeaves, 1)
	U.integer(maxDepth, 0)
	assert(maxDepth <= 24, "Adaptive depth must be at most 24")
	local stack = N.bezierPatches(surface)
	assert(#stack <= maxLeaves, "Initial Bezier patch budget exceeded")
	for _, node in stack do
		node.depth = 0
	end
	local leaves, visited, maximum, converged, retained = {}, 0, 0, true, 0
	while #stack > 0 do
		local node = table.remove(stack)
		node.active = not active or active(node)
		local error = node.active and bound(node.surface) or 0
		if error > tolerance and node.depth < maxDepth and #stack + #leaves + 4 <= maxLeaves then
			local left, right = N.splitSurface(node.surface, "U", 0.5)
			local a, b = N.splitSurface(left, "V", 0.5)
			local c, d = N.splitSurface(right, "V", 0.5)
			local um, vm = (node.u0 + node.u1) * 0.5, (node.v0 + node.v1) * 0.5
			for _, child in
				{
					{ a, node.u0, um, node.v0, vm },
					{ b, node.u0, um, vm, node.v1 },
					{ c, um, node.u1, node.v0, vm },
					{ d, um, node.u1, vm, node.v1 },
				}
			do
				table.insert(stack, {
					surface = child[1],
					u0 = child[2],
					u1 = child[3],
					v0 = child[4],
					v1 = child[5],
					depth = node.depth + 1,
				})
			end
			visited += 1
		else
			node.errorBound = error
			table.insert(leaves, node)
			maximum = math.max(maximum, error)
			converged = converged and error <= tolerance
			if node.active then
				retained += 1
			end
		end
		if options.checkpoint then
			options.checkpoint({ stage = "refine", leaves = #stack + #leaves, refinements = visited })
		end
	end
	return leaves,
		{
			errorBound = maximum,
			converged = converged,
			refinements = visited,
			leaves = retained,
			partitionLeaves = #leaves,
			discardedLeaves = #leaves - retained,
		}
end
