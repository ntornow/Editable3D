--!strict
-- Bounded polygon reduction and triangle edge-collapse workflows.
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Options are validated by the implementing modules.
type Options = { [string]: any }
local S = {}
function S.planar(mesh: Mesh, angleLimit: number, options: Options?)
	return require(script.Parent.PlanarReduce)(mesh, angleLimit, options)
end
function S.unsubdivide(mesh: Mesh, iterations: number, options: Options?)
	return require(script.Parent.GridUnsubdivide)(mesh, iterations, options)
end
function S.decimate(mesh: Mesh, targetFaces: number, options: Options?)
	return require(script.Parent.MeshDecimate)(mesh, targetFaces, options)
end
return S
