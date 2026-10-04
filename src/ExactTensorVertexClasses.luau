-- Equivalence classes of existing anchor samples on certified tile boundaries.
-- Continuous interval joins remain the authority where only one side has an anchor.
local rootCompare = require(script.Parent.ExactRootCompare)
return function(data, spans, internals, joins, seed, visitPair, visitNode)
	local compare = rootCompare(data.R, data.P, data.isolation)
	local parents = {}
	for i in data.report.vertices do
		parents[i] = i
	end
	local function owner(i)
		while parents[i] ~= i do
			parents[i] = parents[parents[i]]
			i = parents[i]
		end
		return i
	end
	if seed then
		for _, class in seed.classes do
			for _, i in class.vertexIndices do
				parents[owner(i)] = owner(class.vertexIndices[1])
			end
		end
	end
	local function boundary(spanIndex, axis, side)
		local out = {}
		local span, cad = spans[spanIndex], internals[spanIndex]
		for _, anchor in span.anchors do
			visitNode()
			local event = cad.events[anchor.event]
			if axis == 1 and anchor.event == (side == 1 and 1 or #cad.events) then
				table.insert(out, { index = anchor.vertex, root = event.lift.points[anchor.point].root })
			elseif axis == 2 and anchor.point == (side == 1 and 1 or #event.lift.points) then
				table.insert(out, { index = anchor.vertex, root = event.root })
			end
		end
		return out
	end
	for _, join in joins do
		local first = boundary(join.firstSpan, join.axis, 2)
		local second = boundary(join.secondSpan, join.axis, 1)
		for _, a in first do
			for _, b in second do
				visitPair()
				if compare(a.root, b.root) == 0 then
					parents[owner(a.index)] = owner(b.index)
				end
			end
		end
	end
	local groups, classes, map = {}, {}, {}
	for i in parents do
		local root = owner(i)
		local class = groups[root]
		if not class then
			class = { index = #classes + 1, representative = i, vertexIndices = {} }
			groups[root] = class
			table.insert(classes, class)
		end
		table.insert(class.vertexIndices, i)
		map[i] = class.index
	end
	return { classes = classes, map = map }
end
