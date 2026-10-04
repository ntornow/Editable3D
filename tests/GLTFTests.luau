-- Independent byte fixtures exercise the glTF specification as well as round trips.
return function(API)
	local G = assert(API.GLTF)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, message = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(
			report.results,
			{ name = name, passed = ok, error = not ok and tostring(message) or nil }
		)
	end
	local function near(a, b)
		assert(math.abs(a - b) < 1e-5, tostring(a) .. " != " .. tostring(b))
	end
	local function vec(a, b)
		assert((a - b).Magnitude < 1e-5, tostring(a) .. " != " .. tostring(b))
	end
	local function rejects(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok, "Expected rejection")
		if pattern then
			assert(tostring(err):find(pattern, 1, true), tostring(err))
		end
	end
	local I = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
	local function fixture()
		-- Triangle is specified independently of GLTF's writer.
		local b = buffer.create(44)
		for i, v in { 0, 0, 0, 1, 0, 0, 0, 1, 0 } do
			buffer.writef32(b, (i - 1) * 4, v)
		end
		buffer.writeu16(b, 36, 0)
		buffer.writeu16(b, 38, 1)
		buffer.writeu16(b, 40, 2)
		return {
			asset = { version = "2.0" },
			buffers = { { byteLength = 44 } },
			bufferViews = { { buffer = 0, byteLength = 36 }, { buffer = 0, byteOffset = 36, byteLength = 6 } },
			accessors = {
				{
					bufferView = 0,
					componentType = 5126,
					count = 3,
					type = "VEC3",
					min = { 0, 0, 0 },
					max = {
						1,
						1,
						0,
					},
				},
				{ bufferView = 1, componentType = 5123, count = 3, type = "SCALAR" },
			},
			meshes = { { primitives = { { attributes = { POSITION = 0 }, indices = 1 } } } },
			nodes = { { mesh = 0 } },
			scenes = { { nodes = { 0 } } },
			scene = 0,
		}, { b }
	end
	test("independent triangle bytes and default material", function()
		local d, b = fixture()
		local s = G.fromDocument(d, b)
		assert(#s.meshes[1]:triangles() == 1 and s.meshes[1].faces[1].material == 0)
		vec(s.meshes[1].vertices[2], Vector3.xAxis)
		vec(s.meshes[1]:faceNormal(1), Vector3.zAxis)
	end)
	test("interleaved normalized corner attributes", function()
		local d, b = fixture()
		local colors = buffer.create(24)
		for i = 0, 2 do
			buffer.writeu8(colors, i * 8, 255)
			buffer.writeu8(colors, i * 8 + 1, 128)
			buffer.writeu8(colors, i * 8 + 2, 0)
			buffer.writeu8(colors, i * 8 + 3, 64)
		end
		d.buffers[2] = { byteLength = 24 }
		b[2] = colors
		d.bufferViews[3] = { buffer = 1, byteLength = 24, byteStride = 8 }
		d.accessors[3] = { bufferView = 2, componentType = 5121, normalized = true, count = 3, type = "VEC4" }
		d.meshes[1].primitives[1].attributes.COLOR_0 = 2
		local c = G.fromDocument(d, b).meshes[1].faces[1].corners[1]
		near(c.color.R, 1)
		near(c.color.G, 128 / 255)
		near(c.alpha, 64 / 255)
	end)
	test("sparse accessor zero base and sorted override", function()
		local b = buffer.create(16)
		buffer.writeu8(b, 0, 2)
		buffer.writef32(b, 4, 7)
		buffer.writef32(b, 8, 8)
		buffer.writef32(b, 12, 9)
		local d = {
			buffers = { { byteLength = 16 } },
			bufferViews = { { buffer = 0, byteLength = 1 }, { buffer = 0, byteOffset = 4, byteLength = 12 } },
			accessors = {
				{
					componentType = 5126,
					type = "VEC3",
					count = 3,
					sparse = {
						count = 1,
						indices = { bufferView = 0, componentType = 5121 },
						values = {
							bufferView = 1,
						},
					},
				},
			},
		}
		local values = G.readAccessor(d, { b }, 0)
		near(values[1][1], 0)
		near(values[3][1], 7)
		near(values[3][3], 9)
	end)
	test("small integer matrix columns honor four byte padding", function()
		local b = buffer.create(12)
		for c = 0, 2 do
			for r = 0, 2 do
				buffer.writeu8(b, c * 4 + r, c * 3 + r + 1)
			end
		end
		local d = {
			buffers = { { byteLength = 12 } },
			bufferViews = { { buffer = 0, byteLength = 12 } },
			accessors = { { bufferView = 0, componentType = 5121, count = 1, type = "MAT3" } },
		}
		for i, n in G.readAccessor(d, { b }, 0)[1] do
			near(n, i)
		end
		-- The final byte of matrix padding is optional in the Khronos specification.
		d.buffers[1].byteLength = 11
		d.bufferViews[1].byteLength = 11
		near(G.readAccessor(d, { b }, 0)[1][9], 9)
	end)
	test("hierarchical quaternion TRS and nonuniform scale", function()
		local d, b = fixture()
		d.nodes = {
			{ translation = { 3, 4, 5 }, children = { 1 } },
			{ mesh = 0, scale = { 2, 3, 1 }, rotation = { 0, 0, math.sqrt(0.5), math.sqrt(0.5) } },
		}
		local s = G.fromDocument(d, b)
		local m = G.meshAt(s, 2)
		vec(m.vertices[1], Vector3.new(3, 4, 5))
		vec(m.vertices[2], Vector3.new(3, 6, 5))
		vec(m.vertices[3], Vector3.new(0, 4, 5))
	end)
	test("reflection reverses triangle winding and inverse transpose normals", function()
		local d, b = fixture()
		local s = G.fromDocument(d, b)
		s.meshes[1]:recalculateNormals()
		s.nodes[1].matrix = { -2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
		local m = G.meshAt(s, 1)
		vec(m:faceNormal(1), Vector3.zAxis)
		vec(m.faces[1].corners[1].normal, Vector3.zAxis)
		for _, c in s.meshes[1].faces[1].corners do
			c.normal = Vector3.new(1, 1, 0).Unit
		end
		local angled = G.meshAt(s, 1)
		vec(angled.faces[1].corners[1].normal, Vector3.new(-0.5, 1 / 3, 0).Unit)
	end)
	test("triangle strip alternating winding", function()
		local d = fixture()
		local data = buffer.create(48)
		for i, v in { 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0 } do
			buffer.writef32(data, (i - 1) * 4, v)
		end
		d.buffers = { { byteLength = 48 } }
		d.bufferViews = { { buffer = 0, byteLength = 48 } }
		d.accessors = { { bufferView = 0, componentType = 5126, count = 4, type = "VEC3" } }
		d.meshes[1].primitives[1] = { attributes = { POSITION = 0 }, mode = 5 }
		local m = G.fromDocument(d, { data }).meshes[1]
		assert(#m:triangles() == 2)
		vec(m:faceNormal(1), Vector3.zAxis)
		vec(m:faceNormal(2), Vector3.zAxis)
	end)
	test("per corner UV seams and materials survive GLB", function()
		local m = API.Mesh.new()
		for _, v in { Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.new(1, 1, 0) } do
			m:addVertex(v)
		end
		m:addFace(
			{ 1, 2, 3 },
			{ { uv = Vector2.new(0, 0) }, { uv = Vector2.new(1, 0) }, { uv = Vector2.new(0, 1) } },
			1
		)
		m:addFace(
			{ 2, 4, 3 },
			{ { uv = Vector2.new(0.25, 0.75) }, { uv = Vector2.new(1, 1) }, { uv = Vector2.new(0, 1) } },
			2
		)
		local s = G.fromMesh(m, {
			materials = {
				{ name = "Copper", pbrMetallicRoughness = { metallicFactor = 0.2 } },
				{
					name = "Stone",
				},
			},
		})
		local bin = G.toGLB(s)
		assert(buffer.readu32(bin, 0) == 0x46546C67 and buffer.readu32(bin, 8) == buffer.len(bin))
		local out = G.fromGLB(bin)
		assert(out.materials[2].name == "Stone" and out.meshes[1].faces[2].material == 2)
		near(out.meshes[1].faces[2].corners[1].uv.X, 0.25)
		assert(#out.meshes[1]:triangles() == 2)
	end)
	test("embedded and external JSON use identical binary data", function()
		local d, b = fixture()
		local s = G.fromDocument(d, b)
		local json = G.toJSON(s)
		vec(G.fromJSON(json).meshes[1].vertices[2], Vector3.xAxis)
		local external, buffers = G.toJSON(s, "mesh.bin")
		vec(G.fromJSON(external, { ["mesh.bin"] = buffers[1] }).meshes[1].vertices[3], Vector3.yAxis)
		rejects(function()
			G.fromJSON(external)
		end, "external URI")
	end)
	test("image payload and PBR texture bindings preserve bytes", function()
		local d, b = fixture()
		local s = G.fromDocument(d, b)
		-- Payload is intentionally opaque; GLTF is not a PNG codec.
		s.images = { { mimeType = "image/png", data = buffer.fromstring("opaque png payload") } }
		s.textures = { { source = 0 } }
		s.materials = { { pbrMetallicRoughness = { baseColorTexture = { index = 0 } } } }
		s.meshes[1].faces[1].material = 1
		local out = G.fromGLB(G.toGLB(s))
		assert(
			buffer.tostring(out.images[1].data) == "opaque png payload"
				and out.materials[1].pbrMetallicRoughness.baseColorTexture.index == 0
		)
	end)
	test("rig bridge and inverse bind skinning produce expected motion", function()
		local d, b = fixture()
		local m = G.fromDocument(d, b).meshes[1]
		local rig = API.Rig.new()
		local root = rig:addBone("Root", nil, CFrame.new(0, 2, 0))
		local child = rig:addBone("Tip", root, CFrame.new(0, 1, 0))
		for id in m.vertices do
			m.weights[id] = { [child] = 1 }
		end
		local s = G.fromGLB(G.toGLB(G.fromRig(m, rig)))
		vec(G.meshAt(s, 1).vertices[2], Vector3.xAxis)
		local pose = { [2] = table.clone(I) }
		pose[2][13] = 4
		pose[2][14] = 2
		vec(G.meshAt(s, 1, pose).vertices[2], Vector3.new(5, 0, 0))
	end)
	test("malformed ranges and sparse ordering reject", function()
		local d, b = fixture()
		d.accessors[1].count = 4
		rejects(function()
			G.fromDocument(d, b)
		end, "exceeds bufferView")
		local v = buffer.create(12)
		buffer.writeu8(v, 0, 1)
		buffer.writeu8(v, 1, 1)
		local bad = {
			buffers = { { byteLength = 12 } },
			bufferViews = { { buffer = 0, byteLength = 2 }, { buffer = 0, byteOffset = 4, byteLength = 8 } },
			accessors = {
				{
					componentType = 5126,
					type = "SCALAR",
					count = 3,
					sparse = {
						count = 2,
						indices = { bufferView = 0, componentType = 5121 },
						values = {
							bufferView = 1,
						},
					},
				},
			},
		}
		rejects(function()
			G.readAccessor(bad, { v }, 0)
		end, "Sparse indices")
	end)
	test("unsupported data rejects instead of silently disappearing", function()
		local d, b = fixture()
		d.extensionsRequired = { "KHR_draco_mesh_compression" }
		rejects(function()
			G.fromDocument(d, b)
		end, "Required glTF")
		d.extensionsRequired = nil
		d.meshes[1].primitives[1].attributes._CUSTOM = 0
		rejects(function()
			G.fromDocument(d, b)
		end, "Unsupported vertex attribute")
	end)
	test("node cycles and multiple parents reject", function()
		local d, b = fixture()
		d.nodes = { { children = { 1 } }, { children = { 0 }, mesh = 0 } }
		rejects(function()
			G.fromDocument(d, b)
		end, "Cycle")
		d.nodes = { { children = { 2 } }, { children = { 2 } }, { mesh = 0 } }
		rejects(function()
			G.fromDocument(d, b)
		end, "multiply parented")
	end)
	test("truncated GLB lengths reject", function()
		local d, b = fixture()
		local bin = G.toGLB(G.fromDocument(d, b))
		buffer.writeu32(bin, 8, buffer.len(bin) - 4)
		rejects(function()
			G.fromGLB(bin)
		end, "length mismatch")
		buffer.writeu32(bin, 8, buffer.len(bin))
		buffer.writeu32(bin, 12, buffer.len(bin))
		rejects(function()
			G.fromGLB(bin)
		end, "chunk length")
	end)
	test("eight influences and second UV set survive", function()
		local d, b = fixture()
		local m = G.fromDocument(d, b).meshes[1]
		local rig = API.Rig.new()
		for i = 1, 8 do
			rig:addBone("Joint " .. i, nil, CFrame.new(i, 0, 0))
		end
		for id in m.vertices do
			m.weights[id] = {}
			for i = 1, 8 do
				m.weights[id][i] = 1 / 8
			end
		end
		for _, c in m.faces[1].corners do
			c.uv1 = Vector2.new(0.3, 0.7)
		end
		local out = G.fromGLB(G.toGLB(G.fromRig(m, rig)))
		near(out.meshes[1].weights[1][8], 1 / 8)
		near(out.meshes[1].faces[1].corners[1].uv1.Y, 0.7)
		vec(G.meshAt(out, 1).vertices[2], Vector3.xAxis)
	end)
	test("malformed joint references reject on export", function()
		local d, b = fixture()
		local m = G.fromDocument(d, b).meshes[1]
		local rig = API.Rig.new()
		rig:addBone("Root")
		for id in m.vertices do
			m.weights[id] = { [1] = 1 }
		end
		local scene = G.fromRig(m, rig)
		scene.meshes[1].weights[1] = { [2] = 1 }
		rejects(function()
			G.toGLB(scene)
		end, "joint out of range")
	end)
	test("invalid texture bindings and local shear reject", function()
		local d, b = fixture()
		d.materials = { { normalTexture = { index = 0 } } }
		rejects(function()
			G.fromDocument(d, b)
		end, "material texture")
		d.materials = nil
		d.nodes[1].matrix = table.clone(I)
		d.nodes[1].matrix[5] = 0.5
		rejects(function()
			G.fromDocument(d, b)
		end, "cannot contain shear")
	end)
	return report
end
