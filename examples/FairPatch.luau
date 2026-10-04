-- Flatten a bumped patch with constrained biharmonic fairing and exact border pins.
return function(E, n)
	E = E or require(script.Parent.Parent)
	n = n or 8
	local source = E.Mesh.new()
	local function id(i, j)
		return j * (n + 1) + i + 1
	end
	for j = 0, n do
		for i = 0, n do
			local x, y = i / n, j / n
			local boundary = i == 0 or j == 0 or i == n or j == n
			local z = boundary and 0 or 0.12 * math.sin(math.pi * x) * math.sin(math.pi * y)
			source:addVertex(Vector3.new(x, y, z))
		end
	end
	for j = 0, n - 1 do
		for i = 0, n - 1 do
			for _, ids in
				{
					{ id(i, j), id(i + 1, j), id(i + 1, j + 1) },
					{ id(i, j), id(i + 1, j + 1), id(i, j + 1) },
				}
			do
				local corners = {}
				for k, vertex in ids do
					local p = source.vertices[vertex]
					corners[k] = { uv = Vector2.new(p.X, p.Y) }
				end
				source:addFace(ids, corners)
			end
		end
	end
	local mesh, fairing = E.Sculpt.fair(source, nil, {
		order = 2,
		lockAxes = { X = true, Y = true },
		requireComplete = true,
	})
	return { mesh = mesh, source = source, fairing = fairing }
end
