local U = require(script.Parent.Util)
local Traversal = require(script.Parent.MeshTraversal)
local Connectivity = require(script.Parent.Connectivity)
local Loops = require(script.Parent.MeshLoops)
local S = {}
function S.all(mesh)
	local r = {}
	for id in mesh.vertices do
		r[id] = 1
	end
	return r
end
function S.sphere(mesh, center, radius, falloff)
	assert(radius > 0)
	local r = {}
	for id, p in mesh.vertices do
		local t = (p - center).Magnitude / radius
		if t <= 1 then
			r[id] = falloff == false and 1 or U.smooth(1 - t)
		end
	end
	return r
end
function S.box(mesh, lo, hi)
	local r = {}
	for id, p in mesh.vertices do
		if p.X >= lo.X and p.Y >= lo.Y and p.Z >= lo.Z and p.X <= hi.X and p.Y <= hi.Y and p.Z <= hi.Z then
			r[id] = 1
		end
	end
	return r
end
function S.boundary(mesh)
	local r = {}
	for _, e in mesh:topology().edges do
		if #e.faces == 1 then
			r[e.a] = 1
			r[e.b] = 1
		end
	end
	return r
end
function S.geodesic(mesh, seeds, radius, options)
	assert(type(radius) == "number" and U.finite(radius) and radius > 0, "Positive finite radius required")
	options = table.clone(options or {})
	options.domain, options.radius = "vertex", radius
	local result = Traversal.search(Traversal.prepare(mesh, options), seeds, nil, options)
	assert(result.complete, "Geodesic traversal budget exceeded: " .. tostring(result.reason))
	local mask = {}
	for id, d in result.distances do
		mask[id] = U.smooth(1 - d / radius)
	end
	return mask, result.distances, result
end
function S.shortestPath(mesh, startId, endId, options)
	assert(endId ~= nil, "Path target required")
	return Traversal.search(Traversal.prepare(mesh, options), { [startId] = true }, endId, options)
end
function S.linked(mesh, seeds, options)
	local result = Traversal.search(Traversal.prepare(mesh, options), seeds, nil, options)
	return result.selection, result
end
function S.regionBoundary(mesh, selected, options)
	local index = Connectivity.index(mesh, options)
	local faces, selection = {}, {}
	for fid, value in selected do
		assert(index.faces[fid], "Unknown selected face")
		if Traversal.active(value) then
			faces[fid] = mesh.faces[fid]
		end
	end
	for key, edge in index.edges do
		local count = 0
		for _, fid in edge.faces do
			if faces[fid] then
				count += 1
			end
		end
		if count > 0 then
			assert(#edge.faces <= 2, "Region boundary requires manifold selected edges")
			if count == 1 then
				selection[key] = true
			end
		end
	end
	local loops, report = Connectivity.boundaries({ vertices = mesh.vertices, faces = faces }, options)
	return selection, loops, report
end
function S.edgeLoop(mesh, edgeKey, options)
	return Loops.edgeLoop(mesh, edgeKey, options)
end
function S.edgeRing(mesh, edgeKey, options)
	return Loops.edgeRing(mesh, edgeKey, options)
end
function S.faceLoop(mesh, edgeKey, options)
	local result = Loops.edgeRing(mesh, edgeKey, options)
	result.selection = result.faceSelection
	return result
end
function S.combine(a, b, operation)
	assert(operation == "union" or operation == "intersect" or operation == "subtract")
	local r = {}
	local ids = table.clone(a)
	for id in b do
		ids[id] = true
	end
	for id in ids do
		local x, y = a[id] or 0, b[id] or 0
		r[id] = operation == "union" and math.max(x, y)
			or operation == "intersect" and math.min(x, y)
			or math.max(0, x - y)
	end
	return r
end
function S.invert(mesh, mask)
	local r = {}
	for id in mesh.vertices do
		r[id] = 1 - U.weight(mask, id)
	end
	return r
end
function S.convertDomain(mesh, mask, sourceDomain, targetDomain, options)
	options = table.clone(options or {})
	local Core = require(script.Parent.AttributeCore)
	local values, keys = {}, Core.keys(mesh, sourceDomain)
	for key, value in mask do
		assert(keys[key], "Unknown mask element")
		if type(value) == "boolean" then
			values[key] = value and 1 or 0
		else
			assert(
				type(value) == "number" and U.finite(value) and value >= 0 and value <= 1,
				"Mask weight must be in [0,1]"
			)
			values[key] = value
		end
	end
	local mode = options.mode or "all"
	assert(mode == "all" or mode == "any" or mode == "mean", "Unknown mask conversion mode")
	options.interpolation = mode == "all" and "min" or (mode == "any" and "max" or "linear")
	local channel = {
		domain = sourceDomain,
		dataType = "number",
		default = 0,
		interpolation = options.interpolation,
		values = values,
	}
	local result, report =
		require(script.Parent.AttributeDomains).convert(mesh, channel, targetDomain, options)
	return result.values, report
end
return S
