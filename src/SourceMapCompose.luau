-- Compose geometric source correspondences before final attribute sampling.
local U = require(script.Parent.Util)
return function(outer, inner, visit)
	local out = { identity = { vertex = false, edge = false, face = false, corner = false } }
	for _, domain in { "vertex", "edge", "face", "corner" } do
		out[domain] = {}
		for id, refs in outer[domain] do
			local sums = {}
			for _, ref in refs do
				visit("build")
				local previous = inner[domain][ref[1]]
				if not previous and inner.identity[domain] then
					previous = { { ref[1], 1 } }
				end
				if previous then
					local total = 0
					for _, p in previous do
						total += p[2] or 1
					end
					assert(total > 0, "Empty regularization source correspondence")
					for _, p in previous do
						visit("build")
						sums[p[1]] = (sums[p[1]] or 0) + (ref[2] or 1) * (p[2] or 1) / total
					end
				end
			end
			local result = {}
			for _, source in U.keys(sums) do
				if sums[source] > 0 then
					result[#result + 1] = { source, sums[source] }
				end
			end
			if #result > 0 then
				out[domain][id] = result
			end
		end
	end
	return out
end
