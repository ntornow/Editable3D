-- Bounded detached meshes/options before any arrangement callback can run.
local U = require(script.Parent.Util)
local Mesh = require(script.Parent.Mesh)
return function(meshes, settings)
	assert(settings == nil or type(settings) == "table", "Arrangement options must be a table")
	settings = settings or {}
	local maximum =
		U.integer(settings.maxSnapshotEntries == nil and 4000000 or settings.maxSnapshotEntries, 1)
	local entries, active = 0, {}
	local function copy(value, depth)
		if type(value) ~= "table" then
			return value
		end
		assert(
			depth <= 64 and not active[value],
			"Arrangement snapshot has cyclic or excessively nested data"
		)
		active[value] = true
		local out = {}
		for key, item in value do
			entries += 1
			assert(entries <= maximum, "Arrangement snapshot entry budget exceeded")
			out[key] = copy(item, depth + 1)
		end
		active[value] = nil
		return out
	end
	local options = copy(settings, 1)
	local out = {}
	for i, source in meshes do
		assert(
			type(source) == "table" and type(source.vertices) == "table" and type(source.faces) == "table",
			"Arrangement source mesh required"
		)
		local detached = Mesh.new()
		for key, value in copy(source, 1) do
			detached[key] = value
		end
		out[i] = detached
	end
	return out, options
end
