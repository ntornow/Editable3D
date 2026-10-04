-- quotient of the profile base and its connected compact ruling fibers.
local intervalContacts = require(script.Parent.ExactIntervalContacts)
local rootCompare = require(script.Parent.ExactRootCompare)
local vertexClasses = require(script.Parent.ExactRuledPairVertexClasses)
return function(result)
	local data, spans, internals, gluing = result.data, result.spans, result.internals, result.gluing
	local R, P, ctx, options = data.R, data.P, data.ctx, data.options
	local stats =
		{ axes = {}, joins = {}, components = {}, unresolved = {}, nodes = 0, pairs = 0, certified = false }
	local function node()
		assert(stats.nodes < (options.maxSeamNodes or 20000), "Ruled pair seam node budget exceeded")
		stats.nodes += 1
		ctx.visit(1)
	end
	local function pair()
		assert(stats.pairs < (options.maxSeamPairs or 100000), "Ruled pair seam pair budget exceeded")
		stats.pairs += 1
		ctx.visit(1)
	end
	local candidates = {}
	for operand, info in { result.first, result.second } do
		local source = data.sources[operand]
		local profile = info.profileAxis
		if source.kind ~= "cyclicSurface" or source[profile == 1 and "cyclicU" or "cyclicV"] == false then
			continue
		end
		local parameterAxis = (operand - 1) * 2 + profile
		local range = data.report.parameterBox[parameterAxis]
		local entry = {
			surface = operand,
			axis = profile,
			baseAxis = operand,
			parameterAxis = parameterAxis,
			enabled = range[1] == 0 and range[2] == 1,
			identities = {},
			certified = false,
		}
		table.insert(stats.axes, entry)
		if not entry.enabled then
			entry.reason = "restrictedRange"
			continue
		end
		local lower, upper
		for _, span in spans do
			local i = span.indices[operand]
			lower = not lower and i or math.min(lower, i)
			upper = not upper and i or math.max(upper, i)
		end
		local first, last = {}, {}
		for index, span in spans do
			if span.indices[operand] == lower then
				first[span.indices[3 - operand]] = index
			end
			if span.indices[operand] == upper then
				last[span.indices[3 - operand]] = index
			end
		end
		for other, firstIndex in first do
			local lastIndex = assert(last[other])
			node()
			local a, b = gluing.curve(lastIndex, operand, 2), gluing.curve(firstIndex, operand, 1)
			local identity = { firstSpan = lastIndex, secondSpan = firstIndex, equal = true }
			for coordinate = 1, 3 do
				node()
				local difference = P.add(
					P.product(a[coordinate], b[4]),
					P.scale(P.product(b[coordinate], a[4]), R.number(-1))
				)
				if #difference > 0 then
					identity.equal, identity.coordinate, identity.difference = false, coordinate, difference
					table.insert(entry.identities, identity)
					table.insert(stats.unresolved, { surface = operand, axis = profile, identity = identity })
					stats.reason = "seamGeometry"
					return stats
				end
			end
			table.insert(entry.identities, identity)
			table.insert(candidates, {
				firstSpan = lastIndex,
				secondSpan = firstIndex,
				axis = operand,
				surface = operand,
				parameterAxis = parameterAxis,
			})
		end
		entry.certified, entry.reason = true, "exactRulingIdentity"
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
	local function parameterComponent(spanIndex, cell)
		local cad = internals[spanIndex]
		return cad.components[cad.cells[cell].component].parameterComponent
	end
	local compare = rootCompare(R, P, data.isolation)
	for _, join in candidates do
		node()
		join.contacts = intervalContacts(
			gluing.boundary(join.firstSpan, join.axis, 2),
			gluing.boundary(join.secondSpan, join.axis, 1),
			compare,
			pair,
			node
		)
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
		group.dimension = math.max(group.dimension, component.fullDimension)
	end
	stats.vertices =
		vertexClasses(data, spans, result.anchors, stats.joins, result.parameterVertices, pair, node)
	stats.certified, stats.reason = true, "complete"
	return stats
end
