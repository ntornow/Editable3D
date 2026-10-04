-- Bounded polygon reduction and triangle edge-collapse workflows.
local S = {}
function S.planar(mesh, angleLimit, options)
	return require(script.Parent.PlanarReduce)(mesh, angleLimit, options)
end
function S.unsubdivide(mesh, iterations, options)
	return require(script.Parent.GridUnsubdivide)(mesh, iterations, options)
end
function S.decimate(mesh, targetFaces, options)
	return require(script.Parent.MeshDecimate)(mesh, targetFaces, options)
end
return S
