local U = require(script.Parent.Util)
local A = {}
function A.track(keys, interpolation)
	assert(#keys > 0)
	keys = U.copy(keys)
	table.sort(keys, function(a, b)
		return a.time < b.time
	end)
	for i = 2, #keys do
		assert(keys[i].time > keys[i - 1].time, "Duplicate key time")
	end
	interpolation = interpolation or "linear"
	assert(interpolation == "linear" or interpolation == "step" or interpolation == "smooth")
	return { keys = keys, interpolation = interpolation }
end
function A.sample(track, time)
	local keys = track.keys
	if time <= keys[1].time then
		return keys[1].value
	end
	if time >= keys[#keys].time then
		return keys[#keys].value
	end
	local lo, hi = 1, #keys
	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)
		if keys[mid].time <= time then
			lo = mid
		else
			hi = mid
		end
	end
	if track.interpolation == "step" then
		return keys[lo].value
	end
	local t = (time - keys[lo].time) / (keys[hi].time - keys[lo].time)
	if track.interpolation == "smooth" then
		t = U.smooth(t)
	end
	return U.mix(keys[lo].value, keys[hi].value, t)
end
function A.evaluate(tracks, time, duration, looped)
	if looped then
		assert(duration and duration > 0)
		time %= duration
	end
	local result = {}
	for name, track in tracks do
		result[name] = A.sample(track, time)
	end
	return result
end
function A.blend(a, b, weight)
	weight = math.clamp(weight, 0, 1)
	local out = table.clone(a)
	for name, value in b do
		out[name] = a[name] ~= nil and U.mix(a[name], value, weight) or value
	end
	return out
end
function A.bake(tracks, startTime, endTime, fps)
	assert(fps > 0 and endTime >= startTime)
	local frames = {}
	local count = math.ceil((endTime - startTime) * fps)
	for i = 0, count do
		local t = math.min(startTime + i / fps, endTime)
		table.insert(frames, { time = t, values = A.evaluate(tracks, t) })
	end
	return frames
end
return A
