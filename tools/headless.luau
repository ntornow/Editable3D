-- Lune adapter for pure authoring tests. Native services reject instead of mocking success.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")
local process = require("@lune/process")
local root = "."
local cache = {}
local parent = {}
function parent:FindFirstChild(name)
	return self[name]
end
for _, folder in { "src", "tests" } do
	for _, filename in fs.readDir(root .. "/" .. folder) do
		if string.sub(filename, -5) == ".luau" then
			local name = string.sub(filename, 1, -6)
			local path = root .. "/" .. folder .. "/" .. filename
			parent[name] = { Name = name, Parent = parent, path = path, source = fs.readFile(path) }
		end
	end
end
local http = {
	JSONEncode = function(_, value)
		return serde.encode("json", value)
	end,
	JSONDecode = function(_, value)
		return serde.decode("json", value)
	end,
}
local game = {
	GetService = function(_, name)
		assert(name == "HttpService", "Native service unavailable in headless tests: " .. name)
		return http
	end,
}
local function load(node)
	if cache[node.Name] ~= nil then
		return cache[node.Name]
	end
	local code = node.source
	local environment = {
		script = node,
		require = load,
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		CFrame = roblox.CFrame,
		Enum = roblox.Enum,
		game = game,
		task = task,
	}
	local fn = luau.load(code, { environment = environment, debugName = node.path })
	local value = fn()
	cache[node.Name] = value
	return value
end
local E = setmetatable({}, {
	__index = function(_, name)
		return load(parent[name])
	end,
})
local suites =
	{ "TextureTests", "OperationBudgetTests", "GuardedImageTests", "PublishTests", "NativeContentTests" }
local result = { passed = 0, failed = 0, suites = {} }
for _, name in suites do
	local report = load(parent[name])(E, { native = false })
	result.suites[name] = report
	result.passed += report.passed
	result.failed += report.failed
	print(name, report.passed, "passed", report.failed, "failed")
	for _, case in report.results do
		if not case.passed then
			warn(case.name, case.error)
		end
	end
end
fs.writeDir(".validation")
fs.writeFile(".validation/headless.json", serde.encode("json", result, true))
assert(result.failed == 0, "Headless regression failures")
if process.args[1] == "--bench" then
	local report = load(parent.ProductionBenchmarks)(E)
	fs.writeFile(".validation/benchmarks.json", serde.encode("json", report, true))
end
