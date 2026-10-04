-- Audited subtraction with typed channels and distinct cutter material slots.
return function(E)
	E = E or require(script.Parent.Parent)
	local left, right = E.Primitives.box(), E.Primitives.box()
	for id, p in right.vertices do
		right.vertices[id] = p + Vector3.new(0.7, 0.3, 0.2)
	end
	for index, mesh in { left, right } do
		local values = {}
		for id, p in mesh.vertices do
			values[id] = p.X
		end
		mesh = E.Attributes.set(
			E.Attributes.create(mesh, "horizontal", "vertex", "number", 0),
			"horizontal",
			values
		)
		mesh = E.Attributes.create(mesh, "region", "face", "string", "")
		local regions = {}
		for fid in mesh.faces do
			regions[fid] = index == 1 and "body" or "cut"
		end
		mesh = E.Attributes.set(mesh, "region", regions)
		if index == 1 then
			left = mesh
		else
			right = mesh
		end
	end
	local mesh, operation = E.Boolean.subtract(left, right, { method = "arrangement", materialOffsetB = 10 })
	assert(operation.complete and math.abs(mesh:volume() - 4.022) < 1e-5)
	return { mesh = mesh, operation = operation, source = E.IO.encode(mesh) }
end
