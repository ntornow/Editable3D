-- Private typed sparse channels and explicit topology correspondence.
local U = require(script.Parent.Util)
local domains = { vertex = true, edge = true, face = true, corner = true }
local types = { number = true, boolean = true, string = true, Vector2 = true, Vector3 = true, Color3 = true }
local function finite(value, kind)
	if typeof(value) ~= kind then
		return false
	end
	if kind == "number" then
		return U.finite(value)
	end
	if kind == "Vector2" then
		return U.finite(value.X) and U.finite(value.Y)
	end
	if kind == "Vector3" then
		return U.vector(value)
	end
	if kind == "Color3" then
		return U.finite(value.R) and U.finite(value.G) and U.finite(value.B)
	end
	return true
end
local function schema(channel)
	assert(
		type(channel) == "table" and domains[channel.domain] and types[channel.dataType],
		"Invalid attribute schema"
	)
	assert(finite(channel.default, channel.dataType), "Attribute default has wrong type or is nonfinite")
	local mode = channel.interpolation
	assert(
		mode == "nearest" or mode == "linear" or mode == "max" or mode == "min",
		"Invalid attribute interpolation"
	)
	assert(
		mode ~= "linear" or (channel.dataType ~= "boolean" and channel.dataType ~= "string"),
		"Linear interpolation requires numeric data"
	)
	assert(
		(mode ~= "max" and mode ~= "min") or channel.dataType == "number" or channel.dataType == "boolean",
		"Min/max require scalar data"
	)
	assert(type(channel.values) == "table", "Attribute values must be a table")
