-- Lune adapter for the full regression suite outside Studio.
-- Mirrors the package tree (root module, test modules, Examples folder) and provides
-- deterministic stand-ins for the few engine services that pure authoring code uses.
-- Native engine access (AssetService, Instance, EditableMesh) raises NATIVE_SENTINEL, and
-- tests failing only with that sentinel are reported as native skips, not passes.
--
-- Usage: lune run tools/headless.luau [--suite Name ...] [--out path] [--bench]
-- Without --suite, every suite in RunAllTests runs (unless --bench alone is given).
-- tools/run_headless.py runs suites in parallel and enforces tests/headless-baseline.json.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")
local process = require("@lune/process")

local NATIVE_SENTINEL = "Native engine API unavailable in headless tests"

-- Package tree: the root ModuleScript holds src and tests; examples live in a child Folder.
local function node(name, parent, path)
	return { Name = name, Parent = parent, path = path, source = path and fs.readFile(path), children = {} }
end
local root = node("Editable3D", nil, "src/init.luau")
local examples = node("Examples", root, nil)
root.children.Examples = examples
local function mount(folder, parent)
	for _, filename in fs.readDir(folder) do
		local name = string.match(filename, "^(.+)%.luau$")
		if name and name ~= "init" then
			parent.children[name] = node(name, parent, folder .. "/" .. filename)
		end
	end
end
mount("src", root)
mount("tests", root)
mount("examples", examples)

-- Read-only Instance view of the tree: Name, Parent, FindFirstChild, GetChildren, child access.
local instances = {}
local function wrap(n)
	if n == nil then
		return nil
	end
	if instances[n] == nil then
		instances[n] = setmetatable({}, {
			__index = function(_, key)
				if key == "Name" then
					return n.Name
				elseif key == "Parent" then
					return wrap(n.Parent)
				elseif key == "FindFirstChild" then
					return function(_, name)
						return wrap(n.children[name])
					end
				elseif key == "GetChildren" then
					return function()
						local list = {}
						for _, child in n.children do
							table.insert(list, wrap(child))
						end
						return list
					end
				elseif key == "__node" then
					return n
				end
				local child = n.children[key]
				if child == nil then
					error(tostring(key) .. " is not a valid member of " .. n.Name, 2)
				end
				return wrap(child)
			end,
		})
	end
	return instances[n]
end

-- HttpService JSON with Roblox's table rules: a table with #t > 0 is an array (other keys are
-- dropped); any other table is an object whose keys are stringified.
local function encode(value, out)
	local kind = type(value)
	if kind == "nil" then
		table.insert(out, "null")
	elseif kind == "boolean" then
		table.insert(out, tostring(value))
	elseif kind == "number" then
		assert(value == value and math.abs(value) ~= math.huge, "Can't convert to JSON")
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			table.insert(out, string.format("%d", value))
		else
			table.insert(out, string.format("%.17g", value))
		end
	elseif kind == "string" then
		table.insert(out, serde.encode("json", value))
	elseif kind == "table" then
		local n = #value
		if n > 0 then
			table.insert(out, "[")
			for i = 1, n do
				if i > 1 then
					table.insert(out, ",")
				end
				encode(value[i], out)
			end
			table.insert(out, "]")
		else
			local keys = {}
			for key in value do
				assert(type(key) == "string" or type(key) == "number", "Can't convert to JSON")
				table.insert(keys, key)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			table.insert(out, "{")
			for i, key in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, serde.encode("json", tostring(key)))
				table.insert(out, ":")
				encode(value[key], out)
			end
			table.insert(out, "}")
		end
	else
		error("Can't convert to JSON")
	end
end
local HttpService = {
	JSONEncode = function(_, value)
		local out = {}
		encode(value, out)
		return table.concat(out)
	end,
	JSONDecode = function(_, value)
		return serde.decode("json", value)
	end,
}
local function native()
	error(NATIVE_SENTINEL, 2)
end
local nativeObject = setmetatable({}, { __index = native })
local game = setmetatable({
	GetService = function(_, name)
		if name == "HttpService" then
			return HttpService
		end
		return nativeObject
	end,
	HttpService = HttpService,
}, { __index = native })

-- Deterministic Random stand-in. Only NextNumber is used by the package; sequences differ
-- from the engine's, so tests must not depend on specific engine random values.
local Random = {}
Random.__index = Random
function Random.new(seed)
	local s = math.floor(tonumber(seed) or 1) % 2147483647
	if s <= 0 then
		s += 2147483646
	end
	return setmetatable({ s = s }, Random)
