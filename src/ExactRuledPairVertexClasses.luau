-- equality of existing ruling-fiber vertices across certified base edges.
local rootCompare = require(script.Parent.ExactRootCompare)
return function(data, spans, anchors, joins, seed, visitPair, visitNode)
	local R = data.R
	local compare = rootCompare(R, data.P, data.isolation)
	local parents = {}
	for i in anchors do
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
		local span = spans[spanIndex]
		local out = {}
		for _, i in span.anchorIndices do
			visitNode()
			local anchor = anchors[i]
			local base = anchor.base
			if axis == 1 then
				if base.s.exact and R.equal(base.s.low, span.cad.domain[1][side]) then
					assert(base.lift.scalar == R, "Rational boundary coefficient field required")
					table.insert(out, { index = i, root = base.t, pattern = anchor.boundaryMask })
				end
			elseif base.t.exact and R.equal(base.lift.asRational(base.t.low), span.cad.domain[2][side]) then
				table.insert(out, { index = i, root = base.s, pattern = anchor.boundaryMask })
			end
		end
		return out
	end
	for _, join in joins do
		local a, b = boundary(join.firstSpan, join.axis, 2), boundary(join.secondSpan, join.axis, 1)
		for _, x in a do
			for _, y in b do
				visitPair()
				if x.pattern == y.pattern and compare(x.root, y.root) == 0 then
					parents[owner(x.index)] = owner(y.index)
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
