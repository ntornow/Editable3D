-- Exact crossing branches and a coplanar band, without polygonal approximation.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local plane = E.NURBS.surface({ { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
	local saddle =
		E.NURBS.surface({ { V(0, 0, 0.25), V(0, 1, -0.25) }, { V(1, 0, -0.25), V(1, 1, 0.25) } }, 1, 1)
	local crossing = E.SplineQuery.intersectSurfaces(saddle, plane, {
		method = "exactRuled",
		requireComplete = true,
		requireComponents = true,
	})
	assert(crossing.componentCount == 1 and #crossing.cells == 5 and #crossing.vertices == 5)
	local coplanar = E.NURBS.surface(
		{ { V(0, 0, 0), V(0, 1, 0) }, { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } },
		2,
		1
	)
	local overlap = E.SplineQuery.intersectSurfaces(coplanar, plane, {
		method = "exactRuled",
		parameterBox = { { 0, 1 }, { 0, 1 }, { 0.25, 0.75 }, { 0, 1 } },
		requireComplete = true,
	})
	assert(overlap.componentCount == 1 and overlap.components[1].parameterDimension == 2)
	assert(overlap.cells[3].kind == "band")
	return { surface = saddle, plane = plane, crossing = crossing, coplanar = coplanar, overlap = overlap }
end
