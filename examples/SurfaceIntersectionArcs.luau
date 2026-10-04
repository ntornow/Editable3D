-- Every returned chart is an ordered arc with a certified chord-error bound.
return function(E)
	E = E or require(script.Parent.Parent)
	local p, h = {}, { 1, -1, 1 }
	for i = 1, 3 do
		p[i] = { Vector3.new(i - 2, -1, h[i]), Vector3.new(i - 2, 1, h[i]) }
	end
	local a = E.NURBS.surface(p, 2, 1)
	local b = E.NURBS.surface(
		{ { Vector3.new(-2, 0, -2), Vector3.new(-2, 0, 2) }, { Vector3.new(2, 0, -2), Vector3.new(2, 0, 2) } },
		1,
		1
	)
	local intersections = E.SplineQuery.intersectSurfaces(a, b, { tolerance = 0.002, requireComplete = true })
	assert(#intersections.curves == 1 and intersections.segmentCount > 1)
	return { surfaceA = a, surfaceB = b, intersections = intersections, mesh = E.NURBS.tessellate(a, 16, 8) }
end
