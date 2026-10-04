-- Curved contacts across both knot directions and a periodic corner quotient.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local plane = E.NURBS.surface({ { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
	local control, height = {}, { 0.25, -0.25, 0.25 }
	for i = 1, 3 do
		control[i] = {}
		for j = 1, 3 do
			control[i][j] = V((i - 1) / 2, (j - 1) / 2, height[i] + height[j] - 0.125)
		end
	end
	local surface = E.NURBS.surface(control, 2, 2)
	surface = E.NURBS.insertSurfaceKnot(surface, "U", 0.5, 2)
	surface = E.NURBS.insertSurfaceKnot(surface, "V", 0.5, 2)
	local circle = E.SplineQuery.intersectSurfaces(surface, plane, {
		method = "exactTensorPlane",
		requireComplete = true,
		requireComponents = true,
	})
	assert(circle.componentCount == 1 and circle.components[1].parameterDimension == 1)
	assert(#circle.spanJoins == 4)
	local periodicControl = {}
	for i = 1, 4 do
		periodicControl[i] = {}
		for j = 1, 4 do
			periodicControl[i][j] = V(0.5, 0.5, (i == 1 and 0 or 1) + (j == 1 and 0 or 1))
		end
	end
	local periodic = E.Cyclic.surface(periodicControl, 1, 1)
	local corner = E.SplineQuery.intersectSurfaces(periodic, plane, {
		method = "exactTensorPlane",
		requireComplete = true,
		requireQuotient = true,
	})
	assert(corner.componentCount == 4 and corner.quotientComponentCount == 1)
	return { surface = surface, plane = plane, circle = circle, periodic = periodic, corner = corner }
end
