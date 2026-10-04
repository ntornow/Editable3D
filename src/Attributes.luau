-- Pure operators. Channels are sparse; omitted values resolve to the typed default.
local C = require(script.Parent.AttributeCore)
local A = {}
function A.create(mesh, name, domain, dataType, default, interpolation)
	assert(type(name) == "string" and #name > 0, "Nonempty attribute name required")
	assert(not (mesh.attributes or {})[name], "Attribute already exists")
	local channel = {
		domain = domain,
		dataType = dataType,
		default = default,
		interpolation = interpolation
			or ((dataType == "string" or dataType == "boolean") and "nearest" or "linear"),
		values = {},
	}
	C.schema(channel)
	local out = mesh:clone()
	out.attributes = out.attributes or {}
	out.attributes[name] = channel
	out.revision += 1
	return out
end
function A.set(mesh, name, values)
	local out = mesh:clone()
	local channel = assert((out.attributes or {})[name], "Unknown attribute")
	for key, value in values do
		channel.values[key] = value
	end
	C.validate(out)
	out.revision += 1
	return out
end
function A.get(mesh, name, key)
	local channel = assert((mesh.attributes or {})[name], "Unknown attribute")
	assert(C.keys(mesh, channel.domain)[key], "Unknown attribute element")
	return C.read(channel, key)
end
function A.remove(mesh, name)
	local out = mesh:clone()
	assert((out.attributes or {})[name], "Unknown attribute")
	out.attributes[name] = nil
	out.revision += 1
	return out
end
function A.names(mesh, domain)
	if domain then
		C.keys(mesh, domain)
	end
	local result = {}
	for name, channel in mesh.attributes or {} do
		if not domain or channel.domain == domain then
			table.insert(result, name)
		end
	end
	table.sort(result)
	return result
end
function A.transfer(source, target, maps)
	local out = target:clone()
	C.transfer(source, out, maps)
	out.revision += 1
	return out
end
function A.convertDomain(mesh, name, domain, options)
	options = options or {}
	C.validate(mesh)
	local channel = assert((mesh.attributes or {})[name], "Unknown attribute")
	local nextName = options.name or name
	assert(type(nextName) == "string" and #nextName > 0, "Nonempty attribute name required")
	assert(nextName == name or not mesh.attributes[nextName], "Attribute already exists")
	local converted, report = require(script.Parent.AttributeDomains).convert(mesh, channel, domain, options)
	local out = mesh:clone()
	out.attributes[nextName] = converted
	out.revision += 1
	return out, report
end
function A.project(source, target, options)
	return require(script.Parent.AttributeProjection)(source, target, options)
end
return A
