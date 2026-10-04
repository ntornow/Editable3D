--!strict
--!strict
-- Callable control-grid authoring for rational and unique cyclic surfaces.
local P = require(script.Parent.SurfacePointEdit)
local G = require(script.Parent.SurfaceGridEdit)
-- Surface records and edit reports come from the non-strict SurfaceEditCore family; inputs are runtime-validated there.
type Surface = any
type Options = { [string]: any }?
local S = {}
function S.select(surface: Surface, selector: any, options: Options)
	return P.select(surface, selector, options)
end
function S.map(
	surface: Surface,
	operation: (Vector3, number, number, number) -> (Vector3, number?),
	options: Options
)
	return P.map(surface, operation, options)
end
function S.transform(surface: Surface, frame: CFrame, options: Options)
	return P.transform(surface, frame, options)
end
function S.setWeights(surface: Surface, values: any, options: Options)
	return P.weights(surface, values, options)
end
function S.smooth(surface: Surface, iterations: number?, options: Options)
	return P.smooth(surface, iterations, options)
end
function S.deform(surface: Surface, operation: (...any) -> ...any, options: Options)
	return P.deform(surface, operation, options)
end
function S.duplicate(surface: Surface, uRange: any, vRange: any, options: Options)
	return G.duplicate(surface, uRange, vRange, options)
end
function S.transpose(surface: Surface, options: Options)
	return G.transpose(surface, options)
end
function S.setCyclic(surface: Surface, axis: string, enabled: boolean, options: Options)
	return G.setCyclic(surface, axis, enabled, options)
end
function S.extrude(surface: Surface, boundary: string, steps: number?, operation: any, options: Options)
	return G.extrude(surface, boundary, steps, operation, options)
end
function S.split(surface: Surface, axis: string, index: number, options: Options)
	return G.split(surface, axis, index, options)
end
function S.deleteRows(surface: Surface, axis: string, indices: any, options: Options)
	return G.deleteRows(surface, axis, indices, options)
end
function S.deleteSegments(surface: Surface, axis: string, first: number, last: number, options: Options)
	return G.deleteSegments(surface, axis, first, last, options)
end
function S.boundaryCurve(surface: Surface, boundary: string, options: Options)
	return G.boundaryCurve(surface, boundary, options)
end
function S.spin(
	surface: Surface,
	boundary: string,
	origin: Vector3,
	axis: Vector3,
	angle: number,
	options: Options
)
	return G.spin(surface, boundary, origin, axis, angle, options)
end
return S
