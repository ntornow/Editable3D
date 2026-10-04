-- Pure-data inset, cut and individual extrusion with reversible source checkpoints.
return function(E)
	E = E or require(script.Parent.Parent)
	local base = E.Primitives.box(Vector3.new(4, 2, 3))
	local inset, insetReport = E.MeshEdit.insetRegion(base, { [5] = true }, 0.2, { depth = 0.25 })
	local cut, cutReport = E.MeshEdit.loopCut(inset, "1:2", { 0.3, 0.7 })
	local final, extrusion = E.MeshEdit.extrudeFaces(cut, { [1] = true }, 0.2)
	assert(final:validate().closed)
	return {
		mesh = final,
		inset = insetReport,
		cuts = cutReport,
		extrusion = extrusion,
		source = E.IO.encode(final),
	}
end
