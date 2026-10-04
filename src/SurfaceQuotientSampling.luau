-- Concatenate proved quotient sections, retaining source parameter charts.
local I = require(script.Parent.DirectedInterval)
local function distance(a, b)
	local squared = { 0, 0 }
	for _, axis in { "X", "Y", "Z" } do
		squared = I.add(squared, I.square(I.sub(I.new(a[axis]), I.new(b[axis]))))
	end
	return I.sqrt({ 0, squared[2] })[2]
end
return function(path, components, ctx, tolerance)
	path.samples, path.segments, path.errorBound = {}, {}, 0
	for _, section in path.sections do
		if not components[section.componentIndex].ordered.complete then
			path.complete, path.reason, path.errorBound = false, "sourceApproximation", math.huge
			return
		end
	end
	local parent, source = {}, {}
	local function key(component, sample)
		return component .. ":" .. sample
	end
	local function find(k)
		while parent[k] ~= k do
			parent[k] = parent[parent[k]]
			k = parent[k]
		end
		return k
	end
	for _, section in path.sections do
		local c = section.componentIndex
		for i, sample in components[c].ordered.samples do
			local k = key(c, i)
			parent[k], source[k] = k, sample
			ctx.visit()
		end
	end
	local function endpoint(c, side)
		local segments = components[c].ordered.segments
		return key(c, side == 1 and segments[1].first or segments[#segments].last)
	end
	for _, join in path.seamJoins do
		local a = find(endpoint(join.fromComponent, join.fromEndpoint))
		local b = find(endpoint(join.toComponent, join.toEndpoint))
		parent[b] = a
	end
	local indices = {}
	local function sample(c, i)
		local k = key(c, i)
		local representative = find(k)
		if not indices[representative] then
			local p = source[k]
			table.insert(path.samples, {
				position = p.position,
				positionBox = p.positionBox,
				errorBound = p.errorBound,
				certified = true,
				accurate = true,
				sources = {},
			})
			indices[representative] = #path.samples
		end
		return indices[representative]
	end
	path.complete = true
	for _, section in path.sections do
		local c, direction = section.componentIndex, section.direction
		local original = components[c].ordered
		for offset = 1, #original.segments do
			ctx.check("seamSample")
			ctx.visit(20)
			local index = direction == 1 and offset or #original.segments + 1 - offset
			local segment = original.segments[index]
			local first = direction == 1 and segment.first or segment.last
			local last = direction == 1 and segment.last or segment.first
			local a, b = sample(c, first), sample(c, last)
			local displacement = math.max(
				distance(original.samples[first].position, path.samples[a].position),
				distance(original.samples[last].position, path.samples[b].position)
			)
			local bound = I.add(I.new(segment.errorBound), I.new(displacement))[2]
			local accurate = segment.accurate and bound <= tolerance
			table.insert(path.segments, {
				first = a,
				last = b,
				sourceComponent = c,
				sourceSegment = index,
				direction = direction,
				errorBound = bound,
				endpointDisplacementBound = displacement,
				certified = segment.certified,
				accurate = accurate,
			})
			path.errorBound = math.max(path.errorBound, bound)
			path.complete = path.complete and accurate
		end
	end
	-- Each seam vertex has multiple parameter representatives, even though its
	-- world-space sample is shared. Never replace these with one averaged UV.
	for _, section in path.sections do
		local c = section.componentIndex
		for i in components[c].ordered.samples do
			local index = indices[find(key(c, i))]
			assert(index, "Quotient lost a complete source sample")
			table.insert(path.samples[index].sources, { componentIndex = c, sampleIndex = i })
		end
	end
	for i = 2, #path.segments do
		assert(path.segments[i - 1].last == path.segments[i].first, "Quotient lost shared seam identity")
	end
	if path.closed then
		assert(path.segments[#path.segments].last == path.segments[1].first, "Quotient lost closure")
	end
	path.reason = path.complete and "complete" or "seamApproximation"
end
