-- Private local-domain snapshot; capture all reads before topology or data writes.
local A = require(script.Parent.AttributeCore)
return function(source, maps, removed)
	local values = {}
	for name, channel in source.attributes or {} do
		local edits = {}
		for key, refs in maps[channel.domain] or {} do
			if #refs > 0 then
				edits[key] = A.blend(channel, refs)
			else
				edits[key] = channel.default
			end
		end
		values[name] = edits
	end
	return function(target)
		for name, edits in values do
			local channel = target.attributes[name]
			for key in (removed or {})[channel.domain] or {} do
				channel.values[key] = nil
			end
			for key, value in edits do
				if value == channel.default then
					channel.values[key] = nil
				else
					channel.values[key] = value
				end
			end
		end
	end
end
