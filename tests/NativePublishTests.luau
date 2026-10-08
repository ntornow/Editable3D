-- Uses the production engine adapter with local in-memory readbacks. Never uploads.
local Adapter = require(script.Parent.RobloxPublish)
local Pipeline = require(script.Parent.PublishPipeline)
local harness = require(script.Parent.TestHarness)
return function(E, options)
	local report, test, rejects = harness()
	test("Scene publishes default their time budget to the work (a caller's limit is kept)", function()
		local small = Adapter.sceneOptions({ handles = { {}, {} } }, nil)
		assert(small.maxSeconds == 600, "at least ten minutes: " .. tostring(small.maxSeconds))
		local handles = table.create(23, {})
		local big = Adapter.sceneOptions({ handles = handles, images = { {}, {} } }, { attempts = 3 })
		assert(big.maxSeconds == 120 * 25 and big.attempts == 3, "two minutes per part or image")
		local ledger = {}
		local kept = Adapter.sceneOptions({ handles = handles }, { maxSeconds = 30, resume = ledger })
		assert(kept.maxSeconds == 30 and kept.resume == ledger, "caller's limit and ledger kept")
	end)
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
			-- a part that keeps no face is hidden without a preview; it goes only when every other part
			-- publishes, so a failed publish leaves it for revert
			local other =
				E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(2, 2, 2))), { name = "ReshapeGone" })
			other.model.Parent = holder
			local gonePart = other.handles[1].part
			gonePart.Name = "ReshapeGone" -- toModel names its parts Mesh_1, Mesh_2, ...
			local both = E.Roblox.reshape({ part, gonePart }, function(p)
				return p
			end, {
				keep = function(_, owner)
					return owner ~= gonePart
				end,
			})
			local gone = both.entries[2]
			assert(gone.removed and gone.bundle == nil and gonePart.Transparency == 1, "removed part hidden")
			assert(both.entries[1].bundle ~= nil and not both.entries[1].removed, "other part previewed")
			local failed = both:publish({ Name = "ReshapeFixture" }, {
				cancelled = function()
					return true
				end,
			})
			assert(not failed.success and #failed.removed == 0, "nothing removed after a failed publish")
			assert(failed.parts[2].part == "ReshapeGone" and failed.parts[2].removed, "removed row reported")
			assert(gonePart.Parent ~= nil and gonePart.Transparency == 1, "removed part kept for revert")
			both:revert()
			assert(gonePart.Transparency == 0 and part.Transparency == 0, "revert shows both again")
			local only = E.Roblox.reshape({ gonePart }, function(p)
				return p
			end, {
				keep = function()
					return false
				end,
			})
			local done = only:publish({ Name = "ReshapeFixture" })
			assert(done.success and done.removed[1] == "ReshapeGone", "removed on a successful publish")
			assert(gonePart.Parent == nil, "removed part destroyed")
			E.Roblox.destroy(other, { force = true })
		end)
		holder:Destroy()
		E.Roblox.destroy(source)
		assert(ok, err)
	end)
	test(
		"Roblox.stage hides the replaced parts, keeps them on a failed publish and revert restores them",
		function()
			local old =
				E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(2, 2, 2))), { name = "StageOld" })
			local fresh =
				E.Roblox.toModel(E.UV.box(E.Primitives.box(Vector3.new(3, 3, 3))), { name = "StageNew" })
			local folder = Instance.new("Folder")
			old.model.Parent = folder
			fresh.model.Parent = folder
			local part = old.handles[1].part
			local ok, err = pcall(function()
				local stage = E.Roblox.stage({ New = fresh }, { part })
				assert(part.Transparency == 1, "replaced part hidden")
				assert(
					stage.bundles.New == fresh and #stage.hidden == 1,
					"handle lists bundles and hidden parts"
				)
				-- a cancelled publish fails before any upload: nothing is removed, the preview stays
				local report = stage:publish({ Name = "StageFixture" }, {
					cancelled = function()
						return true
					end,
				})
				assert(not report.success and report.failures.New ~= nil, "failure keyed by bundle name")
				assert(report.removed == 0 and report.assets.New == nil, "nothing removed or recorded")
				assert(part.Parent ~= nil and part.Transparency == 1, "replaced part kept hidden")
				assert(fresh.model.Parent == folder and not fresh.published, "preview kept")
				stage:revert()
				assert(part.Transparency == 0, "replaced part shown again")
				assert(fresh.model.Parent == nil, "preview destroyed")
				assert(#stage.hidden == 0, "hidden list cleared")
			end)
			folder:Destroy()
			E.Roblox.destroy(old)
			assert(ok, err)
		end
	)
	test("Roblox.sweep destroys editables no part displays and keeps displayed ones", function()
		local service = game:GetService("AssetService")
		local shown = assert(service:CreateEditableImage({ Size = Vector2.new(2, 2) }))
		local stale = assert(service:CreateEditableImage({ Size = Vector2.new(2, 2) }))
		local mesh = assert(service:CreateEditableMesh({}))
		mesh:AddVertex(Vector3.zero)
		local folder = Instance.new("Folder")
		local part = Instance.new("MeshPart")
		local surface = Instance.new("SurfaceAppearance")
		surface.ColorMapContent = Content.fromObject(shown)
		surface.Parent = part
		part.Parent = folder
		local ok, err = pcall(function()
			local live = E.Roblox.liveEditables({ folder })
			assert(live[shown] and not live[stale], "displayed image found")
			local report = E.Roblox.sweep(
				{ a = { shown }, b = { { stale, mesh } }, c = part },
				{ roots = { folder } }
			)
			assert(report.destroyed == 2 and report.kept == 1, report.destroyed .. " / " .. report.kept)
			-- a destroyed editable reads as a 1x1 image or an empty mesh rather than raising
			assert(shown.Size == Vector2.new(2, 2), "displayed image kept")
			assert(stale.Size == Vector2.new(1, 1) and #mesh:GetVertices() == 0, "stale editables destroyed")
		end)
		folder:Destroy()
		shown:Destroy()
		assert(ok, err)
	end)
	test(
		"Roblox.bakedModel bakes colour and normal maps over the UVs and owns only its own images",
		function()
			local service = game:GetService("AssetService")
			local shared = assert(service:CreateEditableImage({ Size = Vector2.new(2, 2) }))
			local holder = Instance.new("Folder")
			local bundle
			local ok, err = pcall(function()
				local mesh = E.UV.box(E.Primitives.box(Vector3.new(2, 2, 2)))
				bundle = E.Roblox.bakedModel(mesh, {
					size = 16,
					color = function()
						return Color3.new(1, 0, 0), 1
					end,
					normal = function(ctx)
						return ctx.normal + Vector3.yAxis * 0.5
					end,
					roughness = shared,
					metalness = Content.fromUri("rbxassetid://1"),
					name = "BakedFixture",
					parent = holder,
				})
				assert(
					bundle.model.Parent == holder and #bundle.images == 2,
					"model parented, two images owned"
				)
				local part = bundle.handles[1].part
				local sa = part:FindFirstChildOfClass("SurfaceAppearance")
				assert(sa.ColorMapContent.Object == bundle.images[1], "colour map")
				assert(sa.NormalMapContent.Object == bundle.images[2], "normal map")
				assert(sa.RoughnessMapContent.Object == shared, "shared roughness kept")
				assert(sa.MetalnessMapContent.Uri == "rbxassetid://1", "metalness content kept")
				assert(part.Material == Enum.Material.SmoothPlastic and part.DoubleSided, "part defaults")
				local px = bundle.images[1]:ReadPixelsBuffer(Vector2.zero, Vector2.new(16, 16))
				local red = 0
				for i = 0, 255 do
					if buffer.readu8(px, i * 4) == 255 and buffer.readu8(px, i * 4 + 1) == 0 then
						red += 1
					end
				end
				assert(red > 100, "colour baked: " .. red)
				E.Roblox.destroy(bundle)
				assert(shared.Size == Vector2.new(2, 2), "shared image not destroyed")
				bundle = nil
			end)
			if bundle then
				E.Roblox.destroy(bundle)
			end
			holder:Destroy()
			shared:Destroy()
			assert(ok, err)
		end
	)
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
			-- the factor sees each texel's current colour: halve texels brighter than 90/255 (all of them here)
			local seen = 0
			local graded = E.Roblox.modulateColor({ part }, function(_, _, current)
				if math.abs(current.R * 255 - 100) < 0.5 then
					seen += 1
				end
				return if current.R > 90 / 255 then 0.5 else 1
			end, { padding = 1 })
			local gp = graded.images[1]:ReadPixelsBuffer(Vector2.zero, Vector2.new(32, 32))
			local halved = 0
			for i = 0, 32 * 32 - 1 do
				if buffer.readu8(gp, i * 4) == 50 then
					halved += 1
				end
			end
			assert(seen > 0 and halved == graded.changed and halved > 0, "graded by colour: " .. halved)
			graded.revert()
		end)
		holder:Destroy()
		E.Roblox.destroy(source)
		image:Destroy()
		assert(ok, err)
	end)
	test(
		"Roblox.bakeNormalMap bakes a world-space normal in the parts' UV space; revert restores the surface",
		function()
			local service = game:GetService("AssetService")
			local source = E.Roblox.toModel(
				E.UV.box(E.Primitives.box(Vector3.new(4, 4, 4))),
				{ name = "NormalMapFixture" }
			)
			local part = source.handles[1].part
			local image = assert(service:CreateEditableImage({ Size = Vector2.new(32, 32) }))
			local surface = Instance.new("SurfaceAppearance")
			surface.ColorMapContent = Content.fromObject(image)
			surface.Parent = part
			local holder = Instance.new("Folder")
			source.model.Parent = holder
			local ok, err = pcall(function()
				-- tilt every normal toward +y: the sides tilt 26.6 degrees, the top and bottom stay flat
				local bake = E.Roblox.bakeNormalMap({ part }, function(_, n)
					return n + Vector3.yAxis * 0.5
				end)
				local sa = part:FindFirstChildOfClass("SurfaceAppearance") :: SurfaceAppearance
				assert(sa ~= surface and sa.NormalMapContent.Object == bake.images[1], "map on a new surface")
				assert(sa.ColorMapContent.Object == image, "colour map kept")
				local px = bake.images[1]:ReadPixelsBuffer(Vector2.zero, Vector2.new(32, 32))
				local tilted, flat = 0, 0
				for i = 0, 32 * 32 - 1 do
					local b = buffer.readu8(px, i * 4 + 2)
					if b >= 236 and b <= 246 then
						tilted += 1
					elseif b >= 253 then
						flat += 1
					end
				end
				assert(tilted > 100 and flat > 20, "tilted " .. tilted .. ", flat " .. flat)
				bake.revert()
				assert(
					part:FindFirstChildOfClass("SurfaceAppearance") == surface,
					"original surface restored"
				)
				assert(#bake.images == 0, "images released")
			end)
			holder:Destroy()
			E.Roblox.destroy(source)
			image:Destroy()
			assert(ok, err)
		end
	)
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
