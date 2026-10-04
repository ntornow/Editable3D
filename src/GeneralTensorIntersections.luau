-- Bounded exact contacts between arbitrary positive tensor surfaces.
return function(surfaceA, surfaceB, settings)
	local prepared = require(script.Parent.GeneralTensorPreparation)(surfaceA, surfaceB, settings)
	local data = prepared.data
	local R, ctx, options = data.R, data.ctx, data.options
	local cad = require(script.Parent.GuardedTowerCAD)(
		prepared.polynomials,
		4,
		R,
		ctx,
		options,
		function(signs)
			return prepared.owner(signs) ~= nil
		end
	)
	local components = require(script.Parent.ClosedCADComponents)(cad, R, ctx, options)
	local vertices = {}
	for _, cell in components.cells do
		assert(#vertices < data.limits.maxVertices, "General tensor native anchor allocation budget exceeded")
		vertices[#vertices + 1] = require(script.Parent.GeneralTensorSample)(prepared, cell)
	end
	local quotient
	if options.identifyPeriodicSeams or options.requireQuotient then
		quotient = require(script.Parent.GeneralTensorPeriodicQuotient)(prepared, cad, components)
	end
	local report = require(script.Parent.FiniteCADReport)(prepared, cad, components, vertices, quotient)
	report.prototype = nil
	report.algorithm = "exactTensorPair"
	report.method = "Exact guarded cylindrical decomposition of original rational tensor contacts"
	report.representation =
		"Four-parameter algebraic cells and finite closure decisions; native vertices are bounded sample anchors"
	report.boundaryOwnership = "One global parameter owner with closed original-span guards"
	report.componentSpace = "Original closed four-dimensional parameter domain"
	report.componentCount = #report.components
	report.covered = #report.cells
	report.excluded = #cad.leaves - #report.cells
	report.cellTopologyCertified = true
	report.cellDimensionsCertified = true
	report.coverageCertified = true
	report.rootCoverageComplete = true
	report.parameterComponentsCertified = true
	report.parameterTopologyCertified = false
	report.componentTopologyCertified = false
	report.ordering = { requested = false }
	report.unresolved = {}
	report.parameterVertexClasses = {}
	report.parameterVertexMap = {}
	for i, cell in report.cells do
		cell.parameterDimension = cell.dimension
		cell.certified = true
		cell.kind = "parameterCell"
		cell.complex = 1
		cell.anchorVertex = cell.vertex
		local vertex = vertices[i]
		vertex.index = i
		vertex.cell = i
		vertex.complex = 1
		report.parameterVertexClasses[i] = { index = i, representative = i, vertexIndices = { i } }
		report.parameterVertexMap[i] = i
	end
	for _, component in report.components do
		component.cellIndices = component.cells
		component.cells = nil
		component.connectionIndices = {}
		component.connected = true
		component.certified = true
	end
	for i, connection in report.connections do
		connection.index = i
		connection.firstCell = connection.from
		connection.secondCell = connection.to
		connection.kind = "closureIncidence"
		connection.certified = true
		local component = report.cells[connection.firstCell].component
		assert(
			component == report.cells[connection.secondCell].component,
			"Contact incidence crosses parameter components"
		)
		table.insert(report.components[component].connectionIndices, i)
	end
	local accurate = true
	for i, vertex in vertices do
		accurate = accurate and vertex.accurate
		if not vertex.accurate then
			report.unresolved[#report.unresolved + 1] = { vertex = i, reason = "nativeAnchorApproximation" }
		end
	end
	report.complete = accurate
	report.success = accurate
	report.converged = accurate
	report.reason = accurate and "complete" or "approximation"
	report.quotientTopologyCertified = false
	report.quotientComponentsCertified = false
	report.quotientComplete = false
	local q = report.periodicQuotient
	if q then
		q.requested = true
		q.contactsCertified = q.certified
		q.componentsCertified = q.certified
		q.topologyCertified = q.certified and #q.axes == 0
		q.complete = q.certified and accurate
		q.componentCount = q.certified and #q.components or nil
		q.reason = not q.certified and q.reason or accurate and "complete" or "approximation"
		q.representation =
			"Exact images of connected boundary cells and complete periodic parameter components"
		for _, component in q.components do
			component.connected = true
			component.certified = true
		end
		report.quotientTopologyCertified = q.topologyCertified
		report.quotientComponentsCertified = q.componentsCertified
		report.quotientComplete = q.complete
		report.quotientComponentCount = q.componentCount
	else
		report.periodicQuotient = { requested = false, nodes = 0, pairs = 0 }
	end

	ctx.check("finish")
	assert(not options.cancelled or not options.cancelled(), "Surface intersection query cancelled")
	assert(
		accurate or not options.requireComplete,
		"Exact tensor-pair native anchor approximation exceeds tolerance"
	)
	assert(
		not options.requireQuotient or report.quotientComplete,
		"Exact tensor-pair quotient incomplete: " .. tostring(report.periodicQuotient.reason)
	)
	report.work = data.report.work
	report.coefficientsAllocated = data.report.coefficientsAllocated
	return report
end
