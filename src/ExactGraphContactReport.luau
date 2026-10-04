-- Finite exact graph-pair certificate, using the shared planar cell encoder.
return function(prepared, cad, vertices, anchors)
	local data = prepared.data
	local R = data.R
	data.report.algorithm = "exactGraphPair"
	data.report.vertices = vertices
	local zero, one = R.number(0), R.number(1)
	local globalSpan = { offset = { zero, zero }, scale = { one, one }, anchors = anchors }
	local classes, map = {}, {}
	for i in vertices do
		classes[i] = { index = i, representative = i, vertexIndices = { i } }
		map[i] = i
	end
	local parameterVertices = { classes = classes, map = map }
	local components = {}
	for i, c in cad.components do
		components[i] = { index = i, dimension = c.dimension, parts = { { span = 1, component = c } } }
	end
	local gluing = { components = components, joins = {} }
	local quotient
	if data.options.identifyPeriodicSeams or data.options.requireQuotient then
		quotient = {
			axes = {},
			joins = {},
			components = {},
			unresolved = {},
			nodes = 0,
			pairs = 0,
			topologyCertified = true,
			vertices = parameterVertices,
		}
		for i, c in cad.components do
			quotient.components[i] = { index = i, dimension = c.dimension, parameterComponentIndices = { i } }
		end
	end
	local report = require(script.Parent.ExactTensorContactReport)(
		data,
		{ globalSpan },
		{ cad },
		gluing,
		parameterVertices,
		quotient
	)
	report.baseComplex = report.spans[1]
	report.spans = nil
	report.baseComplex.affineNumerators = nil
	report.sourceSpans = { {}, {} }
	for operand, spans in prepared.spans do
		for i, span in spans do
			report.sourceSpans[operand][i] = {
				index = i,
				indices = span.indices,
				knotSpans = span.knotSpans,
				offset = span.offset,
				scale = span.scale,
				homogeneous = span.original,
				baseHomogeneous = span.h,
				weightBounds = span.weightBounds,
				baseGuards = span.bounds,
			}
		end
	end
	report.projection = {
		direction = prepared.direction,
		droppedCoordinate = prepared.drop,
		forms = prepared.projectionForms,
		rank = 2,
		certified = true,
	}
	report.parameterMap = prepared.parameterMap
	report.spanPairs = prepared.pairs
	report.domainGuards = prepared.domainRefs
	for _, collection in { report.cells, report.events, report.vertices } do
		for _, entry in collection do
			entry.span = nil
			entry.complex = 1
		end
	end
	report.method = "Exact planar decomposition of common affine-projection graph contacts"
	report.boundaryOwnership =
		"One global base parameter owner; closed original span-pair guards define a continuous Boolean feasible set"
	report.componentSpace =
		"Full four-dimensional parameter contact set under an exact affine graph homeomorphism"
	report.representation =
		"Algebraic event fibers and root-ordinal cells in the first surface parameters; native vertices are bounded anchors"
	report.spanJoins = nil
	if quotient then
		report.periodicQuotient.representation =
			"Identity quotient: both supported graph domains are ordinary nonperiodic rectangles"
	end
	return report
end
