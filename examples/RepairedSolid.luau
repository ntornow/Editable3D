-- Pure-data repair of three intersecting closed components.
return function(E)
	E = E or require(script.Parent.Parent)
	local parts = {}
	for _, offset in { Vector3.zero, Vector3.new(0.5, 0.25, 0), Vector3.new(0.2, -0.3, 0.7) } do
		local part = E.Primitives.box()
		for id, p in part.vertices do
			part.vertices[id] = p + offset
		end
		table.insert(parts, part)
	end
	local source = E.Topology.join(parts)
	local mesh, repair = E.MeshRepair.resolveIntersections(source)
	assert(repair.complete, repair.reason)
	assert(math.abs(mesh:volume() - 14.395) < 1e-5)
	return { mesh = mesh, sourceMesh = source, repair = repair, source = E.IO.encode(mesh) }
end
