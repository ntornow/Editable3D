-- Explicitly close a narrow source gap before winding classification.
return function(E)
	E = E or require(script.Parent.Parent)
	local a, b = E.Primitives.box(), E.Primitives.box()
	for id, p in b.vertices do
		b.vertices[id] = p + Vector3.new(2 + 2 ^ -19, 0, 0)
	end
	local source = E.Topology.join({ a, b })
	local mesh, repair = E.MeshRepair.resolveIntersections(source, {
		regularization = { method = "vertexClusters", distance = 2 ^ -18 },
		tolerance = 1e-7,
		windingPrecision = "exact",
		maxWork = 50000000,
	})
	assert(repair.complete, repair.reason)
	assert(repair.validation.surfaceComponents == 1)
	return { source = source, mesh = mesh, repair = repair }
end
