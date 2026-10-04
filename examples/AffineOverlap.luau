-- Exact overlap of two affine patches, including the closed boundary contacts.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local a = E.NURBS.surface({ { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
	local b = E.NURBS.surface(
		{ { V(0.5, -0.25, 0), V(-0.25, 0.5, 0) }, { V(1.25, 0.5, 0), V(0.5, 1.25, 0) } },
		1,
		1
	)
	local result = E.SplineQuery.intersectSurfaces(
		a,
		b,
		{ method = "exactAffine", requireComplete = true, requireComponents = true }
	)
	local cell = result.cells[1]
	local mesh, ids = E.Mesh.new(), {}
	for i, vertex in cell.vertices do
		ids[i] = mesh:addVertex(vertex.position)
	end
	for _, triangle in cell.triangles do
		mesh:addFace({ ids[triangle[1]], ids[triangle[2]], ids[triangle[3]] })
	end
	assert(mesh:validate().valid)
	return { mesh = mesh, intersection = result, surfaceA = a, surfaceB = b }
end
