-- Finite public certificate data; private fields, caches, and closures stay local.
return function(data, spans, internals, gluing, parameterVertices, quotient)
	local R, report, ctx = data.R, data.report, data.ctx
	local function root(source, lift)
		local rational = not lift or lift.scalar == R
		return {
			low = lift and lift.asRational(source.low) or source.low,
			high = lift and lift.asRational(source.high) or source.high,
			exact = source.exact,
			polynomial = source.analysis and source.analysis.squarefree or {},
			coefficientField = rational and "rational" or "profileAlgebraic",
		}
	end
	report.spans, report.events, report.cells, report.components, report.connections = {}, {}, {}, {}, {}
	local maps = {}
	for spanIndex, span in spans do
		local cad = internals[spanIndex]
		local map = { cells = {}, events = {}, vertices = {} }
		maps[spanIndex] = map
		for _, anchor in span.anchors do
			map.vertices[anchor.event] = map.vertices[anchor.event] or {}
			map.vertices[anchor.event][anchor.point] = anchor.vertex
		end
		for i, cell in cad.cells do
			local out = {
				index = #report.cells + 1,
				span = spanIndex,
				kind = cell.kind == "event" and "fiber" or cell.kind,
				parameterDimension = cell.dimension,
				certified = true,
			}
			map.cells[i] = out.index
			table.insert(report.cells, out)
		end
		for i, event in cad.events do
			local out = {
				index = #report.events + 1,
				span = spanIndex,
				profile = root(event.root),
				roots = {},
				sectors = {},
				cellIndices = {},
			}
			map.events[i] = out.index
			for j, point in event.lift.points do
				local encoded = root(point.root, event.lift)
				encoded.feasible, encoded.signs = point.feasible, point.signs
				encoded.vertex = map.vertices[i] and map.vertices[i][j] or nil
				out.roots[j] = encoded
				if encoded.vertex then
					local v = report.vertices[encoded.vertex]
					v.index, v.event, v.span, v.root = encoded.vertex, out.index, spanIndex, j
					v.parameterClass = parameterVertices.map[encoded.vertex]
				end
			end
			for j, sector in event.lift.sectors do
				out.sectors[j] = { sample = sector.sample, feasible = sector.feasible, signs = sector.signs }
			end
			for _, c in event.lift.components do
				table.insert(out.cellIndices, map.cells[c.cell])
			end
			table.insert(report.events, out)
		end
		for i, cell in cad.cells do
			local out = report.cells[map.cells[i]]
			if cell.kind == "event" then
				local event = cad.events[cell.event]
				local c = event.lift.components[cell.fiber]
				out.event = map.events[cell.event]
				out.rootIndices = { c.first, c.last }
				out.vertexIndices = {}
				for j = c.first, c.last do
					table.insert(out.vertexIndices, map.vertices[cell.event][j])
				end
			else
				local slab = cad.slabs[cell.slab]
				local c = slab.lift.components[cell.fiber]
				out.firstEvent, out.lastEvent = map.events[slab.first], map.events[slab.last]
				out.rootIndices = { c.first, c.last }
				out.profileOpen = true
				out.profileSample = slab.sample
				out.sampleRootBounds = {
					root(slab.lift.points[c.first].root, slab.lift),
					root(slab.lift.points[c.last].root, slab.lift),
				}
				out.boundaryVertices = {}
			end
		end
		for _, connection in cad.connections do
			local out = {
				index = #report.connections + 1,
				firstCell = map.cells[connection.cell],
				secondCell = map.cells[connection.eventCell],
				event = map.events[connection.event],
				rootIndices = { connection.first, connection.last },
				parameterDimension = connection.first == connection.last and 0 or 1,
				certified = true,
				kind = "profileLimit",
			}
			out.vertexIndices = {
				map.vertices[connection.event][connection.first],
				map.vertices[connection.event][connection.last],
			}
			table.insert(report.connections, out)
			table.insert(report.cells[out.firstCell].boundaryVertices, out.vertexIndices)
		end
		local neighborhoods = {}
		for i, proof in cad.neighborhoods do
			neighborhoods[map.events[i]] = {
				cuts = proof.cuts,
				profileRange = { proof.low, proof.high },
				separatorPolynomials = proof.crossing,
				left = proof.left,
				right = proof.right,
			}
		end
		report.spans[spanIndex] = {
			index = spanIndex,
			indices = span.indices,
			knotSpans = span.knotSpans,
			offset = span.offset,
			scale = span.scale,
			domain = cad.domain,
			homogeneous = span.h,
			weightBounds = span.weightBounds,
			affineNumerators = { span.u, span.v },
			constraints = cad.original,
			basis = cad.basis,
			projection = cad.projection,
			controlBounds = span.controlBounds,
			eventIndices = map.events,
			adjacency = neighborhoods,
		}
	end
	local function joins(sources, periodic)
		local out = {}
		for _, join in sources do
			local row = {
				index = #out + 1,
				firstSpan = join.firstSpan,
				secondSpan = join.secondSpan,
				axis = join.axis,
				contacts = {},
				certified = true,
			}
			local a, b = maps[join.firstSpan], maps[join.secondSpan]
			local span = spans[join.firstSpan]
			row.parameterMap = { offset = span.offset[3 - join.axis], scale = span.scale[3 - join.axis] }
			for _, contact in join.contacts do
				local entry = {
					firstCell = a.cells[contact.first.cell],
					secondCell = b.cells[contact.second.cell],
					parameterRange = { root(contact.low), root(contact.high) },
					openLow = contact.openLow,
					openHigh = contact.openHigh,
					certified = true,
				}
				table.insert(row.contacts, entry)
				if not periodic then
					entry.index = #report.connections + 1
					entry.kind = "sharedKnot"
					entry.axis = join.axis
					table.insert(report.connections, entry)
				end
			end
			table.insert(out, row)
		end
		return out
	end
	report.spanJoins = joins(gluing.joins, false)
	for _, component in gluing.components do
		local out = {
			index = component.index,
			cellIndices = {},
			connectionIndices = {},
			parameterDimension = component.dimension,
			connected = true,
			certified = true,
		}
		for _, part in component.parts do
			for _, cell in part.component.cells do
				local id = maps[part.span].cells[cell]
				table.insert(out.cellIndices, id)
				report.cells[id].component = out.index
			end
		end
		table.sort(out.cellIndices)
		table.insert(report.components, out)
	end
	for i, connection in report.connections do
		local first, second =
			report.cells[connection.firstCell].component, report.cells[connection.secondCell].component
		assert(first == second, "Contact connection crosses certified parameter components")
		table.insert(report.components[first].connectionIndices, i)
	end
	report.parameterVertexClasses, report.parameterVertexMap =
		parameterVertices.classes, parameterVertices.map
	local allAccurate = true
	for i, vertex in report.vertices do
		allAccurate = allAccurate and vertex.accurate
		if not vertex.accurate then
			table.insert(report.unresolved, { vertex = i, reason = "nativeAnchorApproximation" })
		end
	end
	report.method = "Exact cylindrical algebraic decomposition of tensor/affine-plane contacts"
	report.representation =
		"Algebraic event fibers and root-ordinal graph/band cells; native vertices are anchors, not a polygonal approximation"
	report.boundaryOwnership =
		"Each knot tile owns its closed local domain; shared tile boundaries have explicit exact identifications"
	report.componentSpace = "Closed four-dimensional parameter domain with shared original knots identified"
	report.componentCount = #report.components
	report.covered = #report.cells
	report.visited = data.isolation.nodes
	report.coverageCertified, report.rootCoverageComplete, report.cellTopologyCertified, report.cellDimensionsCertified, report.parameterComponentsCertified =
		true, true, true, true, true
	report.parameterTopologyCertified, report.componentTopologyCertified = false, false
	report.complete, report.success, report.converged = allAccurate, allAccurate, allAccurate
	report.reason = allAccurate and "complete" or "approximation"
	report.quotientTopologyCertified, report.quotientComplete = false, false
	if quotient then
		local q = {
			requested = true,
			axes = quotient.axes,
			joins = joins(quotient.joins, true),
			components = {},
			unresolved = quotient.unresolved,
			nodes = quotient.nodes,
			pairs = quotient.pairs,
			topologyCertified = quotient.topologyCertified,
			contactsCertified = quotient.topologyCertified,
			componentsCertified = quotient.topologyCertified,
		}
		report.periodicQuotient = q
		q.complete = q.topologyCertified and allAccurate
		q.reason = q.topologyCertified and (allAccurate and "complete" or "approximation") or quotient.reason
		q.representation =
			"Original exact tensor contact cells with continuous equal-parameter seam interval identifications in each active periodic direction"
		for _, component in quotient.components do
			local out = {
				index = component.index,
				parameterComponentIndices = component.parameterComponentIndices,
				cellIndices = {},
				parameterDimension = component.dimension,
				connected = true,
				certified = true,
			}
			for _, index in out.parameterComponentIndices do
				for _, id in report.components[index].cellIndices do
					table.insert(out.cellIndices, id)
				end
			end
			table.sort(out.cellIndices)
			table.insert(q.components, out)
		end
		if quotient.vertices then
			q.vertexClasses, q.vertexMap = quotient.vertices.classes, quotient.vertices.map
		end
		q.componentCount = #q.components
		report.quotientTopologyCertified, report.quotientComplete = q.topologyCertified, q.complete
		report.quotientComponentCount = q.componentCount
	end
	ctx.check("finish")
	assert(not data.options.cancelled or not data.options.cancelled(), "Surface intersection query cancelled")
	assert(
		report.complete or not data.options.requireComplete,
		"Exact tensor native anchor approximation exceeds tolerance"
	)
	assert(
		not data.options.requireQuotient or report.quotientComplete,
		"Exact tensor periodic quotient incomplete: " .. tostring(report.periodicQuotient.reason)
	)
	return report
end
