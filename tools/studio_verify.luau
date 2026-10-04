-- Invoke explicitly in Studio's Edit context after serving dist on localhost:8772.
-- Uses a fresh tree to avoid require caches. Does not replace the installed package.
local H = game:GetService("HttpService")
local function writeReport(parent, value)
	local encoded = H:JSONEncode(value)
	local folder = Instance.new("Folder")
	folder.Name = "VerificationReport"
	local count = math.ceil(#encoded / 50000)
	for index = 1, count do
		local chunk = Instance.new("StringValue")
		chunk.Name = string.format("Part%04d", index)
		chunk.Value = string.sub(encoded, (index - 1) * 50000 + 1, index * 50000)
		chunk.Parent = folder
	end
	folder:SetAttribute("Chunks", count)
	folder:SetAttribute("Bytes", #encoded)
	local previous = parent:FindFirstChild("VerificationReport")
	if previous then
		previous:Destroy()
	end
	folder.Parent = parent
	return #encoded
end
local before = H.HttpEnabled
H.HttpEnabled = true
local ok, files = pcall(function()
	return H:JSONDecode(H:GetAsync("http://127.0.0.1:8772/sources.json"))
end)
H.HttpEnabled = before
assert(ok, files)
local root = Instance.new("ModuleScript")
root.Name = "Editable3D_Verification_" .. os.time()
for _, file in files do
	if file.path == "" then
		root.Source = file.source
	else
		local parent = root
		local segments = string.split(file.path, "/")
		for i = 1, #segments - 1 do
			local folder = parent:FindFirstChild(segments[i])
			if not folder then
				folder = Instance.new("Folder")
				folder.Name = segments[i]
				folder.Parent = parent
			end
			parent = folder
		end
		local module = Instance.new("ModuleScript")
		module.Name, module.Source, module.Parent = file.name, file.source, parent
	end
end
root.Parent = game:GetService("ServerStorage")
root:SetAttribute("TestState", "running")
task.defer(function()
	local success, report = pcall(function()
		local E = require(root)
		local tests = require(root.RunAllTests)(E, {
			suiteCheckpoint = function(state)
				root:SetAttribute("CurrentSuite", state.suite)
				root:SetAttribute("SuiteStage", state.stage)
				root:SetAttribute("TestsPassed", state.passed)
				root:SetAttribute("TestsFailed", state.failed)
				task.wait()
			end,
		})
		local examples = { passed = 0, failed = 0, results = {} }
		for _, module in root.Examples:GetChildren() do
			root:SetAttribute("CurrentExample", module.Name)
			task.wait()
			local passed, err = pcall(function()
				local run = require(module)
				if module.Name == "SculptAndMaterial" or module.Name == "TiledMaterial" then
					local bundle = run()
					E.Roblox.destroy(bundle)
				elseif module.Name == "PBRPreview" then
					run({ width = 12, height = 8, samples = 1 })
				elseif module.Name == "GLTFRoundtrip" then
					run(E)
				else
					run()
				end
			end)
			examples[passed and "passed" or "failed"] += 1
			table.insert(
				examples.results,
				{ name = module.Name, passed = passed, error = not passed and tostring(err) or nil }
			)
		end
		local sourceParity = true
		for _, file in files do
			local object = root
			if file.path ~= "" then
				for _, segment in string.split(file.path, "/") do
					object = object:FindFirstChild(segment)
				end
			end
			sourceParity = sourceParity and object.Source == file.source
		end
		return {
			version = E.Version,
			tests = tests,
			examples = examples,
			sourceParity = sourceParity,
			portableModules = #files,
			httpEnabled = H.HttpEnabled,
			installed = false,
			assetPublishingInvoked = false,
			scopeComplete = false,
			success = tests.success and examples.failed == 0 and sourceParity,
		}
	end)
	writeReport(root, success and report or { success = false, error = tostring(report) })
	root:SetAttribute("TestState", success and report.success and "passed" or "failed")
end)
return { root = root.Name, state = "running", modules = #files }
