-- Typed numeric channels. Quaternion components are x,y,z,w; times are seconds.
local U = require(script.Parent.Util)
local Q = require(script.Parent.Quaternion)
local T = {}
local dimensions = { translation = 3, scale = 3, rotation = 4 }
local function tuple(value, n)
	assert(type(value) == "table" and #value == n, "Channel tuple size mismatch")
	for _, v in value do
		assert(type(v) == "number" and U.finite(v), "Nonfinite channel value")
	end
end
function T.channel(path, times, values, options)
	options = options or {}
	assert(
		path == "translation" or path == "scale" or path == "rotation" or path == "weights" or path == "value",
		"Unsupported channel path"
	)
	assert(#times > 0 and #times == #values, "Channel key count mismatch")
	local size = dimensions[path] or #values[1]
	assert(size > 0, "Empty channel tuple")
	local interpolation = options.interpolation or "LINEAR"
	assert(
		interpolation == "STEP" or interpolation == "LINEAR" or interpolation == "CUBICSPLINE",
		"Unsupported interpolation"
	)
	local cubic = interpolation == "CUBICSPLINE"
	if cubic then
		assert(
			#times >= 2
				and options.inTangents
				and options.outTangents
				and #options.inTangents == #times
				and #options.outTangents == #times,
			"Cubic channel needs two keys and paired tangents"
		)
	end
	for i, time in times do
		assert(
			type(time) == "number" and U.finite(time) and (i == 1 or time > times[i - 1]),
			"Key times must increase strictly"
		)
		tuple(values[i], size)
		if path == "rotation" then
			assert(math.abs(Q.dot(values[i], values[i]) - 1) < 1e-4, "Rotation keys must be unit quaternions")
		end
		if cubic then
			tuple(options.inTangents[i], size)
			tuple(options.outTangents[i], size)
		end
	end
	return {
		path = path,
		node = options.node,
		interpolation = interpolation,
		times = U.copy(times),
		values = U.copy(values),
		inTangents = cubic and U.copy(options.inTangents) or nil,
		outTangents = cubic and U.copy(options.outTangents) or nil,
	}
end
function T.sampleChannel(channel, time)
	assert(type(time) == "number" and U.finite(time), "Invalid sample time")
	local times, values = channel.times, channel.values
	if time <= times[1] then
		return table.clone(values[1])
	end
	if time >= times[#times] then
		return table.clone(values[#times])
	end
	local lo, hi = 1, #times
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if times[mid] <= time then
			lo = mid
		else
			hi = mid
		end
	end
	local dt = times[hi] - times[lo]
	local t = (time - times[lo]) / dt
	if channel.interpolation == "STEP" then
		return table.clone(values[lo])
	end
	if channel.interpolation == "LINEAR" and channel.path == "rotation" then
		return Q.slerp(values[lo], values[hi], t)
	end
	local result = {}
	for k, a in values[lo] do
		local b = values[hi][k]
		if channel.interpolation == "CUBICSPLINE" then
			result[k] = (2 * t ^ 3 - 3 * t ^ 2 + 1) * a
				+ (t ^ 3 - 2 * t ^ 2 + t) * dt * channel.outTangents[lo][k]
				+ (-2 * t ^ 3 + 3 * t ^ 2) * b
				+ (t ^ 3 - t ^ 2) * dt * channel.inTangents[hi][k]
		else
			result[k] = a + (b - a) * t
		end
	end
	return channel.path == "rotation" and Q.normalize(result) or result
end
function T.clip(channels, name)
	assert(#channels > 0, "Empty clip")
	local first, last = math.huge, -math.huge
	local seen = {}
	for _, c in channels do
		local key = tostring(c.node or 1) .. ":" .. c.path
		assert(not seen[key], "Duplicate animation target/path")
		seen[key] = true
		first = math.min(first, c.times[1])
		last = math.max(last, c.times[#c.times])
	end
	return {
		name = name,
		channels = U.copy(channels),
		startTime = first,
		endTime = last,
		duration = last - first,
	}
end
function T.sample(clip, time, options)
	options = options or {}
	assert(U.finite(time), "Invalid sample time")
	local first = clip.startTime or math.huge
	local last = clip.endTime or -math.huge
	if not clip.startTime then
		for _, c in clip.channels do
			first = math.min(first, c.times[1])
			last = math.max(last, c.times[#c.times])
		end
	end
	local duration = last - first
	if options.loop and duration > 0 then
		if options.pingPong then
			local phase = (time - first) % (2 * duration)
			time = first + (phase <= duration and phase or 2 * duration - phase)
		else
			time = first + (time - first) % duration
		end
	end
	local result = {}
	for _, c in clip.channels do
		local node = c.node or 1
		result[node] = result[node] or {}
		result[node][c.path] = T.sampleChannel(c, time)
	end
	return result, time
end
function T.layer(base, overlay, weight, additive)
	assert(type(weight) == "number" and U.finite(weight), "Invalid layer weight")
	local out = U.copy(base)
	for node, paths in overlay do
		out[node] = out[node] or {}
		for path, b in paths do
			local a = out[node][path]
			if not a then
				a = table.create(#b, path == "scale" and 1 or 0)
				if path == "rotation" then
					a[4] = 1
				end
			end
			assert(#a == #b, "Layer tuple size mismatch")
			local value = {}
			if path == "rotation" then
				value = additive and Q.multiply(a, Q.slerp(Q.identity, b, weight)) or Q.slerp(a, b, weight)
			else
				for k, v in b do
					value[k] = additive
							and (path == "scale" and a[k] * (1 + (v - 1) * weight) or a[k] + v * weight)
						or a[k] + (v - a[k]) * weight
				end
			end
			out[node][path] = value
		end
	end
	return out
end
return T
