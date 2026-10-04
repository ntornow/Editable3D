-- A three-quad boundary sector with a limiting normal and growing chart derivatives.
return function()
	local E = require(script.Parent.Parent)
	local V = Vector3.new
	local mesh = E.Mesh.new()
	for _, p in
		{
			V(0, 0.25, 0.125),
			V(-2, 0, 0),
			V(-1, 1, 2),
			V(1, 1, -0.5),
			V(2, 0, 0.25),
			V(-3, 2, 1),
			V(0, 3, 1.5),
			V(3, 2, -1),
		}
	do
		mesh:addVertex(p)
	end
	for i = 1, 3 do
		mesh:addFace({ 1, i + 1, i + 5, i + 2 })
	end
	local limits = {}
	for face = 1, 3 do
		local result = E.Subdivision.limit(mesh, face, 0, 0)
		assert(
			result.normalAvailable
				and not result.derivativesAvailable
				and result.normalMethod == "creaseThreeSector"
		)
		limits[face] = result
	end
	return mesh, limits
end
