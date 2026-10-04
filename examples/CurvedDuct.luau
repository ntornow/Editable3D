-- A tapered duct mapped by physical distance onto an exact rational arc.
return function(E)
	E = E or require(script.Parent.Parent)
	local rings = {}
	for i = 0, 16 do
		local ring = {}
		for j = 0, 11 do
			local angle = 2 * math.pi * j / 12
			ring[j + 1] = Vector3.new(i / 4, 0.3 * math.cos(angle), 0.3 * math.sin(angle))
		end
		table.insert(rings, ring)
	end
	local source = E.Curves.loft(rings, true)
	local labels = {}
	for id, p in source.vertices do
		labels[id] = p.X / 4
	end
	source =
		E.Attributes.set(E.Attributes.create(source, "station", "vertex", "number", 0), "station", labels)
	local tapered, taper = E.Deform.taperProfile(source, {
		Vector2.new(0, 1),
		Vector2.new(0.4, 1.25),
		Vector2.new(1, 0.65),
	}, { axis = "X" })
	local curve = E.Surfaces.arc(CFrame.identity, 3, 0, math.pi / 2)
	local mesh, deformation = E.Deform.curve(tapered, curve, {
		fit = true,
		up = Vector3.zAxis,
		tolerance = 0.001,
		roll = function(t)
			return t * math.pi / 4
		end,
	})
	assert(taper.complete and deformation.complete and mesh:validate().closed)
	for id, station in labels do
		assert(E.Attributes.get(mesh, "station", id) == station)
	end
	return { mesh = mesh, taper = taper, deformation = deformation, source = E.IO.encode(mesh) }
end
