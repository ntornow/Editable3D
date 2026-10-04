-- A fixed three-face sector, queried through its explicitly refined corner patch.
return function()
	local E = require(script.Parent.Parent)
	local V = Vector3.new
	local mesh = E.Mesh.new()
	for _, p in
		{
			V(0, 0, 0),
			V(-2, 0, 0),
			V(-1, 1, 1),
			V(1, 1, 1),
			V(2, 0, 0),
			V(-3, 2, 1),
			V(0, 3, 2),
			V(3, 2, 1),
		}
	do
		mesh:addVertex(p)
	end
	for i = 1, 3 do
		mesh:addFace({ 1, i + 1, i + 5, i + 2 })
	end
	mesh = E.Subdivision.crease(mesh, nil, { [1] = 10 })
	local sample = E.Subdivision.limit(mesh, 1, 0, 0, {
		corner = 1,
		exactConstrainedNormals = true,
		checkpoint = function(progress)
			if progress.stage == "exactNormalWork" then
				task.wait()
			end
		end,
	})
	assert(sample.normalAvailable and sample.constrainedNormalCertificate.normalCertified)
	assert(sample.constrainedNormalCertificate.exactHistorySteps == 1)
	return mesh, sample
end
