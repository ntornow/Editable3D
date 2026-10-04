-- Custom corner normals without topology or material changes.
local U = require(script.Parent.Util)
local Core = require(script.Parent.NormalCore)
local A = require(script.Parent.AttributeCore)
local N = {}
function N.recalculate(mesh, options)
	return Core.reduce(mesh, Core.setup(mesh, options), options, false)
end
function N.average(mesh, options)
	return Core.reduce(mesh, Core.setup(mesh, options), options, true)
end
function N.set(mesh, values, options)
	assert(type(values) == "table", "Corner normal dictionary required")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(values) do
		assert(state.index.corners[key], "Unknown normal corner")
		state.write(key, Core.unit(values[key]))
	end
	return state.finish()
end
function N.direction(mesh, direction, options)
	local n = Core.unit(direction)
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, n)
	end
	return state.finish()
end
function N.point(mesh, target, options)
	options = options or {}
	assert(U.vector(target), "Finite normal target required")
	local direction = options.direction or "toward"
	assert(direction == "toward" or direction == "away", "Normal point direction must be toward or away")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		if state.weight(key) == 0 then
			continue
		end
		local p = mesh.vertices[state.index.corners[key].vertex]
		local d = direction == "toward" and target - p or p - target
		if d == Vector3.zero then
			assert(
				options.coincident == "keep",
				"Normal target coincides with a vertex; use coincident='keep' explicitly"
			)
			state.report.coincidentCorners = (state.report.coincidentCorners or 0) + 1
		else
			state.write(key, d)
		end
	end
	return state.finish()
end
function N.rotate(mesh, rotation, options)
	assert(typeof(rotation) == "CFrame", "Normal rotation requires a CFrame")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, rotation:VectorToWorldSpace(state.source(key)))
	end
	return state.finish()
end
function N.flip(mesh, options)
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, -state.source(key))
	end
	return state.finish()
end
function N.markSharp(mesh, edges, options)
	assert(type(edges) == "table", "Sharp edge dictionary required")
	local state = Core.setup(mesh, options)
	for key, value in edges do
		assert(state.index.edges[key] and type(value) == "boolean", "Invalid sharp edge")
	end
	local channel = state.out.attributes.sharp_edge
	if channel then
		assert(
			channel.domain == "edge" and channel.dataType == "boolean",
			"sharp_edge must be an edge boolean channel"
		)
	else
		channel =
			{ domain = "edge", dataType = "boolean", default = false, interpolation = "nearest", values = {} }
		state.out.attributes.sharp_edge = channel
	end
	for key, value in edges do
		if value == channel.default then
			channel.values[key] = nil
		else
			channel.values[key] = value
		end
	end
	A.validate(state.out)
	if options and options.recalculate == false then
		return state.finish()
	end
	local config = table.clone(options or {})
	config.sharpEdges = nil
	return N.recalculate(state.out, config)
end
function N.tangents(mesh, options)
	return require(script.Parent.NormalTangents)(mesh, options)
end
return N
