-- Complete seam identification of tensor/affine-plane contact cell complexes.
local rootCompare = require(script.Parent.ExactRootCompare)
local intervalContacts = require(script.Parent.ExactIntervalContacts)
local vertexClasses = require(script.Parent.ExactTensorVertexClasses)
return function(data, spans, internals, gluing, parameterVertices)
	local report, R, P, ctx = data.report, data.R, data.P, data.ctx
	local source, options = data.sources[1], data.options
	local stats = {
		requested = true,
		axes = {},
		joins = {},
		components = {},
		unresolved = {},
		nodes = 0,
		pairs = 0,
		topologyCertified = false,
		complete = false,
	}
	report.periodicQuotient = stats
	local function node()
		assert(stats.nodes < (options.maxSeamNodes or 20000), "Tensor seam node budget exceeded")
		stats.nodes += 1
		ctx.visit(1)
	end
	local function pair()
		assert(stats.pairs < (options.maxSeamPairs or 100000), "Tensor seam comparison budget exceeded")
		stats.pairs += 1
		ctx.visit(1)
	end
	local compare = rootCompare(R, P, data.isolation)
	local candidates = {}
	for axis = 1, 2 do
		if source.kind ~= "cyclicSurface" or source[axis == 1 and "cyclicU" or "cyclicV"] == false then
			continue
		end
		local active = report.parameterBox[axis][1] == 0 and report.parameterBox[axis][2] == 1
		local entry =
			{ axis = axis, enabled = active, certified = false, reason = "restrictedRange", identities = {} }
		table.insert(stats.axes, entry)
		if not active then
			continue
		end
		local lower, upper
		for _, span in spans do
			local index = span.indices[axis]
			lower = not lower and index or math.min(lower, index)
			upper = not upper and index or math.max(upper, index)
		end
		local first, last = {}, {}
		for index, span in spans do
			if span.indices[axis] == lower then
				first[span.indices[3 - axis]] = index
			end
			if span.indices[axis] == upper then
				last[span.indices[3 - axis]] = index
			end
		end
		ctx.check("tensorSeamGeometry")
		for other, firstIndex in first do
			local lastIndex = assert(last[other], "Missing paired tensor seam tile")
			node()
			local a, b = gluing.curve(lastIndex, axis, 2), gluing.curve(firstIndex, axis, 1)
			local identity =
				{ firstSpan = lastIndex, secondSpan = firstIndex, equal = true, certified = true }
			for coordinate = 1, 3 do
				node()
				local difference = P.add(
					P.product(a[coordinate], b[4]),
					P.scale(P.product(b[coordinate], a[4]), R.number(-1))
				)
				if #difference > 0 then
					identity.equal, identity.coordinate, identity.difference = false, coordinate, difference
					entry.reason = "differentBoundaryCurves"
					table.insert(
						stats.unresolved,
						{ axis = axis, identity = identity, reason = entry.reason }
					)
					stats.reason = "seamGeometry"
					table.insert(entry.identities, identity)
					return stats
				end
			end
			table.insert(entry.identities, identity)
			table.insert(
				candidates,
				{ axis = axis, firstSpan = lastIndex, secondSpan = firstIndex, certified = true }
			)
		end
		entry.certified, entry.reason = true, "exactBoundaryIdentity"
	end
	local parents = {}
	for i in gluing.components do
		parents[i] = i
	end
	local function owner(i)
		while parents[i] ~= i do
			parents[i] = parents[parents[i]]
			i = parents[i]
		end
		return i
	end
	local function parameterComponent(span, cell)
		local cad = internals[span]
		return cad.components[cad.cells[cell].component].parameterComponent
	end
	ctx.check("tensorSeamContacts")
	for _, join in candidates do
		node()
		local a = gluing.boundary(join.firstSpan, join.axis, 2)
		local b = gluing.boundary(join.secondSpan, join.axis, 1)
		join.contacts = intervalContacts(a, b, compare, pair, node)
		for _, contact in join.contacts do
			parents[owner(parameterComponent(join.firstSpan, contact.first.cell))] =
				owner(parameterComponent(join.secondSpan, contact.second.cell))
		end
		table.insert(stats.joins, join)
	end
	local groups = {}
	for i, component in gluing.components do
		local root = owner(i)
		local group = groups[root]
		if not group then
			group = { index = #stats.components + 1, parameterComponentIndices = {}, dimension = 0 }
			groups[root] = group
			table.insert(stats.components, group)
		end
		table.insert(group.parameterComponentIndices, i)
		group.dimension = math.max(group.dimension, component.dimension)
	end
	stats.vertices = vertexClasses(data, spans, internals, stats.joins, parameterVertices, pair, node)
	stats.topologyCertified = true
	stats.complete = true -- native accuracy is applied by the final public report builder
	return stats
end
