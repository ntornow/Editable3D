-- Private chart matching and conservative data-boundary protection.
local A = require(script.Parent.AttributeCore)
local U = require(script.Parent.Util)
local function equal(a, b, tolerance)
	if a == b then
		return true
	end
	local kind = typeof(a)
	if kind ~= typeof(b) or tolerance == 0 then
		return false
	end
	if kind == "number" then
		return math.abs(a - b) <= tolerance
	end
	if kind == "Vector2" then
		return math.max(math.abs(a.X - b.X), math.abs(a.Y - b.Y)) <= tolerance
	end
	if kind == "Vector3" then
		return math.max(math.abs(a.X - b.X), math.abs(a.Y - b.Y), math.abs(a.Z - b.Z)) <= tolerance
	end
	if kind == "Color3" then
		return math.max(math.abs(a.R - b.R), math.abs(a.G - b.G), math.abs(a.B - b.B)) <= tolerance
	end
	return false
end
local function same(mesh, fa, ia, fb, ib, options, compareFaces)
	options = options or {}
	local a, b = mesh.faces[fa], mesh.faces[fb]
	if a.material ~= b.material then
		return false
	end
	local x, y = a.corners[ia], b.corners[ib]
	local fields = {}
	for name in x do
		fields[name] = true
	end
	for name in y do
		fields[name] = true
	end
	for name in fields do
		if name ~= "normal" and name ~= "tangent" then
			local tolerance = name == "uv" and (options.uvTolerance or 1e-6)
				or (options.attributeTolerance or 0)
			if not equal(x[name], y[name], tolerance) then
				return false
			end
		end
	end
	for _, channel in mesh.attributes or {} do
		if
			channel.domain == "corner"
			and not equal(
				A.read(channel, fa .. ":" .. ia),
				A.read(channel, fb .. ":" .. ib),
				options.attributeTolerance or 0
			)
		then
			return false
		end
		if
			compareFaces ~= false
			and channel.domain == "face"
			and not equal(A.read(channel, fa), A.read(channel, fb), options.attributeTolerance or 0)
		then
			return false
		end
	end
	return true
end
local function locked(mesh, topology, options)
	options = options or {}
	local result = {}
	if options.preserveSeams == false then
		return result
	end
	for _, name in { "uvTolerance", "attributeTolerance" } do
		assert(
			options[name] == nil
				or type(options[name]) == "number" and U.finite(options[name]) and options[name] >= 0,
			"Nonnegative finite attribute tolerance required"
		)
	end
	local first = {}
	for _, fid in U.keys(mesh.faces) do
		for i, id in mesh.faces[fid].vertices do
			local previous = first[id]
			if previous and not same(mesh, previous[1], previous[2], fid, i, options) then
				result[id] = true
			end
			first[id] = previous or { fid, i }
		end
	end
	local names = { sharp_edge = true, uv_seam = true, subdivision_edge_sharpness = true }
	for _, name in options.seamAttributes or {} do
		assert(mesh.attributes[name], "Missing seam attribute")
		names[name] = true
	end
	for name in names do
		local channel = mesh.attributes[name]
		if channel then
			assert(
				channel.domain == "edge" and (channel.dataType == "boolean" or channel.dataType == "number"),
				"Seam attributes require numeric or boolean edge channels"
			)
			for key, edge in topology.edges do
				local value = A.read(channel, key)
				if value == true or type(value) == "number" and value > 0 then
					result[edge.a], result[edge.b] = true, true
				end
			end
		end
	end
	return result
end
return { same = same, locked = locked }
