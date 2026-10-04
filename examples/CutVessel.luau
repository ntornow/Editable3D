-- Pure-data profile spin, finite knife detail and a capped cross section.
return function(E)
	E = E or require(script.Parent.Parent)
	local profile, ids = E.Mesh.new(), {}
	for _, point in
		{ Vector3.new(0, -1, 0), Vector3.new(2, -1, 0), Vector3.new(2, 1, 0), Vector3.new(0, 1, 0) }
	do
		table.insert(ids, profile:addVertex(point))
	end
	local vessel, spin =
		E.MeshEdit.spin(profile, ids, Vector3.zero, Vector3.yAxis, -2 * math.pi, 32, { uv = "sweep" })
	local detailed, knife =
		E.MeshEdit.knife(vessel, { { face = 2, path = { { edge = 1, t = 0.4 }, { edge = 3, t = 0.6 } } } })
	local section, cut = E.MeshEdit.bisect(
		detailed,
		Vector3.new(0.3, 0, 0),
		Vector3.xAxis,
		{ keep = "negative", cap = true, material = 2 }
	)
	assert(section:validate().closed)
	return { mesh = section, spin = spin, knife = knife, cut = cut, source = E.IO.encode(section) }
end
