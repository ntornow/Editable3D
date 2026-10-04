return function(E)
	E = E or require(script.Parent.Parent)
	local N = E.NURBS
	local ring = { Vector3.xAxis, Vector3.new(1, 1, 0), Vector3.yAxis }
	local control, weights = {}, {}
	for i, p in ring do
		control[i] = { p, p + Vector3.zAxis * 3 }
		local w = i == 2 and math.sqrt(0.5) or 1
		weights[i] = { w, w }
	end
	local source = N.surface(control, 2, 1, { weights = weights })
	local refined = N.insertSurfaceKnot(N.insertSurfaceKnot(source, "U", 0.5, 2), "V", 0.5)
	-- Knot insertion retains the exact cylinder; moving the new control changes it.
	local edited = N.surface(
		refined.control,
		refined.degreeU,
		refined.degreeV,
		{ knotsU = refined.knotsU, knotsV = refined.knotsV, weights = refined.weights }
	)
	edited.control[3][2] += Vector3.new(0.2, 0.2, 0)
	return { source = source, refined = refined, edited = edited, mesh = N.tessellate(edited, 40, 20) }
end
