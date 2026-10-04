-- Original rational geometry. Pure data; callers choose placement and publishing.
return function(API)
	local E = API or require(script.Parent.Parent)
	local sphere = E.Surfaces.sphere(CFrame.identity, 2)
	local sphereMesh = E.NURBS.tessellate(sphere, 24, 32, { closedV = true, collapsePoles = true })
	local torus = E.Surfaces.torus(CFrame.new(6, 0, 0), 2, 0.6)
	local torusMesh = E.NURBS.tessellate(torus, 24, 32, { closedU = true, closedV = true })
	local sections = {}
	for i = 0, 3 do
		sections[i + 1] = E.Surfaces.arc(CFrame.new(-6, 0, i), 1 + 0.2 * i * i, 0, math.pi * 1.5)
	end
	local loft, report = E.Surfaces.loft(sections)
	assert(sphereMesh:validate().closed and torusMesh:validate().closed)
	return { sphere = sphereMesh, torus = torusMesh, loft = E.NURBS.tessellate(loft, 24, 24), report = report }
end
