-- Feature-preserving density adaptation followed by certified all-quad patches.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
local Core = require(script.Parent.QuadRetopologyCore)
local Pair = require(script.Parent.QuadPair)
local Q = require(script.Parent.QuadGeometry)
local G = require(script.Parent.PlanarReduceGeometry)
return function(input, targetLength, settings)
	local context = Core.prepare(input, targetLength, settings)
	local options = context.options
	local report = {
		complete = false,
		applied = false,
		allQuads = false,
		errorBound = 0,
		maximumNormalAngle = 0,
		initialFaces = U.count(context.input.faces),
		intersectionChecked = options.checkIntersections ~= false,
		boundKind = "composedSurjectivePatchCorrespondence",
		stages = {},
	}
	local mesh = context.input:clone()
	local function finish(rollback, reason)
		report.reason = reason
		if rollback then
			report.candidateErrorBound, report.candidateNormalAngle =
				report.errorBound, report.maximumNormalAngle
			report.errorBound, report.maximumNormalAngle = 0, 0
			mesh = context.input:clone()
			report.complete, report.applied = false, false
		end
		report.allQuads = true
		for _, f in mesh.faces do
			if #f.vertices ~= 4 then
				report.allQuads = false
			end
		end
		report.finalFaces = U.count(mesh.faces)
		report.finalVertices = U.count(mesh.vertices)
		report.success = report.complete
		report.validation = mesh:validate({ minimumFaceArea = 0 })
		context.checkpoint(
			"complete",
			{ complete = report.complete, applied = report.applied, reason = reason }
		)
		report.work = context.work
		assert(not options.requireComplete or report.complete, "Quad retopology incomplete: " .. reason)
		return mesh, report
	end
	local function accumulate(stage)
		if stage.errorBound > 0 then
			report.errorBound =
				I.add({ report.errorBound, report.errorBound }, { stage.errorBound, stage.errorBound })[2]
		end
		report.maximumNormalAngle += stage.maximumNormalAngle or 0
		context.remainingDeviation = math.max(0, options.maxDeviation - report.errorBound)
		return report.errorBound <= options.maxDeviation
			and report.maximumNormalAngle <= options.maxNormalAngle + 2 ^ -42
	end
	if report.intersectionChecked then
		report.inputIntersections = context.audit(mesh, "inputIntersections")
		if not report.inputIntersections.complete or not report.inputIntersections.intersectionFree then
			return finish(true, "inputIntersections")
		end
	end
	mesh, report.stages.triangulation = Core.triangulate(mesh, context)
	local signature = context.signature(mesh)
	if signature ~= context.reference or not mesh:validate({ minimumFaceArea = 0 }).valid then
		return finish(true, "triangulationTopology")
	end
	local pins = table.clone(options.pins)
	context.visit(U.count(mesh.vertices) + 3 * U.count(mesh.faces))
	for _, edge in mesh:topology().edges do
		if Pair.protected(mesh, edge, options, context.visit) then
			pins[edge.a], pins[edge.b] = true, true
		end
	end
	local target = options.targetTriangles
	if target == nil and context.target and options.coarsen ~= false then
		local estimate = 0
		for _, fid in U.keys(mesh.faces) do
			local face = mesh.faces[fid]
			local plane =
				assert(G.plane(mesh, face.vertices, context.visit), "Degenerate retopology source triangle")
			local length = context.target(Q.mean(mesh, face.vertices))
			estimate += plane.area / (2 * length ^ 2)
		end
		target = math.max(1, math.floor(math.min(estimate, U.count(mesh.faces))))
	end
	report.coarseningTarget = target
	if target and target < U.count(mesh.faces) and options.coarsen ~= false then
		local remaining = context.limits.maxWork - context.work
		local config = {
			pins = pins,
			preserveBoundary = true,
			preserveSeams = true,
			checkIntersections = false,
			recalculateNormals = false,
			maxIterations = options.maxCoarsenIterations,
			maxDeviation = context.remainingDeviation,
			minimumNormalDot = math.cos(options.maxNormalAngle),
			maxWork = remaining,
			uvTolerance = options.uvTolerance,
			attributeTolerance = options.attributeTolerance,
			cancelled = options.cancelled,
		}
		for _, name in { "maxVertices", "maxFaces", "maxCorners", "maxTriangles", "maxFaceVertices" } do
			config[name] = context.limits[name]
		end
		local used = 0
		config.checkpoint = function(status)
			context.visit(math.max(0, (status.work or 0) - used))
			used = status.work or used
			context.checkpoint("coarsening", { faces = status.faces, collapses = status.collapses })
		end
		mesh, report.stages.coarsening = require(script.Parent.MeshDecimate)(mesh, target, config)
		context.visit(math.max(0, report.stages.coarsening.work - used))
		if not accumulate(report.stages.coarsening) then
			return finish(true, "coarseningBounds")
		end
	end
	report.coarseningMet = options.targetTriangles == nil or U.count(mesh.faces) <= options.targetTriangles
	context.checkpoint("refine")
	local densityTarget = context.target and function(p)
		return 2 * context.target(p)
	end or nil
	mesh, report.stages.density = require(script.Parent.QuadDensity).refine(mesh, densityTarget, context)
	if not mesh then
		return finish(true, report.stages.density.reason)
	end
	if not accumulate(report.stages.density) then
		return finish(true, "densityBounds")
	end
	context.checkpoint("pair")
	mesh, report.stages.pairing = Pair.pair(mesh, context)
	if not accumulate(report.stages.pairing) then
		return finish(true, "pairingBounds")
	end
	context.checkpoint("quadrangulate")
	mesh, report.stages.quadrangulation = require(script.Parent.QuadSplit)(mesh, context)
	if not mesh then
		return finish(true, report.stages.quadrangulation.reason)
	end
	if not accumulate(report.stages.quadrangulation) then
		return finish(true, "quadrangulationBounds")
	end
	local finalSignature, topology = context.signature(mesh)
	report.outputTopology = topology
	if finalSignature ~= context.reference or not mesh:validate({ minimumFaceArea = 0 }).valid then
		return finish(true, "outputTopology")
	end
	for id in pins do
		if pins[id] and mesh.vertices[id] ~= context.input.vertices[id] then
			return finish(true, "protectedVertex")
		end
	end
	report.quality = Core.quality(mesh, context)
	if not report.quality then
		return finish(true, "outputShape")
	end
	if report.intersectionChecked then
		report.outputIntersections = context.audit(mesh, "outputIntersections")
		if not report.outputIntersections.complete or not report.outputIntersections.intersectionFree then
			return finish(true, "outputIntersections")
		end
	end
	mesh, report.normals = context.normals(mesh)
	report.complete = report.quality.shapeMet and report.quality.densityMet and report.coarseningMet
	report.applied = true
	return finish(
		false,
		report.complete and "target"
			or not report.quality.shapeMet and "shapeTarget"
			or not report.quality.densityMet and "densityTarget"
			or "coarseningTarget"
	)
end
