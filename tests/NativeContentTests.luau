local C = require(script.Parent.NativeContent)
local B = require(script.Parent.OperationBudget)
local harness = require(script.Parent.TestHarness)
local function fixture(order)
	local m = {
		vertices = order or { 1, 2, 3 },
		face = { 1, 2, 3 },
		positions = { Vector3.zero, Vector3.xAxis, Vector3.yAxis },
		uvs = { Vector2.zero, Vector2.xAxis, Vector2.yAxis },
		normal = Vector3.zAxis,
		color = Color3.new(1, 1, 1),
		alpha = 1,
	}
	function m:GetFacsPoses()
		return {}
	end
	function m:GetFacsCorrectivePoses()
		return {}
	end
	function m:GetBones()
		return {}
	end
	function m:GetVertices()
		return self.vertices
	end
	function m:GetVertexBones()
		return {}
	end
	function m:GetVertexBoneWeights()
		return {}
	end
	function m:GetPosition(id)
		return self.positions[id]
	end
	function m:GetFaces()
		return { 100 }
	end
	function m:GetFaceVertices()
		return self.face
	end
	function m:GetFaceUVs()
		return self.face
	end
	function m:GetFaceNormals()
		return self.face
	end
	function m:GetFaceColors()
		return self.face
	end
	function m:GetUV(id)
		return self.uvs[id]
	end
	function m:GetNormal()
		return self.normal
	end
	function m:GetColor()
		return self.color
	end
	function m:GetColorAlpha()
		return self.alpha
	end
	return m
end
local function fingerprint(m)
	return C.mesh(m, B.new(nil, "fingerprint"))
end
-- Two triangles sharing the edge (2,3). Welded: 4 shared vertices. Split: one vertex per corner,
-- as Roblox's asset pipeline stores published meshes. `orphan` adds an unreferenced vertex.
local function pair(split, orphan)
	local corners = {
		{ Vector3.zero, Vector2.zero },
		{ Vector3.xAxis, Vector2.xAxis },
		{ Vector3.yAxis, Vector2.yAxis },
		{ Vector3.yAxis, Vector2.yAxis },
		{ Vector3.xAxis, Vector2.xAxis },
		{ Vector3.new(1, 1, 0), Vector2.one },
	}
	local m = { positions = {}, uvs = {}, vertices = {}, faces = {}, triangles = {} }
	local weld = { 1, 2, 3, 3, 2, 4 }
	for i, c in corners do
		local id = split and i or weld[i]
		m.positions[id], m.uvs[i] = c[1], c[2]
		m.vertices[id] = id
	end
	if orphan then
		m.positions[99], m.vertices[99] = Vector3.new(5, 5, 5), 99
	end
	m.triangles = { [10] = { 1, 2, 3 }, [20] = { 4, 5, 6 } }
	local list = {}
	for id in m.vertices do
		table.insert(list, id)
	end
	function m:GetFacsPoses()
		return {}
	end
	function m:GetFacsCorrectivePoses()
		return {}
	end
	function m:GetBones()
		return {}
	end
	function m:GetVertices()
		return list
	end
	function m:GetVertexBones()
		return {}
	end
	function m:GetVertexBoneWeights()
		return {}
	end
	function m:GetPosition(id)
		return self.positions[id]
	end
	function m:GetFaces()
		local ids = {}
		for id in self.triangles do
			table.insert(ids, id)
		end
		return ids
	end
	function m:GetFaceVertices(fid)
		local out = {}
		for i, corner in self.triangles[fid] do
			out[i] = split and corner or weld[corner]
		end
		return out
	end
	function m:GetFaceUVs(fid)
		return self.triangles[fid]
	end
	function m:GetFaceNormals(fid)
		return self.triangles[fid]
	end
	function m:GetFaceColors(fid)
		return self.triangles[fid]
	end
	function m:GetUV(id)
		return self.uvs[id]
	end
	function m:GetNormal()
		return Vector3.zAxis
	end
	function m:GetColor()
		return Color3.new(1, 1, 1)
	end
	function m:GetColorAlpha()
		return 1
	end
	return m
