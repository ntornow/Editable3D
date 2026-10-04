-- Run with Lune from the package directory. Reads artifacts without scene access.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
for _, directory in { "dist", "dist/production" } do
	local sources = serde.decode("json", fs.readFile(directory .. "/sources.json"))
	for _, filename in { "Editable3D.rbxmx", "Editable3D-rojo.rbxm" } do
		local objects = roblox.deserializeModel(fs.readFile(directory .. "/" .. filename))
		assert(#objects == 1 and objects[1].ClassName == "ModuleScript")
		local root = objects[1]
		if directory == "dist/production" then
			assert(
				not root:FindFirstChild("Examples") and not root:FindFirstChild("Tests"),
				"Production includes dev modules"
			)
		end
		local count = 1
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("ModuleScript") then
				count += 1
			end
		end
		assert(count == #sources)
		for _, source in sources do
			local module = root
			if source.path ~= "" then
				for _, name in string.split(source.path, "/") do
					module = assert(module:FindFirstChild(name), "Missing " .. source.path)
				end
			end
			assert(module.Source == source.source, "Source mismatch: " .. source.path)
		end
		print(directory .. "/" .. filename .. ": " .. count .. " matching ModuleScript sources")
	end
end
