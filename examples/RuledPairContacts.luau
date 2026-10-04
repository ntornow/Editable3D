-- Two curved cylinders meet in a complete loop; their rulings remain exact.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local a, b = {}, {}
	for i, x in { -1, 0, 1 } do
		local z = ({ 1, -1, 1 })[i]
		a[i] = { V(x, -1, z), V(x, 1, z) }
		b[i] = { V(-1, x, 0.5 - z), V(1, x, 0.5 - z) }
	end
	local first, second = E.NURBS.surface(a, 2, 1), E.NURBS.surface(b, 2, 1)
	local loop = E.SplineQuery.intersectSurfaces(
		first,
		second,
		{ method = "exactRuledPair", requireComplete = true, requireComponents = true }
	)
	assert(loop.componentCount == 1 and loop.components[1].parameterDimension == 1)
	assert(loop.baseCellTopologyCertified and not loop.cellTopologyCertified)
	local overlap =
		E.SplineQuery.intersectSurfaces(first, first, { method = "exactRuledPair", requireComplete = true })
	assert(overlap.componentCount == 1 and overlap.components[1].parameterDimension == 2)
	return { first = first, second = second, loop = loop, overlap = overlap }
end
