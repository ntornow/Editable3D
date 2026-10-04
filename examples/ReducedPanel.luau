-- A bounded symmetric reduction with an unchanged UV perimeter and center pin.
return function(E)
	E = E or require(script.Parent.Parent)
	local source = E.Mesh.new()
	local n = 6
	local function id(i, j)
		return j * (n + 1) + i + 1
	end
	for j = 0, n do
		for i = 0, n do
			local x, y = i - n / 2, j - n / 2
			source:addVertex(Vector3.new(x, y, 0.0625 * x * x + 0.03125 * y * y))
		end
	end
	local function face(ids)
		local corners = {}
		for i, v in ids do
			local p = source.vertices[v]
			corners[i] = { uv = Vector2.new((p.X + 3) / 6, (p.Y + 3) / 6) }
		end
		source:addFace(ids, corners)
	end
	for j = 0, n - 1 do
		for i = 0, n - 1 do
			local a, b, c, d = id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1)
			if i < n / 2 then
				face({ a, b, c })
				face({ a, c, d })
			else
				face({ a, b, d })
				face({ b, c, d })
			end
		end
	end
	local mesh, reduction = E.Simplify.decimate(source, 48, {
		pins = { [id(3, 3)] = true },
		symmetry = { axis = "X" },
		maxDeviation = 2,
		requireComplete = true,
	})
	return { mesh = mesh, source = source, reduction = reduction }
end
