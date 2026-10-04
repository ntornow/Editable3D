return function()
	local E = require(script.Parent.Parent)
	local graph = E.Graph.new()
	local primitive = graph:add(function(_, p)
		return E.Primitives.box(p.size)
	end, {}, { size = Vector3.new(1, 2, 1) })
	local bevel = graph:add(function(inputs)
		return E.Modifiers.bevelConvex(inputs.mesh, 0.1)
	end, { mesh = primitive })
	local array = graph:add(function(inputs)
		return E.Modifiers.array(inputs.mesh, 5, CFrame.new(1.5, 0, 0))
	end, { mesh = bevel })
	return graph:evaluate(array), graph
end
