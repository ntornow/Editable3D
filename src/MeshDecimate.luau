-- Bounded fixed-reference edge collapse with transactional endpoint audits.
local U = require(script.Parent.Util)
local Core = require(script.Parent.DecimateCore)
local K = require(script.Parent.CollapseCandidate)
local S = require(script.Parent.CollapseSymmetry)
local Seams = require(script.Parent.AttributeSeams)
local B = require(script.Parent.CollapseBound)
return function(input, targetFaces, options)
	local context = Core.prepare(input, targetFaces, options)
	options = context.options
	local mesh = context.mesh:clone()
	local symmetry, reason = S.build(mesh, options.symmetry, context.visit)
	assert(
		options.symmetry == nil or symmetry,
		"Decimation symmetry requires an exact reflected triangulation: " .. tostring(reason)
	)
	local report = {
		initialFaces = U.count(mesh.faces),
		originalFaces = U.count(context.input.faces),
		targetFaces = context.targetFaces,
		collapses = 0,
		iterations = 0,
		collapseLog = {},
		rejections = {},
		errorBound = 0,
		maximumNormalAngle = 0,
		intersectionChecked = options.checkIntersections ~= false,
		complete = false,
		applied = false,
		boundKind = "surjectiveVertexCorrespondence",
		placement = options.placement,
		reason = "iterations",
	}
	local function reject(why)
		report.rejections[why] = (report.rejections[why] or 0) + 1
	end
	local function finish(rollback)
		if rollback then
			report.candidateCollapses, report.candidateErrorBound = report.collapses, report.errorBound
			report.collapses, report.errorBound, report.maximumNormalAngle = 0, 0, 0
			mesh = context.input:clone()
			report.sourceVertexToOutput = {}
			for id in mesh.vertices do
				report.sourceVertexToOutput[id] = id
			end
			report.outputFaceToSource = {}
			for fid in mesh.faces do
				report.outputFaceToSource[fid] = fid
			end
		else
			report.sourceVertexToOutput = table.clone(context.representatives)
			report.outputFaceToSource = {}
			for fid in mesh.faces do
				report.outputFaceToSource[fid] = context.faceOrigins[fid]
			end
		end
		report.finalFaces = U.count(mesh.faces)
		report.targetReached = not rollback and report.finalFaces <= context.targetFaces
		report.complete = report.targetReached and not rollback
		report.applied = not rollback
			and (report.collapses > 0 or report.originalFaces ~= report.initialFaces)
		report.success = report.complete
		report.work = context.work
		report.validation = mesh:validate({ minimumFaceArea = 0 })
		context.checkpoint(
			"complete",
			{ collapses = report.collapses, faces = report.finalFaces, complete = report.complete }
		)
		assert(not options.requireComplete or report.complete, "Decimation incomplete: " .. report.reason)
		return mesh, report
	end
	if report.intersectionChecked then
		report.inputIntersections = context.audit(mesh, "inputIntersections")
		if not report.inputIntersections.complete or not report.inputIntersections.intersectionFree then
			report.reason = "inputIntersections"
			return finish(true)
		end
	end
	for _ = 1, options.maxIterations do
		if U.count(mesh.faces) <= context.targetFaces then
			break
		end
		context.visit(U.count(mesh.vertices) + 4 * U.count(mesh.faces))
		local top = mesh:topology()
		local boundary, protected = K.boundary(top), Seams.locked(mesh, top, options)
		local candidates, seen = {}, {}
		for _, key in U.keys(top.edges) do
			context.visit(1)
			if seen[key] then
				continue
			end
			seen[key] = true
			local edge = top.edges[key]
			if symmetry then
				seen[U.edge(symmetry[edge.a], symmetry[edge.b])] = true
			end
			local plan, rejection = K.plan(context, mesh, top, boundary, protected, symmetry, edge.a, edge.b)
			if plan then
				table.insert(candidates, plan)
			else
				reject(rejection)
			end
		end
		table.sort(candidates, function(a, b)
			return a.priority == b.priority and a.key < b.key or a.priority < b.priority
		end)
		local accepted = false
		for _, plan in candidates do
			local result, rejection = K.apply(context, mesh, plan)
			if result then
				K.commit(context, plan, result)
				mesh, symmetry = result.mesh, result.symmetry
				report.collapses += #plan.operations
				report.iterations += 1
				report.errorBound, report.maximumNormalAngle = result.errorBound, result.maximumNormalAngle
				table.insert(report.collapseLog, {
					operations = U.copy(plan.operations),
					quadricError = plan.cost,
					priority = plan.priority,
					kind = plan.kind,
					errorBound = result.errorBound,
					faces = U.count(mesh.faces),
				})
				accepted = true
				break
			else
				reject(rejection)
			end
		end
		context.checkpoint("iteration", { collapses = report.collapses, faces = U.count(mesh.faces) })
		if not accepted then
			report.reason = "constraints"
			break
		end
	end
	-- Recheck the final stored coordinates and map independently of candidate scoring.
	local bound, boundReason = B.check(context.mesh, mesh, context.representatives, context.visit)
	if not bound then
		report.reason = boundReason
		return finish(true)
	end
	assert(
		not options.maxDeviation or bound <= options.maxDeviation,
		"Decimation final deviation budget violated"
	)
	report.errorBound = bound
	if report.intersectionChecked then
		report.outputIntersections = report.collapses == 0 and report.inputIntersections
			or context.audit(mesh, "outputIntersections")
		if not report.outputIntersections.complete or not report.outputIntersections.intersectionFree then
			report.reason = "outputIntersections"
			return finish(true)
		end
	end
	if report.collapses > 0 then
		for _, face in mesh.faces do
			for _, corner in face.corners do
				corner.tangent, corner.tangentSign = nil, nil
			end
		end
	end
	if options.recalculateNormals ~= false then
		local remaining = context.limits.maxWork - context.work
		assert(remaining >= 1, "Decimation work budget exceeded")
		local used = 0
		local config = {
			angle = options.normalAngle,
			minimumFaceArea = 0,
			maxWork = remaining,
			maxElements = context.limits.maxVertices
				+ context.limits.maxFaces
				+ 10 * context.limits.maxCorners,
		}
		config.checkpoint = function(fraction)
			local total = math.floor(fraction * remaining + 0.5)
			context.visit(math.max(0, total - used))
			used = total
			context.checkpoint("normals")
		end
		mesh, report.normals = require(script.Parent.Normals).recalculate(mesh, config)
		context.visit(math.max(0, report.normals.work - used))
	end
	report.reason = U.count(mesh.faces) <= context.targetFaces and "target" or report.reason or "iterations"
	return finish(false)
end
