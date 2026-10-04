-- A reusable rational control-grid edit workflow, with no scene side effects.
return function(E)
	E = E or require(script.Parent.Parent)
	local points = {}
	for i = 1, 4 do
		points[i] = {}
		for j = 1, 4 do
			points[i][j] = Vector3.new(i - 1, 0, j - 1)
		end
	end
	local surface = E.NURBS.surface(points, 2, 2)
	local extended, extension = E.SurfaceEdit.extrude(surface, "U1", 2, Vector3.xAxis)
	local mask = E.SurfaceEdit.select(extended, function(_, _, i, j)
		if i == 1 or i == 6 or j == 1 or j == 4 then
			return 0
		end
		return math.sin((i - 1) * math.pi / 5) * math.sin((j - 1) * math.pi / 3)
	end)
	local raised, transform = E.SurfaceEdit.transform(extended, CFrame.new(0, 1.2, 0), { mask = mask })
	local weighted = E.SurfaceEdit.setWeights(raised, 1.4, { mask = mask })
	local smooth = E.SurfaceEdit.smooth(weighted, 2, { factor = 0.2 })
	local result, deformation = E.SurfaceEdit.deform(smooth, function(mesh)
		return E.Deform.shear(mesh, 0.15, { axis = "Y", direction = "X" })
	end)
	local mesh = E.NURBS.tessellate(result, 16, 12)
	assert(extension.complete and extension.createdControls == 8)
	assert(transform.modifiedControls == 8 and deformation.complete)
	assert(mesh:validate().valid)
	assert(surface.control[4][4] == Vector3.new(3, 0, 3))
	return {
		surface = result,
		mesh = mesh,
		extension = extension,
		transform = transform,
		deformation = deformation,
		source = E.IO.encode(mesh),
	}
end
