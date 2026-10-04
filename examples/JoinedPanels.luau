-- Pin one rational patch and continue its full border through first derivatives.
return function(E)
	E = E or require(script.Parent.Parent)
	local p, q, wa, wb = {}, {}, {}, {}
	for i = 1, 4 do
		p[i], q[i], wa[i], wb[i] = {}, {}, {}, {}
		for j = 1, 4 do
			local u, v = (i - 1) / 3, (j - 1) / 3
			p[i][j] = Vector3.new(u, v, 0.08 * math.sin(i + j))
			q[i][j] = Vector3.new(1.2 + u, v, 0.1 * math.cos(i + j))
			wa[i][j] = ({ 1, 0.7, 0.9, 1 })[j]
			wb[i][j] = wa[i][j] * ({ 1, 0.8, 1.1, 1 })[i]
		end
	end
	local a = E.NURBS.surface(p, 3, 3, { weights = wa })
	local b = E.NURBS.surface(q, 3, 3, { weights = wb })
	local left, right, report = E.Surfaces.join(a, "U1", b, "U0", {
		order = 1,
		fixedA = true,
		pinsB = { ["4:1"] = true, ["4:2"] = true, ["4:3"] = true, ["4:4"] = true },
	})
	local meshes = { (E.NURBS.tessellate(left, 10, 10)), (E.NURBS.tessellate(right, 10, 10)) }
	for _, mesh in meshes do
		assert(mesh:validate().valid)
	end
	return { surfaces = { left, right }, meshes = meshes, join = report }
end
