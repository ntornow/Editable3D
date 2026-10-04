-- Exact native-coordinate intersection classification with rounded constructions.
local Core = require(script.Parent.TriangleIntersectionCore)
local I = {}
function I.segmentTriangle(a, b, triangle)
	return Core.segmentTriangle(a, b, triangle)
end
function I.triangles(a, b)
	return Core.triangles(a, b)
end
function I.mesh(mesh, options)
	return require(script.Parent.MeshIntersectionScan)(mesh, nil, options)
end
function I.between(a, b, options)
	return require(script.Parent.MeshIntersectionScan)(a, b, options)
end
return I
