-- Two edge interiors approach while all original endpoints remain farther apart.
return function()
	local E = require(script.Parent.Parent)
	local source = E.Mesh.new()
	for _, point in
		{
			Vector3.new(-2, 0, 0),
			Vector3.new(2, 0, 0),
			Vector3.new(-2, -0.5, -1),
			Vector3.new(0, -2, 1 / 64),
			Vector3.new(0, 2, 1 / 64),
			Vector3.new(0.5, -2, 1),
		}
	do
		source:addVertex(point)
	end
	source:addFace({ 1, 2, 3 })
	source:addFace({ 4, 5, 6 })
	local out, report = E.MeshRepair.splitIntersections(source, {
		regularization = { method = "features", distance = 1 / 64, edgePairs = true },
		tolerance = 1e-7,
		maxWork = 50000000,
	})
	assert(report.complete and #report.arrangement.regularization.edgeSnaps == 1)
	return out, report
end
