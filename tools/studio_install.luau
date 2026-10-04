-- Explicit Edit-context installation after a completed studio_verify.luau run.
-- Replace all three placeholders before invocation. Archives the previous library.
-- Retain the two newest package archives after a verified installation.
local candidateName = "__VERIFIED_ROOT__"
local expectedVersion = "__NEW_VERSION__"
local previousVersion = "__PREVIOUS_VERSION__"
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
local function reportText(parent)
	local value = assert(parent:FindFirstChild("VerificationReport"), "Verification report missing")
	if value:IsA("StringValue") then
		return value.Value
	end
	assert(value:IsA("Folder"), "Invalid verification storage")
	local chunks = {}
	for index = 1, value:GetAttribute("Chunks") do
		chunks[index] = value[string.format("Part%04d", index)].Value
	end
	local text = table.concat(chunks)
	assert(#text == value:GetAttribute("Bytes"), "Truncated verification report")
	return text
end
local root = assert(game.ServerStorage:FindFirstChild(candidateName), "Verified candidate missing")
assert(root:GetAttribute("TestState") == "passed", "Candidate regression did not pass")
local report = H:JSONDecode(reportText(root))
assert(report.success and report.sourceParity and report.version == expectedVersion)
local E = require(root)
assert(E.Version == expectedVersion)
local installed = assert(game.ReplicatedStorage:FindFirstChild("Editable3D"), "Previous installation missing")
assert(require(installed).Version == previousVersion, "Installed version changed; review before replacing it")
local before = H.HttpEnabled
H.HttpEnabled = true
local ok, files, entries, docs, runtimeFiles = pcall(function()
	return H:JSONDecode(H:GetAsync("http://127.0.0.1:8772/sources.json")),
		H:JSONDecode(H:GetAsync("http://127.0.0.1:8772/api-index.json")),
		H:JSONDecode(H:GetAsync("http://127.0.0.1:8772/docs.json")),
		H:JSONDecode(H:GetAsync("http://127.0.0.1:8772/production/sources.json"))
end)
H.HttpEnabled = before
assert(ok, files)
assert(#files == report.portableModules, "Manifest count changed")
for _, file in files do
	local object = root
	if file.path ~= "" then
		for _, segment in string.split(file.path, "/") do
			object = assert(object:FindFirstChild(segment), "Manifest module missing")
		end
	end
	assert(
		object:IsA("ModuleScript") and object.Source == file.source,
		"Verified source changed: " .. file.path
	)
end
local staticExports, namespaces = 0, {}
for _, entry in entries do
	namespaces[entry.module] = true
	if not entry.method then
		assert(
			type(E[entry.module][entry.member]) == "function",
			"Public export missing: " .. entry.signature
		)
		staticExports += 1
	end
end
-- Every production source must be an exact subset of the tested development tree.
local candidate = root
local runtime = Instance.new("ModuleScript")
runtime.Name = "Editable3D_Runtime_Candidate"
local runtimeOk, runtimeError = pcall(function()
	for _, file in runtimeFiles do
		assert(not file.path:find("/"), "Unexpected nested runtime module")
		local tested = file.path == "" and candidate or candidate:FindFirstChild(file.path)
		assert(
			tested and tested:IsA("ModuleScript") and tested.Source == file.source,
			"Runtime source was not verified: " .. file.path
		)
		if file.path == "" then
			runtime.Source = file.source
		else
			local copy = tested:Clone()
			copy.Parent = runtime
		end
	end
	runtime.Parent = game.ServerStorage
	local runtimeAPI = require(runtime)
	assert(runtimeAPI.Version == expectedVersion)
end)
if not runtimeOk then
	runtime:Destroy()
	error(runtimeError)
end
root = runtime
local documentationFiles = 0
for name, content in { README = assert(docs.README) } do
	if root:FindFirstChild(name) and root[name]:IsA("ModuleScript") then
		name ..= "_GUIDE"
	end
	local doc = root:FindFirstChild(name) or Instance.new("StringValue")
	assert(doc:IsA("StringValue"), "Documentation name collision")
	doc.Name, doc.Value, doc.Parent = name, content, root
	documentationFiles += 1
end
local archive = "Editable3D_Archive_" .. previousVersion:gsub("%.", "_") .. "_" .. os.time()
assert(not game.ServerStorage:FindFirstChild(archive), "Archive name collision")
installed.Name, installed.Parent = archive, game.ServerStorage
root.Name, root.Parent = "Editable3D", game.ReplicatedStorage
local namespaceCount = 0
for _ in namespaces do
	namespaceCount += 1
end
report.installed = true
report.installedProfile = "production"
report.runtimeModules = #runtimeFiles
report.developmentModules = #files
report.installedPath = "ReplicatedStorage.Editable3D"
report.previousArchive = archive
report.verifiedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
report.apiFunctions = #entries
report.staticExports = staticExports
report.publicNamespaces = namespaceCount
report.documentationFiles = documentationFiles
report.scopeComplete = report.scopeComplete == true
report.httpEnabled = H.HttpEnabled
local archives = {}
for _, object in game.ServerStorage:GetChildren() do
	local major, _minor, _patch, stamp = object.Name:match("^Editable3D_Archive_(%d+)_(%d+)_(%d+)_(%d+)$")
	if major and object:IsA("ModuleScript") then
		table.insert(archives, { object = object, stamp = tonumber(stamp) })
	end
end
table.sort(archives, function(a, b)
	return a.stamp > b.stamp
end)
local prunedArchives = {}
for i = 3, #archives do
	local object = archives[i].object
	table.insert(prunedArchives, object.Name)
	object:Destroy()
end
report.archiveRetention = 2
report.prunedArchives = prunedArchives
-- Keep the detailed report on the verification tree for export before its removal.
writeReport(candidate, report)
local compact = table.clone(report)
compact.tests = { passed = report.tests.passed, failed = report.tests.failed, success = report.tests.success }
compact.examples = { passed = report.examples.passed, failed = report.examples.failed }
local reportBytes = writeReport(root, compact)
return {
	version = E.Version,
	runtimeModules = #runtimeFiles,
	verifiedDevelopmentRoot = candidate.Name,
	installedPath = report.installedPath,
	previousArchive = archive,
	tests = report.tests.passed,
	examples = report.examples.passed,
	apiFunctions = #entries,
	staticExports = staticExports,
	documentationFiles = documentationFiles,
	reportBytes = reportBytes,
	prunedArchives = prunedArchives,
}
