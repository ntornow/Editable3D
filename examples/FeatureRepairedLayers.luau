-- Close a gap when one source face has an unmatched interior vertex.
return function()
	local E = require(script.Parent.Parent)
	local a, b = E.Primitives.box(), E.Primitives.box()
	local selected = {}
	for fid, face in b.faces do
		local left = true
		for _, id in face.vertices do
			if b.vertices[id].X ~= -1 then
				left = false
			end
		end
		if left then
			selected[fid] = true
		end
	end
	b = E.MeshEdit.poke(b, selected)
	for id, p in b.vertices do
		b.vertices[id] = p + Vector3.new(2 + 1 / 1024, 0, 0)
	end
	local mesh, report = E.MeshRepair.resolveIntersections(E.Topology.join({ a, b }), {
		regularization = { method = "features", distance = 1 / 512 },
		tolerance = 1e-7,
		windingPrecision = "exact",
		maxWork = 50000000,
	})
	assert(report.complete, report.reason)
	assert(report.arrangement.regularization.addedVertices == 1)
	return mesh, report
end
