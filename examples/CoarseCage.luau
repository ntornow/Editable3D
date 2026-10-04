-- Remove one recognized grid level while bounding the changed polygon surface.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Subdivision.catmullClark(E.Primitives.box(Vector3.new(4, 3, 2)), 2)
	local mesh, report = E.Simplify.unsubdivide(source, 1, { maxDeviation = 0.75, requireComplete = true })
	assert(mesh:validate().valid and report.finalFaces == 24)
	return { mesh = mesh, source = source, report = report }
end
