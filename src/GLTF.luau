--!strict
-- glTF 2.0 geometry interchange. No HTTP, filesystem, plugins, or downloaded models.
-- Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local Morph = require(script.Parent.Morph)
local Timeline = require(script.Parent.Timeline)
local Quaternion = require(script.Parent.Quaternion)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
type Corner = Types.Corner
-- JSON-decoded glTF documents (and the export documents built for JSONEncode) follow the
-- glTF 2.0 schema with many optional sections; they stay dynamic at this boundary.
type Doc = any
-- Bytes keyed by one-based buffer index or by external URI; binary strings or buffers.
export type Sources = { [any]: any }
-- Column-major 4x4 affine matrix.
export type Matrix = { number }
type Tuple = { number }
export type MorphTarget = Morph.Shape
export type TRS = { translation: { number }, rotation: Quaternion.Quat, scale: { number } }
export type Node = {
	name: string?,
	matrix: Matrix,
	children: { number }?,
	mesh: number?,
	skin: number?,
	camera: number?,
	weights: { number }?,
	trs: TRS?,
}
export type Skin = { name: string?, joints: { number }, inverseBindMatrices: { Matrix }, skeleton: number? }
export type Image = { name: string?, mimeType: string, data: buffer | string }
export type SceneRoot = { name: string?, nodes: { number } }
-- Scene arrays and their references use one-based indices.
export type Scene = {
	meshes: { Mesh },
	meshNames: { string }?,
	morphTargets: { { MorphTarget } }?,
	meshWeights: { { number } }?,
	animations: { any }?, -- Timeline clips
	nodes: { Node },
	skins: { Skin },
	-- Material/texture/sampler/camera records are glTF JSON objects passed through unchanged.
	materials: { any },
	textures: { any },
	samplers: { any },
	images: { Image },
	scenes: { SceneRoot },
	scene: number?,
	cameras: { any },
	extensionsUsed: { string }?,
	warnings: { string },
}
export type Pose = { transforms: { [number]: Matrix }, weights: { [number]: { number } }, time: number }
export type ExportOptions = { materials: { any }?, name: string? }
-- Structural view of Rig.Rig (not required here to keep the module's require set unchanged).
type RigLike = {
	order: { number },
	bones: { [number]: { name: string, parent: number?, bindLocal: CFrame } },
	worldTransforms: (any) -> { [number]: CFrame },
}
-- Accessor component table entries are { byteSize, reader }.
type ComponentSpec = { any }
type AccessorWriter = (
	values: { Tuple },
	kind: string,
	component: number,
	target: number?,
	bounds: boolean
) -> number
local GLTF = {}
local Http = game:GetService("HttpService")
local components: { [number]: ComponentSpec } = {
	[5120] = { 1, buffer.readi8 },
	[5121] = { 1, buffer.readu8 },
	[5122] = { 2, buffer.readi16 },
	[5123] = { 2, buffer.readu16 },
	[5125] = { 4, buffer.readu32 },
	[5126] = { 4, buffer.readf32 },
}
local dimensions: { [string]: { number } } = {
	SCALAR = { 1, 1 },
	VEC2 = { 2, 1 },
	VEC3 = { 3, 1 },
	VEC4 = { 4, 1 },
	MAT2 = { 2, 2 },
	MAT3 = { 3, 3 },
	MAT4 = { 4, 4 },
}
local identity: Matrix = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local function integer(n: any, minimum: number?): number
	assert(type(n) == "number" and n % 1 == 0 and n >= (minimum or 0), "Expected nonnegative integer")
	return n
end
local function finite(n: any): number
	assert(U.finite(n), "Nonfinite glTF number")
	return n
end
local function at(list: { any }?, index: number, label: string): any
	integer(index)
	return assert(list and list[index + 1], "Invalid " .. label .. " index " .. index)
end
local function bytes(data: any): buffer
	if type(data) == "string" then
		return buffer.fromstring(data)
	end
	assert(typeof(data) == "buffer", "Expected buffer or binary string")
	return data
end
local function slice(b: buffer, offset: number, length: number): buffer
	integer(offset)
	integer(length)
	assert(offset + length <= buffer.len(b), "Binary range out of bounds")
	local result = buffer.create(length)
	buffer.copy(result, 0, b, offset, length)
	return result
end
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64decode(s: string): buffer
	assert(#s % 4 == 0 and not s:find("[^A-Za-z0-9+/=]"), "Invalid base64")
	local out: { string } = {}
	for i = 1, #s, 4 do
		local n, padding = 0, 0
		for j = 0, 3 do
			local c = s:sub(i + j, i + j)
			if c == "=" then
				assert(i + 3 == #s and j >= 2, "Invalid base64 padding")
				padding += 1
				n *= 64
			else
				assert(padding == 0, "Invalid base64 padding")
				n = n * 64 + assert(alphabet:find(c, 1, true)) - 1
			end
		end
		table.insert(out, string.char(math.floor(n / 65536) % 256))
		if padding < 2 then
			table.insert(out, string.char(math.floor(n / 256) % 256))
		end
		if padding < 1 then
			table.insert(out, string.char(n % 256))
		end
	end
	return buffer.fromstring(table.concat(out))
end
local function base64encode(b: buffer): string
	local out: { string } = {}
	for i = 0, buffer.len(b) - 1, 3 do
		local remaining = buffer.len(b) - i
		local n = buffer.readu8(b, i) * 65536
			+ (remaining > 1 and buffer.readu8(b, i + 1) * 256 or 0)
			+ (remaining > 2 and buffer.readu8(b, i + 2) or 0)
		for j = 3, 0, -1 do
			local digit = math.floor(n / 64 ^ j) % 64
			table.insert(
				out,
				(j == 1 and remaining < 2 or j == 0 and remaining < 3) and "="
					or alphabet:sub(digit + 1, digit + 1)
			)
		end
	end
	return table.concat(out)
end
local function uriBytes(uri: string, sources: Sources?): buffer
	local encoded = uri:match("^data:[^,]*;base64,(.*)$")
	if encoded then
		return base64decode(encoded)
	end
	assert(not uri:match("^data:"), "Only base64 data URIs are supported")
	assert(sources and sources[uri], "Provide bytes for external URI: " .. uri)
	return bytes(sources[uri])
end
local function resolveBuffers(doc: Doc, sources: Sources?): { buffer }
	local result: { buffer } = {}
	for i, item in doc.buffers or {} do
		integer(item.byteLength, 1)
		local data: any = sources and sources[i]
		if not data and item.uri then
			data = uriBytes(item.uri, sources)
		end
		assert(data, "Missing in-memory buffer " .. i)
		data = bytes(data)
		assert(buffer.len(data) >= item.byteLength, "Truncated glTF buffer")
		result[i] = buffer.len(data) == item.byteLength and data or slice(data, 0, item.byteLength)
	end
	return result
end
local function viewRange(doc: Doc, buffers: { buffer }, index: number): (buffer, number, number, any)
	local view = at(doc.bufferViews, index, "bufferView")
	local b = at(buffers, view.buffer, "buffer")
	local offset = integer(view.byteOffset or 0)
	local length = integer(view.byteLength, 1)
	assert(offset + length <= buffer.len(b), "bufferView exceeds buffer")
	return b, offset, length, view
end
local function layout(accessor: any): (ComponentSpec, { number }, number)
	local spec = assert(components[accessor.componentType], "Unsupported accessor componentType")
	local dim = assert(dimensions[accessor.type], "Unsupported accessor type")
	local column = dim[1] * spec[1]
	if dim[2] > 1 then
		column = math.ceil(column / 4) * 4
	end
	local offsets: { number } = {}
	for c = 0, dim[2] - 1 do
		for r = 0, dim[1] - 1 do
			table.insert(offsets, c * column + r * spec[1])
		end
	end
	return spec, offsets, column * dim[2]
end
local function normalized(n: number, component: number): number
	if component == 5120 then
		return math.max(n / 127, -1)
	elseif component == 5121 then
		return n / 255
	elseif component == 5122 then
		return math.max(n / 32767, -1)
	elseif component == 5123 then
		return n / 65535
	end
	error("Only BYTE/UNSIGNED_BYTE/SHORT/UNSIGNED_SHORT may be normalized")
end
-- Returns an array of numeric tuples; document indices remain zero-based.
function GLTF.readAccessor(doc: Doc, sources: Sources?, accessorIndex: number): { Tuple }
	local buffers = resolveBuffers(doc, sources)
	local a = at(doc.accessors, accessorIndex, "accessor")
	local count = integer(a.count, 1)
	local spec, offsets, size = layout(a)
	local lastByte = offsets[#offsets] + spec[1]
	local isMatrix = dimensions[a.type][2] > 1
	if a.normalized then
		normalized(0, a.componentType)
	end
	local result: { Tuple } = {}
	local function read(b: buffer, offset: number): Tuple
		local tuple: Tuple = {}
		for k, delta in offsets do
			local value = finite(spec[2](b, offset + delta))
			tuple[k] = a.normalized and normalized(value, a.componentType) or value
		end
		return tuple
	end
	if a.bufferView ~= nil then
		local b, start, length, view = viewRange(doc, buffers, a.bufferView)
		local offset = integer(a.byteOffset or 0)
		local stride = view.byteStride or size
		integer(stride, size)
		assert(
			stride % spec[1] == 0 and offset % spec[1] == 0 and (start + offset) % spec[1] == 0,
			"Misaligned accessor"
		)
		if view.byteStride then
			assert(stride >= 4 and stride <= 252 and stride % 4 == 0, "Invalid byteStride")
		end
		assert(not isMatrix or (start + offset) % 4 == 0, "Matrix columns must be four byte aligned")
		assert(offset + (count - 1) * stride + lastByte <= length, "Accessor exceeds bufferView")
		for i = 0, count - 1 do
			result[i + 1] = read(b, start + offset + i * stride)
		end
	else
		assert((a.byteOffset or 0) == 0, "Accessor without bufferView cannot have byteOffset")
		for i = 1, count do
			result[i] = table.create(#offsets, 0)
		end
	end
	if a.sparse then
		local s = a.sparse
		local n = integer(s.count, 1)
		assert(n <= count, "Sparse count exceeds accessor")
		local c = s.indices.componentType
		assert(c == 5121 or c == 5123 or c == 5125, "Invalid sparse index component")
		local ispec = components[c]
		local ib, io, il, iv = viewRange(doc, buffers, s.indices.bufferView)
		local vb, vo, vl, vv = viewRange(doc, buffers, s.values.bufferView)
		local ia = integer(s.indices.byteOffset or 0)
		local va = integer(s.values.byteOffset or 0)
		assert(not iv.byteStride and not vv.byteStride, "Sparse bufferViews must not be interleaved")
		assert((io + ia) % ispec[1] == 0 and (vo + va) % spec[1] == 0, "Misaligned sparse accessor")
		assert(not isMatrix or (vo + va) % 4 == 0, "Sparse matrix columns must be four byte aligned")
		assert(
			ia + n * ispec[1] <= il and va + (n - 1) * size + lastByte <= vl,
			"Sparse accessor exceeds bufferView"
		)
		local previous = -1
		for i = 0, n - 1 do
			local index = ispec[2](ib, io + ia + i * ispec[1])
			assert(index > previous and index < count, "Sparse indices must increase and stay in bounds")
			result[index + 1] = read(vb, vo + va + i * size)
			previous = index
		end
	end
	return result
end
local function multiply(a: Matrix, b: Matrix): Matrix
	local out: Matrix = {}
	for c = 0, 3 do
		for r = 0, 3 do
			local v = 0
			for k = 0, 3 do
				v += a[k * 4 + r + 1] * b[c * 4 + k + 1]
			end
			out[c * 4 + r + 1] = v
		end
	end
	return out
end
local function point(m: Matrix, p: Vector3): Vector3
	return Vector3.new(
		m[1] * p.X + m[5] * p.Y + m[9] * p.Z + m[13],
		m[2] * p.X + m[6] * p.Y + m[10] * p.Z + m[14],
		m[3] * p.X + m[7] * p.Y + m[11] * p.Z + m[15]
	)
end
local function inverse(m: Matrix): (Matrix, number)
	local a, b, c, d, e, f, g, h, i = m[1], m[5], m[9], m[2], m[6], m[10], m[3], m[7], m[11]
	local det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	assert(math.abs(det) > 1e-12, "Singular transform")
	local r: Matrix = {
		(e * i - f * h) / det,
		(f * g - d * i) / det,
		(d * h - e * g) / det,
		0,
		(c * h - b * i) / det,
		(a * i - c * g) / det,
		(b * g - a * h) / det,
		0,
		(b * f - c * e) / det,
		(c * d - a * f) / det,
		(a * e - b * d) / det,
		0,
		0,
		0,
		0,
		1,
	}
	local t = point(r, Vector3.new(-m[13], -m[14], -m[15]))
	r[13], r[14], r[15] = t.X, t.Y, t.Z
	return r, det
end
local function normal(m: Matrix, n: Vector3): Vector3
	local inv = inverse(m)
	return U.unit(
		Vector3.new(
			inv[1] * n.X + inv[2] * n.Y + inv[3] * n.Z,
			inv[5] * n.X + inv[6] * n.Y + inv[7] * n.Z,
			inv[9] * n.X + inv[10] * n.Y + inv[11] * n.Z
		),
		Vector3.zero
	)
end
local function validateMatrix(m: any): Matrix
	assert(type(m) == "table" and #m == 16, "Expected column-major affine matrix of 16 numbers")
	for _, n in m do
		finite(n)
	end
	assert(
		math.abs(m[4]) + math.abs(m[8]) + math.abs(m[12]) + math.abs(m[16] - 1) < 1e-8,
		"Expected affine matrix"
	)
	return m
end
local function validateNodeMatrix(m: any): Matrix
	validateMatrix(m)
	local columns =
		{ Vector3.new(m[1], m[2], m[3]), Vector3.new(m[5], m[6], m[7]), Vector3.new(m[9], m[10], m[11]) }
	for i = 1, 3 do
		for j = i + 1, 3 do
			assert(
				math.abs(columns[i]:Dot(columns[j]))
					<= 1e-5 * math.max(1, columns[i].Magnitude * columns[j].Magnitude),
				"glTF local node matrices cannot contain shear"
			)
		end
	end
	return m
end
-- Accepts a glTF JSON node or a TRS table.
local function nodeMatrix(node: any): Matrix
	if node.matrix then
		assert(
			not node.translation and not node.rotation and not node.scale,
			"Node cannot mix matrix and TRS"
		)
		return table.clone(validateNodeMatrix(node.matrix))
	end
	local t: { number } = node.translation or { 0, 0, 0 }
	local q: Quaternion.Quat = node.rotation or { 0, 0, 0, 1 }
	local s: { number } = node.scale or { 1, 1, 1 }
	assert(#t == 3 and #q == 4 and #s == 3, "Invalid TRS dimensions")
	for _, values in { t, q, s } do
		for _, v in values do
			finite(v)
		end
	end
	local x, y, z, w = table.unpack(q)
	assert(math.abs(x * x + y * y + z * z + w * w - 1) < 1e-4, "Rotation quaternion must be unit length")
	return {
		(1 - 2 * y * y - 2 * z * z) * s[1],
		(2 * x * y + 2 * w * z) * s[1],
		(2 * x * z - 2 * w * y) * s[1],
		0,
		(2 * x * y - 2 * w * z) * s[2],
		(1 - 2 * x * x - 2 * z * z) * s[2],
		(2 * y * z + 2 * w * x) * s[2],
		0,
		(2 * x * z + 2 * w * y) * s[3],
		(2 * y * z - 2 * w * x) * s[3],
		(1 - 2 * x * x - 2 * y * y) * s[3],
		0,
		t[1],
		t[2],
		t[3],
		1,
	}
end
-- Scene arrays and their references use one-based indices, unlike source glTF JSON.
-- pose is a Pose from sampleAnimation or a bare map of one-based node index -> local Matrix.
function GLTF.worldMatrices(scene: Scene, pose: any?): { [number]: Matrix }
	pose = pose and (pose.transforms or pose)
	local result: { [number]: Matrix }, visiting: { [number]: boolean? }, parents: { [number]: number } =
		{}, {}, {}
	for i, node in scene.nodes do
		for _, child in (node.children or {}) :: { number } do
			integer(child, 1)
			assert(scene.nodes[child] and not parents[child], "Invalid or multiply parented node")
			parents[child] = i
		end
	end
	local function visit(i: number): Matrix
		if result[i] then
			return result[i]
		end
		assert(not visiting[i], "Cycle in node hierarchy")
		visiting[i] = true
		local localMatrix = validateMatrix(pose and pose[i] or scene.nodes[i].matrix)
		result[i] = parents[i] and multiply(visit(parents[i]), localMatrix) or table.clone(localMatrix)
		visiting[i] = nil
		return result[i]
	end
	for i in scene.nodes do
		visit(i)
	end
	return result
end
local function attribute(
	doc: Doc,
	buffers: { buffer },
	index: number,
	kind: string,
	allowed: { [number]: boolean }
): ({ Tuple }, any)
	local a = at(doc.accessors, index, "accessor")
	assert(a.type == kind, "Wrong attribute tuple size; expected " .. kind)
	assert(allowed[a.componentType], "Unsupported attribute component type")
	return GLTF.readAccessor(doc, buffers, index), a
end
local FLOAT: { [number]: boolean } = { [5126] = true }
local UINT: { [number]: boolean } = { [5121] = true, [5123] = true, [5125] = true }
local NORM: { [number]: boolean } = { [5121] = true, [5123] = true, [5126] = true }
local JOINT: { [number]: boolean } = { [5121] = true, [5123] = true }
local ANIMATED: { [number]: boolean } =
	{ [5120] = true, [5121] = true, [5122] = true, [5123] = true, [5126] = true }
local function readMesh(doc: Doc, buffers: { buffer }, source: any): (Mesh, { MorphTarget }, { number })
	local mesh = Mesh.new()
	local targets: { MorphTarget } = {}
	local targetCount = #(source.primitives[1].targets or {})
	for i = 1, targetCount do
		targets[i] = {
			positions = {},
			corners = {},
			name = source.extras and source.extras.targetNames and source.extras.targetNames[i],
		}
	end
	if source.weights then
		assert(#source.weights == targetCount, "Morph weight count mismatch")
		for _, w in source.weights do
			finite(w)
		end
	end
	for _, p in source.primitives do
		assert(#(p.targets or {}) == targetCount, "All primitives must have the same morph target count")
		assert(
			not p.extensions or not p.extensions.KHR_draco_mesh_compression,
			"Draco requires a decoder and is unsupported"
		)
		local mode = p.mode or 4
		assert(mode == 4 or mode == 5 or mode == 6, "Only triangle primitives are supported")
		local attrs = assert(p.attributes)
		local positions = attribute(doc, buffers, assert(attrs.POSITION), "VEC3", FLOAT)
		local data: { [string]: { Tuple } } = {}
		for name: string, index: number in attrs do
			if name == "POSITION" then
				continue
			end
			local kind: string, allowed: { [number]: boolean }
			if name == "NORMAL" then
				kind, allowed = "VEC3", FLOAT
			elseif name == "TANGENT" then
				kind, allowed = "VEC4", FLOAT
			elseif name == "TEXCOORD_0" or name == "TEXCOORD_1" then
				kind, allowed = "VEC2", NORM
			elseif name == "COLOR_0" then
				kind, allowed = at(doc.accessors, index, "accessor").type, NORM
				assert(kind == "VEC3" or kind == "VEC4")
			elseif name == "JOINTS_0" or name == "JOINTS_1" then
				kind, allowed = "VEC4", JOINT
			elseif name == "WEIGHTS_0" or name == "WEIGHTS_1" then
				kind, allowed = "VEC4", NORM
			else
				error("Unsupported vertex attribute: " .. name)
			end
			local values, a = attribute(doc, buffers, index, kind, allowed)
			if allowed == NORM and a.componentType ~= 5126 then
				assert(a.normalized, "Integer texture/color/weight attributes must be normalized")
			end
			if allowed == JOINT then
				assert(not a.normalized, "Joint indices cannot be normalized")
			end
			assert(#values == #positions, "Attribute count mismatch")
			data[name] = values
		end
		local morphData: { [number]: { [string]: { Tuple } } } = {}
		for i: number, target: any in p.targets or {} do
			local decoded: { [string]: { Tuple } } = {}
			assert(next(target), "Empty morph target")
			for name: string, index: number in target do
				assert(attrs[name] ~= nil, "Morph attribute requires a base attribute")
				local kind: any = (name == "POSITION" or name == "NORMAL" or name == "TANGENT") and "VEC3"
					or (
						(name == "TEXCOORD_0" or name == "TEXCOORD_1") and "VEC2"
						or (name == "COLOR_0" and at(doc.accessors, attrs[name], "accessor").type)
					)
				assert(kind, "Unsupported morph attribute: " .. name)
				local values = attribute(doc, buffers, index, kind, FLOAT)
				assert(#values == #positions, "Morph attribute count mismatch")
				decoded[name] = values
			end
			morphData[i] = decoded
		end
		assert(
			(data.JOINTS_0 ~= nil) == (data.WEIGHTS_0 ~= nil)
				and (data.JOINTS_1 ~= nil) == (data.WEIGHTS_1 ~= nil),
			"Joints and weights must be paired"
		)
		assert(not data.JOINTS_1 or data.JOINTS_0, "JOINTS_1 requires JOINTS_0")
		local ids: { number } = {}
		for i, v in positions do
			ids[i] = mesh:addVertex(Vector3.new(v[1], v[2], v[3]))
			for t, md in morphData do
				if md.POSITION then
					targets[t].positions[ids[i]] = Vector3.new(table.unpack(md.POSITION[i]))
				end
			end
			if data.JOINTS_0 then
				local weights: { [number]: number } = {}
				local total = 0
				for set = 0, 1 do
					local js, ws = data["JOINTS_" .. set], data["WEIGHTS_" .. set]
					if js then
						for k, j in js[i] do
							local w = ws[i][k]
							assert(w >= 0, "Negative skin weight")
							if w > 0 then
								weights[j + 1] = (weights[j + 1] or 0) + w
								total += w
							end
						end
					end
				end
				assert(total > 0 and math.abs(total - 1) < 0.02, "Skin weights must sum to one")
				for j, w in weights do
					weights[j] = w / total
				end
				mesh.weights[ids[i]] = weights
			end
		end
		local indices: { number } = {}
		if p.indices ~= nil then
			local values, a = attribute(doc, buffers, p.indices, "SCALAR", UINT)
			assert(not a.normalized, "Indices cannot be normalized")
			for i, v in values do
				assert(v[1] < #ids, "Triangle index out of bounds")
				assert(
					v[1] < 2 ^ (8 * components[a.componentType][1]) - 1,
					"Primitive restart indices are forbidden"
				)
				indices[i] = v[1] + 1
			end
		else
			for i = 1, #ids do
				indices[i] = i
			end
		end
		assert(#indices >= 3, "Triangle primitive needs at least three indices")
		if mode == 4 then
			assert(#indices % 3 == 0, "TRIANGLES index count must be divisible by three")
		end
		local function face(a: number, b: number, c: number)
			if a == b or b == c or c == a then
				return
			end -- legal strip degenerates
			local corners: { Corner } = {}
			for k, id in { a, b, c } do
				local corner: Corner = {}
				for set = 0, 1 do
					local v = data["TEXCOORD_" .. set]
					if v then
						(corner :: any)[set == 0 and "uv" or "uv1"] = Vector2.new(v[id][1], v[id][2])
					end
				end
				local n = data.NORMAL
				if n then
					corner.normal = Vector3.new(table.unpack(n[id]))
				end
				local co = data.COLOR_0
				if co then
					corner.color = Color3.new(co[id][1], co[id][2], co[id][3])
					corner.alpha = co[id][4] or 1
				end
				local ta = data.TANGENT
				if ta then
					corner.tangent = Vector3.new(ta[id][1], ta[id][2], ta[id][3])
					corner.tangentSign = ta[id][4]
				end
				corners[k] = corner
			end
			local material = 0
			if p.material ~= nil then
				at(doc.materials, p.material, "material")
				material = p.material + 1
			end
			local fid = mesh:addFace({ ids[a], ids[b], ids[c] }, corners, material)
			for t, md in morphData do
				local deltas: { Morph.CornerDelta } = {}
				for k, id in { a, b, c } do
					local d: Morph.CornerDelta = {}
					for attr, values in md do
						local v = values[id]
						if attr == "NORMAL" then
							d.normal = Vector3.new(table.unpack(v))
						elseif attr == "TANGENT" then
							d.tangent = Vector3.new(table.unpack(v))
						elseif attr == "TEXCOORD_0" or attr == "TEXCOORD_1" then
							d[attr == "TEXCOORD_0" and "uv" or "uv1"] = Vector2.new(table.unpack(v))
						elseif attr == "COLOR_0" then
							d.color = Vector3.new(v[1], v[2], v[3])
							d.alpha = v[4]
						end
					end
					deltas[k] = d
				end
				targets[t].corners[fid] = deltas
			end
		end
		if mode == 4 then
			for i = 1, #indices, 3 do
				face(indices[i], indices[i + 1], indices[i + 2])
			end
		elseif mode == 5 then
			for i = 3, #indices do
				if i % 2 == 1 then
					face(indices[i - 2], indices[i - 1], indices[i])
				else
					face(indices[i - 1], indices[i - 2], indices[i])
				end
			end
		else
			for i = 3, #indices do
				face(indices[1], indices[i - 1], indices[i])
			end
		end
	end
	return mesh, targets, U.copy(source.weights or table.create(targetCount, 0))
end
local function validateBindings(doc: Doc)
	for _, texture in doc.textures or {} do
		if texture.source ~= nil then
			at(doc.images, texture.source, "texture image")
		end
		if texture.sampler ~= nil then
			at(doc.samplers, texture.sampler, "texture sampler")
		end
	end
	local function textureInfo(info: any)
		if not info then
			return
		end
		at(doc.textures, info.index, "material texture")
		assert(
			info.texCoord == nil or info.texCoord == 0 or info.texCoord == 1,
			"Only two texture coordinate sets are supported"
		)
	end
	for _, material in doc.materials or {} do
		local pbr = material.pbrMetallicRoughness or {}
		textureInfo(pbr.baseColorTexture)
		textureInfo(pbr.metallicRoughnessTexture)
		textureInfo(material.normalTexture)
		textureInfo(material.occlusionTexture)
		textureInfo(material.emissiveTexture)
	end
end
local function decomposeNode(node: Node): TRS
	local m = validateNodeMatrix(node.matrix)
	if node.trs then
		local candidate = nodeMatrix(node.trs)
		local same = true
		for i = 1, 16 do
			if math.abs(candidate[i] - m[i]) > 1e-6 then
				same = false
				break
			end
		end
		if same then
			return U.copy(node.trs)
		end
	end
	local x, y, z =
		Vector3.new(m[1], m[2], m[3]), Vector3.new(m[5], m[6], m[7]), Vector3.new(m[9], m[10], m[11])
	local sx, sy, sz = x.Magnitude, y.Magnitude, z.Magnitude
	assert(math.min(sx, sy, sz) > 1e-12, "Supply explicit TRS for zero-scale animated nodes")
	if x:Cross(y):Dot(z) < 0 then
		sx = -sx
	end
	local q = Quaternion.fromCFrame(CFrame.fromMatrix(Vector3.zero, x / sx, y / sy, z / sz))
	return { translation = { m[13], m[14], m[15] }, rotation = q, scale = { sx, sy, sz } }
end
local function readAnimations(doc: Doc, buffers: { buffer }, scene: Scene): { any }
	local animations: { any } = {}
	for i: number, a: any in doc.animations or {} do
		local channels: { any } = {}
		for _, c in a.channels do
			local target = assert(c.target, "Missing animation target")
			if target.node == nil then
				table.insert(scene.warnings, "Animation channel without a node was ignored")
				continue
			end
			local n = at(doc.nodes, target.node, "animation node")
			assert(not n.matrix, "Animated nodes must use TRS, not matrix")
			local path = target.path
			assert(
				path == "translation" or path == "rotation" or path == "scale" or path == "weights",
				"Unsupported animation target path"
			)
			local sampler = at(a.samplers, c.sampler, "animation sampler")
			local input, inputAccessor = attribute(doc, buffers, sampler.input, "SCALAR", FLOAT)
			assert(inputAccessor.min and inputAccessor.max, "Animation timestamps need min/max bounds")
			local times: { number } = {}
			for k, v in input do
				assert(v[1] >= 0, "Animation timestamps cannot be negative")
				times[k] = v[1]
			end
			local kind = path == "weights" and "SCALAR" or (path == "rotation" and "VEC4" or "VEC3")
			local output, oa = attribute(
				doc,
				buffers,
				sampler.output,
				kind,
				(path == "rotation" or path == "weights") and ANIMATED or FLOAT
			)
			if oa.componentType ~= 5126 then
				assert(oa.normalized, "Integer animation output must be normalized")
			end
			local interpolation = sampler.interpolation or "LINEAR"
			local factor = interpolation == "CUBICSPLINE" and 3 or 1
			local count = 1
			if path == "weights" then
				assert(n.mesh ~= nil, "Weight animation requires a mesh")
				count = #(scene.morphTargets :: { { MorphTarget } })[n.mesh + 1]
				assert(count > 0, "Weight animation requires morph targets")
			end
			assert(#output == #times * factor * count, "Animation output count mismatch")
			local values: { any }, ins: { any }, outs: { any } = {}, {}, {}
			local function value(k: number, slot: number): any
				local offset = ((k - 1) * factor + slot) * count
				if path ~= "weights" then
					return output[offset + 1]
				end
				local result: { number } = {}
				for j = 1, count do
					result[j] = output[offset + j][1]
				end
				return result
			end
			for k in times do
				values[k] = value(k, factor == 3 and 1 or 0)
				if path == "rotation" and oa.componentType ~= 5126 then
					values[k] = Quaternion.normalize(values[k])
				end
				if factor == 3 then
					ins[k] = value(k, 0)
					outs[k] = value(k, 2)
				end
			end
			channels[#channels + 1] = Timeline.channel(path, times, values, {
				node = target.node + 1,
				interpolation = interpolation,
				inTangents = ins,
				outTangents = outs,
			})
		end
		animations[i] = #channels > 0 and Timeline.clip(channels, a.name)
			or { name = a.name, channels = {}, startTime = 0, endTime = 0, duration = 0 }
	end
	return animations
end
function GLTF.sampleAnimation(scene: Scene, animationIndex: number, time: number, options: any?): Pose
	local clip = assert(scene.animations and scene.animations[animationIndex], "Missing animation")
	local sampled, sampleTime = Timeline.sample(clip, time, options)
	local result: Pose = { transforms = {}, weights = {}, time = sampleTime }
	for index, paths in sampled do
		local node = assert(scene.nodes[index], "Invalid animated node")
		local trs = decomposeNode(node)
		for path, value in paths do
			if path == "weights" then
				result.weights[index] = value
			else
				(trs :: any)[path] = value
			end
		end
		result.transforms[index] = nodeMatrix(trs)
	end
	return result
end
function GLTF.fromDocument(doc: Doc, sources: Sources?): Scene
	assert(doc.asset and doc.asset.version == "2.0", "Only glTF 2.0 is supported")
	assert(not doc.asset.minVersion or doc.asset.minVersion == "2.0", "Unsupported minimum glTF version")
	assert(
		not doc.extensionsRequired or #doc.extensionsRequired == 0,
		"Required glTF extensions are unsupported"
	)
	for _, v in doc.bufferViews or {} do
		assert(
			not v.extensions or not v.extensions.EXT_meshopt_compression,
			"Meshopt compression is unsupported"
		)
	end
	validateBindings(doc)
	local buffers = resolveBuffers(doc, sources)
	local scene: Scene = {
		meshes = {},
		meshNames = {},
		morphTargets = {},
		meshWeights = {},
		animations = {},
		nodes = {},
		skins = {},
		materials = U.copy(doc.materials or {}),
		textures = U.copy(doc.textures or {}),
		samplers = U.copy(doc.samplers or {}),
		images = {},
		scenes = {},
		scene = doc.scene and doc.scene + 1 or nil,
		cameras = U.copy(doc.cameras or {}),
		extensionsUsed = U.copy(doc.extensionsUsed or {}),
		warnings = {},
	}
	for _, ext in doc.extensionsUsed or {} do
		table.insert(scene.warnings, "Optional extension not evaluated: " .. ext)
	end
	for i: number, source: any in doc.meshes or {} do
		scene.meshes[i], (scene.morphTargets :: { { MorphTarget } })[i], (scene.meshWeights :: { { number } })[i] =
			readMesh(doc, buffers, source);
		(scene.meshNames :: { string })[i] = source.name or "Mesh " .. i
	end
	for i: number, n: any in doc.nodes or {} do
		local children: { number } = {}
		for j, c in n.children or {} do
			at(doc.nodes, c, "node")
			children[j] = c + 1
		end
		if n.mesh ~= nil then
			at(doc.meshes, n.mesh, "mesh")
		end
		if n.skin ~= nil then
			at(doc.skins, n.skin, "skin")
			assert(n.mesh ~= nil, "Skin requires mesh")
		end
		if n.camera ~= nil then
			at(doc.cameras, n.camera, "camera")
		end
		if n.weights then
			assert(
				n.mesh ~= nil
					and #n.weights == #(scene.morphTargets :: { { MorphTarget } })[n.mesh + 1]
					and #n.weights > 0,
				"Invalid node morph weights"
			)
			for _, w in n.weights do
				finite(w)
			end
		end
		scene.nodes[i] = {
			name = n.name,
			matrix = nodeMatrix(n),
			children = children,
			mesh = n.mesh and n.mesh + 1 or nil,
			skin = n.skin and n.skin + 1 or nil,
			camera = n.camera and n.camera + 1 or nil,
			weights = U.copy(n.weights),
			trs = not n.matrix and {
				translation = U.copy(n.translation or { 0, 0, 0 }),
				rotation = U.copy(n.rotation or { 0, 0, 0, 1 }),
				scale = U.copy(n.scale or { 1, 1, 1 }),
			} or nil,
		}
	end
	GLTF.worldMatrices(scene)
	for i: number, s: any in doc.scenes or {} do
		local roots: { number } = {}
		for j, n in s.nodes or {} do
			at(doc.nodes, n, "node")
			roots[j] = n + 1
		end
		scene.scenes[i] = { name = s.name, nodes = roots }
	end
	if doc.scene ~= nil then
		at(doc.scenes, doc.scene, "scene")
	end
	for i: number, s: any in doc.skins or {} do
		local joints: { number } = {}
		local seen: { [number]: boolean } = {}
		for j, n in s.joints do
			at(doc.nodes, n, "joint node")
			assert(not seen[n], "Duplicate skin joint")
			seen[n] = true
			joints[j] = n + 1
		end
		assert(#joints > 0, "Empty skin")
		local matrices: { Matrix } = {}
		if s.inverseBindMatrices ~= nil then
			matrices = attribute(doc, buffers, s.inverseBindMatrices, "MAT4", FLOAT)
			assert(#matrices == #joints, "Inverse bind count mismatch")
		else
			for j = 1, #joints do
				matrices[j] = table.clone(identity)
			end
		end
		for _, m in matrices do
			validateMatrix(m)
		end
		if s.skeleton ~= nil then
			at(doc.nodes, s.skeleton, "skeleton node")
		end
		scene.skins[i] = {
			name = s.name,
			joints = joints,
			inverseBindMatrices = matrices,
			skeleton = s.skeleton and s.skeleton + 1 or nil,
		}
	end
	for _, n in scene.nodes do
		if n.skin then
			local skin = scene.skins[n.skin]
			local mesh = scene.meshes[n.mesh :: number]
			for id in mesh.vertices do
				local weights = mesh.weights[id]
				assert(weights and next(weights), "Skinned mesh lacks vertex weights")
				for j in weights do
					assert(skin.joints[j], "Skin weight joint out of range")
				end
			end
		end
	end
	for i: number, img: any in doc.images or {} do
		assert((img.uri ~= nil) ~= (img.bufferView ~= nil), "Image needs exactly one URI or bufferView")
		local data: buffer
		if img.uri then
			data = uriBytes(img.uri, sources)
		else
			local b, o, l = viewRange(doc, buffers, img.bufferView)
			data = slice(b, o, l)
		end
		local mime = img.mimeType or (img.uri and img.uri:match("^data:([^;]+);"))
		if not mime and img.uri then
			local ext = img.uri:lower():match("%.([%w]+)$")
			mime = ext == "png" and "image/png" or ((ext == "jpg" or ext == "jpeg") and "image/jpeg" or nil)
		end
		assert(mime == "image/png" or mime == "image/jpeg", "Only PNG/JPEG image payloads are supported")
		scene.images[i] = { name = img.name, mimeType = mime, data = data }
	end
	scene.animations = readAnimations(doc, buffers, scene)
	return scene
end
function GLTF.fromJSON(json: string, sources: Sources?): Scene
	return GLTF.fromDocument(Http:JSONDecode(json), sources)
end
function GLTF.fromGLB(data: buffer | string, sources: Sources?): Scene
	local b = bytes(data)
	assert(buffer.len(b) >= 20, "Truncated GLB")
	assert(buffer.readu32(b, 0) == 0x46546C67 and buffer.readu32(b, 4) == 2, "Invalid GLB magic/version")
	assert(buffer.readu32(b, 8) == buffer.len(b), "GLB length mismatch")
	local offset = 12
	local doc: Doc, bin: buffer?
	local count = 0
	while offset < buffer.len(b) do
		assert(offset + 8 <= buffer.len(b), "Truncated GLB chunk header")
		local length, kind = buffer.readu32(b, offset), buffer.readu32(b, offset + 4)
		assert(length % 4 == 0 and offset + 8 + length <= buffer.len(b), "Invalid GLB chunk length")
		count += 1
		if count == 1 then
			assert(kind == 0x4E4F534A, "GLB JSON must be first")
		end
		if kind == 0x4E4F534A then
			assert(not doc, "Duplicate JSON chunk")
			doc = Http:JSONDecode(buffer.readstring(b, offset + 8, length))
		elseif kind == 0x004E4942 then
			assert(doc and not bin and count == 2, "GLB BIN must be second")
			bin = slice(b, offset + 8, length)
		end
		offset += 8 + length
	end
	local supplied: Sources = table.clone(sources or {})
	if bin then
		assert(
			doc.buffers and doc.buffers[1] and not doc.buffers[1].uri,
			"GLB BIN requires first buffer without URI"
		)
		assert(buffer.len(bin) - doc.buffers[1].byteLength <= 3, "Excess GLB padding")
		supplied[1] = bin
	end
	return GLTF.fromDocument(assert(doc), supplied)
end
local function transformMesh(mesh: Mesh, m: Matrix): Mesh
	local out = mesh:clone()
	local _inv, det = inverse(m)
	for id, p in out.vertices do
		out.vertices[id] = point(m, p)
	end
	for _, face in out.faces do
		for _, c in face.corners do
			if c.normal then
				c.normal = normal(m, c.normal)
			end
			if c.tangent then
				local v = c.tangent
				c.tangent = U.unit(
					Vector3.new(
						m[1] * v.X + m[5] * v.Y + m[9] * v.Z,
						m[2] * v.X + m[6] * v.Y + m[10] * v.Z,
						m[3] * v.X + m[7] * v.Y + m[11] * v.Z
					),
					Vector3.zero
				)
				c.tangentSign = (c.tangentSign or 1) * (det < 0 and -1 or 1)
			end
		end
		if det < 0 then
			local vs: { number }, cs: { Corner } = {}, {}
			for j = #face.vertices, 1, -1 do
				table.insert(vs, face.vertices[j])
				table.insert(cs, face.corners[j])
			end
			face.vertices, face.corners = vs, cs
		end
	end
	out.revision += 1
	return out
end
-- Evaluate a mesh instance in world coordinates, including its skin at a matrix pose.
-- Pose maps one-based node indices to local column-major matrices.
-- pose is a Pose from sampleAnimation or a bare node-index -> Matrix map (see worldMatrices).
function GLTF.meshAt(scene: Scene, nodeIndex: number, pose: any?): Mesh
	local node = assert(scene.nodes[nodeIndex], "Missing scene node")
	local mesh = assert(scene.meshes[node.mesh :: number], "Node has no mesh")
	local targets = scene.morphTargets and scene.morphTargets[node.mesh :: number]
	if targets and #targets > 0 then
		local weights: { number } = pose and pose.weights and pose.weights[nodeIndex]
			or node.weights
			or (scene.meshWeights and scene.meshWeights[node.mesh :: number])
			or table.create(#targets, 0)
		assert(#weights == #targets, "Morph weight count mismatch")
		mesh = Morph.evaluate(mesh, targets, weights)
		for fid, f in mesh.faces do
			local flat = mesh:faceNormal(fid)
			for _, c in f.corners do
				if not c.normal then
					c.normal = flat
				end
			end
		end
	end
	local world = GLTF.worldMatrices(scene, pose)
	if not node.skin then
		return transformMesh(mesh, world[nodeIndex])
	end
	local skin = assert(scene.skins[node.skin])
	local transforms: { Matrix } = {}
	for i, j in skin.joints do
		transforms[i] = multiply(world[j], skin.inverseBindMatrices[i])
	end
	local out = mesh:clone()
	local blendedMatrices: { [number]: Matrix } = {}
	for id, p in mesh.vertices do
		local blended = table.create(16, 0)
		local sum = 0
		for j, w in (mesh.weights[id] or {}) :: { [number]: number } do
			assert(transforms[j] and w >= 0, "Invalid skin weights")
			for k = 1, 16 do
				blended[k] += transforms[j][k] * w
			end
			sum += w
		end
		assert(sum > 0, "Skinned vertex has no influences")
		for k = 1, 16 do
			blended[k] /= sum
		end
		out.vertices[id] = point(blended, p)
		blendedMatrices[id] = blended
	end
	for _, face in out.faces do
		for c, v in face.vertices do
			local attr = face.corners[c]
			if attr.normal then
				attr.normal = normal(blendedMatrices[v], attr.normal)
			end
			attr.tangent = nil
			attr.tangentSign = nil -- require rebaking after deformation
		end
	end
	out.weights = {}
	out.revision += 1
	return out
end
local function frameMatrix(cf: CFrame): Matrix
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return { r00, r10, r20, 0, r01, r11, r21, 0, r02, r12, r22, 0, x, y, z, 1 }
end
function GLTF.fromMesh(mesh: Mesh, options: ExportOptions?): Scene
	local options: ExportOptions = options or {}
	local materials: { any } = U.copy(options.materials or {})
	local count = 0
	for _, face in mesh.faces do
		integer(face.material)
		count = math.max(count, face.material)
	end
	if options.materials then
		assert(#materials >= count, "Missing material slots")
	else
		for i = 1, count do
			materials[i] = { name = "Material " .. i }
		end
	end
	return {
		meshes = { mesh:clone() },
		meshNames = { options.name or "Mesh" },
		nodes = { { name = options.name or "Mesh", matrix = table.clone(identity), mesh = 1, children = {} } },
		skins = {},
		materials = materials,
		images = {},
		textures = {},
		samplers = {},
		cameras = {},
		scenes = { { nodes = { 1 } } },
		scene = 1,
		warnings = {},
	}
end
-- Rig weights are remapped from authoring bone IDs to ordered glTF skin joints.
function GLTF.fromRig(mesh: Mesh, rig: RigLike, options: ExportOptions?): Scene
	local scene = GLTF.fromMesh(mesh, options)
	local map: { [number]: number }, joints: { number }, matrices: { Matrix } = {}, {}, {}
	local world = rig:worldTransforms()
	for i, id in rig.order do
		map[id] = i
		joints[i] = i + 1
		matrices[i] = frameMatrix(world[id]:Inverse())
	end
	for i, id in rig.order do
		local bone = rig.bones[id]
		scene.nodes[i + 1] = { name = bone.name, matrix = frameMatrix(bone.bindLocal), children = {} }
	end
	for i, id in rig.order do
		local parent = rig.bones[id].parent
		if parent then
			table.insert(scene.nodes[map[parent] + 1].children :: { number }, i + 1)
		else
			table.insert(scene.scenes[1].nodes, i + 1)
		end
	end
	assert(#joints > 0, "Cannot export empty rig")
	for id in scene.meshes[1].vertices do
		local weights: { [number]: number } = {}
		local sum = 0
		for bone, w in (mesh.weights[id] or {}) :: { [number]: number } do
			assert(map[bone] and U.finite(w) and w >= 0, "Unknown bone or invalid weight")
			weights[map[bone]] = w
			sum += w
		end
		assert(sum > 0, "Each skinned vertex needs weights")
		for j, w in weights do
			weights[j] = w / sum
		end
		scene.meshes[1].weights[id] = weights
	end
	scene.nodes[1].skin = 1
	scene.skins[1] =
		{ name = options and options.name or "Rig", joints = joints, inverseBindMatrices = matrices }
	return scene
end
local function writer(doc: Doc): ((buffer, number?) -> number, AccessorWriter, () -> buffer)
	local chunks: { buffer } = {}
	local length = 0
	local function append(b: buffer, target: number?): number
		local padding = -length % 4
		if padding > 0 then
			table.insert(chunks, buffer.create(padding))
			length += padding
		end
		local index = #doc.bufferViews
		table.insert(
			doc.bufferViews,
			{ buffer = 0, byteOffset = length, byteLength = buffer.len(b), target = target }
		)
		table.insert(chunks, b)
		length += buffer.len(b)
		return index
	end
	local function accessor(
		values: { Tuple },
		kind: string,
		component: number,
		target: number?,
		bounds: boolean
	): number
		assert(#values > 0, "Cannot write empty accessor")
		local spec = assert(components[component])
		local dim = assert(dimensions[kind])
		local width = dim[1] * dim[2]
		assert(component == 5126 or component == 5125 or component == 5123, "Unsupported output component")
		local b = buffer.create(#values * width * spec[1])
		local write = component == 5126 and buffer.writef32
			or (component == 5125 and buffer.writeu32 or buffer.writeu16)
		local lo = table.create(width, math.huge)
		local hi = table.create(width, -math.huge)
		for i, tuple in values do
			assert(#tuple == width, "Output accessor dimension mismatch")
			for k, v in tuple do
				finite(v)
				if component ~= 5126 then
					integer(v)
					assert(v < (component == 5125 and 4294967295 or 65536), "Unsigned component overflow")
				else
					assert(math.abs(v) <= 3.4028234663852886e38, "Float32 overflow")
				end
				write(b, ((i - 1) * width + k - 1) * spec[1], v)
				lo[k] = math.min(lo[k], v)
				hi[k] = math.max(hi[k], v)
			end
		end
		local index = #doc.accessors
		table.insert(doc.accessors, {
			bufferView = append(b, target),
			componentType = component,
			count = #values,
			type = kind,
			min = bounds and lo or nil,
			max = bounds and hi or nil,
		})
		return index
	end
	local function finish(): buffer
		local b = buffer.create(length)
		local offset = 0
		for _, chunk in chunks do
			buffer.copy(b, offset, chunk)
			offset += buffer.len(chunk)
		end
		return b
	end
	return append, accessor, finish
end
local function exportMesh(
	mesh: Mesh,
	doc: Doc,
	write: AccessorWriter,
	name: string?,
	targets: { MorphTarget }?,
	weights: { number }?
): any
	local targets: { MorphTarget } = targets or {}
	if weights then
		assert(#weights == #targets and #targets > 0, "Morph weight count mismatch")
		for _, w in weights do
			finite(w)
		end
	end
	local groups: { [number]: { number } } = {}
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		integer(face.material)
		assert(face.material == 0 or doc.materials[face.material], "Face material slot not supplied")
		groups[face.material] = groups[face.material] or {}
		table.insert(groups[face.material], fid)
	end
	local primitives: { any } = {}
	for _, material in U.keys(groups) do
		local enabled: { [string]: boolean } = { POSITION = true }
		local morphEnabled: { [number]: { [string]: boolean } } = {}
		for t, target in targets do
			local attrs: { [string]: boolean } = { POSITION = true }
			for _, fid in groups[material] do
				for k, d in (target.corners and target.corners[fid] or {}) :: { [number]: Morph.CornerDelta } do
					local c = assert(mesh.faces[fid].corners[k], "Missing morph corner")
					for key in d do
						local attr = ({
							normal = "NORMAL",
							tangent = "TANGENT",
							uv = "TEXCOORD_0",
							uv1 = "TEXCOORD_1",
							color = "COLOR_0",
							alpha = "COLOR_0",
						})[key]
						assert(attr, "Unsupported morph corner attribute")
						assert(key == "alpha" or (c :: any)[key], "Morph attribute requires a base attribute")
						attrs[attr] = true
					end
				end
			end
			morphEnabled[t] = attrs
		end
		local influenceCount = 0
		for _, fid in groups[material] do
			local face = mesh.faces[fid]
			for i, c in face.corners do
				if c.normal then
					enabled.NORMAL = true
				end
				if c.uv then
					enabled.TEXCOORD_0 = true
				end
				if c.uv1 then
					enabled.TEXCOORD_1 = true
				end
				if c.color or c.alpha then
					enabled.COLOR_0 = true
				end
				if c.tangent then
					enabled.TANGENT = true
				end
				local n = 0
				for _, w in (mesh.weights[face.vertices[i]] or {}) :: { [number]: number } do
					if w > 0 then
						n += 1
					end
				end
				influenceCount = math.max(influenceCount, n)
			end
		end
		assert(
			influenceCount <= 8,
			"Export supports at most eight influences per vertex; normalize/prune explicitly"
		)
		if influenceCount > 0 then
			enabled.JOINTS_0 = true
			enabled.WEIGHTS_0 = true
		end
		if influenceCount > 4 then
			enabled.JOINTS_1 = true
			enabled.WEIGHTS_1 = true
		end
		local arrays: { [string]: { Tuple } }, indices: { Tuple }, mapping: { [string]: number } = {}, {}, {}
		local morphArrays: { [number]: { [string]: { Tuple } } } = {}
		for t, attrs in morphEnabled do
			morphArrays[t] = {}
			for attr in attrs do
				assert(enabled[attr], "Morph attribute requires a base attribute")
				morphArrays[t][attr] = {}
			end
		end
		for attr in enabled do
			arrays[attr] = {}
		end
		for _, fid in groups[material] do
			local face = mesh.faces[fid]
			local faceNormal = mesh:faceNormal(fid)
			for _, triangle in mesh:faceTriangles(fid) do
				for _, cornerIndex in triangle do
					local id = face.vertices[cornerIndex]
					local c = face.corners[cornerIndex]
					local p = mesh.vertices[id]
					local values: { [string]: Tuple } = { POSITION = { p.X, p.Y, p.Z } }
					local n = c.normal or faceNormal
					values.NORMAL = { n.X, n.Y, n.Z }
					local uv = c.uv or Vector2.zero
					values.TEXCOORD_0 = { uv.X, uv.Y }
					uv = c.uv1 or Vector2.zero
					values.TEXCOORD_1 = { uv.X, uv.Y }
					local color = c.color or Color3.new(1, 1, 1)
					values.COLOR_0 = { color.R, color.G, color.B, c.alpha or 1 }
					if enabled.TANGENT then
						assert(
							c.tangent and (c.tangentSign == 1 or c.tangentSign == -1),
							"Every tangent corner needs a vector and sign"
						)
						values.TANGENT = { c.tangent.X, c.tangent.Y, c.tangent.Z, c.tangentSign :: number }
					end
					if influenceCount > 0 then
						local list: { Tuple } = {}
						local sum = 0
						for joint, w in (mesh.weights[id] or {}) :: { [number]: number } do
							integer(joint, 1)
							finite(w)
							assert(w >= 0, "Negative skin weight")
							if w > 0 then
								table.insert(list, { joint - 1, w })
								sum += w
							end
						end
						assert(sum > 0, "Mixed weighted/unweighted vertices in a primitive")
						table.sort(list, function(a, b)
							return a[1] < b[1]
						end)
						for set = 0, (influenceCount > 4 and 1 or 0) do
							local js: Tuple, ws: Tuple = {}, {}
							for j = 1, 4 do
								local pair = list[set * 4 + j]
								js[j] = pair and pair[1] or 0
								ws[j] = pair and pair[2] / sum or 0
							end
							values["JOINTS_" .. set], values["WEIGHTS_" .. set] = js, ws
						end
					end
					local key: { string } = { tostring(id) }
					for _, attr in U.keys(enabled) do
						for _, v in values[attr] do
							table.insert(key, string.format("%.17g", v))
						end
					end
					local morphValues: { [number]: { [string]: Tuple } } = {}
					for t, target in targets do
						local d: Morph.CornerDelta = target.corners
								and target.corners[fid]
								and target.corners[fid][cornerIndex]
							or {}
						local dp = target.positions and target.positions[id] or Vector3.zero
						local dn, dt = d.normal or Vector3.zero, d.tangent or Vector3.zero
						local uv0, uv1 = d.uv or Vector2.zero, d.uv1 or Vector2.zero
						local col = d.color or Vector3.zero
						local mv: { [string]: Tuple } = {
							POSITION = { dp.X, dp.Y, dp.Z },
							NORMAL = { dn.X, dn.Y, dn.Z },
							TANGENT = { dt.X, dt.Y, dt.Z },
							TEXCOORD_0 = { uv0.X, uv0.Y },
							TEXCOORD_1 = { uv1.X, uv1.Y },
							COLOR_0 = { col.X, col.Y, col.Z, d.alpha or 0 },
						}
						morphValues[t] = mv
						for _, attr in U.keys(morphEnabled[t]) do
							for _, v in mv[attr] do
								table.insert(key, string.format("%.17g", v))
							end
						end
					end
					local encoded = table.concat(key, ",")
					local index = mapping[encoded]
					if index == nil then
						index = #arrays.POSITION
						mapping[encoded] = index
						for attr in enabled do
							table.insert(arrays[attr], values[attr])
						end
						for t, attrs in morphEnabled do
							for attr in attrs do
								table.insert(morphArrays[t][attr], morphValues[t][attr])
							end
						end
					end
					table.insert(indices, { index })
				end
			end
		end
		local attrs: { [string]: number } = {}
		for _, attr in U.keys(enabled) do
			local kind = (attr == "POSITION" or attr == "NORMAL") and "VEC3"
				or ((attr == "TEXCOORD_0" or attr == "TEXCOORD_1") and "VEC2" or "VEC4")
			attrs[attr] =
				write(arrays[attr], kind, attr:match("^JOINTS") and 5123 or 5126, 34962, attr == "POSITION")
		end
		local primitiveTargets: { { [string]: number } } = {}
		for t, targetAttrs in morphEnabled do
			local result: { [string]: number } = {}
			for _, attr in U.keys(targetAttrs) do
				local kind = attr == "COLOR_0" and "VEC4"
					or ((attr == "TEXCOORD_0" or attr == "TEXCOORD_1") and "VEC2" or "VEC3")
				result[attr] = write(morphArrays[t][attr], kind, 5126, 34962, attr == "POSITION")
			end
			primitiveTargets[t] = result
		end
		table.insert(primitives, {
			attributes = attrs,
			indices = write(indices, "SCALAR", #arrays.POSITION < 65536 and 5123 or 5125, 34963, false),
			material = material > 0 and material - 1 or nil,
			mode = 4,
			targets = #primitiveTargets > 0 and primitiveTargets or nil,
		})
	end
	assert(#primitives > 0, "Cannot export empty mesh")
	local names: { string } = {}
	for i, target in targets do
		names[i] = target.name or "Target " .. i
	end
	return {
		name = name,
		primitives = primitives,
		weights = weights and U.copy(weights) or nil,
		extras = #names > 0 and { targetNames = names } or nil,
	}
end
-- Return glTF JSON table and an array containing its binary buffer.
function GLTF.toDocument(scene: Scene): (Doc, { buffer })
	GLTF.worldMatrices(scene)
	local doc: Doc = {
		asset = { version = "2.0", generator = "Editable3D Luau GLTF" },
		accessors = {},
		bufferViews = {},
		buffers = {},
		meshes = {},
		nodes = {},
		skins = {},
		animations = {},
		materials = U.copy(scene.materials or {}),
		textures = U.copy(scene.textures or {}),
		samplers = U.copy(scene.samplers or {}),
		images = {},
		cameras = U.copy(scene.cameras or {}),
		extensionsUsed = U.copy(scene.extensionsUsed or {}),
		scenes = {},
		scene = scene.scene and scene.scene - 1 or nil,
	}
	local append, write, finish = writer(doc)
	for i, mesh in scene.meshes do
		local targets = scene.morphTargets and scene.morphTargets[i]
		local weights = targets and #targets > 0 and scene.meshWeights and scene.meshWeights[i] or nil
		doc.meshes[i] = exportMesh(mesh, doc, write, scene.meshNames and scene.meshNames[i], targets, weights)
	end
	local animated: { [number]: boolean } = {}
	for _, clip in (scene.animations or {}) :: { any } do
		if #clip.channels == 0 then
			continue
		end -- ignored node-less input channels
		local channels: { any }, samplers: { any } = {}, {}
		Timeline.clip(clip.channels, clip.name) -- validates unique target/path pairs
		for k, c in clip.channels do
			local node = assert(scene.nodes[c.node], "Invalid animation node")
			local path: string = c.path
			assert(path ~= "value", "glTF supports TRS and weights channels only")
			local checked = Timeline.channel(path, c.times, c.values, c)
			local times: { Tuple }, values: { any } = {}, {}
			for _, t in checked.times do
				assert(t >= 0, "Negative animation time")
				table.insert(times, { t })
			end
			if path == "weights" then
				assert(
					node.mesh
						and scene.morphTargets
						and scene.morphTargets[node.mesh]
						and #scene.morphTargets[node.mesh] == #c.values[1],
					"Morph animation count mismatch"
				)
			end
			local function emit(value: any)
				if path == "weights" then
					for _, v in value do
						table.insert(values, { v })
					end
				else
					table.insert(values, value)
				end
			end
			for j, value in checked.values do
				if checked.interpolation == "CUBICSPLINE" then
					emit((checked.inTangents :: { any })[j])
					emit(value)
					emit((checked.outTangents :: { any })[j])
				else
					emit(value)
				end
			end
			local kind = path == "weights" and "SCALAR" or (path == "rotation" and "VEC4" or "VEC3")
			samplers[k] = {
				input = write(times, "SCALAR", 5126, nil, true),
				output = write(values, kind, 5126, nil, false),
				interpolation = checked.interpolation,
			}
			channels[k] = { sampler = k - 1, target = { node = c.node - 1, path = path } }
			animated[c.node] = true
		end
		table.insert(doc.animations, { name = clip.name, channels = channels, samplers = samplers })
	end
	for i, node in scene.nodes do
		local children: { number } = {}
		for k, n in (node.children or {}) :: { number } do
			assert(scene.nodes[n], "Invalid child node")
			children[k] = n - 1
		end
		if node.mesh then
			assert(scene.meshes[node.mesh], "Invalid node mesh")
		end
		if node.skin then
			assert(node.mesh and scene.skins[node.skin], "Invalid node skin")
			local skin = scene.skins[node.skin]
			for id in scene.meshes[node.mesh :: number].vertices do
				local weights = scene.meshes[node.mesh :: number].weights[id]
				assert(weights and next(weights), "Skinned mesh lacks vertex weights")
				for joint in weights do
					assert(skin.joints[joint], "Skin weight joint out of range")
				end
			end
		end
		if node.camera then
			assert(doc.cameras[node.camera], "Invalid node camera")
		end
		if node.weights then
			assert(
				node.mesh
					and scene.morphTargets
					and #node.weights == #scene.morphTargets[node.mesh :: number]
					and #node.weights > 0,
				"Invalid node morph weights"
			)
			for _, w in node.weights do
				finite(w)
			end
		end
		doc.nodes[i] = {
			name = node.name,
			matrix = table.clone(validateNodeMatrix(node.matrix)),
			children = #children > 0 and children or nil,
			mesh = node.mesh and node.mesh - 1 or nil,
			skin = node.skin and node.skin - 1 or nil,
			camera = node.camera and node.camera - 1 or nil,
			weights = U.copy(node.weights),
		}
		if animated[i] then
			local trs = decomposeNode(node)
			doc.nodes[i].matrix = nil
			doc.nodes[i].translation = trs.translation
			doc.nodes[i].rotation = trs.rotation
			doc.nodes[i].scale = trs.scale
		end
	end
	for i, skin in (scene.skins or {}) :: { Skin } do
		assert(#skin.joints > 0 and #skin.joints == #skin.inverseBindMatrices, "Invalid skin")
		local joints: { number } = {}
		local seen: { [number]: boolean } = {}
		for j, n in skin.joints do
			assert(scene.nodes[n], "Invalid skin joint")
			assert(not seen[n], "Duplicate skin joint")
			seen[n] = true
			joints[j] = n - 1
			validateMatrix(skin.inverseBindMatrices[j])
		end
		doc.skins[i] = {
			name = skin.name,
			joints = joints,
			inverseBindMatrices = write(skin.inverseBindMatrices, "MAT4", 5126, nil, false),
			skeleton = skin.skeleton and skin.skeleton - 1 or nil,
		}
	end
	for i, img in (scene.images or {}) :: { Image } do
		assert(img.mimeType == "image/png" or img.mimeType == "image/jpeg", "Unsupported image MIME")
		assert(buffer.len(bytes(img.data)) > 0, "Image payload cannot be empty")
		doc.images[i] = { name = img.name, mimeType = img.mimeType, bufferView = append(bytes(img.data)) }
	end
	for i, s in (scene.scenes or {}) :: { SceneRoot } do
		local roots: { number } = {}
		for j, n in s.nodes do
			assert(scene.nodes[n], "Invalid scene root")
			roots[j] = n - 1
		end
		doc.scenes[i] = { name = s.name, nodes = #roots > 0 and roots or nil }
	end
	assert(not scene.scene or doc.scenes[scene.scene], "Invalid default scene")
	validateBindings(doc)
	local b = finish()
	if buffer.len(b) > 0 then
		doc.buffers[1] = { byteLength = buffer.len(b) }
	end
	-- Empty JSON arrays must be omitted: Roblox encodes empty tables as objects.
	for key, value in doc do
		if type(value) == "table" and next(value) == nil then
			doc[key] = nil
		end
	end
	return doc, { b }
end
-- Embedded JSON by default; pass a URI to return JSON plus external binary bytes.
function GLTF.toJSON(scene: Scene, bufferURI: string?): (string, { buffer })
	local doc, buffers = GLTF.toDocument(scene)
	if doc.buffers then
		doc.buffers[1].uri = bufferURI or "data:application/octet-stream;base64," .. base64encode(buffers[1])
	end
	return Http:JSONEncode(doc), buffers
end
function GLTF.toGLB(scene: Scene): buffer
	local doc, buffers = GLTF.toDocument(scene)
	local json = Http:JSONEncode(doc)
	json ..= string.rep(" ", -#json % 4)
	local b = buffers[1]
	local binaryLength = buffer.len(b)
	local padded = binaryLength + -binaryLength % 4
	local length = 12 + 8 + #json + (binaryLength > 0 and 8 + padded or 0)
	local out = buffer.create(length)
	buffer.writeu32(out, 0, 0x46546C67)
	buffer.writeu32(out, 4, 2)
	buffer.writeu32(out, 8, length)
	buffer.writeu32(out, 12, #json)
	buffer.writeu32(out, 16, 0x4E4F534A)
	buffer.writestring(out, 20, json)
	if binaryLength > 0 then
		local offset = 20 + #json
		buffer.writeu32(out, offset, padded)
		buffer.writeu32(out, offset + 4, 0x004E4942)
		buffer.copy(out, offset + 8, b)
	end
	return out
end
return GLTF
