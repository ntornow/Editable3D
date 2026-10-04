-- Relax existing UV nodes with fixed samples, monotone native steps, and global audits.
local U = require(script.Parent.Util)
local Core = require(script.Parent.UVIslandCore)
local Analysis = require(script.Parent.UVAnalysis)
local Chart = require(script.Parent.UVRelaxChart)
local Energy = require(script.Parent.UVRelaxEnergy)
local Optimizer = require(script.Parent.UVRelaxOptimizer)
local P = require(script.Parent.Predicates)
local R = {}
function R.run(source, settings)
	local config = U.copy(settings or {})
	for key, value in { maxVertices = 20000, maxFaces = 40000, maxCorners = 200000, maxWork = 50000000 } do
		if config[key] == nil then
			config[key] = value
		end
	end
	local maxTriangles = U.integer(config.maxTriangles or 40000, 1)
	local triangleCount = 0
	for _, face in source.faces do
		triangleCount += #face.vertices - 2
		assert(triangleCount <= maxTriangles, "UV relaxation triangle budget exceeded")
	end
	local method = config.method or "angle"
	assert(method == "angle" or method == "symmetricDirichlet", "Unknown UV relaxation method")
	local function positive(value, default)
		if value == nil then
			value = default
		end
		assert(
			type(value) == "number" and U.finite(value) and value > 0,
			"Positive finite UV relaxation value required"
		)
		return value
	end
	local solverOptions = {
		iterations = U.integer(config.iterations or 100, 0),
		lineSearchSteps = U.integer(config.lineSearchSteps or 40, 1),
		historySize = U.integer(config.historySize or 8, 1),
		gradientTolerance = positive(config.gradientTolerance, 1e-6),
	}
	assert(
		solverOptions.iterations <= 1000
			and solverOptions.lineSearchSteps <= 64
			and solverOptions.historySize <= 32,
		"UV relaxation iteration or history limit exceeded"
	)
	assert(
		config.pinBoundary == nil or type(config.pinBoundary) == "boolean",
		"UV relaxation pinBoundary must be boolean"
	)
	if config.density ~= nil then
		positive(config.density)
	end
	local context = Core.prepare(source, config)
	local options, mesh, visit = context.options, context.mesh, context.visit
	local pins, selection = options.pins or {}, options.corners
	for _, set in { pins, selection or {} } do
		assert(type(set) == "table", "UV relaxation corner masks must be boolean sets")
		local valid = {}
		for fid, face in mesh.faces do
			for i in face.corners do
				visit(1)
				valid[fid .. ":" .. i] = true
			end
		end
		for key, value in set do
			assert(valid[key] and type(value) == "boolean", "Invalid UV relaxation corner mask")
		end
	end
	local report = {
		complete = false,
		applied = false,
		method = method,
		islands = {},
		changedCorners = 0,
		overlapChecked = options.checkOverlaps ~= false,
	}
	local function finish(out, reason)
		report.work = context.work
		if out == mesh and report.changedCorners > 0 then
			report.candidateChangedCorners, report.changedCorners = report.changedCorners, 0
		end
		if not report.complete then
			report.reason = reason
		end
		assert(
			not options.requireComplete or report.complete,
			"UV relaxation incomplete: " .. tostring(reason)
		)
		return out, report
	end
	for _, island in context.islands do
		if #island.missing > 0 then
			return finish(mesh, "missingUV")
		end
		if island.degenerateTriangles > 0 or island.mixedOrientation then
			return finish(mesh, "inputOrientation")
		end
	end
	if report.overlapChecked then
		local input = Analysis.scan(context)
		report.inputOverlapCount = input.overlapCount
		if input.overlapCount > 0 then
			return finish(mesh, "inputOverlap")
		end
	end
	local topology = mesh:topology()
	local out = mesh:clone()
	local converged = true
	for _, island in context.islands do
		if island.selected then
			local chart = Chart.prepare(context, island, topology, pins, selection)
			local function evaluate(coordinates)
				return Energy.evaluate(coordinates, chart.triangles, method, visit)
			end
			local function native(coordinates)
				local actual, values = table.clone(coordinates), {}
				for id, node in chart.nodes do
					visit(1)
					local value = node.uv
					if not node.pinned then
						value = Vector2.new(
							chart.origin[1] + coordinates[2 * id - 1] * chart.span / context.size.X,
							chart.origin[2] + coordinates[2 * id] * chart.span / context.size.Y
						)
					end
					if not Core.vector(value) then
						return nil
					end
					values[id] = value
					actual[2 * id - 1] = (value.X - chart.origin[1]) * context.size.X / chart.span
					actual[2 * id] = (value.Y - chart.origin[2]) * context.size.Y / chart.span
				end
				for _, triangle in chart.triangles do
					visit(1)
					local ids = triangle.nodes
					if P.orient2D(values[ids[1]], values[ids[2]], values[ids[3]]) ~= triangle.orientation then
						return nil
					end
				end
				return actual, values
			end
			context.checkpoint("relaxPrepared")
			local _, result, values = Optimizer.solve(
				chart.coordinates,
				chart.movable,
				evaluate,
				native,
				solverOptions,
				visit,
				context.checkpoint
			)
			result.id, result.nodes, result.movableNodes, result.pinnedNodes, result.density =
				island.id, #chart.nodes, #chart.movable, #chart.pinned, chart.density
			result.automaticPins = {}
			for _, id in chart.automaticPins do
				table.insert(result.automaticPins, U.copy(chart.nodes[id].references))
			end
			table.insert(report.islands, result)
			converged = converged and result.converged
			if result.reason == "nonfiniteEnergy" then
				return finish(mesh, "nonfiniteEnergy")
			end
			if values then
				for id, node in chart.nodes do
					for _, ref in node.references do
						visit(1)
						local corner = out.faces[ref.face].corners[ref.corner]
						if corner.uv ~= values[id] then
							corner.uv, corner.tangent, corner.tangentSign = values[id], nil, nil
							report.changedCorners += 1
						end
					end
				end
			end
		end
	end
	local audit = { options = options, visit = visit, triangles = {} }
	report.nativeOrientation = true
	for _, original in context.triangles do
		visit(1)
		local measured = Core.measure(out, {
			original.vertices[1],
			original.vertices[2],
			original.vertices[3],
			face = original.face,
			corners = original.corners,
		}, context.size)
		measured.index, measured.island = original.index, original.island
		table.insert(audit.triangles, measured)
		report.nativeOrientation = report.nativeOrientation and measured.orientation == original.orientation
	end
	if not report.nativeOrientation then
		return finish(mesh, "nativeOrientation")
	end
	if report.overlapChecked then
		local scan = Analysis.scan(audit)
		report.overlapCount, report.overlaps, report.overlapsTruncated =
			scan.overlapCount, scan.overlaps, scan.overlapsTruncated
		report.overlapFree = scan.overlapCount == 0
		if not report.overlapFree then
			return finish(mesh, "outputOverlap")
		end
	end
	report.converged, report.complete, report.applied = converged, converged, report.changedCorners > 0
	context.checkpoint("relaxVerified")
	return finish(out, "optimization")
end
return R
