-- Private finite brush-image transforms. Scalar arithmetic keeps small offsets.
local U = require(script.Parent.Util)
local Core = require(script.Parent.DeformCore)
local B = {}
local names = { "X", "Y", "Z" }
local function tableOption(value, message)
	if value == nil then
		return {}
	end
	assert(type(value) == "table", message)
	return value
end
local function multiply(a, b)
	local out = {}
	for i = 1, 3 do
		out[i] = {}
		for j = 1, 3 do
			out[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
		end
	end
	return out
end
local function vector(a, p)
	return {
		a[1][1] * p[1] + a[1][2] * p[2] + a[1][3] * p[3],
		a[2][1] * p[1] + a[2][2] * p[2] + a[2][3] * p[3],
		a[3][1] * p[1] + a[3][2] * p[2] + a[3][3] * p[3],
	}
end
function B.build(options, visit)
	local symmetry = tableOption(options.symmetry, "Stroke symmetry must be a table")
	local frame = Core.frame(symmetry.frame == nil and CFrame.identity or symmetry.frame)
	local data = { frame:GetComponents() }
	local origin = { data[1], data[2], data[3] }
	local rotation = {
		{ data[4], data[5], data[6] },
		{ data[7], data[8], data[9] },
		{ data[10], data[11], data[12] },
	}
	local transpose = {}
	for i = 1, 3 do
		transpose[i] = {}
		for j = 1, 3 do
			transpose[i][j] = rotation[j][i]
		end
	end
	local identity = multiply(rotation, transpose)
	for i = 1, 3 do
		for j = 1, 3 do
			assert(
				math.abs(identity[i][j] - (i == j and 1 or 0)) <= 1e-5,
				"Symmetry frame must be orthonormal"
			)
		end
	end
	local mirror = tableOption(symmetry.mirror, "Stroke mirror must be an axis boolean set")
	for name, value in mirror do
		assert(
			(name == "X" or name == "Y" or name == "Z") and type(value) == "boolean",
			"Invalid stroke mirror axis"
		)
	end
	local radial = tableOption(symmetry.radial, "Stroke radial symmetry must be a table")
	local axis = radial.axis == nil and "Z" or radial.axis
	assert(axis == "X" or axis == "Y" or axis == "Z", "Unknown stroke radial axis")
	local count = U.integer(radial.count == nil and 1 or radial.count, 1)
	local maximum = U.integer(options.maxCopies == nil and 256 or options.maxCopies, 1)
	local offsets = symmetry.tileOffsets == nil and { Vector3.zero } or symmetry.tileOffsets
	assert(type(offsets) == "table" and #offsets >= 1, "Stroke tile offsets must be a nonempty array")
	for key, value in offsets do
		assert(
			type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #offsets and U.vector(value),
			"Invalid stroke tile offset"
		)
	end
	local signs = { { 1, 1, 1 } }
	for i, name in names do
		if mirror[name] then
			for j = 1, #signs do
				local value = table.clone(signs[j])
				value[i] = -1
				table.insert(signs, value)
			end
		end
	end
	assert(
		count <= maximum and #offsets <= maximum and count * #signs * #offsets <= maximum,
		"Stroke symmetry allocation budget exceeded"
	)
	local transforms, seen = {}, {}
	for k = 0, count - 1 do
		local c, s
		if (4 * k) % count == 0 then
			local q = (4 * k / count) % 4
			c, s = ({ 1, 0, -1, 0 })[q + 1], ({ 0, 1, 0, -1 })[q + 1]
		else
			local angle = 2 * math.pi * k / count
			c, s = math.cos(angle), math.sin(angle)
		end
		local spin = axis == "X" and { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } }
			or axis == "Y" and { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } }
			or { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } }
		for _, sign in signs do
			local localMatrix = {}
			local parts = {}
			local isIdentity = true
			for i = 1, 3 do
				localMatrix[i] = {}
				for j = 1, 3 do
					localMatrix[i][j] = spin[i][j] * sign[j]
					isIdentity = isIdentity and localMatrix[i][j] == (i == j and 1 or 0)
					table.insert(parts, string.format("%.17g", localMatrix[i][j] + 0))
				end
			end
			local matrixKey = table.concat(parts, ",")
			local world = multiply(multiply(rotation, localMatrix), transpose)
			if isIdentity then
				world = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
			end
			for _, offset in offsets do
				visit(1)
				local key = matrixKey
					.. string.format("/%.17g,%.17g,%.17g", offset.X + 0, offset.Y + 0, offset.Z + 0)
				if not seen[key] then
					seen[key] = true
					local move = vector(rotation, { offset.X, offset.Y, offset.Z })
					table.insert(transforms, { matrix = world, offset = move, identity = isIdentity })
				end
			end
		end
	end
	local function copies(sample)
		local result = {}
		local centered = {}
		for i = 1, 3 do
			centered[i] = sample.position[i] - origin[i]
		end
		for _, transform in transforms do
			visit(1)
			local p = transform.identity and table.clone(sample.position)
				or vector(transform.matrix, centered)
			for i = 1, 3 do
				p[i] += (transform.identity and 0 or origin[i]) + transform.offset[i]
			end
			local normal = sample.normal and vector(transform.matrix, sample.normal) or nil
			if normal then
				local size = math.sqrt(normal[1] ^ 2 + normal[2] ^ 2 + normal[3] ^ 2)
				for i = 1, 3 do
					normal[i] /= size
				end
			end
			table.insert(result, {
				position = p,
				pressure = sample.pressure,
				arc = sample.arc,
				delta = vector(transform.matrix, sample.delta),
				normal = normal,
			})
		end
		return result
	end
	return copies, #transforms
end
return B
