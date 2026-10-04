local U = require(script.Parent.Util)
local Graph = {}
Graph.__index = Graph
function Graph.new()
	return setmetatable({ nodes = {}, nextId = 1 }, Graph)
end
function Graph:add(operation, inputs, parameters)
	assert(type(operation) == "function")
	local id = self.nextId
	self.nextId += 1
	self.nodes[id] =
		{ operation = operation, inputs = U.copy(inputs or {}), parameters = U.copy(parameters or {}) }
	return id
end
function Graph:connect(node, slot, source)
	assert(self.nodes[node] and self.nodes[source])
	local old = self.nodes[node].inputs[slot]
	self.nodes[node].inputs[slot] = source
	local ok, err = pcall(function()
		self:order(node)
	end)
	if not ok then
		self.nodes[node].inputs[slot] = old
		error(err, 2)
	end
end
function Graph:order(output)
	local visiting, seen, result = {}, {}, {}
	local function visit(id)
		assert(self.nodes[id], "Unknown graph node")
		assert(not visiting[id], "Graph cycle detected")
		if seen[id] then
			return
		end
		visiting[id] = true
		for _, key in U.keys(self.nodes[id].inputs) do
			visit(self.nodes[id].inputs[key])
		end
		visiting[id] = nil
		seen[id] = true
		table.insert(result, id)
	end
	visit(output)
	return result
end
function Graph:evaluate(output, context)
	local values = {}
	for _, id in self:order(output) do
		local n = self.nodes[id]
		local input = {}
		for slot, source in n.inputs do
			input[slot] = values[source]
		end
		values[id] = n.operation(input, U.copy(n.parameters), context or {})
	end
	return values[output]
end
return Graph
