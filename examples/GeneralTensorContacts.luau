-- A nonlinear four-parameter tensor contact loop with irrational boundary values.
return function(E)
	E = E or require(script.Parent.Parent)
	local linear, square = { 0, 0.5, 1 }, { 0, 0, 1 }
	local a, b = {}, {}
	for i = 1, 3 do
		a[i], b[i] = {}, {}
		for j = 1, 3 do
			a[i][j] = Vector3.new(linear[i], linear[j], square[i] + square[j])
			b[i][j] = Vector3.new(
				square[i],
				linear[j],
				0.625 * square[i] + 0.75 * square[j] + 0.25 * linear[j] - 25 / 256
			)
		end
	end
	a, b = E.NURBS.surface(a, 2, 2), E.NURBS.surface(b, 2, 2)
	local contacts = E.SplineQuery.intersectSurfaces(a, b, {
		method = "exactTensorPair",
		parameterOrder = { 3, 4, 1, 2 },
		requireComplete = true,
	})
	assert(contacts.parameterComponentsCertified and contacts.componentCount == 1)
	assert(contacts.components[1].parameterDimension == 1)
	return { surfaceA = a, surfaceB = b, contacts = contacts }
end
