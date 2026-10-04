-- Repair rounded, nearly coincident source layers using exact side samples.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local a, b = E.Primitives.box(V(2, 2, 2)), E.Primitives.box(V(2, 2, 2))
	for id, p in b.vertices do
		b.vertices[id] = p + V(0.5, 0.25, 0)
	end
	local source = E.Topology.join({ a, b })
	local frame = CFrame.new(16, -8, 32) * CFrame.Angles(0.2, 0.4, 0.3)
	for id, p in source.vertices do
		source.vertices[id] = frame:PointToWorldSpace(p)
	end
	local mesh, repair = E.MeshRepair.resolveIntersections(source, { maxWork = 50000000 })
	assert(repair.complete, "Rounded-layer repair did not pass its final geometry audits")
	return { source = source, mesh = mesh, repair = repair }
end
