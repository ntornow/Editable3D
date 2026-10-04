-- Private topology recognizer for a full quadrilateral subdivision level.
local U = require(script.Parent.Util)
local R = {}
local function coloring(vertices, neighbors, work)
	local colors = {}
	for _, seed in vertices do
		if colors[seed] ~= nil then
			continue
		end
		local queue, cursor = { seed }, 1
		colors[seed] = 0
		while cursor <= #queue do
			local v = queue[cursor]
			cursor += 1
			for w in neighbors[v] do
				work(1)
				if colors[w] == nil then
					colors[w] = 1 - colors[v]
					table.insert(queue, w)
				elseif colors[w] == colors[v] then
					return nil
				end
			end
		end
	end
	return colors
end
function R.component(mesh, top, vertices, faces, work)
	for _, fid in faces do
		if #mesh.faces[fid].vertices ~= 4 then
			return {}, "nonquad"
		end
	end
	local bipartite = coloring(vertices, top.neighbors, work)
	if not bipartite then
		return {}, "oddCycle"
	end
	local boundary = {}
	for _, v in vertices do
		for w in top.neighbors[v] do
			work(1)
			if #top.edges[U.edge(v, w)].faces == 1 then
				boundary[v] = true
			end
		end
	end
	local phases = {}
	for edgeColor = 0, 1 do
		local other, diagonal = {}, {}
		for _, v in vertices do
			if bipartite[v] ~= edgeColor then
				table.insert(other, v)
				diagonal[v] = {}
			end
		end
		for _, fid in faces do
			local face = mesh.faces[fid].vertices
			local i = bipartite[face[1]] ~= edgeColor and 1 or 2
			local a, b = face[i], face[i + 2]
			diagonal[a][b], diagonal[b][a] = true, true
		end
		local cross = coloring(other, diagonal, work)
		if not cross then
			continue
		end
		for faceColor = 0, 1 do
			local roles, old, edges, centers = {}, {}, {}, {}
			for _, v in vertices do
				local role = bipartite[v] == edgeColor and 2 or cross[v] == faceColor and 3 or 1
				roles[v] = role
				table.insert(role == 1 and old or role == 2 and edges or centers, v)
			end
			local valid = true
			local edgeEnds, coarseEdges = {}, {}
			for _, v in edges do
				local ends, interior = {}, 0
				for w in top.neighbors[v] do
					work(1)
					if roles[w] == 1 then
						table.insert(ends, w)
					elseif roles[w] == 3 then
						interior += 1
					else
						valid = false
					end
				end
				if #ends ~= 2 or interior ~= (boundary[v] and 1 or 2) then
					valid = false
					break
				end
				table.sort(ends)
				local key = U.edge(ends[1], ends[2])
				if coarseEdges[key] then
					valid = false
					break
				end
				coarseEdges[key] = v
				edgeEnds[v] = ends
			end
			if not valid then
				continue
			end
			local groups = {}
			for _, center in centers do
				if
					boundary[center]
					or U.count(top.neighbors[center]) ~= 4
					or #top.vertexFaces[center] ~= 4
				then
					valid = false
					break
				end
				local successors, refs, star = {}, {}, {}
				for _, fid in top.vertexFaces[center] do
					work(1)
					local face = mesh.faces[fid].vertices
					local i = assert(table.find(face, center))
					local j = (i + 1) % 4 + 1
					local vertex, forward, previous = face[j], face[j % 4 + 1], face[(j + 2) % 4 + 1]
					if
						roles[vertex] ~= 1
						or roles[forward] ~= 2
						or roles[previous] ~= 2
						or successors[vertex]
					then
						valid = false
						break
					end
					local ends = edgeEnds[forward]
					local next = ends[1] == vertex and ends[2] or ends[2] == vertex and ends[1] or nil
					if not next then
						valid = false
						break
					end
					successors[vertex] = next
					refs[vertex] = { fid, j }
					table.insert(star, fid)
				end
				if not valid then
					break
				end
				local ids = U.keys(successors)
				local loop, seen = {}, {}
				local v = ids[1]
				for _ = 1, 4 do
					if not v or seen[v] then
						valid = false
						break
					end
					seen[v] = true
					table.insert(loop, v)
					v = successors[v]
				end
				if not valid or v ~= ids[1] then
					valid = false
					break
				end
				table.sort(star)
				table.insert(groups, { center = center, loop = loop, faces = star, cornerRefs = refs })
			end
			if valid and #groups * 4 == #faces then
				table.insert(phases, {
					roles = roles,
					old = old,
					edges = edges,
					centers = centers,
					groups = groups,
					edgeEnds = edgeEnds,
					coarseEdges = coarseEdges,
				})
			end
		end
	end
	return phases, #phases == 0 and "unrecognized" or nil
end
return R
