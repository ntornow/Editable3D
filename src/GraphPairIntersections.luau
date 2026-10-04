-- Complete planar CAD under an exact affine parameter-graph homeomorphism.
local decompose = require(script.Parent.ExactPlanarSignCells)
return function(surfaceA, surfaceB, settings)
	local prepared = require(script.Parent.ExactGraphPreparation)(surfaceA, surfaceB, settings)
	local data = prepared.data
	local R, P, B, ctx, options = data.R, data.P, data.B, data.ctx, data.options
	local spans, polys, pairs, owner = prepared.spans, prepared.polynomials, prepared.pairs, prepared.owner
	local zero, one = R.number(0), R.number(1)
	local cad = decompose(
		polys,
		{ data.bounds[1], data.bounds[2] },
		R,
		P,
		B,
		data.isolation,
		ctx,
		options,
		function(signs)
			return owner(signs) ~= nil
		end
	)
	data.enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local vertices, anchors = {}, {}
	for eventIndex, event in cad.events do
		for pointIndex, point in event.lift.points do
			if point.feasible then
				assert(#vertices < data.limits.maxVertices, "Graph native anchor allocation budget exceeded")
				local pairIndex = assert(owner(point.signs))
				local pair = pairs[pairIndex]
				local span = spans[1][pair.a]
				local sampleSpan = {
					h = span.h,
					u = span.u,
					v = span.v,
					offset = { zero, zero },
					scale = { one, one },
					weightBounds = span.weightBounds,
				}
				local vertex = require(script.Parent.ExactTensorContactSample)(sampleSpan, event, point, data)
				vertex.spanPair = pairIndex
				table.insert(vertices, vertex)
				table.insert(anchors, { event = eventIndex, point = pointIndex, vertex = #vertices })
			end
		end
	end
	local certificate = require(script.Parent.ExactGraphContactReport)(prepared, cad, vertices, anchors)
	return certificate
end
