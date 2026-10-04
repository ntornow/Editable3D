-- Private stable joined source identities shared by both Boolean methods.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
return function(a, b, offset)
	offset = offset or 0
	assert(type(offset) == "number" and U.finite(offset), "Finite Boolean material offset required")
	A.validate(a)
	A.validate(b)
	local right = b
	if offset ~= 0 then
		right = b:clone()
		for _, face in right.faces do
			assert(type(face.material) == "number", "Material offset requires numeric material IDs")
			face.material += offset
		end
	end
	local joined = require(script.Parent.Topology).join({ a, right })
	local forward, inverse = {}, { vertex = {}, edge = {}, face = {}, corner = {} }
	local vertexId, faceId = 0, 0
	for index, mesh in { a, b } do
		local name = index == 1 and "a" or "b"
		local maps = { vertex = {}, edge = {}, face = {}, corner = {} }
		forward[name] = maps
		local function map(domain, oldId, newId)
			maps[domain][oldId] = newId
			inverse[domain][newId] = { operand = name, id = oldId }
		end
		for _, id in U.keys(mesh.vertices) do
			vertexId += 1
			map("vertex", id, vertexId)
		end
		for _, fid in U.keys(mesh.faces) do
			faceId += 1
			map("face", fid, faceId)
			local face = mesh.faces[fid]
			for i, v in face.vertices do
				map("corner", fid .. ":" .. i, faceId .. ":" .. i)
				local nextId = face.vertices[i % #face.vertices + 1]
				map("edge", U.edge(v, nextId), U.edge(maps.vertex[v], maps.vertex[nextId]))
			end
		end
	end
	assert(
		vertexId == U.count(joined.vertices) and faceId == U.count(joined.faces),
		"Joined Boolean source mapping mismatch"
	)
	return joined, forward, inverse
end
