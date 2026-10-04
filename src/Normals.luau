--!strict
-- Custom corner normals without topology or material changes.
local U = require(script.Parent.Util)
local Core = require(script.Parent.NormalCore)
local A = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Shared normal-editing options (selection masks, weighting, budgets); validated by NormalCore.
type Options = { [string]: any }
local N = {}
function N.recalculate(mesh: Mesh, options: Options?)
	return Core.reduce(mesh, Core.setup(mesh, options), options, false)
end
function N.average(mesh: Mesh, options: Options?)
	return Core.reduce(mesh, Core.setup(mesh, options), options, true)
end
function N.set(mesh: Mesh, values: { [any]: Vector3 }, options: Options?)
	assert(type(values) == "table", "Corner normal dictionary required")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(values) do
		assert(state.index.corners[key], "Unknown normal corner")
		state.write(key, Core.unit(values[key]))
	end
	return state.finish()
end
function N.direction(mesh: Mesh, direction: Vector3, options: Options?)
	local n = Core.unit(direction)
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, n)
	end
	return state.finish()
end
function N.point(mesh: Mesh, target: Vector3, options: Options?)
	local options: Options = options or {}
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
function N.rotate(mesh: Mesh, rotation: CFrame, options: Options?)
	assert(typeof(rotation) == "CFrame", "Normal rotation requires a CFrame")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, rotation:VectorToWorldSpace(state.source(key)))
	end
	return state.finish()
end
function N.flip(mesh: Mesh, options: Options?)
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, -state.source(key))
	end
	return state.finish()
end
function N.markSharp(mesh: Mesh, edges: { [string]: boolean }, options: Options?)
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
	local config: Options = table.clone(options or {})
	config.sharpEdges = nil
	return N.recalculate(state.out, config)
end
function N.tangents(mesh: Mesh, options: Options?)
	return require(script.Parent.NormalTangents)(mesh, options)
end
return N
