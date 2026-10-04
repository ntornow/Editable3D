-- Shared sample indices close a globally ordered, certified intersection loop.
return function(E)
	E = E or require(script.Parent.Parent)
	local p, h = {}, { 0.25, -0.25, 0.25 }
	for i = 1, 3 do
		p[i] = {}
		for j = 1, 3 do
			p[i][j] = Vector3.new((i - 1) / 2 - 0.5, (j - 1) / 2 - 0.5, h[i] + h[j])
		end
	end
	local a = E.NURBS.surface(p, 2, 2)
	local b = E.NURBS.surface({
		{ Vector3.new(-1, -1, 0.125), Vector3.new(-1, 1, 0.125) },
		{
			Vector3.new(1, -1, 0.125),
			Vector3.new(1, 1, 0.125),
		},
	}, 1, 1)
	local intersections = E.SplineQuery.intersectSurfaces(a, b, { tolerance = 0.003, requireOrdered = true })
	local path = intersections.components[1].ordered
	assert(path.closed and path.segments[#path.segments].last == path.segments[1].first)
	return {
		surfaceA = a,
		surfaceB = b,
		intersections = intersections,
		path = path,
		mesh = E.NURBS.tessellate(a, 16, 16),
	}
end
