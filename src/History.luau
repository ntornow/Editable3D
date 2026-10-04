--!strict
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
local History = {}
History.__index = History
export type State = { label: string, mesh: Mesh }
type HistoryData = { states: { State }, cursor: number, limit: number }
export type History = typeof(setmetatable({} :: HistoryData, History))
function History.new(mesh: Mesh, limit: number?): History
	return setmetatable(
		{ states = { { label = "Initial", mesh = mesh:clone() } }, cursor = 1, limit = limit or 32 } :: HistoryData,
		History
	)
end
function History.current(self: History): Mesh
	return self.states[self.cursor].mesh:clone()
end
function History.apply(self: History, label: string, operation: (Mesh) -> Mesh): Mesh
	local candidate = operation(self:current())
	assert(candidate and candidate.validate, "Operation must return mesh")
	local report = candidate:validate()
	assert(report.valid, "Operation produced invalid geometry")
	while #self.states > self.cursor do
		table.remove(self.states)
	end
	table.insert(self.states, { label = label, mesh = candidate:clone() })
	if #self.states > self.limit then
		table.remove(self.states, 1)
	end
	self.cursor = #self.states
	return self:current()
end
function History.undo(self: History): Mesh
	self.cursor = math.max(1, self.cursor - 1)
	return self:current()
end
function History.redo(self: History): Mesh
	self.cursor = math.min(#self.states, self.cursor + 1)
	return self:current()
end
return History
