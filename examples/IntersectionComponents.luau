-- Parameter components can be certified even when one component needs many arcs.
return function(E)
	E = E or require(script.Parent.Parent)
	local control = {}
	for i, h in { 0.1875, -0.3125, 0.1875 } do
		local x = (i - 1) / 2 - 0.5
		control[i] = { Vector3.new(x, -0.5, h), Vector3.new(x, 0.5, h) }
	end
	local a = E.NURBS.surface(control, 2, 1)
	local b = E.NURBS.surface({
		{ Vector3.new(-1, -1, 0), Vector3.new(-1, 1, 0) },
		{ Vector3.new(1, -1, 0), Vector3.new(1, 1, 0) },
	}, 1, 1)
	local intersections = E.SplineQuery.intersectSurfaces(a, b, {
		requireComplete = true,
		requireComponents = true,
	})
	assert(intersections.componentCount == 2)
	return { surfaceA = a, surfaceB = b, intersections = intersections, mesh = E.NURBS.tessellate(a, 16, 8) }
end
