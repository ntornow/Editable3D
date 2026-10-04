--!strict
-- Exact native-coordinate intersection classification with rounded constructions.
local Core = require(script.Parent.TriangleIntersectionCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Classification/report records come from the non-strict intersection core; fields vary by classification.
export type IntersectionResult = { [string]: any }
export type ScanReport = { [string]: any }
local I = {}
function I.segmentTriangle(a: Vector3, b: Vector3, triangle: { Vector3 }): IntersectionResult
	return Core.segmentTriangle(a, b, triangle)
end
function I.triangles(a: { Vector3 }, b: { Vector3 }): IntersectionResult
	return Core.triangles(a, b)
end
function I.mesh(mesh: Mesh, options: { [string]: any }?): ({ IntersectionResult }, ScanReport)
	return require(script.Parent.MeshIntersectionScan)(mesh, nil, options)
end
function I.between(a: Mesh, b: Mesh, options: { [string]: any }?): ({ IntersectionResult }, ScanReport)
	return require(script.Parent.MeshIntersectionScan)(a, b, options)
end
return I
