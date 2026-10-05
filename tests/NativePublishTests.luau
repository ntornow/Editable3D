-- Uses the production engine adapter with local in-memory readbacks. Never uploads.
local Adapter = require(script.Parent.RobloxPublish)
local Pipeline = require(script.Parent.PublishPipeline)
local harness = require(script.Parent.TestHarness)
return function(E, options)
	local report, test, rejects = harness()
	if options and options.native == false then
		return report
	end
	test("Native adapter tracks base texture and all surface image maps", function()
		local service = game:GetService("AssetService")
		local image = assert(service:CreateEditableImage({ Size = Vector2.new(1, 1) }))
		local part = Instance.new("MeshPart")
		local surface = Instance.new("SurfaceAppearance")
		surface.Parent = part
		local ok, err = pcall(function()
			local original = Content.fromObject(image)
			part.TextureContent = original
			for _, name in { "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap", "EmissiveMask" } do
				surface[name .. "Content"] = original
			end
			local maps = Adapter.backend(service).maps(part)
			assert(#maps == 6)
			for _, map in maps do
				assert(map.object == image and map.read() == original)
				map.write(Content.none)
				assert(map.read() == Content.none)
				map.write(map.original)
				assert(map.read() == original)
			end
		end)
		part:Destroy()
		image:Destroy()
		assert(ok, err)
	end)
	test("Native scene guard rejects replaced surfaces and reparenting", function()
		local part = Instance.new("MeshPart")
		local surface = Instance.new("SurfaceAppearance")
		surface.Parent = part
		local folder = Instance.new("Folder")
		local ok, err = pcall(function()
			local backend = Adapter.backend(game:GetService("AssetService"))
			local guard = backend.guard(part)
			surface.Parent = nil
			rejects(guard, "SurfaceAppearance changed")
			surface.Parent = part
			guard = backend.guard(part)
			part.Parent = folder
			rejects(guard, "Parent")
		end)
		part:Destroy()
		surface:Destroy()
		folder:Destroy()
		assert(ok, err)
	end)
	test("Native staging forwards all fidelity options", function()
		local part = Instance.new("MeshPart")
		local captured
		local backend = Adapter.backend({
			CreateMeshPartAsync = function(_, _, options)
				captured = options
				return part
			end,
		})
		local ok, err = pcall(function()
			assert(backend.stage("1", part) == part)
			for _, key in { "CollisionFidelity", "RenderFidelity", "FluidFidelity" } do
				assert(captured[key] == part[key], key)
			end
		end)
		part:Destroy()
		assert(ok, err)
	end)
	for _, fail in { false, true } do
		test(
			"Native publish adapter "
				.. (fail and "rolls back partial ApplyMesh" or "commits and preserves placement"),
			function()
				local resources = {}
				local function keep(o)
					table.insert(resources, assert(o))
					return o
				end
				local ok, err = pcall(function()
					local service = game:GetService("AssetService")
					local old = E.Roblox.toEditable(E.Primitives.box(Vector3.one))
					keep(old.editable)
					local part = keep(service:CreateMeshPartAsync(Content.fromObject(old.editable)))
					part.Size = Vector3.new(3, 4, 5)
					part.CFrame = CFrame.new(8, 9, 10)
					part.TextureContent = Content.fromUri("rbxassetid://123")
					local texture = part.TextureContent
					local original = part.MeshContent
					local nextMesh = E.Roblox.toEditable(E.Primitives.box(Vector3.new(2, 3, 4)))
					keep(nextMesh.editable)
					local backend = Adapter.backend(service)
					local objects = {}
					backend.upload = function(object)
						local id = tostring(#objects + 1)
						table.insert(objects, object)
						return id
					end
					backend.load = function(id)
						return service:CreateEditableMeshAsync(
							Content.fromObject(objects[assert(tonumber(id))])
						)
					end
					backend.stage = function(id)
						return service:CreateMeshPartAsync(Content.fromObject(objects[assert(tonumber(id))]))
					end
					if fail then
						local apply = backend.apply
						backend.apply = function(p, s)
							apply(p, s)
							p.Size = Vector3.one
							error("native partial update")
						end
					end
					local result = Pipeline.run(
						{ handles = { { editable = nextMesh.editable, part = part } } },
						{},
						nil,
						backend
					)
					assert(result.success == not fail, result.error)
					assert(part.Size == Vector3.new(3, 4, 5) and part.CFrame == CFrame.new(8, 9, 10))
					if fail then
						assert(result.rolledBack and part.MeshContent == original)
					else
						assert(part.MeshContent ~= original)
					end
					assert(part.TextureContent == texture, "ApplyMesh lost the existing texture")
					assert(#result.rollbackErrors == 0 and #result.cleanupErrors == 0)
				end)
				for _, r in resources do
					r:Destroy()
				end
				assert(ok, err)
			end
		)
	end
	test("Roblox.rebake previews a world-space bake and revert restores the appearance", function()
		local bundle =
			E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(4, 4, 4))), { name = "RebakeFixture" })
		local part = bundle.handles[1].part
		local original = Instance.new("SurfaceAppearance")
		original.Color = Color3.new(0.5, 0.6, 0.7)
		original.Parent = part
		local ok, err = pcall(function()
			local handle = E.Roblox.rebake({ part }, function()
				return Color3.new(1, 0, 0), 1
			end, { size = 16 })
			local sa = part:FindFirstChildOfClass("SurfaceAppearance")
			assert(sa ~= original and sa.Color == original.Color, "new appearance with copied tint")
			assert(original.Parent == nil, "previous appearance detached")
			local image = handle.entries[1].image
			local pixel = image:ReadPixelsBuffer(Vector2.new(8, 8), Vector2.new(1, 1))
			assert(buffer.readu8(pixel, 0) > 200 and buffer.readu8(pixel, 1) < 40, "baked red")
			handle:revert()
			assert(part:FindFirstChildOfClass("SurfaceAppearance") == original, "reverted")
		end)
		E.Roblox.destroy(bundle)
		assert(ok, err)
	end)
	test("Roblox.fillTerrain writes land, edge band and sea inside the outline's box", function()
		local terrain = workspace.Terrain
		local origin = Vector2.new(4000, 4000)
		local outline = {}
		for k = 0, 15 do
			local a = 2 * math.pi * k / 16
			table.insert(outline, origin + Vector2.new(math.cos(a), math.sin(a)) * 40)
		end
		local region = Region3.new(Vector3.new(3940, -16, 3940), Vector3.new(4060, 24, 4060)):ExpandToGrid(4)
		local mats, occ = terrain:ReadVoxels(region, 4)
		local ok, err = pcall(function()
			local land = E.Roblox.fillTerrain(terrain, outline, {
				ground = 8,
				seaLevel = 0,
				edge = Enum.Material.Pavement,
				edgeWidth = 8,
				inset = 2,
				margin = 12,
			})
			assert(land > 200, "land columns " .. land)
			local function at(x, z, y)
				local m = terrain:ReadVoxels(
					Region3.new(Vector3.new(x, y, z), Vector3.new(x + 4, y + 4, z + 4)):ExpandToGrid(4),
					4
				)
				return m[1][1][1]
			end
			assert(at(4000, 4000, 4) == Enum.Material.Grass, "lawn at the centre")
			assert(at(4034, 4000, 4) == Enum.Material.Pavement, "edge band")
			assert(at(4048, 4000, -4) == Enum.Material.Water, "sea outside")
		end)
		terrain:WriteVoxels(region, 4, mats, occ)
		assert(ok, err)
	end)
	return report
end
