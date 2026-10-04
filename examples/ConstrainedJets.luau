-- A six-face crease with an exactly absent growing mode and finite chart jets.
return function()
	local E = require(script.Parent.Parent)
	local V = Vector3.new
	local mesh = E.Mesh.new()
	mesh:addVertex(Vector3.zero)
	local rays = { V(1, 0, 0), V(0, 1, 0), V(-1, 0, 0), V(0, -1, 0) }
	local edges = {}
	for j = 0, 6 do
		local p = rays[j % 4 + 1]
		edges[j + 1] = mesh:addVertex(p + V(0, 0, p.Y))
	end
	for j = 0, 5 do
		local a, b = rays[j % 4 + 1], rays[(j + 1) % 4 + 1]
		local d = mesh:addVertex(a + b + V(0, 0, -2 * (a.Y + b.Y)))
		mesh:addFace({ 1, edges[j + 1], d, edges[j + 2] })
	end
	local evaluator = E.Subdivision.prepareLimit(mesh, { exactConstrainedJets = true })
	local limits = {}
	for face = 1, 6 do
		local r = evaluator:evaluate(face, 0, 0)
		assert(r.derivativesAvailable and r.normalAvailable and r.constrainedJetCertificate.finiteCertified)
		limits[face] = r
	end
	return mesh, limits
end
