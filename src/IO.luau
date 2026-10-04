--!strict
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- JSON-compatible mesh document (format "Editable3D.Mesh", version 1 or 2). Decoded documents
-- are untrusted input and are validated field by field in fromTable.
export type MeshDocument = { [string]: any }
local IO = {}
local function encodeValue(value: any): any
	local kind = typeof(value)
	if kind == "Vector2" then
		return { value.X, value.Y }
	end
	if kind == "Vector3" then
		return { value.X, value.Y, value.Z }
	end
	if kind == "Color3" then
		return { value.R, value.G, value.B }
	end
	return value
end
local function decodeValue(value: any, kind: string): any
	if kind == "Vector2" then
		assert(type(value) == "table" and #value == 2)
		return Vector2.new(table.unpack(value))
	end
	if kind == "Vector3" then
		assert(type(value) == "table" and #value == 3)
		return Vector3.new(table.unpack(value))
	end
	if kind == "Color3" then
		assert(type(value) == "table" and #value == 3)
		return Color3.new(table.unpack(value))
	end
	return value
end
function IO.toTable(mesh: Mesh): MeshDocument
	A.validate(mesh)
	local data: MeshDocument =
		{ format = "Editable3D.Mesh", version = 1, vertices = {}, faces = {}, groups = {} }
	for _, id in U.keys(mesh.vertices) do
		local p = mesh.vertices[id]
		local weights: { { number } } = {}
		for _, bone in U.keys(mesh.weights[id] or {}) do
			table.insert(weights, { bone, mesh.weights[id][bone] })
		end
		table.insert(data.vertices, { id = id, position = { p.X, p.Y, p.Z }, weights = weights })
	end
	for _, id in U.keys(mesh.faces) do
		local f = mesh.faces[id]
		local corners: { { [string]: any } } = {}
		for i, c in f.corners do
			local a: { [string]: any } = {}
			if c.uv then
				a.uv = { c.uv.X, c.uv.Y }
			end
			if c.normal then
				a.normal = { c.normal.X, c.normal.Y, c.normal.Z }
			end
			if c.color then
				a.color = { c.color.R, c.color.G, c.color.B }
			end
			a.alpha = c.alpha
			if c.tangent then
				a.tangent = encodeValue(c.tangent)
			end
			a.tangentSign = c.tangentSign
			corners[i] = a
		end
		table.insert(
			data.faces,
			{ id = id, vertices = table.clone(f.vertices), corners = corners, material = f.material }
		)
	end
	for name, group in mesh.groups do
		local list: { { number } } = {}
		for _, id in U.keys(group) do
			table.insert(list, { id, group[id] })
		end
		data.groups[name] = list
	end
	if next(mesh.attributes or {}) then
		data.version, data.attributes = 2, {}
		for _, name in U.keys(mesh.attributes) do
			local channel = mesh.attributes[name]
			local values: { { any } } = {}
			for _, key in U.keys(channel.values) do
				table.insert(values, { key, encodeValue(channel.values[key]) })
			end
			table.insert(data.attributes, {
				name = name,
				domain = channel.domain,
				dataType = channel.dataType,
				default = encodeValue(channel.default),
				interpolation = channel.interpolation,
				values = values,
			})
		end
	end
	return data
end
function IO.fromTable(data: MeshDocument): Mesh
	assert(
		data.format == "Editable3D.Mesh" and (data.version == 1 or data.version == 2),
		"Unsupported mesh format"
	)
	local m = Mesh.new()
	for _, v in data.vertices do
		U.integer(v.id, 1)
		assert(not m.vertices[v.id])
		m.vertices[v.id] = Vector3.new(table.unpack(v.position))
		m.nextVertex = math.max(m.nextVertex, v.id + 1)
		m.weights[v.id] = {}
		for _, w in v.weights or {} do
			m.weights[v.id][w[1]] = w[2]
		end
	end
	for _, f in data.faces do
		local corners: { Types.Corner } = {}
		for i, c in f.corners do
			local a: Types.Corner = {}
			if c.uv then
				a.uv = Vector2.new(table.unpack(c.uv))
			end
			if c.normal then
				a.normal = Vector3.new(table.unpack(c.normal))
			end
			if c.color then
				a.color = Color3.new(table.unpack(c.color))
			end
			a.alpha = c.alpha
			if c.tangent then
				a.tangent = decodeValue(c.tangent, "Vector3")
			end
			a.tangentSign = c.tangentSign
			corners[i] = a
		end
		U.integer(f.id, 1)
		assert(not m.faces[f.id])
		m.faces[f.id] = { vertices = table.clone(f.vertices), corners = corners, material = f.material or 1 }
		m.nextFace = math.max(m.nextFace, f.id + 1)
	end
	for name, list in data.groups or {} do
		m.groups[name] = {}
		for _, pair in list do
			m.groups[name][pair[1]] = pair[2]
		end
	end
	assert(data.version ~= 1 or data.attributes == nil, "Attributes require mesh format version 2")
	if data.version == 2 then
		assert(type(data.attributes) == "table", "Version 2 mesh requires attributes")
		for _, entry in data.attributes do
			assert(
				type(entry.name) == "string" and not m.attributes[entry.name],
				"Duplicate or invalid attribute name"
			)
			local channel: Types.Channel = {
				domain = entry.domain,
				dataType = entry.dataType,
				default = decodeValue(entry.default, entry.dataType),
				interpolation = entry.interpolation,
				values = {},
			}
			A.schema(channel)
			assert(type(entry.values) == "table", "Malformed attribute values")
			for _, pair in entry.values do
				assert(channel.values[pair[1]] == nil, "Duplicate attribute element")
				channel.values[pair[1]] = decodeValue(pair[2], entry.dataType)
			end
			m.attributes[entry.name] = channel
		end
	end
	local report = m:validate()
	assert(#report.errors == 0, "Malformed serialized mesh")
	return m
end
function IO.encode(mesh: Mesh): string
	return game:GetService("HttpService"):JSONEncode(IO.toTable(mesh))
end
function IO.decode(json: string): Mesh
	return IO.fromTable(game:GetService("HttpService"):JSONDecode(json))
end
function IO.toOBJ(mesh: Mesh): string
	local lines = { "# Editable3D original geometry" }
	local mapping: { [number]: number } = {}
	for i, id in U.keys(mesh.vertices) do
		local p = mesh.vertices[id]
		mapping[id] = i
		table.insert(lines, string.format("v %.9g %.9g %.9g", p.X, p.Y, p.Z))
	end
	local corners = 0
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		for _, c in f.corners do
			local uv = c.uv or Vector2.zero
			table.insert(lines, string.format("vt %.9g %.9g", uv.X, uv.Y))
		end
	end
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		local normal = mesh:faceNormal(fid)
		for _, c in f.corners do
			local n = c.normal or normal
			table.insert(lines, string.format("vn %.9g %.9g %.9g", n.X, n.Y, n.Z))
		end
	end
	local material: number? = nil
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		if f.material ~= material then
			material = f.material
			table.insert(lines, "usemtl material_" .. (material :: number))
		end
		local parts = { "f" }
		for _, id in f.vertices do
			corners += 1
			table.insert(parts, mapping[id] .. "/" .. corners .. "/" .. corners)
		end
		table.insert(lines, table.concat(parts, " "))
	end
	return table.concat(lines, "\n") .. "\n"
end
function IO.fromOBJ(text: string): Mesh
	local m = Mesh.new()
	local vertices: { number }, uvs: { Vector2 }, normals: { Vector3 } = {}, {}, {}
	local material = 1
	local names: { [string]: number } = {}
	local count = 0
	local function index<T>(s: string, list: { T }): T
		local i = tonumber(s)
		assert(i and i ~= 0)
		i = i < 0 and #list + i + 1 or i
		local value = list[i]
		assert(value, "OBJ index out of range")
		return value
	end
	for line in text:gmatch("[^\r\n]+") do
		local values: { string } = {}
		for value in line:gsub("#.*$", ""):gmatch("%S+") do
			table.insert(values, value)
		end
		local kind = values[1]
		if kind == "v" then
			table.insert(
				vertices,
				m:addVertex(
					Vector3.new(
						assert(tonumber(values[2])),
						assert(tonumber(values[3])),
						assert(tonumber(values[4]))
					)
				)
			)
		elseif kind == "vt" then
			table.insert(uvs, Vector2.new(assert(tonumber(values[2])), assert(tonumber(values[3]))))
		elseif kind == "vn" then
			table.insert(
				normals,
				Vector3.new(
					assert(tonumber(values[2])),
					assert(tonumber(values[3])),
					assert(tonumber(values[4]))
				)
			)
		elseif kind == "usemtl" then
			if not names[values[2]] then
				count += 1
				names[values[2]] = count
			end
			material = names[values[2]]
		elseif kind == "f" then
			local face: { number }, corners: { Types.Corner } = {}, {}
			for i = 2, #values do
				local v, uv, n = values[i]:match("^([^/]+)/?([^/]*)/?([^/]*)$")
				assert(v, "Malformed OBJ face")
				table.insert(face, index(v, vertices))
				local c: Types.Corner = {}
				if uv ~= "" then
					c.uv = index(uv :: string, uvs)
				end
				if n ~= "" then
					c.normal = index(n :: string, normals)
				end
				table.insert(corners, c)
			end
			m:addFace(face, corners, material)
		end
	end
	return m
end
return IO
