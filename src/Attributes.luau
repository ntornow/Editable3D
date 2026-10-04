--!strict
-- Pure operators. Channels are sparse; omitted values resolve to the typed default.
local C = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
type Channel = Types.Channel
local A = {}
function A.create(
	mesh: Mesh,
	name: string,
	domain: string,
	dataType: string,
	default: unknown,
	interpolation: string?
): Mesh
	assert(type(name) == "string" and #name > 0, "Nonempty attribute name required")
	assert(not (mesh.attributes or {})[name], "Attribute already exists")
	local channel: Channel = {
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
function A.set(mesh: Mesh, name: string, values: { [any]: unknown }): Mesh
	local out = mesh:clone()
	local channel = assert((out.attributes or {})[name], "Unknown attribute")
	for key, value in values do
		channel.values[key] = value
	end
	C.validate(out)
	out.revision += 1
	return out
end
function A.get(mesh: Mesh, name: string, key: any): any
	local channel = assert((mesh.attributes or {})[name], "Unknown attribute")
	assert(C.keys(mesh, channel.domain)[key], "Unknown attribute element")
	return C.read(channel, key)
end
function A.remove(mesh: Mesh, name: string): Mesh
	local out = mesh:clone()
	assert((out.attributes or {})[name], "Unknown attribute")
	out.attributes[name] = nil
	out.revision += 1
	return out
end
function A.names(mesh: Mesh, domain: string?): { string }
	if domain then
		C.keys(mesh, domain)
	end
	local result: { string } = {}
	for name, channel in (mesh.attributes or {}) :: { [string]: Channel } do
		if not domain or channel.domain == domain then
			table.insert(result, name)
		end
	end
	table.sort(result)
	return result
end
function A.transfer(source: Mesh, target: Mesh, maps: any): Mesh
	local out = target:clone()
	C.transfer(source, out, maps)
	out.revision += 1
	return out
end
function A.convertDomain(mesh: Mesh, name: string, domain: string, options: { [string]: any }?): (Mesh, any)
	local options: { [string]: any } = options or {}
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
function A.project(source: Mesh, target: Mesh, options: { [string]: any }?): (Mesh, any)
	return require(script.Parent.AttributeProjection)(source, target, options)
end
return A
