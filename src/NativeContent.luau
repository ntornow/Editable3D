-- Canonical native content, independent of vertex/face/normal/UV IDs, face order and vertex welding.
-- Each triangle corner carries its exact float32 position, skin weights, UV, color and alpha, plus its
-- normal; faces are compared as a multiset in winding order. Vertex sharing is not compared: Roblox's
-- asset pipeline stores one vertex per corner, which renders identically. Unreferenced vertices are not
-- content. Normals are compared within NORMAL_TOLERANCE because the pipeline quantizes them (observed
-- error up to ~8.4e-4); everything else is exact. Fail closed.
local C = {}
C.NORMAL_TOLERANCE = 2e-3
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
		local corners, cornerNormals = {}, {}
		for i, id in ids do
			corners[i] = framed(byId[id])
				.. vec(mesh:GetUV(uvs[i]))
				.. color(mesh:GetColor(colors[i]))
				.. scalar(mesh:GetColorAlpha(colors[i]))
			local n = mesh:GetNormal(normals[i])
			assert(n.X == n.X and n.Y == n.Y and n.Z == n.Z, "Nonfinite native content")
			cornerNormals[i] = n
		end
		-- Canonical starting corner: the smallest exact rotation; normals follow the same order.
		local best, start = nil, 1
		for r = 1, 3 do
			local key = corners[r] .. corners[r % 3 + 1] .. corners[(r + 1) % 3 + 1]
			if best == nil or key < best then
				best, start = key, r
			end
		end
		table.insert(faces, {
			key = best,
			normals = {
				cornerNormals[start],
				cornerNormals[start % 3 + 1],
				cornerNormals[(start + 1) % 3 + 1],
			},
		})
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
	-- Faces sort by exact key; equal keys sort by normals so tolerant pairing is stable.
	table.sort(faces, function(a, b)
		if a.key ~= b.key then
			return a.key < b.key
		end
		for i = 1, 3 do
			local p, q = a.normals[i], b.normals[i]
			if p.X ~= q.X then
				return p.X < q.X
			elseif p.Y ~= q.Y then
				return p.Y < q.Y
			elseif p.Z ~= q.Z then
				return p.Z < q.Z
			end
		end
		return false
	end)
	local keys, flat = {}, {}
	for _, f in faces do
		table.insert(keys, f.key)
		for _, n in f.normals do
			table.insert(flat, n)
		end
	end
	-- `section` sorts in place; keys are already in face order, so sorting keeps that order.
	return { exact = section(bones) .. section(keys), normals = flat }
end
-- Mesh snapshots: exact parts equal and every normal within tolerance. Strings (images) compare exactly.
function C.equivalent(a, b, tolerance)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	if a.exact ~= b.exact or #a.normals ~= #b.normals then
		return false
	end
	local limit = tolerance or C.NORMAL_TOLERANCE
	for i, n in a.normals do
		if (n - b.normals[i]).Magnitude > limit then
			return false
		end
	end
	return true
end
-- Compact digests of snapshots for the publish resume ledger, which only has to notice that a source changed
-- between attempts: 64 bits (two Murmur3-style lanes over the bytes, 32-bit words) plus the length. Mesh snapshots
-- digest their exact part and their normals' float bits.
local function mul32(a: number, b: number): number
	local lo = bit32.band(a, 0xffff) * b
	local hi = bit32.band(bit32.rshift(a, 16) * b, 0xffff)
	return bit32.band(lo + hi * 65536, 0xffffffff)
end
local function fmix(h: number): number
	h = mul32(bit32.bxor(h, bit32.rshift(h, 16)), 0x85ebca6b)
	h = mul32(bit32.bxor(h, bit32.rshift(h, 13)), 0xc2b2ae35)
	return bit32.bxor(h, bit32.rshift(h, 16))
end
local function lanes(b: buffer, h1: number, h2: number): (number, number)
	local n = buffer.len(b)
	local words = n // 4
	for i = 0, words - 1 do
		local k = buffer.readu32(b, i * 4)
		local k1 = mul32(bit32.lrotate(mul32(k, 0xcc9e2d51), 15), 0x1b873593)
		h1 = bit32.band(mul32(bit32.lrotate(bit32.bxor(h1, k1), 13), 5) + 0xe6546b64, 0xffffffff)
		local k2 = mul32(bit32.lrotate(mul32(k, 0x239b961b), 17), 0xab0e9789)
		h2 = bit32.band(mul32(bit32.lrotate(bit32.bxor(h2, k2), 15), 5) + 0x38b34ae5, 0xffffffff)
	end
	local tail = 0
	for i = words * 4, n - 1 do
		tail = tail * 256 + buffer.readu8(b, i)
	end
	h1 = fmix(bit32.bxor(h1, mul32(tail, 0xcc9e2d51), n))
	h2 = fmix(bit32.bxor(h2, mul32(tail, 0x239b961b), n))
	return h1, h2
end
function C.digest(snapshot: any): string
	if type(snapshot) == "string" then
		local h1, h2 = lanes(buffer.fromstring(snapshot), 0x9747b28c, 0x5bd1e995)
		return string.format("%d:%08x%08x", #snapshot, h1, h2)
	end
	assert(type(snapshot) == "table" and type(snapshot.exact) == "string", "Unknown snapshot")
	local normals = snapshot.normals
	local packed = buffer.create(#normals * 12)
	for i, v in normals do
		buffer.writef32(packed, (i - 1) * 12, v.X)
		buffer.writef32(packed, (i - 1) * 12 + 4, v.Y)
		buffer.writef32(packed, (i - 1) * 12 + 8, v.Z)
	end
	local e1, e2 = lanes(buffer.fromstring(snapshot.exact), 0x9747b28c, 0x5bd1e995)
	local n1, n2 = lanes(packed, e1, e2)
	return string.format("m%d/%d:%08x%08x", #snapshot.exact, #normals, n1, n2)
end
function C.image(image, budget)
	local size = image.Size
	budget:image(size.X, size.Y, 4)
	budget:step(size.X * size.Y)
	return size.X .. ":" .. size.Y .. ":" .. buffer.tostring(image:ReadPixelsBuffer(Vector2.zero, size))
end
return C
