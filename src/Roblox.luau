--!strict
local Mesh = require(script.Parent.Mesh)
local Texture = require(script.Parent.Texture)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Mesh.Mesh
type Corner = Types.Corner
type Texture = Types.Texture

-- Rig bone record as stored by Rig:addBone (bindLocal is relative to the parent bone).
export type BoneDefinition = { name: string, parent: any?, bindLocal: CFrame, virtual: boolean? }
-- One native EditableMesh plus the bookkeeping needed to update, pose and rebuild it.
export type Handle = {
	editable: EditableMesh,
	vertexIds: { [number]: number },
	faceIds: { { id: number, source: Types.Triangle } },
	boneIds: { [any]: number },
	boneOrder: { any },
	boneDefinitions: { [any]: BoneDefinition },
	origin: Vector3,
	signature: string,
	placement: CFrame,
	part: MeshPart?,
	boneInstances: { [any]: Bone }?,
	sourceVertices: { [number]: number }?,
	material: number?,
}
-- A Model of MeshParts built from one authoring mesh. Owns its native editables and images.
export type Bundle = {
	model: Model,
	handles: { Handle },
	images: { EditableImage },
	tiles: { columns: number, rows: number }?,
}
export type Chunk = { mesh: Mesh, sourceVertices: { [number]: number }, material: number }
export type EditableOptions = { rig: any?, cframe: CFrame? }
export type PartOptions = {
	collisionFidelity: Enum.CollisionFidelity?,
	name: string?,
	anchored: boolean?,
	parent: Instance?,
}
export type ModelOptions = {
	rig: any?,
	cframe: CFrame?,
	name: string?,
	maxTriangles: number?,
	anchored: boolean?,
	collisionFidelity: Enum.CollisionFidelity?,
	parent: Instance?,
}
export type TexturedModelOptions = {
	rig: any?,
	cframe: CFrame?,
	name: string?,
	maxTriangles: number?,
	anchored: boolean?,
	collisionFidelity: Enum.CollisionFidelity?,
	parent: Instance?,
	tileSize: number?,
}
-- PBR map name (ColorMap, NormalMap, RoughnessMap, MetalnessMap, EmissiveMask) to texture.
export type MaterialMaps = { [string]: Texture }

local R = {}
local function service(): AssetService
	return game:GetService("AssetService")
end
local function ensureNormals(mesh: Mesh): Mesh
	local out = mesh:clone()
	local missing = false
	for _, f in out.faces do
		for _, c in f.corners do
			if not c.normal then
				missing = true
			end
		end
	end
	if missing then
		local calculated = out:clone():recalculateNormals()
		for id, f in out.faces do
			for i, c in f.corners do
				c.normal = c.normal or calculated.faces[id].corners[i].normal
			end
		end
	end
	return out
end
local function signature(mesh: Mesh): string
	local t: { string } = {}
	for _, id in U.keys(mesh.vertices) do
		table.insert(t, "v" .. id)
	end
	for _, id in U.keys(mesh.faces) do
		local f = mesh.faces[id]
		table.insert(t, "f" .. id .. ":" .. table.concat(f.vertices, ",") .. ":" .. f.material)
	end
	return table.concat(t, ";")
end
function R.fromEditable(editable: EditableMesh): (Mesh, { [number]: number }, any)
	local m = Mesh.new()
	local map: { [number]: number } = {}
	for _, id in editable:GetVertices() do
		map[id] = m:addVertex(editable:GetPosition(id))
	end
	for _, fid in editable:GetFaces() do
		local vs = editable:GetFaceVertices(fid)
		local us, ns, cs = editable:GetFaceUVs(fid), editable:GetFaceNormals(fid), editable:GetFaceColors(fid)
		local vertices: { number }, corners: { Corner } = {}, {}
		for i, id in vs do
			vertices[i] = map[id]
			corners[i] = {
				uv = editable:GetUV(us[i]),
				normal = editable:GetNormal(ns[i]),
				color = editable:GetColor(cs[i]),
				alpha = editable:GetColorAlpha(cs[i]),
			}
		end
		m:addFace(vertices, corners)
	end
	local rig = (require(script.Parent.Rig) :: any).new()
	local boneMap: { [number]: any }, visiting: { [number]: boolean } = {}, {}
	local function importBone(id: number): any
		if boneMap[id] then
			return boneMap[id]
		end
		assert(not visiting[id], "Cyclic native skeleton")
		visiting[id] = true
		local parent = editable:GetBoneParent(id)
		local parentId = parent ~= 0 and importBone(parent) or nil
		local bind = editable:GetBoneCFrame(id)
		local localBind = parent ~= 0 and editable:GetBoneCFrame(parent):Inverse() * bind or bind
		boneMap[id] = rig:addBone(editable:GetBoneName(id), parentId, localBind)
		visiting[id] = nil
		return boneMap[id]
	end
	for _, id in editable:GetBones() do
		importBone(id)
	end
	for old, new in map do
		local ids, weights = editable:GetVertexBones(old), editable:GetVertexBoneWeights(old)
		local vertexWeights: { [number]: number } = {}
		m.weights[new] = vertexWeights
		local total = 0
		for _, weight in weights do
			total += weight
		end
		for i, bone in ids do
			vertexWeights[boneMap[bone]] = total > 0 and weights[i] / total or 0
		end
	end
	return m, map, rig
