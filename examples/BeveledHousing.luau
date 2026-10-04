-- Pure-data recessed housing with edge profiles and a final weighted-normal pass.
return function(E)
	E = E or require(script.Parent.Parent)
	local block = E.Primitives.box(Vector3.new(4, 2, 3))
	local recessed = E.MeshEdit.insetRegion(block, { [5] = true }, 0.35, { depth = -0.2 })
	local beveled, bevel = E.Modifiers.bevel(recessed, 0.05, { segments = 3, angle = math.rad(20) })
	local final, normals = E.Normals.recalculate(beveled, { weighting = "areaAngle" })
	assert(final:validate().closed)
	return { mesh = final, bevel = bevel, normals = normals, source = E.IO.encode(final) }
end
