-- A fixed two-face corner has a limiting normal despite an unbounded chart partial.
return function(E)
	E = E or require(script.Parent.Parent)
	local V = Vector3.new
	local mesh = E.Mesh.new()
	for _, p in { V(0, 0.5, 0), V(-2, 0, 0), V(0, 1, 2), V(2, 0, 0), V(-1, 2, 3), V(1, 2, 0) } do
		mesh:addVertex(p)
	end
	mesh:addFace({ 1, 2, 5, 3 })
	mesh:addFace({ 1, 3, 6, 4 })
	mesh = E.Subdivision.crease(mesh, nil, { [1] = 10 })
	local first = E.Subdivision.limit(mesh, 1, 0, 0)
	local second = E.Subdivision.limit(mesh, 2, 0, 0)
	assert(first.normalAvailable and second.normalAvailable and first.normalMethod == "fixedCornerJordan")
	assert(not first.derivativesAvailable and not second.derivativesAvailable)
	assert((first.normal - second.normal).Magnitude < 1e-6)
	return { mesh = mesh, first = first, second = second }
end
