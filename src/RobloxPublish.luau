-- Engine boundary for the independently testable publishing transaction.
local Pipeline = require(script.Parent.PublishPipeline)
local Native = require(script.Parent.NativeContent)
local function backendFor(assetService)
	local backend = {
		upload = function(object, kind, meta)
			local status, id = assetService:CreateAssetAsync(object, Enum.AssetType[kind], meta or {})
			assert(
				status == Enum.CreateAssetResult.Success,
				"Asset upload failed: " .. tostring(status) .. " " .. tostring(id)
			)
			return tostring(id)
		end,
		load = function(id, kind)
			local content = Content.fromUri("rbxassetid://" .. id)
			if kind == "Mesh" then
				return assert(
					assetService:CreateEditableMeshAsync(content),
					"Mesh readback allocation failed"
				)
			end
			return assert(assetService:CreateEditableImageAsync(content), "Image readback allocation failed")
		end,
		snapshot = function(object, kind, budget)
			return (kind == "Mesh" and Native.mesh or Native.image)(object, budget)
		end,
		-- Meshes: exact corners, normals within Native.NORMAL_TOLERANCE (the pipeline quantizes them).
		equivalent = function(_kind, a, b)
			return Native.equivalent(a, b)
		end,
		-- The resume ledger keeps a 64-bit digest, not the pixels or the mesh (a session's ledger otherwise
		-- holds a full copy of everything it published).
		digest = function(_kind, snapshot)
			return Native.digest(snapshot)
		end,
		destroy = function(object)
			object:Destroy()
		end,
		backup = function(part)
			return assert(part:Clone(), "Publish rollback backup requires Archivable=true")
		end,
		stage = function(id, part)
			return assetService:CreateMeshPartAsync(Content.fromUri("rbxassetid://" .. id), {
				CollisionFidelity = part.CollisionFidelity,
				RenderFidelity = part.RenderFidelity,
				FluidFidelity = part.FluidFidelity,
			})
		end,
		apply = function(part, source)
			local frame, size, texture = part.CFrame, part.Size, part.TextureContent
			part:ApplyMesh(source)
			part.TextureContent = texture
			part.Size = size
			part.CFrame = frame
		end,
		restore = function(part, backup)
			part:ApplyMesh(backup)
			part.Size = backup.Size
			part.CFrame = backup.CFrame
		end,
		guard = function(part)
			local properties = {
				"MeshContent",
				"TextureContent",
				"Parent",
				"CFrame",
				"Size",
				"RenderFidelity",
				"CollisionFidelity",
				"FluidFidelity",
			}
			local before = {}
			local surface = part:FindFirstChildOfClass("SurfaceAppearance")
			for _, key in properties do
				before[key] = part[key]
			end
			return function()
				assert(
					part:FindFirstChildOfClass("SurfaceAppearance") == surface,
					"SurfaceAppearance changed during publishing"
				)
				for _, key in properties do
					assert(part[key] == before[key], "MeshPart changed during publishing: " .. key)
				end
			end
		end,
		maps = function(part)
			local maps = {}
			local function track(object, key)
				local content = object[key]
				if content.SourceType == Enum.ContentSourceType.Object then
					table.insert(maps, {
						object = content.Object,
						original = content,
						read = function()
							return object[key]
						end,
						write = function(value)
							object[key] = value
						end,
					})
				end
			end
			track(part, "TextureContent")
			local surface = part:FindFirstChildOfClass("SurfaceAppearance")
			if surface then
				for _, name in { "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap", "EmissiveMask" } do
					track(surface, name .. "Content")
				end
			end
			return maps
		end,
		uri = function(id)
			return Content.fromUri("rbxassetid://" .. id)
		end,
		sleep = function(seconds)
			task.wait(seconds)
		end,
	}
	return backend
end
local function run(bundle, metadata, options)
	return Pipeline.run(bundle, metadata, options, backendFor(game:GetService("AssetService")))
end
local function runChunked(bundle, metadata, options, perTransaction)
	return Pipeline.runChunked(
		bundle,
		metadata,
		options,
		backendFor(game:GetService("AssetService")),
		perTransaction
	)
end
return table.freeze({ run = run, runChunked = runChunked, backend = backendFor })