end
local function keys(mesh, domain)
	assert(domains[domain], "Unknown attribute domain")
	local result = {}
	if domain == "vertex" or domain == "face" then
		for id in (domain == "vertex" and mesh.vertices or mesh.faces) do
			result[id] = true
		end
	else
		for fid, face in mesh.faces do
			for i, v in face.vertices do
				result[domain == "edge" and U.edge(v, face.vertices[i % #face.vertices + 1]) or fid .. ":" .. i] =
					true
			end
		end
	end
	return result
end
local function read(channel, key)
	local value = channel.values[key]
	if value == nil then
		return channel.default
	end
	return value
end
local function validate(mesh)
	assert(mesh.attributes == nil or type(mesh.attributes) == "table", "Mesh attributes must be a table")
	local sets = {}
	for name, channel in mesh.attributes or {} do
		assert(type(name) == "string" and #name > 0, "Attribute name must be a nonempty string")
		schema(channel)
		sets[channel.domain] = sets[channel.domain] or keys(mesh, channel.domain)
		for key, value in channel.values do
			assert(
				sets[channel.domain][key],
				"Attribute " .. name .. " refers to missing element " .. tostring(key)
			)
			assert(finite(value, channel.dataType), "Attribute " .. name .. " has invalid value")
		end
	end
	return true
end
local function prune(mesh)
	local sets = {}
	for _, channel in mesh.attributes or {} do
		sets[channel.domain] = sets[channel.domain] or keys(mesh, channel.domain)
		for key in channel.values do
			if not sets[channel.domain][key] then
				channel.values[key] = nil
			end
		end
	end
end
local function blend(channel, references)
	assert(#references > 0, "Attribute correspondence cannot be empty")
	local sum, total, bestWeight = nil, 0, -1
	for _, ref in references do
		local weight = ref[2] or 1
		assert(
			type(weight) == "number" and U.finite(weight) and weight >= 0,
			"Attribute weights must be finite and nonnegative"
		)
		if weight > 0 then
			local value = read(channel, ref[1])
			if channel.interpolation == "nearest" then
				if weight > bestWeight then
					sum, bestWeight = value, weight
				end
			elseif channel.interpolation == "max" or channel.interpolation == "min" then
				if sum == nil then
					sum = value
				elseif channel.dataType == "boolean" then
					if channel.interpolation == "max" then
						sum = sum or value
					else
						sum = sum and value
					end
				elseif channel.interpolation == "max" then
					sum = math.max(sum, value)
				else
					sum = math.min(sum, value)
				end
			else
				sum = sum == nil and value or U.mix(sum, value, weight / (total + weight))
			end
			total += weight
		end
	end
	assert(total > 0 and U.finite(total), "Attribute correspondence needs positive finite total weight")
	assert(finite(sum, channel.dataType), "Attribute interpolation overflow")
	return sum
end
local function compatible(a, b)
	return a.domain == b.domain
		and a.dataType == b.dataType
		and a.default == b.default
		and a.interpolation == b.interpolation
end
-- maps[domain][newKey] = {{oldKey, weight}, ...}; unmapped keys use identity
-- unless maps.identity[domain] == false. New elements otherwise use the default.
local function transfer(source, target, maps, merge)
	maps = maps or {}
	assert(type(maps) == "table", "Correspondence must be a table")
	if maps.identity then
		assert(type(maps.identity) == "table", "Identity correspondence must be a table")
		for domain, value in maps.identity do
			assert(domains[domain] and type(value) == "boolean", "Invalid identity correspondence")
		end
	end
	validate(source)
	local sourceSets, targetSets = {}, {}
	for domain, mapping in maps do
		if domain ~= "identity" then
			assert(domains[domain] and type(mapping) == "table", "Unknown correspondence domain")
			sourceSets[domain], targetSets[domain] = keys(source, domain), keys(target, domain)
			for key, references in mapping do
				assert(targetSets[domain][key], "Correspondence target is missing")
				assert(type(references) == "table" and #references > 0, "Empty correspondence")
				local total = 0
				for _, ref in references do
					assert(
						type(ref) == "table" and sourceSets[domain][ref[1]],
						"Correspondence source is missing"
					)
					local w = ref[2] or 1
					assert(type(w) == "number" and U.finite(w) and w >= 0, "Invalid correspondence weight")
					total += w
				end
				assert(total > 0 and U.finite(total), "Correspondence needs a positive finite weight sum")
			end
		end
	end
	local attributes = merge and U.copy(target.attributes or {}) or {}
	for name, channel in source.attributes or {} do
		local domain = channel.domain
		sourceSets[domain] = sourceSets[domain] or keys(source, domain)
		targetSets[domain] = targetSets[domain] or keys(target, domain)
		local nextChannel = attributes[name]
		assert(
			not nextChannel or compatible(channel, nextChannel),
			"Incompatible joined attribute schema: " .. name
		)
		if not nextChannel then
			nextChannel = U.copy(channel)
			nextChannel.values = {}
			attributes[name] = nextChannel
		end
		for _, key in U.keys(targetSets[domain]) do
			local refs = (maps[domain] or {})[key]
			if not refs and (maps.identity or {})[domain] ~= false and sourceSets[domain][key] then
				refs = { { key, 1 } }
			end
			if refs then
				local value = blend(channel, refs)
				if value == channel.default then
					nextChannel.values[key] = nil
				else
					nextChannel.values[key] = value
				end
			end
		end
	end
	target.attributes = attributes
	prune(target)
	return target
end
local function vertexData(source, target, mapping)
	for newId, refs in mapping do
		local total, weights = 0, {}
		for _, ref in refs do
			total += ref[2] or 1
		end
		for _, ref in refs do
			for bone, value in source.weights[ref[1]] or {} do
				weights[bone] = (weights[bone] or 0) + value * (ref[2] or 1) / total
			end
		end
		target.weights[newId] = weights
		for name, group in source.groups do
			target.groups[name] = target.groups[name] or {}
			local value = 0
			for _, ref in refs do
				value += (group[ref[1]] or 0) * (ref[2] or 1) / total
			end
			target.groups[name][newId] = value
		end
	end
end
return {
	keys = keys,
	read = read,
	schema = schema,
	finite = finite,
	validate = validate,
	prune = prune,
	blend = blend,
	transfer = transfer,
	vertexData = vertexData,
}
