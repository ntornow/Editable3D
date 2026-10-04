-- Direct incidences between the four mesh domains. Shared by attributes and masks.
local U = require(script.Parent.Util)
local Connectivity = require(script.Parent.Connectivity)
local D = {}
local domains = { vertex = "vertices", edge = "edges", face = "faces", corner = "corners" }
function D.prepare(mesh, source, target, options)
	assert(domains[source] and domains[target], "Unknown attribute domain")
	local index = Connectivity.index(mesh, options)
	return index, index[domains[source]], index[domains[target]]
end
function D.references(index, source, target, key)
	if source == target then
		return { { key, 1 } }
	end
	local found = {}
	local function add(id)
		found[id] = true
	end
	local function corner(ck)
		local h = index.corners[ck]
		if source == "vertex" then
			add(h.vertex)
		elseif source == "face" then
			add(h.face)
		elseif source == "corner" then
			add(ck)
		end
	end
	if target == "vertex" then
		local v = index.vertices[key]
		if source == "edge" then
			for _, ek in v.edges do
				add(ek)
			end
		else
			for _, ck in v.corners do
				corner(ck)
			end
		end
	elseif target == "edge" then
		local e = index.edges[key]
		if source == "vertex" then
			add(e.a)
			add(e.b)
		else
			for _, ck in e.corners do
				corner(ck)
				if source == "corner" then
					corner(index.corners[ck].next)
				end
			end
		end
	elseif target == "face" then
		for _, ck in index.faces[key].corners do
			if source == "edge" then
				add(index.corners[ck].edge)
			else
				corner(ck)
			end
		end
	else
		if source == "edge" then
			local h = index.corners[key]
			add(h.edge)
			add(index.corners[h.previous].edge)
		else
			corner(key)
		end
	end
	local references = {}
	for _, id in U.keys(found) do
		table.insert(references, { id, 1 })
	end
	return references
end
function D.convert(mesh, channel, target, options)
	options = options or {}
	local index, _, targets = D.prepare(mesh, channel.domain, target, options)
	local limit = U.integer(options.maxReferences or 2000000, 1)
	assert(options.weight == nil or type(options.weight) == "function", "Domain weight must be a function")
	local Core = require(script.Parent.AttributeCore)
	local out = U.copy(channel)
	out.domain, out.values = target, {}
	out.interpolation = options.interpolation or out.interpolation
	Core.schema(out)
	local readChannel = table.clone(channel)
	readChannel.interpolation = out.interpolation
	local report = { elements = 0, references = 0, defaulted = 0 }
	for _, key in U.keys(targets) do
		local refs = D.references(index, channel.domain, target, key)
		report.references += #refs
		assert(report.references <= limit, "Domain conversion reference budget exceeded")
		local total = 0
		for _, ref in refs do
			if options.weight then
				ref[2] = options.weight(ref[1], key)
			end
			assert(type(ref[2]) == "number" and U.finite(ref[2]) and ref[2] >= 0, "Invalid domain weight")
			total += ref[2]
		end
		assert(U.finite(total), "Domain weight sum overflow")
		local value = out.default
		if total > 0 then
			value = Core.blend(readChannel, refs)
		else
			report.defaulted += 1
		end
		if value ~= out.default then
			out.values[key] = value
		end
		report.elements += 1
		if options.checkpoint and report.elements % 256 == 0 then
			options.checkpoint(report.references / limit)
		end
	end
	return out, report
end
return D
