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
	-- set by a committed Roblox.publish: the model is now live scene content
	published: boolean?,
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
-- Splits triangles into chunks of at most `limit` that are compact in space: recursive splits at
-- the centroid order statistic along the longest axis, sized so every chunk but the last is full.
-- Cutting in face order instead can interleave chunks (after triangulation, the second triangle of
-- every quad gets a new face id at the end), and each chunk then carries its own texture.
local function spatialChunks(mesh: Mesh, tris: { Types.Triangle }, limit: number): { { Types.Triangle } }
	local items = table.create(#tris)
	for i, t in tris do
		items[i] = { t = t, c = (mesh.vertices[t[1]] + mesh.vertices[t[2]] + mesh.vertices[t[3]]) / 3, i = i }
	end
	local out: { { Types.Triangle } } = {}
	local function split(list: { any })
		if #list <= limit then
			table.sort(list, function(a, b)
				return a.i < b.i
			end)
			local piece = table.create(#list)
			for i, item in list do
				piece[i] = item.t
			end
			table.insert(out, piece)
			return
		end
		local lo, hi = list[1].c, list[1].c
		for _, item in list do
			lo, hi = lo:Min(item.c), hi:Max(item.c)
		end
		local size = hi - lo
		local axis = if size.X >= size.Y and size.X >= size.Z
			then "X"
			elseif size.Y >= size.Z then "Y"
			else "Z"
		table.sort(list, function(a, b)
			local x, y = (a.c :: any)[axis], (b.c :: any)[axis]
			if x == y then
				return a.i < b.i
			end
			return x < y
		end)
		local chunks = math.ceil(#list / limit)
		local left = math.floor(chunks / 2) * limit
		split(table.move(list, 1, left, 1, {}))
		split(table.move(list, left + 1, #list, 1, {}))
	end
	split(items)
	return out
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
		for _, piece in spatialChunks(mesh, tris, maxTriangles) do
			local m = Mesh.new()
			local map: { [number]: number }, reverse: { [number]: number } = {}, {}
			local maps = {
				vertex = {} :: { [number]: { { any } } },
				edge = {} :: { [string]: { { any } } },
				face = {} :: { [number]: { { any } } },
				corner = {} :: { [string]: { { any } } },
				identity = { vertex = false, edge = false, face = false, corner = false },
			}
			for _, t in piece do
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
export type DestroyOptions = { force: boolean? }
type Disposable = { model: Model?, handles: { Handle }?, images: { EditableImage }?, published: boolean? }
-- Frees a bundle's editable meshes and images without touching its model. Use it after
-- publishing, when the parts already render the uploaded assets.
function R.release(bundle: Disposable)
	for _, h in (bundle.handles or {}) :: { Handle } do
		local editable = (h :: any).editable
		if editable then
			editable:Destroy();
			(h :: any).editable = nil
		end
	end
	for _, im in (bundle.images or {}) :: { EditableImage } do
		im:Destroy()
	end
	bundle.images = {}
end
-- Destroys a preview bundle: its model, editables and images. A published bundle's model is live
-- scene content, so destroying it requires { force = true }; use Roblox.release to free only its
-- editables. (A stale reference to a published bundle otherwise deletes the scene's parts.)
function R.destroy(bundle: Disposable, options: DestroyOptions?)
	assert(
		not bundle.published or (options ~= nil and options.force == true),
		"Bundle is published: its model is live scene content. Use Roblox.release, or pass { force = true }"
	)
	if bundle.model then
		bundle.model:Destroy()
	end
	R.release(bundle)
end
-- Content properties that can display an editable, by class (IsA, so Texture is covered by Decal).
local CONTENT_PROPERTIES: { [string]: { string } } = {
	MeshPart = { "MeshContent", "TextureContent" },
	SurfaceAppearance = {
		"ColorMapContent",
		"NormalMapContent",
		"RoughnessMapContent",
		"MetalnessMapContent",
		"EmissiveMaskContent",
	},
	Decal = { "ColorMapContent", "TextureContent" },
	ImageLabel = { "ImageContent" },
	ImageButton = { "ImageContent" },
}
-- An EditableMesh or EditableImage. typeof reports these as "Object", not "Instance".
local function isEditableObject(value: any): boolean
	local kind = typeof(value)
	if kind ~= "Object" and kind ~= "Instance" then
		return false
	end
	local ok, yes = pcall(function()
		return value:IsA("EditableMesh") or value:IsA("EditableImage")
	end)
	return ok and yes == true
end
-- The editable meshes and images that instances under roots display (MeshPart mesh and texture,
-- SurfaceAppearance maps, Decal/Texture and image GUI content), as a set keyed by the object. roots
-- default to Workspace, ServerStorage, ReplicatedStorage, Lighting and StarterGui.
function R.liveEditables(roots: { Instance }?): { [any]: boolean }
	local live = {}
	local list = roots
		or {
			workspace,
			game:GetService("ServerStorage"),
			game:GetService("ReplicatedStorage"),
			game:GetService("Lighting"),
			game:GetService("StarterGui"),
		}
	for _, root in list :: { Instance } do
		for _, object in root:GetDescendants() do
			for class, properties in CONTENT_PROPERTIES do
				if object:IsA(class) then
					for _, property in properties do
						local ok, content = pcall(function()
							return (object :: any)[property]
						end)
						if
							ok
							and typeof(content) == "Content"
							and content.SourceType == Enum.ContentSourceType.Object
							and content.Object
						then
							live[content.Object] = true
						end
					end
				end
			end
		end
	end
	return live
end
export type SweepOptions = {
	roots: { Instance }?,
	live: { [any]: boolean }?,
	depth: number?,
	dryRun: boolean?,
	checkpoint: (() -> ())?,
	isEditable: ((any) -> boolean)?,
}
export type SweepReport = { destroyed: number, kept: number, tables: number }
-- Destroys the editable meshes and images reachable from value (keys and values of nested tables, up
-- to depth levels, default 8) that nothing under roots displays (Roblox.liveEditables, or the live
-- set given). Long sessions keep build results (bundles, preview images) in tables; dropping a table
-- leaves its editables allocated until they are collected, and they count against the engine's
-- editable memory budget, past which new textures render white. Displayed editables (unpublished
-- previews) are kept. dryRun only counts. checkpoint (e.g. task.wait) runs every 50,000 keys and values.
-- isEditable replaces the engine check, for wrapped objects.
function R.sweep(value: any, options: SweepOptions?): SweepReport
	local o: SweepOptions = options or {}
	local live = o.live or R.liveEditables(o.roots)
	local detect = o.isEditable or isEditableObject
	local limit = o.depth or 8
	local report: SweepReport = { destroyed = 0, kept = 0, tables = 0 }
	local seen = {}
	local visits = 0
	local function visit(v: any, depth: number)
		visits += 1
		if o.checkpoint and visits % 50000 == 0 then
			o.checkpoint()
		end
		local kind = type(v)
		if (kind ~= "table" and kind ~= "userdata") or seen[v] then
			return
		end
		if detect(v) then
			seen[v] = true
			if live[v] then
				report.kept += 1
			else
				if not o.dryRun then
					pcall(function()
						v:Destroy()
					end)
				end
				report.destroyed += 1
			end
		elseif kind == "table" and depth <= limit then
			seen[v] = true
			report.tables += 1
			for key, item in next, v do
				visit(key, depth + 1)
				visit(item, depth + 1)
			end
		end
	end
	visit(value, 1)
	return report
end
-- Reads a MeshPart's mesh back into an authoring Mesh. space "world" (default) applies the part's
-- size scale and CFrame and maps corner normals through the transform; "mesh" keeps the stored
-- coordinates. Published meshes come back one vertex per triangle corner; weld (Topology.weld) or
-- use Normals.unify before recalculating normals. Unpublished parts (EditableMesh content) are read
-- in place.
export type FromPartOptions = { space: ("world" | "mesh")? }
function R.fromPart(part: MeshPart, options: FromPartOptions?): Mesh
	local space = options and options.space or "world"
	assert(space == "world" or space == "mesh", "Unknown space")
	local content = part.MeshContent
	local mesh: Mesh
	if content.SourceType == Enum.ContentSourceType.Object then
		-- an unpublished part renders an EditableMesh the caller owns; read it, don't destroy it
		local object = content.Object
		assert(object and object:IsA("EditableMesh"), "Part mesh content is not an EditableMesh")
		mesh = R.fromEditable(object :: EditableMesh)
	else
		local editable = game:GetService("AssetService"):CreateEditableMeshAsync(content)
		local ok, result = pcall(R.fromEditable, editable)
		editable:Destroy()
		if not ok then
			error(result, 0)
		end
		mesh = result
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
-- Publishes standalone EditableImages (for example skybox faces or decals) with the same upload,
-- readback verification and resume ledger as publish; report.imageIds lists their asset IDs in
-- input order. No scene object is changed.
function R.publishImages(
	images: { EditableImage },
	metadata: unknown,
	options: Types.PublishOptions?
): Types.PublishReport
	assert(#images > 0, "No images to publish")
	return (require(script.Parent.RobloxPublish) :: any).run(
		{ handles = {}, images = images },
		metadata,
		options
	)
end
function R.publish(bundle: Bundle, metadata: unknown, options: Types.PublishOptions?): Types.PublishReport
	local report: Types.PublishReport = (require(script.Parent.RobloxPublish) :: any).run(
		bundle,
		metadata,
		options
	)
	if report.committed then
		bundle.published = true
	end
	return report
end
-- Publishes a large bundle as several transactions of at most partsPerTransaction parts (default 8), each
-- with its own operation budget, sharing one resume ledger (options.resume, or a fresh one returned as
-- report.resume) so a texture shared by every part uploads once. Each chunk is atomic; a failure stops
-- before the later chunks, the committed ones stay, and report.committedParts / report.partial say how far
-- it got. Rerun with the same ledger to finish without re-uploading. Use it when one Roblox.publish over
-- the bundle would exceed maxBytes (every part is snapshotted several times within one transaction).
function R.publishInChunks(
	bundle: Bundle,
	metadata: unknown,
	options: (Types.PublishOptions & { partsPerTransaction: number? })?
): Types.PublishReport
	local o: any = table.clone(options or {})
	local per = o.partsPerTransaction or 8
	o.partsPerTransaction = nil
	local report: any = (require(script.Parent.RobloxPublish) :: any).runChunked(bundle, metadata, o, per)
	if report.committed then
		bundle.published = true
	end
	return report
end
-- Drops resume-ledger entries whose source editables have been garbage collected (released or destroyed and no
-- longer referenced); returns how many. Every publish does this first, and entries keep a digest of the content
-- rather than the content, so one ledger can serve a whole session.
function R.pruneLedger(ledger: Types.PublishLedger): number
	return require(script.Parent.PublishPipeline).pruneLedger(ledger)
end
-- Defaults for bakes over parts read back from the scene: the caller chose the parts, so the triangle limit is the
-- mesh's own count (Bake's 250k default stops a many-part head), and the bake yields between rows (without a
-- checkpoint a long bake holds Studio's main thread until it ends).
local function sceneBakeLimits(mesh: Mesh, o: any): (number, () -> ())
	local count = 0
	for _, face in mesh.faces do
		count += math.max(0, #face.vertices - 2)
	end
	local limit = o.maxTriangles or math.max(250000, count)
	local checkpoint = o.checkpoint or function()
		task.wait()
	end
	return limit, checkpoint
end
-- Multiplies the colour maps of MeshParts by a factor field over their surfaces and leaves every other texel
-- byte-identical. Parts sharing a colour map are read back (world space) and joined; factor(position, normal,
-- current) -> number or Color3 (a linear multiple per channel; current is the texel's colour before, as a Color3 of
-- its sRGB bytes, for factors that regrade it) is rasterized at the map's size in its UV space (padded by
-- `padding` texels, default 6) and the map's pixels are multiplied where it covers them (Bake.modulateBytes). Each
-- part gets a new SurfaceAppearance carrying the result (one is not reliably refreshed in place), with its other
-- maps kept. Re-rasterizing the whole colour over a read-back mesh instead leaves seams along its triangle edges.
-- Returns { images, changed, revert }; publish the new maps with Roblox.publishMaterials.
export type ModulateOptions = Types.Limits & { padding: number?, tolerance: number? }
export type Modulation = { images: { EditableImage }, changed: number, revert: () -> () }
function R.modulateColor(
	parts: { MeshPart },
	factor: (Vector3, Vector3, Color3) -> number | Color3,
	options: ModulateOptions?
): Modulation
	local o: any = options or {}
	local Bake = require(script.Parent.Bake) :: any
	local Topology = require(script.Parent.Topology) :: any
	local AS = game:GetService("AssetService")
	local groups, order = {}, {}
	for _, part in parts do
		local sa = part:FindFirstChildOfClass("SurfaceAppearance")
		assert(sa, "modulateColor needs a SurfaceAppearance on every part")
		local content = sa.ColorMapContent
		local key: any = if content.SourceType == Enum.ContentSourceType.Object
			then content.Object
			else content.Uri
		assert(key ~= nil and key ~= "", "modulateColor needs a colour map on every part")
		if not groups[key] then
			groups[key] = { content = content, parts = {} }
			table.insert(order, key)
		end
		table.insert(groups[key].parts, part)
	end
	local images, previous, changed = {}, {}, 0
	local ok, err = pcall(function()
		for _, key in order do
			local g = groups[key]
			local meshes = {}
			for i, part in g.parts do
				meshes[i] = R.fromPart(part)
				task.wait()
			end
			local mesh = Topology.join(meshes)
			local limit, checkpoint = sceneBakeLimits(mesh, o)
			local old = if g.content.SourceType == Enum.ContentSourceType.Object
				then g.content.Object
				else AS:CreateEditableImageAsync(g.content)
			local size = old.Size
			local before = old:ReadPixelsBuffer(Vector2.zero, size)
			local ftex = Bake.rasterize(mesh, size.X, size.Y, function(ctx: Types.BakeContext)
				-- the texel's current colour (sRGB bytes as a Color3) for factors that depend on it
				local uv: Vector2 = ctx.uv
				local x = math.clamp(math.floor(uv.X * size.X), 0, size.X - 1)
				local y = math.clamp(math.floor(uv.Y * size.Y), 0, size.Y - 1)
				local i = (y * size.X + x) * 4
				local current = Color3.fromRGB(
					buffer.readu8(before, i),
					buffer.readu8(before, i + 1),
					buffer.readu8(before, i + 2)
				)
				local f = factor(ctx.position, ctx.normal, current)
				if typeof(f) == "number" then
					return Color3.new(f, f, f), 1
				end
				return f :: Color3, 1
			end, {
				padding = o.padding or 6,
				maxSeconds = o.maxSeconds,
				maxWork = o.maxWork,
				maxBytes = o.maxBytes,
				maxTriangles = limit,
				checkpoint = checkpoint,
				cancelled = o.cancelled,
			})
			local pixels, n = Bake.modulateBytes(before, size.X, size.Y, ftex, o.tolerance)
			if g.content.SourceType ~= Enum.ContentSourceType.Object then
				old:Destroy()
			end
			local img = AS:CreateEditableImage({ Size = size })
			img:WritePixelsBuffer(Vector2.zero, size, pixels)
			table.insert(images, img)
			changed += n
			for _, part in g.parts do
				local sa = part:FindFirstChildOfClass("SurfaceAppearance") :: SurfaceAppearance
				local fresh = sa:Clone()
				fresh.ColorMapContent = Content.fromObject(img)
				table.insert(previous, { part = part, surface = sa })
				sa.Parent = nil
				fresh.Parent = part
			end
		end
	end)
	local function revert()
		for _, entry in previous do
			local current = entry.part:FindFirstChildOfClass("SurfaceAppearance")
			if current then
				current:Destroy()
			end
			entry.surface.Parent = entry.part
		end
		for _, img in images do
			img:Destroy()
		end
		table.clear(previous)
		table.clear(images)
	end
	if not ok then
		revert()
		error(err, 0)
	end
	return { images = images, changed = changed, revert = revert }
end
export type NormalMapOptions = Types.Limits & { padding: number?, size: Vector2? }
export type NormalMapBake = { images: { EditableImage }, revert: () -> () }
-- Bakes a normal map onto MeshParts from a world-space shading normal per texel (Bake.worldNormalMap):
-- normal(position, meshNormal) returns the normal wanted there, or nil to leave it flat. Parts sharing a
-- colour map share its UV space, so they are read back, joined and baked together into one map at the
-- colour map's size (or options.size). Each part gets a new SurfaceAppearance with the map and its other
-- maps kept; revert() restores the originals. Publish with Roblox.publishMaterials. Tangent frames follow
-- each triangle's UVs (read-back meshes have split corners); on a smooth UV layout that is the engine's
-- per-vertex frame to within the triangle's variation. Roblox renders a published colour map with an
-- editable normal map white, so a published colour map is previewed from an editable copy (in images),
-- which publishMaterials uploads along with the normal map.
function R.bakeNormalMap(
	parts: { MeshPart },
	normal: (Vector3, Vector3) -> Vector3?,
	options: NormalMapOptions?
): NormalMapBake
	local o: any = options or {}
	local Bake = require(script.Parent.Bake) :: any
	local Topology = require(script.Parent.Topology) :: any
	local AS = game:GetService("AssetService")
	local groups, order = {}, {}
	for _, part in parts do
		local sa = part:FindFirstChildOfClass("SurfaceAppearance")
		assert(sa, "bakeNormalMap needs a SurfaceAppearance on every part")
		local content = sa.ColorMapContent
		local key: any = if content.SourceType == Enum.ContentSourceType.Object
			then content.Object
			else content.Uri
		assert(key ~= nil and key ~= "", "bakeNormalMap needs a colour map on every part (its UV space)")
		if not groups[key] then
			groups[key] = { content = content, parts = {} }
			table.insert(order, key)
		end
		table.insert(groups[key].parts, part)
	end
	local images, previous = {}, {}
	local ok, err = pcall(function()
		for _, key in order do
			local g = groups[key]
			local meshes = {}
			for i, part in g.parts do
				meshes[i] = R.fromPart(part)
				task.wait()
			end
			local mesh = Topology.join(meshes)
			local limit, checkpoint = sceneBakeLimits(mesh, o)
			-- Roblox renders a SurfaceAppearance with a published (Uri) colour map and an EditableImage normal
			-- map white; with both maps editable it renders. A published colour map is therefore previewed from
			-- an editable copy of itself (publishing uploads that copy too).
			local colorCopy: EditableImage? = nil
			if g.content.SourceType ~= Enum.ContentSourceType.Object then
				colorCopy = AS:CreateEditableImageAsync(g.content)
				table.insert(images, colorCopy :: EditableImage)
			end
			local size = o.size
				or (if colorCopy then colorCopy.Size else (g.content.Object :: EditableImage).Size)
			local tex = Bake.worldNormalMap(mesh, size.X, size.Y, function(ctx)
				return normal(ctx.position, ctx.normal)
			end, {
				padding = o.padding or 6,
				maxSeconds = o.maxSeconds,
				maxWork = o.maxWork,
				maxBytes = o.maxBytes,
				maxTriangles = limit,
				checkpoint = checkpoint,
				cancelled = o.cancelled,
			})
			local img = R.toEditableImage(tex, false)
			table.insert(images, img)
			for _, part in g.parts do
				local sa = part:FindFirstChildOfClass("SurfaceAppearance") :: SurfaceAppearance
				local fresh = sa:Clone()
				fresh.NormalMapContent = Content.fromObject(img)
				if colorCopy then
					fresh.ColorMapContent = Content.fromObject(colorCopy)
				end
				table.insert(previous, { part = part, surface = sa })
				sa.Parent = nil
				fresh.Parent = part
			end
		end
	end)
	local function revert()
		for _, entry in previous do
			local current = entry.part:FindFirstChildOfClass("SurfaceAppearance")
			if current then
				current:Destroy()
			end
			entry.surface.Parent = entry.part
		end
		for _, img in images do
			img:Destroy()
		end
		table.clear(previous)
		table.clear(images)
	end
	if not ok then
		revert()
		error(err, 0)
	end
	return { images = images, revert = revert }
end
-- readPrevious: read the current colour map back and pass it to the shader (one extra image in memory). To adjust an
-- existing texture on published parts, Roblox.modulateColor avoids the seams a full re-raster over a read-back mesh leaves.
-- Budget fields (maxSeconds, maxWork, checkpoint, cancelled) apply to each part's bake.
export type RebakeOptions =
	Types.Limits
	& { size: number?, padding: number?, srgb: boolean?, readPrevious: boolean? }
export type Rebake = {
	entries: {
		{
			part: MeshPart,
			previous: SurfaceAppearance?,
			surface: SurfaceAppearance,
			image: EditableImage,
		}
	},
	publish: (Rebake, metadata: unknown, options: Types.PublishOptions?) -> Types.PublishReport,
	revert: (Rebake) -> (),
}
-- Re-textures existing (usually published) MeshParts from a world-space shader without touching
-- their meshes: each part is read back (fromPart), its own UVs are baked with
-- shader(position, normal, part, ctx) -> (Color3, alpha), where ctx is the full bake context (uv,
-- face, barycentric, tangent frame) and previous is the part's current colour map read back as a
-- Texture (nil without one), so a shader can modulate the existing texture: previous:sample(ctx.uv).
-- A new SurfaceAppearance (other maps,
-- Color and AlphaMode copied) shows the result as a preview. Then :publish(metadata, options)
-- uploads only the colour maps (publishMaterials) and frees the previous appearances and images,
-- or :revert() restores the previous appearances.
function R.rebake(
	parts: { MeshPart },
	shader: (Vector3, Vector3, MeshPart, any, Texture?) -> (Color3, number?),
	options: RebakeOptions?
): Rebake
	local o: RebakeOptions = options or {}
	local size = o.size or 1024
	local Bake = require(script.Parent.Bake) :: any
	local entries = {}
	for _, part in parts do
		local mesh = R.fromPart(part)
		local current = part:FindFirstChildOfClass("SurfaceAppearance")
		local previousTexture: Texture? = nil
		local previousImage: EditableImage? = nil
		if o.readPrevious and current then
			local content = current.ColorMapContent
			if
				content.SourceType == Enum.ContentSourceType.Object
				and content.Object
				and content.Object:IsA("EditableImage")
			then
				previousTexture = R.fromEditableImage(content.Object :: EditableImage, o.srgb)
			elseif content.SourceType == Enum.ContentSourceType.Uri then
				previousImage = game:GetService("AssetService"):CreateEditableImageAsync(content)
				previousTexture = R.fromEditableImage(previousImage :: EditableImage, o.srgb)
			end
		end
		local limit, checkpoint = sceneBakeLimits(mesh, o)
		local texture = Bake.rasterize(mesh, size, size, function(ctx)
			return shader(ctx.position, ctx.normal, part, ctx, previousTexture)
		end, {
			padding = o.padding or 4,
			maxSeconds = o.maxSeconds,
			maxWork = o.maxWork,
			maxBytes = o.maxBytes,
			maxPixels = o.maxPixels,
			maxTriangles = limit,
			checkpointEvery = o.checkpointEvery,
			checkpoint = checkpoint,
			cancelled = o.cancelled,
		})
		if previousImage then
			previousImage:Destroy()
		end
		local image = R.toEditableImage(texture, o.srgb)
		local previous = part:FindFirstChildOfClass("SurfaceAppearance")
		local surface = Instance.new("SurfaceAppearance")
		if previous then
			surface.NormalMapContent = previous.NormalMapContent
			surface.RoughnessMapContent = previous.RoughnessMapContent
			surface.MetalnessMapContent = previous.MetalnessMapContent
			surface.Color = previous.Color
			surface.AlphaMode = previous.AlphaMode
			previous.Parent = nil
		end
		surface.ColorMapContent = Content.fromObject(image)
		surface.Parent = part
		table.insert(entries, { part = part, previous = previous, surface = surface, image = image })
	end
	local handle = {} :: any
	handle.entries = entries
	function handle.publish(
		self: Rebake,
		metadata: unknown,
		publishOptions: Types.PublishOptions?
	): Types.PublishReport
		local list = {}
		for _, e in self.entries do
			table.insert(list, e.part)
		end
		local report = R.publishMaterials(list, metadata, publishOptions)
		if report.success then
			for _, e in self.entries do
				if e.previous then
					e.previous:Destroy()
				end
				e.image:Destroy()
			end
		end
		return report
	end
	function handle.revert(self: Rebake)
		for _, e in self.entries do
			e.surface:Destroy()
			if e.previous then
				e.previous.Parent = e.part
			end
			e.image:Destroy()
		end
	end
	return handle :: Rebake
end
-- Reshapes existing (usually published) MeshParts with a world-space point map, as a preview:
-- each part is read back (fromPart), every vertex goes through map(position, part), normals are
-- re-derived across all parts together (Normals.unify, so seams between chunks stay smooth), and
-- a new bundle with the part's material, colour, DoubleSided and SurfaceAppearance is shown in
-- the part's parent while the original is hidden. :publish(metadata, options) uploads each bundle
-- and puts it in the original's place (a single-part holder model of the same name is replaced
-- whole); :revert() restores the originals. metadata is a table (its Name gets " <part name>"
-- appended, trimmed to 50 characters) or a function of the part. keep(centroid, part) -> boolean
-- trims faces while reshaping: a face whose ORIGINAL centroid fails it is removed (cut away a part of
-- a published mesh that a new piece replaces); faces that survive keep their UVs and textures. A part
-- that loses every face has no preview: it is hidden (entry.removed) and destroyed when a publish
-- succeeds for every other part (its report row has removed = true; report.removed lists its name).
export type ReshapeOptions = {
	unify: boolean?,
	angle: number?,
	tolerance: number?,
	maxTriangles: number?,
	collisionFidelity: Enum.CollisionFidelity?,
	keep: ((Vector3, MeshPart) -> boolean)?,
}
export type ReshapeEntry = { part: MeshPart, bundle: Bundle?, transparency: number, removed: boolean? }
-- published and failures are keyed by part name (parts sharing a name overwrite each other there);
-- parts lists every entry in order, so same-named parts each keep their result.
export type ReshapeResult = { part: string, meshId: string?, error: string?, removed: boolean? }
export type ReshapeReport = {
	success: boolean,
	published: { [string]: string },
	failures: { [string]: string },
	parts: { ReshapeResult },
	removed: { string },
}
export type Reshape = {
	entries: { ReshapeEntry },
	publish: (Reshape, metadata: any, options: Types.PublishOptions?) -> ReshapeReport,
	revert: (Reshape) -> (),
}
function R.reshape(
	parts: { MeshPart },
	map: (Vector3, MeshPart) -> Vector3,
	options: ReshapeOptions?
): Reshape
	local o: ReshapeOptions = options or {}
	local Deform = require(script.Parent.Deform) :: any
	local Normals = require(script.Parent.Normals) :: any
	local meshes = {}
	for i, part in parts do
		local source = R.fromPart(part)
		local keep = o.keep
		if keep then
			for fid, f in source.faces do
				local c = Vector3.zero
				for _, v in f.vertices do
					c += source.vertices[v]
				end
				if not keep(c / #f.vertices, part) then
					source:removeFace(fid)
				end
			end
			source:removeUnused()
		end
		-- a part that keeps no face is removed rather than previewed
		if next(source.faces) ~= nil then
			meshes[i] = Deform.map(source, function(position: Vector3): Vector3
				return map(position, part)
			end)
		end
	end
	if o.unify ~= false then
		local list, index = {}, {}
		for i in parts do
			if meshes[i] then
				table.insert(list, meshes[i])
				table.insert(index, i)
			end
		end
		if #list > 0 then
			local unified =
				Normals.unify(list, { tolerance = o.tolerance or 1e-3, angle = o.angle or math.rad(75) })
			for k, i in index do
				meshes[i] = unified[k]
			end
		end
	end
	local entries: { ReshapeEntry } = {}
	for i, part in parts do
		if not meshes[i] then
			table.insert(entries, { part = part, transparency = part.Transparency, removed = true })
			part.Transparency = 1
			continue
		end
		local bundle = R.toModel(meshes[i], {
			name = part.Name,
			maxTriangles = o.maxTriangles or 18000,
			collisionFidelity = o.collisionFidelity or Enum.CollisionFidelity.Box,
		})
		local appearance = part:FindFirstChildOfClass("SurfaceAppearance")
		for _, handle in bundle.handles do
			local copy = assert(handle.part, "Reshape bundle part missing")
			copy.Name = part.Name
			copy.Material = part.Material
			copy.Color = part.Color
			copy.DoubleSided = part.DoubleSided
			copy.CastShadow = part.CastShadow
			if appearance then
				appearance:Clone().Parent = copy
			end
		end
		bundle.model.Parent = part.Parent
		table.insert(entries, { part = part, bundle = bundle, transparency = part.Transparency })
		part.Transparency = 1
	end
	local handle = {} :: any
	handle.entries = entries
	function handle.publish(
		self: Reshape,
		metadata: any,
		publishOptions: Types.PublishOptions?
	): ReshapeReport
		local report: ReshapeReport =
			{ success = true, published = {}, failures = {}, parts = {}, removed = {} }
		local removed = {}
		for _, e in self.entries do
			local part = e.part
			if e.removed then
				table.insert(removed, e)
				continue
			end
			local bundle = e.bundle :: Bundle
			local meta = metadata
			if type(metadata) == "function" then
				meta = metadata(part)
			elseif type(metadata) == "table" then
				meta = table.clone(metadata)
				meta.Name = string.sub((metadata.Name or "Editable3D") .. " " .. part.Name, 1, 50)
			end
			-- a part whose publish raises (cancellation, an engine error) is recorded as a failure, so
			-- the loop never stops half-way with some originals replaced and no report
			local ok, published = pcall(R.publish, bundle, meta, publishOptions)
			local result: Types.PublishReport = if ok
				then published
				else {
					success = false,
					committed = false,
					rolledBack = true,
					stage = "publish",
					error = tostring(published),
					rollbackErrors = {},
					cleanupErrors = {},
					assets = {},
					resumeAvailable = false,
					operation = {
						operation = "Roblox.publish",
						work = 0,
						allocatedBytes = 0,
						elapsedSeconds = 0,
					},
				}
			if result.success then
				local holder = part.Parent
				if
					holder
					and holder:IsA("Model")
					and holder.Name == part.Name
					and #holder:GetChildren() == 2 -- the original and its preview bundle
					and holder.Parent
				then
					bundle.model.Parent = holder.Parent
					holder:Destroy()
				else
					part:Destroy()
				end
				local first = bundle.handles[1]
				local firstPart = first and first.part
				local meshId = if firstPart then tostring(firstPart.MeshId) else ""
				report.published[part.Name] = meshId
				table.insert(report.parts, { part = part.Name, meshId = meshId })
			else
				report.success = false
				local message = tostring(result.stage) .. ": " .. tostring(result.error)
				report.failures[part.Name] = message
				table.insert(report.parts, { part = part.Name, error = message })
			end
		end
		-- removed parts go only once every other part has published, so a revert can still restore them
		for _, e in removed do
			local part = e.part
			if report.success then
				local holder = part.Parent
				if
					holder
					and holder:IsA("Model")
					and holder.Name == part.Name
					and #holder:GetChildren() == 1
					and holder.Parent
				then
					holder:Destroy()
				else
					part:Destroy()
				end
				table.insert(report.removed, part.Name)
			end
			table.insert(report.parts, { part = part.Name, removed = true })
		end
		return report
	end
	function handle.revert(self: Reshape)
		for _, e in self.entries do
			if e.bundle then
				R.destroy(e.bundle)
			end
			e.part.Transparency = e.transparency
		end
	end
	return handle :: Reshape
end
-- Stages new bundles (keyed by name) in place of existing parts: the replaced parts are hidden while the bundles
-- preview. publish() publishes every bundle with Roblox.publishInChunks; only when all of them commit are the
-- replaced parts destroyed (with any Model they leave empty that holds no staged bundle), and each committed
-- bundle's editables and images (bundle.images) are released. A failure leaves the previews and the hidden parts
-- as they are, so a rerun with the same resume ledger finishes the rest. revert() destroys the uncommitted bundles
-- and shows the replaced parts again. metadata: a table (its Name suffixed with the key, cut to 50 characters) or
-- function(key, bundle) -> metadata. Put each bundle's EditableImages in bundle.images so they are released.
export type StageAsset = { meshes: { string }, color: string? }
export type StageReport = {
	success: boolean,
	assets: { [string]: StageAsset },
	failures: { [string]: string },
	removed: number,
}
export type Stage = {
	bundles: { [string]: Bundle },
	hidden: { { part: BasePart, transparency: number } },
	publish: (
		Stage,
		metadata: any,
		options: (Types.PublishOptions & { partsPerTransaction: number? })?
	) -> StageReport,
	revert: (Stage) -> (),
}
local function assetNumber(content: any): string?
	local text = tostring(content or "")
	return string.match(text, "%d+")
end
function R.stage(bundles: { [string]: Bundle }, replaced: { BasePart }): Stage
	local hidden = {}
	for _, part in replaced do
		table.insert(hidden, { part = part, transparency = part.Transparency })
		part.Transparency = 1
	end
	local handle = { bundles = bundles, hidden = hidden } :: any
	local function keys(): { string }
		local list = {}
		for key in bundles do
			table.insert(list, key)
		end
		table.sort(list)
		return list
	end
	function handle.publish(self: Stage, metadata: any, options: any): StageReport
		local report: StageReport = { success = true, assets = {}, failures = {}, removed = 0 }
		for _, key in keys() do
			local bundle = self.bundles[key]
			if not bundle.published then
				local meta = metadata
				if type(metadata) == "function" then
					meta = metadata(key, bundle)
				elseif type(metadata) == "table" then
					meta = table.clone(metadata)
					meta.Name = string.sub((metadata.Name or "Editable3D") .. " " .. key, 1, 50)
				end
				local ok, result = pcall(R.publishInChunks, bundle, meta, options)
				if not ok or not result.committed then
					report.success = false
					report.failures[key] = if ok
						then tostring(result.stage) .. ": " .. tostring(result.error)
						else tostring(result)
				end
			end
			if bundle.published then
				local meshes = {}
				local color: string? = nil
				for _, h in bundle.handles do
					local part = h.part
					if part then
						table.insert(meshes, assetNumber(part.MeshId) or "?")
						local surface = part:FindFirstChildOfClass("SurfaceAppearance")
						if surface and not color then
							color = assetNumber((surface :: any).ColorMap)
						end
					end
				end
				report.assets[key] = { meshes = meshes, color = color }
				R.release(bundle)
			end
		end
		if report.success then
			local models = {}
			for _, bundle in self.bundles do
				models[bundle.model] = true
			end
			for _, entry in self.hidden do
				local part = entry.part
				local parent = part.Parent
				part:Destroy()
				report.removed += 1
				if parent and parent:IsA("Model") and #parent:GetChildren() == 0 then
					local holdsStaged = false
					for model in models do
						if model:IsDescendantOf(parent) then
							holdsStaged = true
						end
					end
					if not holdsStaged then
						parent:Destroy()
					end
				end
			end
			self.hidden = {}
		end
		return report
	end
	function handle.revert(self: Stage)
		for _, bundle in self.bundles do
			if not bundle.published then
				R.destroy(bundle)
			end
		end
		for _, entry in self.hidden do
			entry.part.Transparency = entry.transparency
		end
		self.hidden = {}
	end
	return handle :: Stage
end
export type TerrainFillOptions = {
	ground: number,
	seaLevel: number?,
	top: Enum.Material?,
	fill: Enum.Material?,
	edge: Enum.Material?,
	edgeWidth: number?,
	inset: number?,
	bottom: number?,
	margin: number?,
	resolution: number?,
	strip: number?,
}
-- Fills Roblox Terrain to a polygon outline (Vector2(x, z), either winding): land up to `ground`
-- inside the outline (top material, with an `edge` band of `edgeWidth` along the outline, e.g. a
-- promenade), pulled `inset` studs inside it (so a wall mesh can form the edge), and water up to
-- `seaLevel` (with air above) everywhere else in the outline's bounding box plus `margin`.
-- Written in strips to bound memory. Returns the number of land columns.
function R.fillTerrain(terrain: Terrain, outline: { Vector2 }, options: TerrainFillOptions): number
	local Planar = require(script.Parent.Planar) :: any
	local res = options.resolution or 4
	local sea = options.seaLevel or 0
	local ground = options.ground
	local bottom = options.bottom or (sea - 12)
	local margin = options.margin or 40
	local inset = options.inset or 0
	local edgeWidth = options.edgeWidth or 0
	local top, fill = options.top or Enum.Material.Grass, options.fill or Enum.Material.Ground
	local edge = options.edge or top
	local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for _, p in outline do
		lo, hi = lo:Min(p), hi:Max(p)
	end
	lo -= Vector2.one * margin
	hi += Vector2.one * margin
	local land = 0
	local stripSize = options.strip or 160
	local z0 = lo.Y
	while z0 < hi.Y do
		local region = Region3.new(
			Vector3.new(lo.X, bottom, z0),
			Vector3.new(hi.X, ground + res * 2, math.min(z0 + stripSize, hi.Y))
		):ExpandToGrid(res)
		local mats, occ = terrain:ReadVoxels(region, res)
		local size = mats.Size
		local base = region.CFrame.Position - region.Size / 2
		for ix = 1, size.X do
			local x = base.X + (ix - 0.5) * res
			for iz = 1, size.Z do
				local z = base.Z + (iz - 0.5) * res
				local p = Vector2.new(x, z)
				local inside = Planar.outlineContains(outline, p)
				local d = if inside then Planar.outlineDistance(outline, p) else 0
				local isLand = inside and d > inset
				local surface = if isLand and d < inset + edgeWidth then edge else top
				if isLand then
					land += 1
				end
				for iy = 1, size.Y do
					local y0 = base.Y + (iy - 1) * res
					local y1 = y0 + res
					local level, below, cover = sea, Enum.Material.Water, Enum.Material.Water
					if isLand then
						level, below, cover = ground, fill, surface
					end
					if y1 <= level - res then
						mats[ix][iy][iz], occ[ix][iy][iz] = below, 1
					elseif y1 <= level then
						mats[ix][iy][iz], occ[ix][iy][iz] = cover, 1
					elseif y0 < level then
						mats[ix][iy][iz], occ[ix][iy][iz] = cover, (level - y0) / res
					else
						mats[ix][iy][iz], occ[ix][iy][iz] = Enum.Material.Air, 0
					end
				end
			end
		end
		terrain:WriteVoxels(region, res, mats, occ)
		z0 += stripSize
	end
	return land
end
return R
