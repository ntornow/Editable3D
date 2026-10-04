-- Tessellate one patch of a rounded box directly on its geometric limit surface.
return function(E)
	E = E or require(script.Parent.Parent)
	local cage = E.Primitives.box(Vector3.new(4, 3, 2))
	local evaluator = E.Subdivision.prepareLimit(cage, { tolerance = 1e-5, requireComplete = true })
	local mesh = E.Mesh.new()
	local samples = {}
	local n = 6
	for i = 0, n do
		for j = 0, n do
			local r = evaluator:evaluate(1, i / n, j / n)
			local id = mesh:addVertex(r.position)
			samples[id] = { uv = Vector2.new(i / n, j / n), normal = r.normal }
		end
	end
	local function id(i, j)
		return i * (n + 1) + j + 1
	end
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local ids = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) }
			local corners = {}
			for k, v in ids do
				corners[k] = samples[v]
			end
			mesh:addFace(ids, corners)
		end
	end
	assert(mesh:validate().valid)
	return { mesh = mesh, cage = cage, queries = evaluator:statistics(), source = E.IO.encode(mesh) }
end
