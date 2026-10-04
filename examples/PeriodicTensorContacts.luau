-- A curved periodic seam contact and a separate curved component.
return function(E)
	E = E or require(script.Parent.Parent)
	local N, C = E.NURBS, E.Cyclic
	local V = Vector3.new
	local linear, square = { 0, 0.5, 1 }, { 0, 0, 1 }
	local ring = { { -1, 0 }, { 0, 1 }, { 1, 0 }, { 0, -1 } }
	local a, b = {}, {}
	for i, p in ring do
		a[i] = {}
		for j = 1, 3 do
			a[i][j] = V(p[1] * (1 + square[j]), p[2] * (1 + square[j]), square[j])
		end
	end
	for i = 1, 3 do
		b[i] = {}
		for j = 1, 3 do
			b[i][j] =
				V(-0.5 * (1 + square[j]) + 2 * linear[i], 0.5 * (1 + square[j]) - 2 * linear[i], square[j])
		end
	end
	local A, B = C.surface(a, 2, 2, { cyclicV = false }), N.surface(b, 2, 2)
	local options = { method = "exactTensorPair", requireComplete = true, requireQuotient = true }
	local r = E.SplineQuery.intersectSurfaces(A, B, options)
	assert(r.componentCount == 3 and r.quotientComponentCount == 2)
	for _, c in r.components do
		assert(c.parameterDimension == 1)
	end
	return { surfaceA = A, surfaceB = B, contacts = r }
end