end
function R.partition(mesh: Mesh, triangleLimit: number?): { Chunk }
	local maxTriangles: number = triangleLimit or 18000
	U.integer(maxTriangles, 1)
	assert(maxTriangles <= 20000, "Triangle limit exceeded")
	A.validate(mesh)
	mesh = ensureNormals(mesh)
	local sourceEdges = A.keys(mesh, "edge")
	local groups: { [number]: { Types.Triangle } } = {}
	local materials: { number } = {}
	for _, tri in mesh:triangles() do
		local material = mesh.faces[tri.face].material
		if not groups[material] then
			groups[material] = {}
			table.insert(materials, material)
		end
		table.insert(groups[material], tri)
	end
	table.sort(materials)
	local chunks: { Chunk } = {}
	for _, material in materials do
		local tris = groups[material]
		for start = 1, #tris, maxTriangles do
			local m = Mesh.new()
			local map: { [number]: number }, reverse: { [number]: number } = {}, {}
			local maps = {
				vertex = {} :: { [number]: { { any } } },
				edge = {} :: { [string]: { { any } } },
				face = {} :: { [number]: { { any } } },
				corner = {} :: { [string]: { { any } } },
				identity = { vertex = false, edge = false, face = false, corner = false },
			}
			for i = start, math.min(start + maxTriangles - 1, #tris) do
				local t = tris[i]
				local vertices: { number }, corners: { Corner } = {}, {}
				local f = mesh.faces[t.face]
				for j = 1, 3 do
					local id = t[j]
					if not map[id] then
						map[id] = m:addVertex(mesh.vertices[id])
						reverse[map[id]] = id
						maps.vertex[map[id]] = { { id, 1 } }
					end
					vertices[j] = map[id]
					corners[j] = f.corners[t.corners[j]]
				end
				local fid = m:addFace(vertices, corners, material)
				maps.face[fid] = { { t.face, 1 } }
				for j = 1, 3 do
					maps.corner[fid .. ":" .. j] = { { t.face .. ":" .. t.corners[j], 1 } }
					local k = j % 3 + 1
					local key = U.edge(t[j], t[k])
					if sourceEdges[key] then
						maps.edge[U.edge(vertices[j], vertices[k])] = { { key, 1 } }
					end
				end
			end
			A.transfer(mesh, m, maps)
			for name in mesh.groups do
				m.groups[name] = {}
			end
			A.vertexData(mesh, m, maps.vertex)
			table.insert(chunks, { mesh = m, sourceVertices = reverse, material = material })
		end
	end
	return chunks
end
function R.toEditable(mesh: Mesh, options: EditableOptions?): Handle
	local options: EditableOptions = options or {}
	assert(
		U.count(mesh.vertices) <= 60000 and #mesh:triangles() <= 20000,
		"Use toModel for automatic partitioning"
	)
	local m = ensureNormals(mesh)
	local editable = assert(service():CreateEditableMesh(), "EditableMesh allocation failed")
	local ok, result = pcall(function(): Handle
		local lo, hi = m:bounds()
		local origin = (lo + hi) / 2
		local vertices: { [number]: number } = {}
		local faces: { { id: number, source: Types.Triangle } } = {}
		for _, id in U.keys(m.vertices) do
			vertices[id] = editable:AddVertex(m.vertices[id] - origin)
		end
		for _, t in m:triangles() do
			local face = editable:AddTriangle(vertices[t[1]], vertices[t[2]], vertices[t[3]])
			local f = m.faces[t.face]
			local ns: { number }, us: { number }, cs: { number } = {}, {}, {}
			for i = 1, 3 do
				local c = f.corners[t.corners[i]]
				ns[i] = editable:AddNormal(c.normal)
				us[i] = editable:AddUV(c.uv or Vector2.zero)
				local alpha: number = if c.alpha == nil then 1 else c.alpha
				cs[i] = editable:AddColor(c.color or Color3.new(1, 1, 1), alpha)
			end
			editable:SetFaceNormals(face, ns)
			editable:SetFaceUVs(face, us)
			editable:SetFaceColors(face, cs)
			table.insert(faces, { id = face, source = t })
		end
		local boneIds: { [any]: number } = {}
		local rig = options.rig
		if rig then
			local bind = rig:worldTransforms()
			for _, id in rig.order do
				local b = rig.bones[id]
				boneIds[id] = editable:AddBone({
					Name = b.name,
					ParentId = b.parent and boneIds[b.parent] or 0,
					CFrame = CFrame.new(-origin) * bind[id],
					Virtual = b.virtual == true,
				})
			end
			for id, weights in m.weights do
				local ids: { number }, values: { number } = {}, {}
				local sum = 0
				for bone, w in weights do
					assert(boneIds[bone], "Unknown rig bone")
					if w > 0 then
						table.insert(ids, boneIds[bone])
						table.insert(values, w)
						sum += w
					end
				end
				if sum > 0 then
					for i in values do
						values[i] /= sum
					end
					editable:SetVertexBones(vertices[id], ids)
					editable:SetVertexBoneWeights(vertices[id], values)
				end
			end
		elseif next(m.weights) then
			for _, w in m.weights do
				assert(not next(w), "Pass options.rig to export weighted geometry")
			end
		end
		return {
			editable = editable,
			vertexIds = vertices,
			faceIds = faces,
			boneIds = boneIds,
			boneOrder = rig and table.clone(rig.order) or {},
			boneDefinitions = rig and U.copy(rig.bones) or {},
			origin = origin,
			signature = signature(mesh),
			placement = options.cframe or CFrame.identity,
		}
	end)
	if not ok then
		editable:Destroy()
		error(result, 2)
	end
	return result :: Handle
end
function R.createPart(handle: Handle, options: PartOptions?): MeshPart
	local options: PartOptions = options or {}
	local part = service():CreateMeshPartAsync(Content.fromObject(handle.editable), {
		CollisionFidelity = options.collisionFidelity or Enum.CollisionFidelity.Hull,
		RenderFidelity = Enum.RenderFidelity.Precise,
	})
	part.Name = options.name or "Editable3DMesh"
	part.Anchored = options.anchored ~= false
	part.CFrame = handle.placement * CFrame.new(handle.origin + handle.editable:GetCenter())
	handle.part = part
	R.createBones(handle)
	part.Parent = options.parent
	return part
end
function R.createBones(handle: Handle): { [any]: Bone }
	local part = assert(handle.part, "Create a MeshPart first")
	local boneInstances: { [any]: Bone } = handle.boneInstances or {}
	handle.boneInstances = boneInstances
	local offset = handle.origin + handle.editable:GetCenter()
	for _, id in handle.boneOrder do
		local definition = handle.boneDefinitions[id]
		local bone = boneInstances[id]
		if not bone then
			local created = Instance.new("Bone")
			created.Name = definition.name
			boneInstances[id] = created
			bone = created
		end
		bone.CFrame = definition.parent and definition.bindLocal or CFrame.new(-offset) * definition.bindLocal
		bone.Parent = definition.parent and boneInstances[definition.parent] or part
	end
	return boneInstances
end
-- pose maps bone IDs to local CFrames; bones without an entry return to their bind pose.
function R.applyPose(handle: Handle, pose: { [any]: CFrame }): Handle
	assert(handle.part, "Create a MeshPart first")
	if not handle.boneInstances then
		R.createBones(handle)
	end
	local boneInstances = handle.boneInstances :: { [any]: Bone }
	for _, id in handle.boneOrder do
		local bind = handle.boneDefinitions[id].bindLocal
		boneInstances[id].Transform = bind:Inverse() * (pose[id] or bind)
	end
	return handle
end
function R.update(handle: Handle, mesh: Mesh): Handle
	assert(handle.signature == signature(mesh), "Topology changed; rebuild editable instead of updating")
	for id, native in handle.vertexIds do
		handle.editable:SetPosition(native, mesh.vertices[id] - handle.origin)
	end
	for _, entry in handle.faceIds do
		local t = entry.source
		local f = mesh.faces[t.face]
		local ns, us, cs =
			handle.editable:GetFaceNormals(entry.id),
			handle.editable:GetFaceUVs(entry.id),
			handle.editable:GetFaceColors(entry.id)
		for i = 1, 3 do
			local c = f.corners[t.corners[i]]
			if c.normal then
				handle.editable:SetNormal(ns[i], c.normal)
			else
				handle.editable:ResetNormal(ns[i])
			end
			handle.editable:SetUV(us[i], c.uv or Vector2.zero)
			handle.editable:SetColor(cs[i], c.color or Color3.new(1, 1, 1))
			local alpha: number = if c.alpha == nil then 1 else c.alpha
			handle.editable:SetColorAlpha(cs[i], alpha)
		end
	end
	local part = handle.part
	if part then
		part.Size = handle.editable:GetSize()
		part.CFrame = handle.placement * CFrame.new(handle.origin + handle.editable:GetCenter())
		R.createBones(handle)
	end
	return handle
end
function R.refreshCollision(handle: Handle)
	local part = assert(handle.part)
	local temp = service():CreateMeshPartAsync(
		Content.fromObject(handle.editable),
		{ CollisionFidelity = part.CollisionFidelity, RenderFidelity = part.RenderFidelity }
	)
	part:ApplyMesh(temp)
	temp:Destroy()
	part.Size = handle.editable:GetSize()
	part.CFrame = handle.placement * CFrame.new(handle.origin + handle.editable:GetCenter())
	R.createBones(handle)
end
function R.toModel(mesh: Mesh, options: ModelOptions?): Bundle
	local options: ModelOptions = options or {}
	local model = Instance.new("Model")
	model.Name = options.name or "Editable3DModel"
	local handles: { Handle } = {}
	local ok, err = pcall(function()
		for i, chunk in R.partition(mesh, options.maxTriangles) do
			local handle = R.toEditable(chunk.mesh, options)
			table.insert(handles, handle)
			handle.sourceVertices = chunk.sourceVertices
			handle.material = chunk.material
			R.createPart(handle, {
				parent = model :: Instance,
				name = "Mesh_" .. i,
				anchored = options.anchored,
				collisionFidelity = options.collisionFidelity,
			});
			(handle.part :: MeshPart):SetAttribute("MaterialSlot", chunk.material)
		end
	end)
	if not ok then
		model:Destroy()
		for _, h in handles do
			h.editable:Destroy()
		end
		error(err, 2)
	end
	model.Parent = options.parent
	return { model = model, handles = handles, images = {} }
end
function R.toEditableImage(texture: Texture, srgb: boolean?): EditableImage
	assert(texture.width <= 1024 and texture.height <= 1024, "Tile textures larger than EditableImage limits")
	local image = assert(
		service():CreateEditableImage({ Size = Vector2.new(texture.width, texture.height) }),
		"EditableImage allocation failed"
	)
	image:WritePixelsBuffer(Vector2.zero, image.Size, texture:toRGBA8(srgb))
	return image
end
function R.fromEditableImage(image: EditableImage, srgb: boolean?): Texture
	return (Texture :: any).fromRGBA8(
		image.Size.X,
		image.Size.Y,
		image:ReadPixelsBuffer(Vector2.zero, image.Size),
		srgb
	)
end
function R.material(maps: MaterialMaps): (SurfaceAppearance, { [string]: EditableImage })
	local native: { [string]: Content }, images: { [string]: EditableImage } = {}, {}
	local ok, result = pcall(function(): SurfaceAppearance
		for key, texture in maps do
			assert(
				key == "ColorMap"
					or key == "NormalMap"
					or key == "RoughnessMap"
					or key == "MetalnessMap"
					or key == "EmissiveMask",
				"Unsupported PBR map"
			)
			local image = R.toEditableImage(texture, key == "ColorMap")
			images[key] = image
			native[key] = Content.fromObject(image)
		end
		return service():CreateSurfaceAppearanceAsync(native)
	end)
	if not ok then
		for _, image in images do
			image:Destroy()
		end
		error(result, 2)
	end
	return result :: SurfaceAppearance, images
end
-- slot limits the material to handles of one material ID (or UV tile); nil applies to all.
function R.applyMaterial(bundle: Bundle, maps: MaterialMaps, slot: number?): { [string]: EditableImage }
	local appearance, images = R.material(maps)
	for _, h in bundle.handles do
		if not slot or h.material == slot then
			local part = h.part :: MeshPart
			local old = part:FindFirstChildOfClass("SurfaceAppearance")
			if old then
				old:Destroy()
			end
			appearance:Clone().Parent = part
		end
	end
	appearance:Destroy()
	for _, image in images do
		table.insert(bundle.images, image)
	end
	return images
end
function R.toTexturedModel(mesh: Mesh, maps: MaterialMaps, options: TexturedModelOptions?): Bundle
	local options: TexturedModelOptions = table.clone(options or {})
	-- UV tiles can be planar slivers; Roblox may reject their convex hull cooking.
	options.collisionFidelity = options.collisionFidelity or Enum.CollisionFidelity.Box
	local size = options.tileSize or 1024
	U.integer(size, 1)
	assert(size <= 1024)
	mesh = ensureNormals(mesh)
	local mapWidth: number?, mapHeight: number?
	for _, texture in maps do
		if not mapWidth then
			mapWidth, mapHeight = texture.width, texture.height
		end
		assert(
			texture.width == mapWidth and texture.height == mapHeight,
			"Tiled PBR maps must have matching dimensions"
		)
	end
	assert(mapWidth, "No texture maps supplied")
	local width, height = mapWidth :: number, mapHeight :: number
	local columns, rows = math.ceil(width / size), math.ceil(height / size)
	local UV = require(script.Parent.UV) :: any
	local Topology = require(script.Parent.Topology) :: any
	local tiles = UV.splitTiles(mesh, columns, rows)
	local meshes: { Mesh } = {}
	for _, tile in tiles do
		table.insert(meshes, tile.mesh)
	end
	local bundle = R.toModel(Topology.join(meshes), options)
	local ok, err = pcall(function()
		for _, tile in tiles do
			local tileMaps: MaterialMaps = {}
			for key, texture in maps do
				tileMaps[key] = (Texture :: any).generate(
					math.ceil(width / columns),
					math.ceil(height / rows),
					function(uv: Vector2)
						return texture:sample(
							(uv + Vector2.new(tile.column, tile.row)) / Vector2.new(columns, rows)
						)
					end
				)
			end
			R.applyMaterial(bundle, tileMaps, tile.tile)
		end
	end)
	if not ok then
		R.destroy(bundle)
		error(err, 2)
	end
	bundle.tiles = { columns = columns, rows = rows }
	return bundle
end
-- Accepts partial bundles (any field may be missing) so cleanup is safe after failures.
function R.destroy(bundle: { model: Model?, handles: { Handle }?, images: { EditableImage }? })
	if bundle.model then
		bundle.model:Destroy()
	end
	for _, h in (bundle.handles or {}) :: { Handle } do
		h.editable:Destroy()
	end
	for _, im in (bundle.images or {}) :: { EditableImage } do
		im:Destroy()
	end
end
-- Reads a MeshPart's mesh back into an authoring Mesh. space "world" (default) applies the part's
-- size scale and CFrame and maps corner normals through the transform; "mesh" keeps the stored
-- coordinates. Published meshes come back one vertex per triangle corner.
export type FromPartOptions = { space: ("world" | "mesh")? }
function R.fromPart(part: MeshPart, options: FromPartOptions?): Mesh
	local space = options and options.space or "world"
	assert(space == "world" or space == "mesh", "Unknown space")
	local editable = game:GetService("AssetService"):CreateEditableMeshAsync(part.MeshContent)
	local ok, mesh = pcall(R.fromEditable, editable)
	editable:Destroy()
	if not ok then
		error(mesh, 0)
	end
	if space == "mesh" then
		return mesh
	end
	local Deform = require(script.Parent.Deform)
	return Deform.transform(mesh, part.CFrame, part.Size / part.MeshSize, { normals = "transform" })
end
-- Publishes only the editable SurfaceAppearance/TextureContent maps of existing MeshParts, keeping
-- their meshes. Same transaction, verification and resume ledger as publish.
function R.publishMaterials(
	parts: { MeshPart },
	metadata: unknown,
	options: Types.PublishOptions?
): Types.PublishReport
	local handles = {}
	for _, part in parts do
		table.insert(handles, { part = part, editable = nil, materialsOnly = true })
	end
	return (require(script.Parent.RobloxPublish) :: any).run({ handles = handles }, metadata, options)
end
function R.publish(bundle: Bundle, metadata: unknown, options: Types.PublishOptions?): Types.PublishReport
	return (require(script.Parent.RobloxPublish) :: any).run(bundle, metadata, options)
end
return R
