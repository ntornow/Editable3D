-- Reduce a tiled panel while preserving a rectangular window and UV coordinates.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Mesh.new()
	local function vertex(i, j)
		return i * 5 + j + 1
	end
	for i = 0, 5 do
		for j = 0, 4 do
			source:addVertex(Vector3.new(i, j, 0))
		end
	end
	for i = 0, 4 do
		for j = 0, 3 do
			if i == 2 and (j == 1 or j == 2) then
				continue
			end
			local ids = { vertex(i, j), vertex(i + 1, j), vertex(i + 1, j + 1), vertex(i, j + 1) }
			local corners = {}
			for k, id in ids do
				local p = source.vertices[id]
				corners[k] = { uv = Vector2.new(p.X / 5, p.Y / 4) }
			end
			source:addFace(ids, corners)
		end
	end
	local mesh, report = E.Simplify.planar(source, 0, { dissolveBoundaries = true, requireComplete = true })
	assert(mesh:validate().valid)
	return { mesh = mesh, source = source, report = report }
end
