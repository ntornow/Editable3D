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
	test("Roblox.rebake can modulate the previous colour map through ctx.uv", function()
		local bundle =
			E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(4, 4, 4))), { name = "RebakeModulate" })
		local part = bundle.handles[1].part
		Instance.new("SurfaceAppearance").Parent = part
		local ok, err = pcall(function()
			local first = E.Roblox.rebake({ part }, function()
				return Color3.new(0, 0.8, 0), 1
			end, { size = 16 })
			local seen = false
			local second = E.Roblox.rebake({ part }, function(_, _, _, ctx, previous)
				seen = previous ~= nil and ctx.uv ~= nil
				local c = previous and previous:sample(ctx.uv) or Color3.new(1, 0, 0)
				return Color3.new(c.R * 0.5, c.G * 0.5, c.B * 0.5), 1
			end, { size = 16, readPrevious = true })
			assert(seen, "shader received ctx and the previous texture")
			local pixel = second.entries[1].image:ReadPixelsBuffer(Vector2.new(8, 8), Vector2.new(1, 1))
			local g = buffer.readu8(pixel, 1)
			assert(g > 80 and g < 125 and buffer.readu8(pixel, 0) < 20, "halved green " .. g)
			second:revert()
			first:revert()
		end)
		E.Roblox.destroy(bundle)
		assert(ok, err)
	end)
	test("Roblox.rebake forwards budget options to each bake", function()
		local bundle =
			E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(4, 4, 4))), { name = "RebakeBudget" })
		local part = bundle.handles[1].part
		local ok, err = pcall(function()
			local checkpoints = 0
			local handle = E.Roblox.rebake({ part }, function()
				return Color3.new(0, 0, 1), 1
			end, {
				size = 32,
				checkpointEvery = 16,
				checkpoint = function()
					checkpoints += 1
				end,
			})
			assert(checkpoints > 0, "checkpoint callback reached the bake")
			handle:revert()
		end)
		E.Roblox.destroy(bundle)
		assert(ok, err)
	end)
	test("Roblox.reshape previews a deformed copy in place and revert restores the original", function()
		local source =
			E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(4, 4, 4))), { name = "ReshapeFixture" })
		local part = source.handles[1].part
		part.Material = Enum.Material.Metal
		part.Color = Color3.new(0.2, 0.5, 0.4)
		local appearance = Instance.new("SurfaceAppearance")
		appearance.Parent = part
		local holder = Instance.new("Folder")
		source.model.Parent = holder
		local ok, err = pcall(function()
			local handle = E.Roblox.reshape({ part }, function(p)
				return p + Vector3.new(0, p.Y > 0 and 1 or 0, 0)
			end)
			local entry = handle.entries[1]
			assert(part.Transparency == 1, "original hidden")
			assert(entry.bundle.model.Parent == part.Parent, "preview shown beside the original")
			local copy = entry.bundle.handles[1].part
			assert(copy.Material == Enum.Material.Metal and copy.Color == part.Color, "appearance copied")
			assert(copy:FindFirstChildOfClass("SurfaceAppearance"), "surface appearance cloned")
			local hi = -math.huge
			for _, v in E.Roblox.fromPart(copy).vertices do
				hi = math.max(hi, v.Y)
			end
			assert(math.abs(hi - (part.Position.Y + 3)) < 1e-3, "top face raised by the map: " .. hi)
			-- a cancelled publish fails before any upload and reports each part in the list
			local report = handle:publish({ Name = "ReshapeFixture" }, {
				cancelled = function()
					return true
				end,
			})
			assert(not report.success and #report.parts == 1, "one failed entry")
			assert(report.parts[1].part == part.Name and report.parts[1].error ~= nil, "entry names its part")
			assert(report.failures[part.Name] == report.parts[1].error, "keyed failure kept")
			assert(part.Parent ~= nil and part.Transparency == 1, "preview kept after a failed publish")
			handle:revert()
			-- keep trims faces by their original centroid: only the bottom face (centroid 2 below the
			-- centre; side triangles have centroids within 2/3 of it) survives
			local trimmed = E.Roblox.reshape({ part }, function(p)
				return p
			end, {
				keep = function(c)
					return c.Y < part.Position.Y - 1.5
				end,
			})
			local copy2 = trimmed.entries[1].bundle.handles[1].part
			local kept = E.Roblox.fromPart(copy2)
			local top, faces = -math.huge, 0
			for _, v in kept.vertices do
				top = math.max(top, v.Y)
			end
			for _ in kept.faces do
				faces += 1
			end
			assert(faces >= 1 and faces <= 2, "only the bottom face kept: " .. faces)
			assert(math.abs(top - (part.Position.Y - 2)) < 1e-3, "kept faces lie on the bottom: " .. top)
			trimmed:revert()
			assert(part.Transparency == 0 and entry.bundle.model.Parent == nil, "reverted")
		end)
		holder:Destroy()
		E.Roblox.destroy(source)
		assert(ok, err)
	end)
	test("Roblox.modulateColor multiplies only the covered texels and revert restores the surface", function()
		local service = game:GetService("AssetService")
		local source =
			E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(4, 4, 4))), { name = "ModulateFixture" })
		local part = source.handles[1].part
		local image = assert(service:CreateEditableImage({ Size = Vector2.new(32, 32) }))
		local gray = buffer.create(32 * 32 * 4)
		for i = 0, 32 * 32 - 1 do
			buffer.writeu8(gray, i * 4, 100)
			buffer.writeu8(gray, i * 4 + 1, 100)
			buffer.writeu8(gray, i * 4 + 2, 100)
			buffer.writeu8(gray, i * 4 + 3, 255)
		end
		image:WritePixelsBuffer(Vector2.zero, image.Size, gray)
		local surface = Instance.new("SurfaceAppearance")
		surface.ColorMapContent = Content.fromObject(image)
		surface.Parent = part
		local holder = Instance.new("Folder")
		source.model.Parent = holder
		local result
		local ok, err = pcall(function()
			-- the top face doubles, everything else keeps its bytes
			result = E.Roblox.modulateColor({ part }, function(p, n)
				return if n.Y > 0.9 then 2 else 1
			end, { padding = 1 })
			assert(#result.images == 1 and result.changed > 0, "texels changed: " .. tostring(result.changed))
			local fresh = part:FindFirstChildOfClass("SurfaceAppearance")
			assert(
				fresh ~= surface and fresh.ColorMapContent.Object == result.images[1],
				"new surface carries the image"
			)
			local px = result.images[1]:ReadPixelsBuffer(Vector2.zero, Vector2.new(32, 32))
			local doubled, same = 0, 0
			for i = 0, 32 * 32 - 1 do
				local v = buffer.readu8(px, i * 4)
				if v == 200 then
					doubled += 1
				elseif v == 100 then
					same += 1
				end
			end
			assert(
				doubled == result.changed and doubled + same == 32 * 32,
				"only exact doubles: " .. doubled .. "/" .. same
			)
			result.revert()
			assert(part:FindFirstChildOfClass("SurfaceAppearance") == surface, "original surface restored")
		end)
		holder:Destroy()
		E.Roblox.destroy(source)
		image:Destroy()
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
