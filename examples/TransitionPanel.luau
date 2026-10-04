-- Four locally coarsened patches retain a conforming UV perimeter in a finer panel.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Mesh.new()
	local n = 8
	local function id(i, j)
		return j * (n + 1) + i + 1
	end
	for j = 0, n do
		for i = 0, n do
			local x, y = i - 4, j - 4
			source:addVertex(Vector3.new(x, y, 0.03125 * (x * x + y * y)))
		end
	end
	local selection = {}
	for j = 0, n - 1 do
		for i = 0, n - 1 do
			local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
			local corners = {}
			for k, v in ids do
				local p = source.vertices[v]
				corners[k] = { uv = Vector2.new((p.X + 4) / 8, (p.Y + 4) / 8) }
			end
			local fid = source:addFace(ids, corners)
			selection[fid] = i >= 2 and i < 6 and j >= 2 and j < 6
		end
	end
	local mesh, coarsening = E.Simplify.unsubdivide(source, 1, {
		transitions = true,
		faces = selection,
		maxDeviation = 0.2,
		requireComplete = true,
	})
	return { mesh = mesh, source = source, coarsening = coarsening }
end