end
return function(_, options)
	local report, test, rejects = harness()
	test("Native fingerprints ignore enumeration order and cyclic face start", function()
		local a, b = fixture(), fixture({ 3, 1, 2 })
		b.face = { 2, 3, 1 }
		assert(fingerprint(a) == fingerprint(b))
		b.positions = { [11] = a.positions[1], [12] = a.positions[2], [13] = a.positions[3] }
		b.uvs = { [11] = a.uvs[1], [12] = a.uvs[2], [13] = a.uvs[3] }
		b.vertices = { 12, 13, 11 }
		b.face = { 11, 12, 13 }
		assert(fingerprint(a) == fingerprint(b))
	end)
	test(
		"Native fingerprints ignore vertex welding, per-corner splitting and unreferenced vertices",
		function()
			-- Roblox's asset pipeline returns one vertex per triangle corner; rendering is unchanged.
			local welded = fingerprint(pair(false, false))
			assert(welded == fingerprint(pair(true, false)), "Split corners must match welded vertices")
			assert(welded == fingerprint(pair(false, true)), "Unreferenced vertices are not rendered content")
		end
	)
	test("Split-corner fingerprints still detect corner, missing and duplicated triangle changes", function()
		local base = fingerprint(pair(true, false))
		local moved = pair(true, false)
		moved.positions[6] = Vector3.new(1, 1, 0.001)
		assert(fingerprint(moved) ~= base, "Changed corner position accepted")
		local uv = pair(true, false)
		uv.uvs[4] = Vector2.new(0, 0.5)
		assert(fingerprint(uv) ~= base, "Changed corner UV accepted")
		local missing = pair(true, false)
		missing.triangles[20] = nil
		assert(fingerprint(missing) ~= base, "Missing triangle accepted")
		local doubled = pair(true, false)
		doubled.triangles[30] = { 4, 5, 6 }
		assert(fingerprint(doubled) ~= base, "Duplicated triangle accepted")
	end)
	for _, attribute in { "position", "uv", "normal", "color", "alpha", "winding" } do
		test("Native fingerprint detects same-count change: " .. attribute, function()
			local a, b = fixture(), fixture()
			if attribute == "position" then
				b.positions[1] = Vector3.new(0, 0, 0.001)
			elseif attribute == "uv" then
				b.uvs[1] = Vector2.one
			elseif attribute == "normal" then
				b.normal = -Vector3.zAxis
			elseif attribute == "color" then
				b.color = Color3.new(1, 0, 1)
			elseif attribute == "alpha" then
				b.alpha = 0.5
			else
				b.face = { 1, 3, 2 }
			end
			assert(fingerprint(a) ~= fingerprint(b))
		end)
	end
	test("Native fingerprint verifies skin weights and bind pose", function()
		local a = fixture()
		function a:GetBones()
			return { 10 }
		end
		function a:GetBoneParent()
			return 0
		end
		function a:GetBoneName()
			return "Root"
		end
		function a:GetBoneIsVirtual()
			return false
		end
		a.frame = CFrame.identity
		a.weight = 1
		function a:GetBoneCFrame()
			return self.frame
		end
		function a:GetVertexBones()
			return { 10 }
		end
		function a:GetVertexBoneWeights()
			return { self.weight }
		end
		local before = fingerprint(a)
		a.weight = 0.5
		assert(fingerprint(a) ~= before)
		a.weight = 1
		a.frame = CFrame.new(1, 0, 0)
		assert(fingerprint(a) ~= before)
	end)
	test("Unsupported FACS and nonfinite content fail closed", function()
		local a = fixture()
		function a:GetFacsPoses()
			return { "pose" }
		end
		rejects(function()
			fingerprint(a)
		end, "FACS")
		local b = fixture()
		b.alpha = 0 / 0
		rejects(function()
			fingerprint(b)
		end, "Nonfinite")
	end)
	test("Native image verification compares all pixel bytes", function()
		local i = { Size = Vector2.new(2, 1), pixels = buffer.create(8) }
		function i:ReadPixelsBuffer()
			return self.pixels
		end
		local before = C.image(i, B.new(nil, "image"))
		buffer.writeu8(i.pixels, 7, 1)
		assert(before ~= C.image(i, B.new(nil, "image")))
		rejects(function()
			C.image(i, B.new({ maxBytes = 7 }, "image"))
		end, "allocation limit")
	end)
	if not options or options.native ~= false then
		test("Native object readback preserves full mesh and image content", function()
			local service = game:GetService("AssetService")
			local resources = {}
			local function keep(o)
				table.insert(resources, assert(o))
				return o
			end
			local ok, err = pcall(function()
				local m = keep(service:CreateEditableMesh())
				local a = m:AddVertex(Vector3.zero)
				local b = m:AddVertex(Vector3.xAxis)
				local c = m:AddVertex(Vector3.yAxis)
				local face = m:AddTriangle(a, b, c)
				local uv = m:AddUV(Vector2.new(0.25, 0.75))
				m:SetFaceUVs(face, { uv, uv, uv })
				local bone = m:AddBone({ Name = "Root", CFrame = CFrame.new(0, 1, 0), Virtual = false })
				m:SetVertexBones(a, { bone })
				m:SetVertexBoneWeights(a, { 1 })
				local copy = keep(service:CreateEditableMeshAsync(Content.fromObject(m)))
				assert(fingerprint(m) == fingerprint(copy))
				local i = keep(service:CreateEditableImage({ Size = Vector2.new(2, 2) }))
				local pixels = buffer.create(16)
				buffer.writeu8(pixels, 0, 37)
				buffer.writeu8(pixels, 15, 255)
				i:WritePixelsBuffer(Vector2.zero, i.Size, pixels)
				local j = keep(service:CreateEditableImageAsync(Content.fromObject(i)))
				assert(C.image(i, B.new(nil, "image")) == C.image(j, B.new(nil, "image")))
			end)
			for _, r in resources do
				r:Destroy()
			end
			assert(ok, err)
		end)
	end
	return report
end
