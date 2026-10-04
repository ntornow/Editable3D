--!strict
local U = require(script.Parent.Util)
local Graph = {}
Graph.__index = Graph
-- Node operations and their values are caller-defined, so slots and values are polymorphic.
export type Operation = (inputs: { [any]: any }, parameters: { [any]: any }, context: any) -> any
export type Node = { operation: Operation, inputs: { [any]: number }, parameters: { [any]: any } }
type GraphData = { nodes: { [number]: Node }, nextId: number }
export type Graph = typeof(setmetatable({} :: GraphData, Graph))
function Graph.new(): Graph
	return setmetatable({ nodes = {}, nextId = 1 } :: GraphData, Graph)
end
function Graph.add(
	self: Graph,
	operation: Operation,
	inputs: { [any]: number }?,
	parameters: { [any]: any }?
): number
	assert(type(operation) == "function")
	local id = self.nextId
	self.nextId += 1
	self.nodes[id] =
		{ operation = operation, inputs = U.copy(inputs or {}), parameters = U.copy(parameters or {}) }
	return id
end
function Graph.connect(self: Graph, node: number, slot: any, source: number)
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
function Graph.order(self: Graph, output: number): { number }
	local visiting: { [number]: boolean? }, seen: { [number]: boolean }, result: { number } = {}, {}, {}
	local function visit(id: number)
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
function Graph.evaluate(self: Graph, output: number, context: any?): any
	local values: { [number]: any } = {}
	for _, id in self:order(output) do
		local n = self.nodes[id]
		local input: { [any]: any } = {}
		for slot, source in n.inputs do
			input[slot] = values[source]
		end
		values[id] = n.operation(input, U.copy(n.parameters), context or {})
	end
	return values[output]
end
return Graph
