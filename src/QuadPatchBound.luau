-- Private certified same-chart PL distance on a canonical triangle or square.
local Overlay = require(script.Parent.GridPatchOverlay)
local B = {}
local function determinant(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end
function B.check(source, target, positions, triangleDomain, visit)
	local expected = triangleDomain and 36 or 72
	for _, triangles in { source, target } do
		local area = 0
		for i, t in triangles do
			visit(1)
			for _, p in t.uv do
				assert(
					p[1] % 1 == 0
						and p[2] % 1 == 0
						and p[1] >= 0
						and p[2] >= 0
						and p[1] <= 6
						and p[2] <= 6
						and (not triangleDomain or p[1] + p[2] <= 6)
				)
			end
			local d = determinant(t.uv[1], t.uv[2], t.uv[3])
			if d <= 0 then
				return nil, "reversedChart"
			end
			area += d
			for j = 1, i - 1 do
				if Overlay.positive(Overlay.samples(t.uv, triangles[j].uv, visit)) then
					return nil, "overlappingChart"
				end
			end
		end
		if area ~= expected then
			return nil, "incompleteChart"
		end
	end
	local bound, pairs = 0, {}
	for i, a in source do
		for j, b in target do
			local samples = Overlay.samples(a.uv, b.uv, visit)
			if Overlay.positive(samples) then
				table.insert(pairs, { i, j })
			end
			for _, p in samples do
				visit(1)
				bound = math.max(bound, Overlay.distance(a, b, p, positions))
			end
		end
	end
	return bound, { pairs = pairs }
end
return B
