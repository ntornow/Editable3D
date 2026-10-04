-- Private chart-local endpoint data and edge-domain transfer for a collapse.
local U = require(script.Parent.Util)
local Edit = require(script.Parent.MeshEditCore)
local Seams = require(script.Parent.AttributeSeams)
local Patch = require(script.Parent.AttributePatch)
local Attributes = require(script.Parent.AttributeCore)
return function(source, a, b, t, topology, options)
	local maps = { vertex = { [a] = { { a, 1 - t }, { b, t } } }, edge = {}, corner = {} }
	local removed = { vertex = { [b] = true }, edge = {}, face = {}, corner = {} }
	local edge = assert(topology.edges[U.edge(a, b)])
	local adjacent = {}
	for _, fid in edge.faces do
		local f = source.faces[fid]
		local indices = {}
		for i, id in f.vertices do
			if id == a or id == b then
				indices[id] = i
			end
			removed.corner[fid .. ":" .. i] = true
		end
		table.insert(adjacent, { face = fid, indices = indices })
		removed.face[fid] = true
	end
	table.sort(adjacent, function(x, y)
		return x.face < y.face
	end)
	local corners = {}
	for _, id in { a, b } do
		for _, fid in topology.vertexFaces[id] do
			if removed.face[fid] then
				continue
			end
			for i, vertex in source.faces[fid].vertices do
				if vertex ~= id then
					continue
				end
				local other = id == a and b or a
				local ownWeight = id == a and 1 - t or t
				local cr, refs = { { fid, i, 1 } }, { { fid .. ":" .. i, 1 } }
				for _, candidate in adjacent do
					if Seams.same(source, fid, i, candidate.face, candidate.indices[id], options, false) then
						cr = {
							{ fid, i, ownWeight },
							{ candidate.face, candidate.indices[other], 1 - ownWeight },
						}
						refs = {
							{ fid .. ":" .. i, ownWeight },
							{ candidate.face .. ":" .. candidate.indices[other], 1 - ownWeight },
						}
						break
					end
				end
				maps.corner[fid .. ":" .. i] = refs
				corners[fid] = corners[fid] or {}
				corners[fid][i] = Edit.corner(source, cr)
			end
		end
	end
	local edgeKeys = {}
	for _, id in { a, b } do
		for other in topology.neighbors[id] do
			edgeKeys[U.edge(id, other)] = true
		end
	end
	for _, key in U.keys(edgeKeys) do
		local old = topology.edges[key]
		removed.edge[key] = true
		local x, y = old.a == b and a or old.a, old.b == b and a or old.b
		if x == y then
			continue
		end
		local newKey = U.edge(x, y)
		maps.edge[newKey] = maps.edge[newKey] or {}
		table.insert(maps.edge[newKey], { key, (old.a == b or old.b == b) and t or 1 - t })
	end
	for _, refs in maps.edge do
		if #refs == 1 then
			refs[1][2] = 1
		end
	end
	local apply = Patch(source, maps, removed)
	local weights, groups = {}, {}
	for _, entry in { { a, 1 - t }, { b, t } } do
		for bone, value in source.weights[entry[1]] or {} do
			weights[bone] = (weights[bone] or 0) + value * entry[2]
		end
	end
	for name, group in source.groups do
		groups[name] = (group[a] or 0) * (1 - t) + (group[b] or 0) * t
	end
	return function(target)
		apply(target)
		for fid, values in corners do
			for i, value in values do
				target.faces[fid].corners[i] = value
			end
		end
		target.weights[a], target.weights[b] = weights, nil
		for name, value in groups do
			target.groups[name][a], target.groups[name][b] = value, nil
		end
		Attributes.prune(target)
	end
end
