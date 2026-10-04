-- Private scalar-distance resampling of immutable world-space stroke records.
local U = require(script.Parent.Util)
local B = {}
local function scalar(value, default)
	if value == nil then
		value = default
	end
	assert(type(value) == "number" and U.finite(value), "Finite stroke scalar required")
	return value
end
local function length(x, y, z)
	local scale = math.max(math.abs(x), math.abs(y), math.abs(z))
	return scale > 0 and scale * math.sqrt((x / scale) ^ 2 + (y / scale) ^ 2 + (z / scale) ^ 2) or 0
end
local function unit(v)
	assert(U.vector(v), "Finite stroke direction required")
	local size = length(v.X, v.Y, v.Z)
	assert(size > 0, "Stroke direction cannot be zero")
	return { v.X / size, v.Y / size, v.Z / size }
end
function B.prepare(input, options, visit)
	assert(type(input) == "table" and #input > 0, "Stroke needs samples")
	local maxSamples = U.integer(options.maxSamples == nil and 10000 or options.maxSamples, 1)
	local maxDabs = U.integer(options.maxDabs == nil and 10000 or options.maxDabs, 1)
	assert(#input <= maxSamples, "Stroke sample budget exceeded")
	for key in input do
		assert(
			type(key) == "number" and key % 1 == 0 and key >= 1 and key <= #input,
			"Stroke samples must be a dense array"
		)
	end
	local mode = options.sampling == nil and "spaced" or options.sampling
	assert(mode == "spaced" or mode == "dabs", "Unknown stroke sampling mode")
	local radius = scalar(options.radius, 1)
	assert(radius > 0, "Positive stroke radius required")
	local spacing = scalar(options.spacing, 0.2)
	assert(spacing > 0, "Positive stroke spacing required")
	local step = radius * spacing
	assert(step > 0 and U.finite(step), "Unresolved stroke spacing")
	local source, total = {}, 0
	local compensation = 0
	for i, record in input do
		visit(1)
		assert(type(record) == "table" and U.vector(record.position), "Stroke sample needs a finite position")
		local pressure = scalar(record.pressure, 1)
		assert(pressure >= 0 and pressure <= 1, "Stroke pressure must be in [0,1]")
		local p = record.position
		local direction = record.normal
		if direction == nil then
			direction = options.normal
		end
		if direction ~= nil then
			assert(U.vector(direction), "Invalid stroke normal")
		end
		local delta = record.delta
		if delta == nil then
			delta = options.delta
		end
		if delta == nil then
			delta = Vector3.zero
		end
		assert(U.vector(delta), "Finite stroke delta required")
		local sample = {
			position = { p.X, p.Y, p.Z },
			pressure = pressure,
			normal = direction and unit(direction) or nil,
			delta = { delta.X, delta.Y, delta.Z },
			arc = total,
			index = i,
		}
		if i > 1 then
			local previous = source[i - 1].position
			local distance = length(p.X - previous[1], p.Y - previous[2], p.Z - previous[3])
			local adjusted = distance - compensation
			local sum = total + adjusted
			compensation = (sum - total) - adjusted
			total = sum
			assert(U.finite(total), "Stroke length overflow")
			sample.arc = total
		end
		source[i] = sample
	end
	local dabs = {}
	local function append(a, b, t, arc)
		visit(1)
		assert(#dabs < maxDabs, "Stroke dab budget exceeded")
		local sample =
			{ position = {}, delta = {}, pressure = a.pressure + (b.pressure - a.pressure) * t, arc = arc }
		for axis = 1, 3 do
			sample.position[axis] = a.position[axis] + (b.position[axis] - a.position[axis]) * t
			sample.delta[axis] = a.delta[axis] + (b.delta[axis] - a.delta[axis]) * t
		end
		assert((a.normal == nil) == (b.normal == nil), "Stroke normal samples must be consistently specified")
		if a.normal then
			local n = {}
			for axis = 1, 3 do
				n[axis] = a.normal[axis] + (b.normal[axis] - a.normal[axis]) * t
			end
			local size = length(n[1], n[2], n[3])
			assert(size > 1e-12, "Stroke normal interpolation cancels")
			sample.normal = { n[1] / size, n[2] / size, n[3] / size }
		end
		table.insert(dabs, sample)
	end
	if mode == "dabs" then
		assert(#source <= maxDabs, "Stroke dab budget exceeded")
		for _, sample in source do
			append(sample, sample, 0, sample.arc)
		end
	else
		local count = math.floor(total / step)
		assert(count < maxDabs, "Stroke dab budget exceeded")
		append(source[1], source[1], 0, 0)
		local segment = 1
		for k = 1, count do
			local arc = k * step
			while segment < #source - 1 and source[segment + 1].arc < arc do
				visit(1)
				segment += 1
			end
			local a, b = source[segment], source[segment + 1]
			assert(b and b.arc > a.arc, "Unresolved stroke segment")
			append(a, b, math.clamp((arc - a.arc) / (b.arc - a.arc), 0, 1), arc)
		end
		if options.includeEnd ~= false and total > dabs[#dabs].arc then
			local difference = total - dabs[#dabs].arc
			if #dabs > 1 and difference <= 16 * 2 ^ -52 * math.max(total, step) then
				-- Avoid a second endpoint dab caused only by length/step roundoff.
				table.remove(dabs)
			end
			append(source[#source], source[#source], 0, total)
		end
	end
	return dabs, { length = total, inputSamples = #source, dabs = #dabs, spacing = step, sampling = mode }
end
B.length = length
return B
