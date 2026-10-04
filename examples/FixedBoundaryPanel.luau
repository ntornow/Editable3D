-- Tessellate adjacent patches at a fixed corner whose exact crease rule agrees.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local cage = E.Mesh.new()
	for _, p in { V(0, 0, 0), V(-2, 0, 0), V(0, 1, 2), V(2, 0, 0), V(-1, 2, 3), V(1, 2, 0) } do
		cage:addVertex(p)
	end
	cage:addFace({ 1, 2, 5, 3 })
	cage:addFace({ 1, 3, 6, 4 })
	cage = E.Subdivision.crease(cage, nil, { [1] = 10 })
	local evaluator = E.Subdivision.prepareLimit(cage, { requireComplete = true })
	local corner = evaluator:evaluate(1, 0, 0)
	assert(
		corner.normalMethod == "fixedMidpointCrease"
			and corner.derivativesAvailable
			and corner.normalAvailable
	)
	local mesh, ids = E.Mesh.new(), {}
	local n = 8
	for fid = 1, 2 do
		local vertices, samples = {}, {}
		for i = 0, n do
			vertices[i], samples[i] = {}, {}
			for j = 0, n do
				local r = evaluator:evaluate(fid, i / n, j / n)
				assert(r.normalAvailable, "Panel sample requires a resolved limit normal")
				local key = fid == 1 and i == 0 and "seam:" .. j
					or fid == 2 and j == 0 and "seam:" .. i
					or fid .. ":" .. i .. ":" .. j
				ids[key] = ids[key] or mesh:addVertex(r.position)
				vertices[i][j] = ids[key]
				samples[i][j] = {
					normal = r.normal,
					uv = fid == 1 and Vector2.new((1 - i / n) / 2, j / n)
						or Vector2.new((1 + j / n) / 2, i / n),
				}
			end
		end
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				mesh:addFace(
					{ vertices[i][j], vertices[i + 1][j], vertices[i + 1][j + 1], vertices[i][j + 1] },
					{ samples[i][j], samples[i + 1][j], samples[i + 1][j + 1], samples[i][j + 1] }
				)
			end
		end
	end
	assert(mesh:validate().valid)
	return { mesh = mesh, cage = cage, corner = corner, queries = evaluator:statistics() }
end
