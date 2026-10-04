local History = {}
History.__index = History
function History.new(mesh, limit)
	return setmetatable(
		{ states = { { label = "Initial", mesh = mesh:clone() } }, cursor = 1, limit = limit or 32 },
		History
	)
end
function History:current()
	return self.states[self.cursor].mesh:clone()
end
function History:apply(label, operation)
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
function History:undo()
	self.cursor = math.max(1, self.cursor - 1)
	return self:current()
end
function History:redo()
	self.cursor = math.min(#self.states, self.cursor + 1)
	return self:current()
end
return History
