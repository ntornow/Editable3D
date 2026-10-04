-- Pure-data boundary intersection audit followed by a checked BSP union.
return function(E)
	E = E or require(script.Parent.Parent)
	local a = E.Primitives.box()
	local b = E.Deform.transform(a, CFrame.new(0.5, 0.25, 0))
	local intersections, before = E.Intersections.between(a, b)
	assert(before.complete and before.surfaceCrossing and #intersections > 0)
	local mesh, operation = E.Boolean.union(a, b, { checkIntersections = true })
	assert(mesh:validate().closed and operation.intersections.intersectionFree)
	return {
		mesh = mesh,
		before = before,
		intersections = intersections,
		operation = operation,
		source = E.IO.encode(mesh),
	}
end
