-- Canonical native content, independent of vertex/face/normal/UV IDs, face order and vertex welding.
-- Each triangle corner carries its exact float32 position, skin weights, UV, normal, color and alpha;
-- faces are compared as a multiset in winding order. Vertex sharing is not compared: Roblox's asset
-- pipeline stores one vertex per corner, which renders identically. Unreferenced vertices are not
-- content. Fail closed.
local C = {}
local function framed(s)
	return #s .. ":" .. s
end
local function scalar(x)
	assert(x == x and math.abs(x) < math.huge, "Nonfinite native content")
	local b = buffer.create(4)
	buffer.writef32(b, 0, x == 0 and 0 or x)
	return buffer.tostring(b)
end
local function vec(v)
	return scalar(v.X) .. scalar(v.Y) .. (typeof(v) == "Vector3" and scalar(v.Z) or "")
end
local function color(c)
	return scalar(c.R) .. scalar(c.G) .. scalar(c.B)
end
function C.mesh(mesh, budget)
	assert(
		#mesh:GetFacsPoses() == 0 and #mesh:GetFacsCorrectivePoses() == 0,
		"Publishing FACS data requires a dedicated verifier"
	)
	local bones = {}
	local paths = {}
	local vertexIds, faceIds, boneIds = mesh:GetVertices(), mesh:GetFaces(), mesh:GetBones()
	budget:reserve(#vertexIds * 256 + #faceIds * 1024 + #boneIds * 256)
	local boneNames = {}
	local visiting = {}
	local function bone(id)
		if id == 0 then
			return ""
		end
		if boneNames[id] then
			return boneNames[id]
		end
		assert(not visiting[id], "Cyclic native bones")
		visiting[id] = true
		local parent = bone(mesh:GetBoneParent(id))
		local name = mesh:GetBoneName(id)
		local key = parent .. #name .. ":" .. name
		boneNames[id] = key
		visiting[id] = nil
		return key
	end
	for _, id in boneIds do
		local path = bone(id)
		assert(not paths[path], "Ambiguous duplicate bone path")
		paths[path] = true
		budget:step()
		local values = { bone(id), mesh:GetBoneIsVirtual(id) and "V" or "R" }
		for _, v in { mesh:GetBoneCFrame(id):GetComponents() } do
			table.insert(values, scalar(v))
		end
		table.insert(bones, table.concat(values))
	end
	local byId = {}
	for _, id in vertexIds do
		budget:step()
		local weights = {}
		local ids, ws = mesh:GetVertexBones(id), mesh:GetVertexBoneWeights(id)
		for i, b in ids do
			table.insert(weights, framed(bone(b)) .. scalar(ws[i]))
		end
		table.sort(weights)
		local value = vec(mesh:GetPosition(id)) .. #weights .. ":" .. table.concat(weights)
		byId[id] = value
	end
	local faces = {}
	for _, fid in faceIds do
		budget:step()
		local ids, uvs, normals, colors =
			mesh:GetFaceVertices(fid), mesh:GetFaceUVs(fid), mesh:GetFaceNormals(fid), mesh:GetFaceColors(fid)
		assert(#ids == 3, "Expected native triangles")
		local corners = {}
		for i, id in ids do
			corners[i] = framed(byId[id])
				.. vec(mesh:GetUV(uvs[i]))
				.. vec(mesh:GetNormal(normals[i]))
				.. color(mesh:GetColor(colors[i]))
				.. scalar(mesh:GetColorAlpha(colors[i]))
		end
		local rotations = {
			corners[1] .. corners[2] .. corners[3],
			corners[2] .. corners[3] .. corners[1],
			corners[3] .. corners[1] .. corners[2],
		}
		table.sort(rotations)
		table.insert(faces, rotations[1])
	end
	-- Length prefixes prevent ambiguity in variable-length bone/weight records.
	local function section(values)
		table.sort(values)
		local out = {}
		for _, v in values do
			budget:step()
			budget:reserve(#v + 16)
			table.insert(out, #v .. ":" .. v)
		end
		return #values .. ";" .. table.concat(out)
	end
	return section(bones) .. section(faces)
end
function C.image(image, budget)
	local size = image.Size
	budget:image(size.X, size.Y, 4)
	budget:step(size.X * size.Y)
	return size.X .. ":" .. size.Y .. ":" .. buffer.tostring(image:ReadPixelsBuffer(Vector2.zero, size))
end
return C
