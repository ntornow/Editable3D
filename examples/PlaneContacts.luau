-- Exact tangency at a patch corner, plus a coplanar clipped rational arc.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local plane = E.NURBS.surface({ { V(0, 0, 0), V(0, 1, 0) }, { V(1, 0, 0), V(1, 1, 0) } }, 1, 1)
	local curve = E.NURBS.curve({ V(0, 0, 1), V(0, 0, -1), V(0, 0, 1) }, 2)
	local tangent =
		E.SplineQuery.intersectCurveSurface(curve, plane, { method = "exactPlane", requireComplete = true })
	assert(#tangent.roots == 1 and tangent.roots[1].contacts[1].order == 2)
	assert(#tangent.roots[1].activeBounds == 2)
	local coplanar = E.NURBS.curve({ V(-1, 0.5, 0), V(-1, 0.5, 0), V(2, 0.5, 0) }, 2)
	local overlap = E.SplineQuery.intersectCurveSurface(
		coplanar,
		plane,
		{ method = "exactPlane", requireComplete = true }
	)
	assert(#overlap.overlaps == 1 and #overlap.roots == 0 and overlap.componentCount == 1)
	assert(not overlap.vertices[1].algebraic.exact and not overlap.vertices[2].algebraic.exact)
	return { surface = plane, curve = curve, tangent = tangent, coplanar = coplanar, overlap = overlap }
end
