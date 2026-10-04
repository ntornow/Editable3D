-- Bounded whole-component quadrilateral grid coarsening.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local I = require(script.Parent.DirectedInterval)
local G = require(script.Parent.PlanarReduceGeometry)
local Roles = require(script.Parent.UnsubdivideTopology)
local Phase = require(script.Parent.UnsubdividePhase)
local function numericOrder(a, b)
	for i = 1, math.min(#a, #b) do
		if a[i] ~= b[i] then
			return a[i] < b[i]
		end
	end
	return #a < #b
end
return function(input, iterations, settings)
	U.integer(iterations, 0)
	assert(iterations <= 16, "Un-subdivision iterations must not exceed sixteen")
	local options = U.copy(settings or {})
	local maxVertices = U.integer(options.maxVertices or 250000, 1)
	local maxFaces = U.integer(options.maxFaces or 250000, 1)
	local maxCorners = U.integer(options.maxCorners or 1000000, 1)
	local maxWork = U.integer(options.maxWork or 20000000, 1)
	assert(
		U.count(input.vertices) <= maxVertices and U.count(input.faces) <= maxFaces,
		"Un-subdivision input allocation budget exceeded"
	)
	local corners = 0
	for _, face in input.faces do
		corners += #face.vertices
		assert(corners <= maxCorners, "Un-subdivision input corner budget exceeded")
	end
	for _, name in { "preserveSeams", "checkIntersections", "requireComplete", "transitions" } do
		assert(
			options[name] == nil or type(options[name]) == "boolean",
			"Un-subdivision flags must be boolean"
		)
	end
	for _, name in { "uvTolerance", "attributeTolerance" } do
		assert(
			options[name] == nil
				or type(options[name]) == "number" and U.finite(options[name]) and options[name] >= 0,
			"Invalid un-subdivision data tolerance"
		)
	end
	options.minimumNormalDot = options.minimumNormalDot or 0.1
	assert(
		type(options.minimumNormalDot) == "number"
			and U.finite(options.minimumNormalDot)
			and options.minimumNormalDot >= 0
			and options.minimumNormalDot <= 1,
		"Minimum normal dot must lie in [0,1]"
	)
	local mesh = input:clone()
	local original = mesh:clone()
	A.validate(mesh)
	local faces, keep = {}, {}
	for _, entry in { { "faces", mesh.faces, faces }, { "keepVertices", mesh.vertices, keep } } do
		local selection = options[entry[1]]
		if selection ~= nil then
			assert(type(selection) == "table", "Un-subdivision selection must be a boolean set")
			for id, value in selection do
				assert(entry[2][id] and type(value) == "boolean", "Invalid un-subdivision selection")
				entry[3][id] = value
			end
		elseif entry[1] == "faces" then
			for id in mesh.faces do
				faces[id] = true
			end
		end
	end
	options.keepVertices = keep
	local vertexSharpness = mesh.attributes.subdivision_vertex_sharpness
	assert(
		not vertexSharpness or vertexSharpness.domain == "vertex" and vertexSharpness.dataType == "number",
		"Vertex sharpness requires a numeric vertex field"
	)
	local names = { sharp_edge = true, uv_seam = true, subdivision_edge_sharpness = true }
	for _, name in options.seamAttributes or {} do
		assert(mesh.attributes[name], "Missing un-subdivision seam attribute")
		names[name] = true
	end
	for name in names do
		local channel = mesh.attributes[name]
		assert(
			not channel
				or channel.domain == "edge"
					and (channel.dataType == "number" or channel.dataType == "boolean"),
			"Un-subdivision feature fields require numeric or boolean edges"
		)
	end
	local diagonal = 0
	if next(mesh.vertices) then
		local lo, hi = mesh:bounds()
		diagonal = math.sqrt((hi.X - lo.X) ^ 2 + (hi.Y - lo.Y) ^ 2 + (hi.Z - lo.Z) ^ 2)
	end
	options.maxDeviation = options.maxDeviation or diagonal * 0.01
	assert(
		type(options.maxDeviation) == "number"
			and U.finite(options.maxDeviation)
			and options.maxDeviation >= 0,
		"Un-subdivision deviation must be finite and nonnegative"
	)
	local report = {
		requestedIterations = iterations,
		iterationsCompleted = 0,
		appliedLevels = 0,
		initialFaces = U.count(mesh.faces),
		steps = {},
		errorBound = 0,
		complete = true,
		intersectionChecked = options.checkIntersections ~= false,
	}
	local work = 0
	local function visit(n)
		work += n or 1
		assert(work <= maxWork, "Un-subdivision work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Un-subdivision cancelled")
	end
	local function checkpoint(stage)
		visit(0)
		if options.checkpoint then
			options.checkpoint({
				stage = stage,
				work = work,
				iteration = report.appliedLevels,
				faces = U.count(mesh.faces),
				errorBound = report.errorBound,
			})
		end
	end
	checkpoint("begin")
	visit(U.count(mesh.vertices) + U.count(mesh.faces) + corners)
	assert(mesh:validate().valid, "Un-subdivision requires a valid oriented source mesh")
	local function audit(object, stage)
		local config = U.copy(options.intersectionOptions or {})
		local callback, additionalCancel = config.checkpoint, config.cancelled
		local previous = 0
		config.maxWork = math.min(config.maxWork or maxWork, maxWork - work)
		config.checkpoint = function(status)
			assert(
				not additionalCancel or not additionalCancel(),
				"Un-subdivision intersection audit cancelled"
			)
			local used = status.work or 0
			visit(math.max(0, used - previous))
			previous = used
			if callback then
				callback(status)
			end
			checkpoint(stage)
		end
		local _, result = require(script.Parent.Intersections).mesh(object, config)
		assert(not additionalCancel or not additionalCancel(), "Un-subdivision intersection audit cancelled")
		visit(math.max(0, (result.work or previous) - previous))
		return result
	end
	if report.intersectionChecked then
		report.inputIntersections = audit(mesh, "inputIntersections")
		assert(
			report.inputIntersections.complete and report.inputIntersections.intersectionFree,
			"Un-subdivision source intersection audit failed or incomplete"
		)
	end
	for level = 1, iterations do
		local top = mesh:topology()
		local components, seen = {}, {}
		for _, seed in U.keys(mesh.vertices) do
			if seen[seed] then
				continue
			end
			local vertices, faceSet, cursor = { seed }, {}, 1
			seen[seed] = true
			while cursor <= #vertices do
				local v = vertices[cursor]
				cursor += 1
				for _, fid in top.vertexFaces[v] do
					faceSet[fid] = true
					visit(1)
				end
				for other in top.neighbors[v] do
					visit(1)
					if not seen[other] then
						seen[other] = true
						table.insert(vertices, other)
					end
				end
			end
			table.sort(vertices)
			if next(faceSet) then
				table.insert(components, { vertices = vertices, faces = U.keys(faceSet) })
			end
		end
		local step = {
			iteration = level,
			components = {},
			errorBound = 0,
			acceptedComponents = 0,
			rejectedComponents = 0,
			transitionPolygons = 0,
			patches = {},
		}
		local triangles = {}
		local accepted = {}
		for _, component in components do
			local selected = 0
			for _, fid in component.faces do
				if faces[fid] then
					selected += 1
				end
			end
			if selected == 0 then
				continue
			end
			local status =
				{ seed = component.vertices[1], faces = #component.faces, accepted = false, rejections = {} }
			table.insert(step.components, status)
			if selected ~= #component.faces and not options.transitions then
				status.reason = "partialComponent"
				step.rejectedComponents += 1
				continue
			end
			local phases, reason = Roles.component(mesh, top, component.vertices, component.faces, visit)
			status.recognizedPhases = #phases
			if #phases == 0 then
				status.reason = reason
				step.rejectedComponents += 1
				continue
			end
			for _, fid in component.faces do
				triangles[fid] = mesh:faceTriangles(
					fid,
					{ validateSimple = true, maxVertices = 4, maxWork = maxWork, _visit = visit }
				)
			end
			local best
			for _, phase in phases do
				local candidate, rejection
				if options.transitions then
					local localOptions = table.clone(options)
					localOptions.maxDeviation = math.max(
						0,
						I.sub(
							{ options.maxDeviation, options.maxDeviation },
							{ report.errorBound, report.errorBound }
						)[1]
					)
					candidate = require(script.Parent.LocalGridPhase).accept(
						mesh,
						top,
						phase,
						triangles,
						localOptions,
						faces,
						visit
					)
				else
					candidate, rejection = Phase.accept(mesh, top, phase, triangles, options, visit)
				end
				if
					candidate
					and I.add(
							{ report.errorBound, report.errorBound },
							{ candidate.errorBound, candidate.errorBound }
						)[2]
						> options.maxDeviation
				then
					candidate = nil
					rejection = "errorBudget"
				end
				if candidate then
					local score, bestScore = #candidate.groups, best and #best.groups or -1
					if
						not best
						or score > bestScore
						or score == bestScore
							and (candidate.errorBound < best.errorBound or candidate.errorBound == best.errorBound and numericOrder(
								candidate.phase.old,
								best.phase.old
							))
					then
						best = candidate
					end
				else
					status.rejections[rejection] = (status.rejections[rejection] or 0) + 1
				end
			end
			if best then
				if #best.groups > 0 then
					table.insert(accepted, best)
					step.acceptedComponents += 1
					step.errorBound = math.max(step.errorBound, best.errorBound)
					status.accepted, status.retainedVertices, status.errorBound =
						true, table.clone(best.phase.old), best.errorBound
				end
				if options.transitions then
					status.selectedFaces, status.coveredSelectedFaces = selected, best.coveredSelectedFaces
					status.patches, status.rejections, status.frontierRounds =
						best.patches, best.rejections, best.frontierRounds
					status.transitionPolygons = best.transitionPolygons
					step.transitionPolygons += best.transitionPolygons
					if best.coveredSelectedFaces < selected then
						status.reason = "patches"
						step.rejectedComponents += 1
					end
				end
			else
				status.reason = "constraints"
				step.rejectedComponents += 1
			end
			checkpoint("component")
		end
		if #step.components == 0 then
			report.reason = "emptySelection"
			break
		end
		local out = mesh:clone()
		local maps = { face = {}, corner = {}, edge = {} }
		for _, candidate in accepted do
			for _, record in candidate.groups do
				local group = record.group
				local fid = group.faces[1]
				local refs, maximumArea = {}, 0
				for _, old in group.faces do
					local plane = assert(G.plane(mesh, mesh.faces[old].vertices, visit))
					maximumArea = math.max(maximumArea, plane.area)
					table.insert(refs, { old, plane.area })
					out.faces[old] = nil
				end
				for _, ref in refs do
					ref[2] /= maximumArea
				end
				local face =
					{ vertices = table.clone(group.loop), corners = {}, material = mesh.faces[fid].material }
				for i, v in group.loop do
					local ref = group.cornerRefs[v]
					face.corners[i] = U.copy(mesh.faces[ref[1]].corners[ref[2]])
					face.corners[i].normal = Vector3.new(record.plane.x, record.plane.y, record.plane.z)
					face.corners[i].tangent = nil
					face.corners[i].tangentSign = nil
					maps.corner[fid .. ":" .. i] = { { ref[1] .. ":" .. ref[2], 1 } }
				end
				out.faces[fid] = face
				maps.face[fid] = refs
				step.patches[fid] = { sourceFaces = table.clone(group.faces), errorBound = record.errorBound }
			end
			for e, ends in candidate.phase.edgeEnds do
				local a, b, p = mesh.vertices[ends[1]], mesh.vertices[ends[2]], mesh.vertices[e]
				local la = math.sqrt((p.X - a.X) ^ 2 + (p.Y - a.Y) ^ 2 + (p.Z - a.Z) ^ 2)
				local lb = math.sqrt((p.X - b.X) ^ 2 + (p.Y - b.Y) ^ 2 + (p.Z - b.Z) ^ 2)
				maps.edge[U.edge(ends[1], ends[2])] =
					{ { U.edge(ends[1], e), la / (la + lb) }, { U.edge(e, ends[2]), lb / (la + lb) } }
			end
		end
		if #accepted > 0 then
			if options.transitions then
				local used = {}
				for _, face in out.faces do
					for _, id in face.vertices do
						used[id] = true
					end
				end
				for id in out.vertices do
					visit(1)
					if not used[id] and #top.vertexFaces[id] > 0 then
						out.vertices[id], out.weights[id] = nil, nil
						for _, group in out.groups do
							group[id] = nil
						end
					end
				end
				if
					not require(script.Parent.LocalGridPhase).topology(
						mesh,
						out,
						visit,
						maxVertices + maxFaces + 10 * maxCorners
					)
				then
					report.complete, report.reason = false, "transitionTopology"
					step.validationFailed = true
					table.insert(report.steps, step)
					break
				end
				A.transfer(mesh, out, maps)
			else
				A.transfer(mesh, out, maps)
				out:removeUnused()
			end
			A.validate(out)
			mesh = out
			report.appliedLevels += 1
			report.errorBound =
				I.add({ report.errorBound, report.errorBound }, { step.errorBound, step.errorBound })[2]
		end
		step.maps = maps
		table.insert(report.steps, step)
		if step.rejectedComponents > 0 then
			report.complete = false
			report.reason = "components"
			break
		end
		report.iterationsCompleted = level
		checkpoint("level")
	end
	report.validation = mesh:validate()
	if report.intersectionChecked then
		report.outputIntersections = audit(mesh, "outputIntersections")
	end
	report.complete = report.complete
		and report.validation.valid
		and (
			not report.intersectionChecked
			or report.outputIntersections.complete and report.outputIntersections.intersectionFree
		)
	report.reason = not report.validation.valid and "invalidOutput"
		or report.intersectionChecked and not report.outputIntersections.intersectionFree and "outputIntersections"
		or report.reason
		or "iterations"
	if
		options.transitions
		and (
			not report.validation.valid
			or report.intersectionChecked
				and (not report.outputIntersections.complete or not report.outputIntersections.intersectionFree)
		)
	then
		report.candidateAppliedLevels, report.candidateErrorBound = report.appliedLevels, report.errorBound
		mesh = original:clone()
		report.appliedLevels, report.iterationsCompleted, report.errorBound = 0, 0, 0
		report.validation = mesh:validate()
		report.complete = false
		report.reason = "outputAudit"
	end
	report.transitions = options.transitions == true
	report.finalFaces, report.maxDeviation, report.work, report.success =
		U.count(mesh.faces), options.maxDeviation, work, report.complete
	checkpoint("complete")
	assert(not options.requireComplete or report.complete, "Un-subdivision incomplete: " .. report.reason)
	return mesh, report
end
