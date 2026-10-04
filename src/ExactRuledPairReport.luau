-- Finite certificate for a planar base with compact convex ruling fibers.
-- Base incidences do not assert full four-parameter cell closure incidences.
return function(result)
	local data, spans, gluing = result.data, result.spans, result.gluing
	local R, report, ctx = data.R, data.report, data.ctx
	local function root(source, lift)
		return {
			low = lift and lift.asRational(source.low) or source.low,
			high = lift and lift.asRational(source.high) or source.high,
			exact = source.exact,
			polynomial = source.analysis and source.analysis.squarefree or {},
			coefficientField = (not lift or lift.scalar == R) and "rational" or "profileAlgebraic",
		}
	end
	report.algorithm = "exactRuledPair"
	report.spans, report.events, report.slabs, report.cells, report.components, report.connections =
		{}, {}, {}, {}, {}, {}
	report.vertices = {}
	for i, source in result.anchors do
		local out = table.clone(source)
		out.base = { profile = root(source.base.s), partner = root(source.base.t, source.base.lift) }
		out.index, out.parameterClass = i, result.parameterVertices.map[i]
		report.vertices[i] = out
	end
	local maps = {}
	for spanIndex, span in spans do
		local cad = span.cad
		local map = { cells = {}, events = {}, slabs = {} }
		maps[spanIndex] = map
		for i, cell in cad.cells do
			local out = {
				index = #report.cells + 1,
				span = spanIndex,
				kind = "fiberedRegion",
				baseKind = cell.kind,
				baseDimension = cell.dimension,
				parameterDimension = cell.fullDimension,
				fiberDimensionRange = cell.fiberDimensionRange,
				coverageCertified = true,
				dimensionCertified = true,
				cellTopologyCertified = false,
			}
			map.cells[i] = out.index
			table.insert(report.cells, out)
		end
		local function fiber(lift)
			local out = { roots = {}, sectors = {}, cellIndices = {} }
			local function atom(source)
				return {
					feasible = source.feasible,
					signs = source.signs,
					fiberDimension = source.fiberDimension,
					parameterDimension = source.fullDimension,
					vertexIndices = source.vertexIndices,
					cell = source.cell and map.cells[source.cell] or nil,
				}
			end
			for j, point in lift.points do
				local row = atom(point)
				row.root = root(point.root, lift)
				out.roots[j] = row
			end
			for j, sector in lift.sectors do
				local row = atom(sector)
				row.sample = sector.sample
				out.sectors[j] = row
			end
			for _, c in lift.components do
				table.insert(out.cellIndices, map.cells[c.cell])
			end
			return out
		end
		for i, event in cad.events do
			local out = fiber(event.lift)
			out.index, out.span, out.profile = #report.events + 1, spanIndex, root(event.root)
			map.events[i] = out.index
			table.insert(report.events, out)
		end
		for i, slab in cad.slabs do
			local out = fiber(slab.lift)
			out.index, out.span, out.profileSample = #report.slabs + 1, spanIndex, slab.sample
			out.firstEvent, out.lastEvent, out.profileOpen =
				map.events[slab.first], map.events[slab.last], true
			map.slabs[i] = out.index
			table.insert(report.slabs, out)
		end
		for i, cell in cad.cells do
			local out = report.cells[map.cells[i]]
			local lift = cell.kind == "event" and cad.events[cell.event].lift or cad.slabs[cell.slab].lift
			local c = lift.components[cell.fiber]
			out.event = cell.event and map.events[cell.event] or nil
			out.slab = cell.slab and map.slabs[cell.slab] or nil
			out.rootIndices = { c.first, c.last }
			out.vertexIndices = {}
			for j = c.first, c.last do
				for _, id in lift.points[j].vertexIndices do
					table.insert(out.vertexIndices, id)
				end
			end
			for j = c.first, c.last - 1 do
				for _, id in lift.sectors[j].vertexIndices do
					table.insert(out.vertexIndices, id)
				end
			end
		end
		for _, connection in cad.connections do
			table.insert(report.connections, {
				index = #report.connections + 1,
				kind = "baseProfileLimit",
				firstCell = map.cells[connection.cell],
				secondCell = map.cells[connection.eventCell],
				event = map.events[connection.event],
				rootIndices = { connection.first, connection.last },
				baseDimension = connection.first == connection.last and 0 or 1,
				baseIncidenceCertified = true,
				fullFiberLimitCertified = false,
			})
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
			knotSpans = { span.sources[1].knotSpan, span.sources[2].knotSpan },
			offset = span.offset,
			scale = span.scale,
			domain = cad.domain,
			endpointCurves = { span.sources[1].endpoints, span.sources[2].endpoints },
			rulingRanges = { span.sources[1].parameterRange, span.sources[2].parameterRange },
			weightBounds = { span.sources[1].weightBounds, span.sources[2].weightBounds },
			equations = span.equations,
			fiber = {
				constraints = span.projection.constraints,
				cases = span.projection.cases,
				normalReferences = span.projection.normalReferences,
				rankTwoReferences = span.projection.rankTwoReferences,
				signPolynomials = span.projection.sources,
			},
			basis = cad.basis,
			projection = cad.projection,
			eventIndices = map.events,
			slabIndices = map.slabs,
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
				baseAxis = join.axis,
				surface = join.surface,
				parameterAxis = join.parameterAxis,
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
					baseParameterRange = { root(contact.low), root(contact.high) },
					openLow = contact.openLow,
					openHigh = contact.openHigh,
					certified = true,
					completeRulingFibers = true,
				}
				table.insert(row.contacts, entry)
				if not periodic then
					entry.index, entry.kind, entry.baseAxis =
						#report.connections + 1, "sharedProfileKnot", join.axis
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
			baseDimension = component.dimension,
			parameterDimension = component.fullDimension,
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
		assert(first == second, "Base connection crosses a certified ruled-pair component")
		table.insert(report.components[first].connectionIndices, i)
	end
	report.parameterVertexClasses, report.parameterVertexMap =
		result.parameterVertices.classes, result.parameterVertices.map
	report.profileAxes = { result.first.profileAxis, result.second.profileAxis + 2 }
	report.rulingAxes = { result.first.linearAxis, result.second.linearAxis + 2 }
	local allAccurate = true
	for i, vertex in report.vertices do
		allAccurate = allAccurate and vertex.accurate
		if not vertex.accurate then
			table.insert(report.unresolved, { vertex = i, reason = "nativeAnchorApproximation" })
		end
	end
	report.method = "Exact planar decomposition with compact convex ruling fibers"
	report.representation =
		"Root-ordinal planar base cells with guarded Cramer vertices and their convex hull in affine ruling coordinates; positive fractional-linear maps recover original parameters"
	report.boundaryOwnership =
		"Closed original profile-knot tiles have explicit exact boundary identifications"
	report.componentSpace = "Closed four-dimensional parameter domain with shared original knots identified"
	report.componentCount, report.covered, report.visited =
		#report.components, #report.cells, data.isolation.nodes
	report.coverageCertified, report.rootCoverageComplete, report.baseCellTopologyCertified, report.cellDimensionsCertified, report.parameterComponentsCertified =
		true, true, true, true, true
	report.cellTopologyCertified, report.parameterTopologyCertified, report.componentTopologyCertified =
		false, false, false
	report.complete, report.success, report.converged = allAccurate, allAccurate, allAccurate
	report.reason = allAccurate and "complete" or "approximation"
	report.quotientTopologyCertified, report.quotientComponentsCertified, report.quotientComplete =
		false, false, false
	local quotient = result.quotient
	if quotient then
		local q = {
			requested = true,
			axes = quotient.axes,
			joins = joins(quotient.joins, true),
			components = {},
			unresolved = quotient.unresolved,
			nodes = quotient.nodes,
			pairs = quotient.pairs,
			topologyCertified = false,
			contactsCertified = quotient.certified,
			componentsCertified = quotient.certified,
		}
		report.periodicQuotient = q
		q.complete = quotient.certified and allAccurate
		q.reason = quotient.certified and (allAccurate and "complete" or "approximation") or quotient.reason
		q.representation =
			"Complete convex ruling fibers identified at equal original parameters across certified periodic profile seams"
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
		report.quotientComponentsCertified, report.quotientComplete, report.quotientComponentCount =
			q.componentsCertified, q.complete, q.componentCount
	end
	ctx.check("finish")
	assert(not data.options.cancelled or not data.options.cancelled(), "Surface intersection query cancelled")
	assert(
		report.complete or not data.options.requireComplete,
		"Exact ruled pair native anchor approximation exceeds tolerance"
	)
	assert(
		not data.options.requireQuotient or report.quotientComplete,
		"Exact ruled pair periodic quotient incomplete: " .. tostring(report.periodicQuotient.reason)
	)
	return report
end
