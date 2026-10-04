-- Separate UV chart cuts and a smooth scalar field on a refined panel.
return function(E)
	E = E or require(script.Parent.Parent)
	local cage = E.Primitives.grid(4, 4, Vector2.new(4, 4))
	for id, p in cage.vertices do
		cage.vertices[id] = Vector3.new(p.X, 0.3 * math.cos(p.X) * math.cos(p.Z), p.Z)
	end
	local values, cuts = {}, {}
	for fid, face in cage.faces do
		for i, v in face.vertices do
			values[fid .. ":" .. i] = cage.vertices[v].Y
		end
	end
	cage = E.Attributes.set(E.Attributes.create(cage, "height", "corner", "number", 0), "height", values)
	for key, e in cage:topology().edges do
		if cage.vertices[e.a].X == 0 and cage.vertices[e.b].X == 0 then
			cuts[key] = true
		end
	end
	local mesh = E.Subdivision.catmullClark(cage, 2, {
		faceVarying = { uv = "corners", ["attribute:height"] = "smooth" },
		faceVaryingSeams = { uv = cuts },
	})
	assert(mesh:validate().valid and mesh.attributes["subdivision_fvar_topology:uv"])
	for fid, face in mesh.faces do
		for i, v in face.vertices do
			assert(math.abs(E.Attributes.get(mesh, "height", fid .. ":" .. i) - mesh.vertices[v].Y) < 3e-6)
		end
	end
	assert(not cage.attributes["subdivision_fvar_topology:uv"])
	return { mesh = mesh, cage = cage, seams = cuts, source = E.IO.encode(mesh) }
end
