-- Edit a unique periodic control net, elevate its degree and undo a refinement.
return function(E)
	E = E or require(script.Parent.Parent)
	local control = {}
	for i = 1, 6 do
		control[i] = {}
		local u = (i - 1) * 2 * math.pi / 6
		for j = 1, 5 do
			local v = (j - 1) * 2 * math.pi / 5
			control[i][j] =
				Vector3.new((3 + math.cos(v)) * math.cos(u), math.sin(v), (3 + math.cos(v)) * math.sin(u))
		end
	end
	local surface = E.Cyclic.surface(control, 3, 2)
	surface.control[1][2] += Vector3.yAxis * 0.3
	local raised, elevation = E.Cyclic.elevateSurfaceDegree(surface, "U", 1, { tolerance = 0.0001 })
	assert(elevation.complete, elevation.reason)
	local refined = E.Cyclic.insertSurfaceKnot(raised, "V", 0.375)
	local result, removal = E.Cyclic.removeSurfaceKnot(refined, "V", 0.375, 1, { tolerance = 0.0001 })
	assert(removal.complete, removal.reason)
	local mesh =
		E.NURBS.tessellate(E.Cyclic.surfaceToNURBS(result), 18, 15, { closedU = true, closedV = true })
	assert(mesh:validate().closed)
	return {
		mesh = mesh,
		surface = result,
		elevation = elevation,
		removal = removal,
		source = E.IO.encode(mesh),
	}
end
