-- A bicubic surface with a vanishing partial and a unique corner normal.
return function()
	local E = require(script.Parent.Parent)
	local mesh = E.Mesh.new()
	local ids = {}
	for i = -1, 2 do
		ids[i] = {}
		for j = -1, 2 do
			ids[i][j] = mesh:addVertex(
				Vector3.new(i ^ 3 - i + 3 * i * (j ^ 3 - j), j, -0.5 * (3 * i * i - 1) * (3 * j * j - 1))
			)
		end
	end
	local target
	for i = -1, 1 do
		for j = -1, 1 do
			local face = mesh:addFace({ ids[i][j], ids[i + 1][j], ids[i + 1][j + 1], ids[i][j + 1] })
			if i == 0 and j == 0 then
				target = face
			end
		end
	end
	local sample = E.Subdivision.limit(mesh, target, 0, 0, {
		exactPolynomialNormals = true,
		checkpoint = function(progress)
			if progress.stage == "exactNormalWork" then
				task.wait()
			end
		end,
	})
	assert(sample.normalAvailable and sample.normal.Z > 0.99999)
	assert(sample.polynomialNormalCertificate.normalExists and sample.derivativeU.Magnitude == 0)
	return mesh, sample
end
