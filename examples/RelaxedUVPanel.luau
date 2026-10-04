-- Preserve a panel border while reducing existing UV stretch in its interior.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Mesh.new()
	local n = 6
	local function id(i, j)
		return j * (n + 1) + i + 1
	end
	for j = 0, n do
		for i = 0, n do
			local u, v = i / n, j / n
			source:addVertex(Vector3.new(u, v, 0.15 * math.sin(math.pi * u) * math.sin(math.pi * v)))
		end
	end
	for j = 0, n - 1 do
		for i = 0, n - 1 do
			local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
			local corners = {}
			for k, vertex in ids do
				local p = source.vertices[vertex]
				local u, v = p.X, p.Y
				if u > 0 and u < 1 and v > 0 and v < 1 then
					u += 0.05 * math.sin(3 * p.X + p.Y)
					v += 0.06 * math.sin(p.X + 4 * p.Y)
				end
				corners[k] = { uv = Vector2.new(u, v) }
			end
			source:addFace(ids, corners)
		end
	end
	source:recalculateNormals()
	local mesh, relaxation = E.UV.relax(source, { method = "symmetricDirichlet", requireComplete = true })
	return { mesh = mesh, source = source, relaxation = relaxation }
end
