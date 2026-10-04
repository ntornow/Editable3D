--!strict
local U = require(script.Parent.Util)
-- Key values are polymorphic: numbers or anything with :Lerp (see Util.mix).
export type Key = { time: number, value: any }
export type Track = { keys: { Key }, interpolation: string }
export type Values = { [string]: any }
export type Frame = { time: number, values: Values }
local A = {}
function A.track(keys: { Key }, interpolation: string?): Track
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
	return { keys = keys, interpolation = interpolation :: string }
end
function A.sample(track: Track, time: number): any
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
function A.evaluate(tracks: { [string]: Track }, time: number, duration: number?, looped: boolean?): Values
	if looped then
		assert(duration and duration > 0)
		time %= duration
	end
	local result: Values = {}
	for name, track in tracks do
		result[name] = A.sample(track, time)
	end
	return result
end
function A.blend(a: Values, b: Values, weight: number): Values
	weight = math.clamp(weight, 0, 1)
	local out = table.clone(a)
	for name, value in b do
		out[name] = a[name] ~= nil and U.mix(a[name], value, weight) or value
	end
	return out
end
function A.bake(tracks: { [string]: Track }, startTime: number, endTime: number, fps: number): { Frame }
	assert(fps > 0 and endTime >= startTime)
	local frames: { Frame } = {}
	local count = math.ceil((endTime - startTime) * fps)
	for i = 0, count do
		local t = math.min(startTime + i / fps, endTime)
		table.insert(frames, { time = t, values = A.evaluate(tracks, t) })
	end
	return frames
end
return A
