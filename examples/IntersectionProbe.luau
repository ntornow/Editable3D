-- A rational-spline query keeps certified points separate from unresolved regions.
return function(E)
	E = E or require(script.Parent.Parent)
	local points = {}
	local height = { 0.25, -0.25, 0.25 }
	for i = 1, 3 do
		points[i] = {}
		for j = 1, 3 do
			points[i][j] = Vector3.new((i - 1) / 2 - 0.5, (j - 1) / 2 - 0.5, height[i] + height[j])
		end
	end
	local surface = E.NURBS.surface(points, 2, 2)
	local curve = E.NURBS.curve({ Vector3.new(0.125, 0.25, -1), Vector3.new(0.125, 0.25, 1) }, 1)
	local intersections = E.SplineQuery.intersectCurveSurface(curve, surface, { requireComplete = true })
	local mesh = E.NURBS.tessellate(surface, 12, 12)
	assert(#intersections.roots == 1 and mesh:validate().valid)
	return { surface = surface, curve = curve, intersections = intersections, mesh = mesh }
end
