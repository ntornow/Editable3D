-- A complete tangent ruling is identified across a periodic source seam.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local rows = {}
	for _, p in { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) } do
		table.insert(rows, { p - V(0, 0, 1), p + V(0, 0, 1) })
	end
	local cylinder = E.Cyclic.surface(rows, 1, 1, { cyclicU = true, cyclicV = false })
	local plane = E.NURBS.surface({ { V(1, -2, -2), V(1, -2, 2) }, { V(1, 2, -2), V(1, 2, 2) } }, 1, 1)
	local contact = E.SplineQuery.intersectSurfaces(cylinder, plane, {
		method = "exactRuled",
		requireQuotient = true,
	})
	assert(contact.componentCount == 2 and contact.quotientComponentCount == 1)
	local join = contact.periodicQuotient.joins[1]
	assert(join.parameterDimension == 1 and contact.quotientTopologyCertified)
	assert(#contact.vertices == 4 and #contact.periodicQuotient.vertexClasses == 2)
	return { surface = cylinder, plane = plane, contact = contact }
end
