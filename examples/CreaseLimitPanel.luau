-- Sample two limit patches with shared positions and separate crease normals.
return function(E)
	E = E or require(script.Parent.Parent)
	local cage = E.Mesh.new()
	local function vertex(i, j)
		return i * 7 + j + 1
	end
	for i = 0, 5 do
		for j = 0, 6 do
			local y = j - 3
			local z = i * i + (y >= 0 and 2 or 5) * y * y + (y >= 0 and 3 or -1) * y
			cage:addVertex(Vector3.new(i, j, z))
		end
	end
	for i = 0, 4 do
		for j = 0, 5 do
			cage:addFace({ vertex(i, j), vertex(i + 1, j), vertex(i + 1, j + 1), vertex(i, j + 1) })
		end
	end
	local creases = {}
	for i = 0, 4 do
		creases[vertex(i, 3) .. ":" .. vertex(i + 1, 3)] = 10
	end
	cage = E.Subdivision.crease(cage, creases)
	local evaluator = E.Subdivision.prepareLimit(cage, { requireComplete = true })
	local mesh, ids = E.Mesh.new(), {}
	local n = 4
	for side = 0, 1 do
		local samples = {}
		for i = 0, n do
			for j = 0, n do
				local r = evaluator:evaluate(15 + side, i / n, j / n)
				assert(r.normalAvailable and r.derivativesAvailable and r.oneSided)
				local key = i .. ":" .. (j + n * side)
				ids[key] = ids[key] or mesh:addVertex(r.position)
				samples[key] = { uv = Vector2.new(i / n, (j + n * side) / (2 * n)), normal = r.normal }
			end
		end
		for i = 0, n - 1 do
			for j = n * side, n * (side + 1) - 1 do
				local keys =
					{ i .. ":" .. j, (i + 1) .. ":" .. j, (i + 1) .. ":" .. (j + 1), i .. ":" .. (j + 1) }
				local vertices, corners = {}, {}
				for k, key in keys do
					vertices[k], corners[k] = ids[key], samples[key]
				end
				mesh:addFace(vertices, corners)
			end
		end
	end
	assert(mesh:validate().valid)
	return { mesh = mesh, cage = cage, queries = evaluator:statistics() }
end
