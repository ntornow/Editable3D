-- Callable control-grid authoring for rational and unique cyclic surfaces.
local P = require(script.Parent.SurfacePointEdit)
local G = require(script.Parent.SurfaceGridEdit)
local S = {}
function S.select(surface, selector, options)
	return P.select(surface, selector, options)
end
function S.map(surface, operation, options)
	return P.map(surface, operation, options)
end
function S.transform(surface, frame, options)
	return P.transform(surface, frame, options)
end
function S.setWeights(surface, values, options)
	return P.weights(surface, values, options)
end
function S.smooth(surface, iterations, options)
	return P.smooth(surface, iterations, options)
end
function S.deform(surface, operation, options)
	return P.deform(surface, operation, options)
end
function S.duplicate(surface, uRange, vRange, options)
	return G.duplicate(surface, uRange, vRange, options)
end
function S.transpose(surface, options)
	return G.transpose(surface, options)
end
function S.setCyclic(surface, axis, enabled, options)
	return G.setCyclic(surface, axis, enabled, options)
end
function S.extrude(surface, boundary, steps, operation, options)
	return G.extrude(surface, boundary, steps, operation, options)
end
function S.split(surface, axis, index, options)
	return G.split(surface, axis, index, options)
end
function S.deleteRows(surface, axis, indices, options)
	return G.deleteRows(surface, axis, indices, options)
end
function S.deleteSegments(surface, axis, first, last, options)
	return G.deleteSegments(surface, axis, first, last, options)
end
function S.boundaryCurve(surface, boundary, options)
	return G.boundaryCurve(surface, boundary, options)
end
function S.spin(surface, boundary, origin, axis, angle, options)
	return G.spin(surface, boundary, origin, axis, angle, options)
end
return S
