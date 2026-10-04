-- Pure-data weighted corners, sharp boundaries and explicit UV tangent frames.
return function(E)
	E = E or require(script.Parent.Parent)
	local base = E.Primitives.box(Vector3.new(6, 4, 2))
	local weighted, weights =
		E.Normals.recalculate(base, { weighting = "areaAngle", faceWeights = { [5] = 2 } })
	local tangents, frames = E.Normals.tangents(weighted)
	assert(frames.complete)
	local radial, edit = E.Normals.point(base, Vector3.zero, { direction = "away", mix = 0.4 })
	return {
		mesh = tangents,
		radial = radial,
		weights = weights,
		frames = frames,
		edit = edit,
		source = E.IO.encode(tangents),
	}
end
