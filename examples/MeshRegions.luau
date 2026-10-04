-- Pure mesh data: quad strips, surface paths and typed domain conversion.
return function(E)
	E = E or require(script.Parent.Parent)
	local mesh = E.Primitives.grid(8, 6, Vector2.new(8, 6))
	local mask = E.Selection.sphere(mesh, Vector3.zero, 2)
	mesh = E.Attributes.set(E.Attributes.create(mesh, "influence", "vertex", "number", 0), "influence", mask)
	mesh = E.Attributes.convertDomain(mesh, "influence", "face", { name = "faceInfluence" })
	local region = E.Selection.convertDomain(mesh, mask, "vertex", "face", { mode = "any" })
	local edges, boundaries, report = E.Selection.regionBoundary(mesh, region)
	assert(report.complete)
	local ring = E.Selection.edgeRing(mesh, "30:31")
	local path = E.Selection.shortestPath(mesh, 1, 63)
	assert(ring.complete and path.found and path.complete)
	return { mesh = mesh, region = region, edges = edges, boundaries = boundaries, ring = ring, path = path }
end
