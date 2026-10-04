-- Replay only a queried local refinement chain, starting from stored native bits.
local U = require(script.Parent.Util)
return function(R, source, config, visit)
	local refinement = require(script.Parent.ExactSubdivisionRefinement)(R, visit)
	local chain, history = {}, source.normalHistory
	while history and not history.initial do
		visit(1)
		table.insert(chain, history)
		history = history.previous
	end
	local initial = history and history.initial or source
	if config.normalAllocate then
		config.normalAllocate(3 * U.count(initial.vertices) + U.count(initial.edges) + U.count(initial.sharp))
	end
	local m, reason = refinement.snapshot(initial)
	if not m then
		return nil, reason
	end
	for i = #chain, 1, -1 do
		local step = chain[i]
		if step.faces then
			local cropped = { vertices = {}, faces = {}, edges = {}, sharp = {} }
			for fid in step.faces do
				local face = assert(m.faces[fid], "Exact history lost cropped face")
				cropped.faces[fid] = face
				for j, vertex in face do
					visit(1)
					cropped.vertices[vertex], cropped.sharp[vertex] = m.vertices[vertex], m.sharp[vertex]
					local key = U.edge(vertex, face[j % #face + 1])
					cropped.edges[key] = m.edges[key]
				end
			end
			m = cropped
		else
			m = refinement.refine(m, config, visit)
		end
	end
	-- Exact and bounded-numerical paths must retain the same deterministic IDs.
	assert(
		U.count(m.vertices) == U.count(source.vertices) and U.count(m.faces) == U.count(source.faces),
		"Exact refinement history topology mismatch"
	)
	for fid, face in source.faces do
		local exact = assert(m.faces[fid])
		assert(#face == #exact, "Exact refinement history face mismatch")
		for i, vertex in face do
			visit(1)
			assert(vertex == exact[i], "Exact refinement history incidence mismatch")
		end
	end
	return m, nil, #chain
end