end
function Random:NextNumber(minimum, maximum)
	self.s = (self.s * 48271) % 2147483647
	local u = (self.s - 1) / 2147483646
	if minimum == nil then
		return u
	end
	return minimum + (maximum - minimum) * u
end
function Random:Clone()
	return setmetatable({ s = self.s }, Random)
end

-- Lune 0.10.5 builds CFrame.lookAt, CFrame.lookAlong and CFrame.new(position, target) facing
-- away from the target (LookVector = +direction). Rebuild them from fromMatrix, which is correct,
-- using the engine's convention that LookVector is the -Z column.
local function lookAlong(position, direction, up)
	local look = direction.Unit
	up = up or roblox.Vector3.yAxis
	local right = look:Cross(up)
	if right.Magnitude < 1e-6 then
		right = look:Cross(math.abs(look.Z) < 0.9 and roblox.Vector3.zAxis or roblox.Vector3.xAxis)
	end
	right = right.Unit
	return roblox.CFrame.fromMatrix(position, right, right:Cross(look))
end
local CFrame = setmetatable({
	lookAlong = lookAlong,
	lookAt = function(position, target, up)
		return lookAlong(position, target - position, up)
	end,
	new = function(...)
		local a, b = ...
		if select("#", ...) == 2 and typeof(a) == "Vector3" and typeof(b) == "Vector3" then
			return lookAlong(a, b - a)
		end
		return roblox.CFrame.new(...)
	end,
}, { __index = roblox.CFrame })

local cache = {}
local function load(instance)
	local target = instance.__node
	assert(target.source, "Not a ModuleScript: " .. target.Name)
	if cache[target] ~= nil then
		return cache[target]
	end
	local environment = {
		script = wrap(target),
		require = load,
		game = game,
		workspace = nativeObject,
		task = task,
		Instance = nativeObject,
		Content = nativeObject,
		Random = Random,
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		Color3 = roblox.Color3,
		CFrame = CFrame,
		Enum = roblox.Enum,
	}
	local value = luau.load(target.source, { environment = environment, debugName = target.path })()
	cache[target] = value
	return value
end

local function suiteNames()
	local names = {}
	for name in string.gmatch(fs.readFile("tests/RunAllTests.luau"), '\n\t\t\t"([%w_]+)",') do
		table.insert(names, name)
	end
	assert(#names > 0, "No suites found in RunAllTests")
	return names
end

local selected, out, bench = {}, ".validation/headless.json", false
local args = process.args
local i = 1
while i <= #args do
	if args[i] == "--suite" then
		table.insert(selected, args[i + 1])
		i += 1
	elseif args[i] == "--out" then
		out = args[i + 1]
		i += 1
	elseif args[i] == "--bench" then
		bench = true
	else
		error("Unknown argument " .. args[i])
	end
	i += 1
end
local names = #selected > 0 and selected or (bench and {} or suiteNames())

local E = load(wrap(root))
local result = { passed = 0, failed = 0, nativeSkipped = 0, suites = {} }
for _, name in names do
	do
		local started = os.clock()
		local ok, report = pcall(function()
			return load(wrap(assert(root.children[name], "Unknown suite " .. name)))(E, { native = false })
		end)
		local summary = { passed = 0, failed = 0, nativeSkipped = {}, failures = {}, seconds = 0 }
		if not ok then
			summary.failed = 1
			summary.failures = { { name = "<suite>", error = tostring(report) } }
		else
			for _, case in report.results do
				if case.passed then
					summary.passed += 1
				elseif string.find(tostring(case.error), NATIVE_SENTINEL, 1, true) then
					table.insert(summary.nativeSkipped, case.name)
				else
					summary.failed += 1
					table.insert(summary.failures, { name = case.name, error = tostring(case.error) })
				end
			end
		end
		summary.seconds = math.floor((os.clock() - started) * 10) / 10
		result.suites[name] = summary
		result.passed += summary.passed
		result.failed += summary.failed
		result.nativeSkipped += #summary.nativeSkipped
		print(
			string.format(
				"%-28s %4d passed %3d failed %3d native %7.1fs",
				name,
				summary.passed,
				summary.failed,
				#summary.nativeSkipped,
				summary.seconds
			)
		)
		for _, failure in summary.failures do
			print("    FAIL " .. failure.name .. ": " .. string.sub(failure.error, 1, 300))
		end
	end
end
fs.writeDir(".validation")
if #names > 0 then
	fs.writeFile(out, serde.encode("json", result, true))
end
if bench then
	local report = load(wrap(root.children.ProductionBenchmarks))(E)
	fs.writeFile(".validation/benchmarks.json", serde.encode("json", report, true))
end
process.exit(result.failed == 0 and 0 or 1)
