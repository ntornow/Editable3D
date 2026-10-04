-- A higher crease with divergent chart partials and a proved limiting normal.
return function()
	local E = require(script.Parent.Parent)
	local V = Vector3.new
	local mesh = E.Mesh.new()
	for _, p in
		{
			V(0, 0.25, 0.125),
			V(-2, 0, 0),
			V(-1, 1, 2),
			V(0, 2, 0.25),
			V(1, 1, -0.5),
			V(2, 0, 0.25),
			V(-3, 2, 1),
			V(-1, 3, 1.5),
			V(1, 3, 2),
			V(3, 2, -1),
		}
	do
		mesh:addVertex(p)
	end
	for i = 1, 4 do
		mesh:addFace({ 1, i + 1, i + 6, i + 2 })
	end
	local sample = E.Subdivision.limit(mesh, 1, 0, 0, {
		exactConstrainedNormals = true,
		checkpoint = function(progress)
			if progress.stage == "exactNormalWork" then
				task.wait()
			end
		end,
	})
	assert(sample.normalAvailable and sample.constrainedNormalCertificate.normalCertified)
	assert(not sample.derivativesAvailable)
	return mesh, sample
end
