-- Private reconstruction of separated sheets or a selected welded boundary.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Edit = require(script.Parent.MeshEditCore)
return function(data, selection, separate, options)
	options = options or {}
	local source = data.source
	local out = source:clone()
	out.vertices, out.faces, out.weights, out.groups = {}, {}, {}, {}
	for name in source.groups do
		out.groups[name] = {}
	end
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = { vertex = false, edge = false, face = false, corner = false },
	}
	local vertexIds, recordsById, keptSourceFace, faceMap = {}, {}, {}, {}
	local nodeMap, fragmentFaces = {}, {}
	local vertices, faces = 0, 0
	local reversed = {}
	local maxVertices = U.integer(options.maxVertices or 100000, 3)
	local maxFaces = U.integer(options.maxFaces or 200000, 1)
	local blend = options.vertexBlend or "average"
	assert(blend == "first" or blend == "average", "Vertex blend must be first or average")
	local edgeSources = {}
	for fi, fragment in data.fragments do
		local orientation = selection and selection[fi] or (not selection and 1)
		if not orientation or orientation == 0 then
			continue
		end
		data.visit("build")
		local context = data.triangles[fragment.triangle]
		local ids, corners, cornerMaps, ordered = {}, {}, {}, {}
		for k = 1, 3 do
			local r = fragment.records[orientation < 0 and 4 - k or k]
			ordered[k] = r
			local key = separate and r.binding or tostring(r.node)
			local id = vertexIds[key]
			if not id then
				vertices += 1
				assert(vertices <= maxVertices, "Intersection reconstruction vertex budget exceeded")
				local original = separate and r.original or (not separate and data.nodes[r.node].originals[1])
				if original then
					id = original
				else
					id = out.nextVertex
					out.nextVertex += 1
				end
				assert(not out.vertices[id], "Reconstructed vertex ID collision")
				out.vertices[id] = data.nodes[r.node].position
				vertexIds[key], recordsById[id] = id, {}
				nodeMap[r.node] = nodeMap[r.node] or {}
				table.insert(nodeMap[r.node], id)
			end
			ids[k] = id
			recordsById[id][context.index] = recordsById[id][context.index] or r.weights
			local cr, cm = {}, {}
			for i, weight in r.weights do
				if weight > 0 then
					table.insert(cr, { context.face, context.corners[i], weight })
					table.insert(cm, { context.face .. ":" .. context.corners[i], weight })
				end
			end
			corners[k], cornerMaps[k] = Edit.corner(source, cr), cm
			if orientation < 0 and corners[k].tangentSign then
				corners[k].tangentSign *= -1
			end
		end
		faces += 1
		assert(faces <= maxFaces, "Intersection reconstruction face budget exceeded")
		assert(
			ids[1] ~= ids[2] and ids[2] ~= ids[3] and ids[3] ~= ids[1],
			"Welding collapses a retained fragment"
		)
		local fid
		if not keptSourceFace[context.face] then
			fid, keptSourceFace[context.face] = context.face, true
			out.faces[fid] =
				{ vertices = ids, corners = corners, material = source.faces[context.face].material }
		else
			fid = out:addFace(ids, corners, source.faces[context.face].material)
		end
		reversed[fid] = orientation < 0
		fragmentFaces[fi] = fid
		faceMap[context.face] = faceMap[context.face] or {}
		table.insert(faceMap[context.face], fid)
		maps.face[fid] = { { context.face, 1 } }
		for i = 1, 3 do
			maps.corner[fid .. ":" .. i] = cornerMaps[i]
			local j = i % 3 + 1
			local key = U.edge(ids[i], ids[j])
			for edge in ordered[i].sourceEdges do
				if ordered[j].sourceEdges[edge] and data.sourceEdges[edge] then
					edgeSources[key] = edgeSources[key] or {}
					edgeSources[key][edge] = true
				end
			end
		end
	end
	for id, records in recordsById do
		local refs = {}
		for _, tid in U.keys(records) do
			local context = data.triangles[tid]
			for i, weight in records[tid] do
				if weight > 0 then
					table.insert(refs, { context.vertices[i], weight })
				end
			end
			if blend == "first" then
				break
			end
		end
		maps.vertex[id] = refs
	end
	for edge, sources in edgeSources do
		maps.edge[edge] = {}
		for _, sourceEdge in U.keys(sources) do
			table.insert(maps.edge[edge], { sourceEdge, 1 })
		end
	end
	local regularization = data.report.regularization
	if regularization and regularization.maps then
		maps = require(script.Parent.SourceMapCompose)(maps, regularization.maps, data.visit)
		source = data.originalSource
		faceMap = {}
		for fid, refs in maps.face do
			for _, ref in refs do
				faceMap[ref[1]] = faceMap[ref[1]] or {}
				table.insert(faceMap[ref[1]], fid)
			end
		end
		for _, ids in faceMap do
			table.sort(ids)
		end
		for fid, face in out.faces do
			for i in face.corners do
				local refs = {}
				for _, reference in maps.corner[fid .. ":" .. i] do
					local original, index = reference[1]:match("^(%d+):(%d+)$")
					assert(original and index, "Invalid original corner correspondence")
					refs[#refs + 1] = { tonumber(original), tonumber(index), reference[2] }
				end
				face.corners[i] = Edit.corner(source, refs)
				if reversed[fid] and face.corners[i].tangentSign then
					face.corners[i].tangentSign *= -1
				end
			end
		end
	end
	A.transfer(source, out, maps)
	A.vertexData(source, out, maps.vertex)
	out:recalculateNormals()
	out.revision += 1
	return out,
		{
			maps = maps,
			faceMap = faceMap,
			nodeMap = nodeMap,
			fragmentFaces = fragmentFaces,
			validation = out:validate(),
			vertices = vertices,
			faces = faces,
			vertexBlend = blend,
		}
end
