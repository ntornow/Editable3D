-- Constrained positional fairing with independent solve, native and geometry reports.
local U = require(script.Parent.Util)
local Core = require(script.Parent.FairingCore)
local Operator = require(script.Parent.FairingOperator)
local Solve = require(script.Parent.FairingSolve)
return function(source, selection, settings)
	local context = Core.prepare(source, selection, settings)
	local mesh, options, visit = context.mesh, context.options, context.visit
	local report = {
		complete = false,
		applied = false,
		components = {},
		order = context.order,
		weights = context.weights,
		modifiedVertices = 0,
		maximumDisplacement = 0,
		maximumNativeError = 0,
		linearConverged = true,
		nativeConverged = true,
		intersectionChecked = options.checkIntersections ~= false,
	}
	local function finish(out, reason)
		report.work = context.work
		if out == mesh and report.modifiedVertices > 0 then
			report.candidateModifiedVertices, report.modifiedVertices = report.modifiedVertices, 0
			report.candidateMaximumDisplacement, report.maximumDisplacement = report.maximumDisplacement, 0
		end
		if reason == "nonfiniteSolve" then
			report.linearConverged = false
		end
		if
			reason == "nonfiniteSolve"
			or reason == "nativeOverflow"
			or reason == "nonfiniteResidual"
			or reason == "nonfiniteEnergy"
		then
			report.nativeConverged = false
		end
		if not report.complete then
			report.reason = reason
		end
		assert(not options.requireComplete or report.complete, "Fairing incomplete: " .. tostring(reason))
		return out, report
	end
	if report.intersectionChecked then
		report.inputIntersections = context.audit(mesh, "inputIntersections")
		if not report.inputIntersections.complete or not report.inputIntersections.intersectionFree then
			return finish(mesh, "inputIntersections")
		end
	end
	local allLocked = context.solver.lockAxes.X and context.solver.lockAxes.Y and context.solver.lockAxes.Z
	for _, component in context.components do
		if #component.free == #component.ids and not allLocked then
			report.unanchoredComponent = component.id
			return finish(mesh, "unanchoredSelection")
		end
	end
	local out = mesh:clone()
	for _, component in context.components do
		local record = {
			id = component.id,
			vertices = #component.ids,
			freeVertices = #component.free,
			pinnedVertices = #component.ids - #component.free,
			axes = {},
			linearConverged = true,
			nativeConverged = true,
			energyBefore = 0,
			energyAfter = 0,
			negativeWeights = 0,
		}
		table.insert(report.components, record)
		if #component.free == 0 or allLocked then
			record.constrainedIdentity = true
			continue
		end
		local model = Operator.build(component.points, component.triangles, context.weights, visit)
		record.negativeWeights = model.negativeWeights
		local _, axes, delta =
			Solve.solve(model, component.points, component.free, context.order, context.solver, visit)
		record.axes = axes
		context.checkpoint("solved")
		for _, i in component.free do
			visit(1)
			local id = component.ids[i]
			local original = mesh.vertices[id]
			local dx, dy, dz =
				delta[i][1] * component.span, delta[i][2] * component.span, delta[i][3] * component.span
			if not (U.finite(dx) and U.finite(dy) and U.finite(dz)) then
				return finish(mesh, "nonfiniteSolve")
			end
			local x, y, z = original.X + dx, original.Y + dy, original.Z + dz
			local value = Vector3.new(x, y, z)
			if not U.vector(value) then
				return finish(mesh, "nativeOverflow")
			end
			out.vertices[id] = value
			local ex, ey, ez = value.X - x, value.Y - y, value.Z - z
			report.maximumNativeError =
				math.max(report.maximumNativeError, math.sqrt(ex * ex + ey * ey + ez * ez))
			if value ~= original then
				report.modifiedVertices += 1
				local a, b, c = value.X - original.X, value.Y - original.Y, value.Z - original.Z
				report.maximumDisplacement =
					math.max(report.maximumDisplacement, math.sqrt(a * a + b * b + c * c))
			end
		end
		local rowBounds = model.rowBounds(context.order)
		for axis, name in { "X", "Y", "Z" } do
			local actual, initial = {}, {}
			local coordinateScale = 0
			for i, id in component.ids do
				visit(1)
				actual[i] = (out.vertices[id][name] - component.origin[axis]) / component.span
				initial[i] = component.points[i][axis]
				-- Reference coordinates set the scale even when a solved axis becomes zero.
				coordinateScale = math.max(coordinateScale, math.abs(actual[i]), math.abs(initial[i]))
			end
			record.energyBefore += model.energy(initial, context.order)
			record.energyAfter += model.energy(actual, context.order)
			local axisReport = axes[axis]
			axisReport.axis = name
			axisReport.coordinateScale = coordinateScale
			axisReport.nativeConverged = true
			if not axisReport.locked then
				local residual = model.apply(actual, context.order)
				local maximum, backward, square = 0, 0, 0
				for _, i in component.free do
					visit(1)
					local value = math.abs(residual[i])
					local scale = rowBounds[i] * coordinateScale
					if not (U.finite(value) and U.finite(scale)) then
						return finish(mesh, "nonfiniteResidual")
					end
					maximum = math.max(maximum, value)
					square += value * value
					backward = math.max(backward, value / math.max(scale, 1e-300))
					axisReport.nativeConverged = axisReport.nativeConverged
						and value <= context.nativeAbsoluteTolerance + context.nativeTolerance * scale
				end
				axisReport.nativeResidual = math.sqrt(square)
				axisReport.maximumNativeResidual = maximum
				axisReport.maximumNativeBackwardError = backward
			end
			record.linearConverged = record.linearConverged and axisReport.converged
			record.nativeConverged = record.nativeConverged and axisReport.nativeConverged
		end
		if not (U.finite(record.energyBefore) and U.finite(record.energyAfter)) then
			return finish(mesh, "nonfiniteEnergy")
		end
		if
			record.energyAfter
			> record.energyBefore + context.energyTolerance * math.max(1, math.abs(record.energyBefore))
		then
			return finish(mesh, "energyIncrease")
		end
		report.linearConverged = report.linearConverged and record.linearConverged
		report.nativeConverged = report.nativeConverged and record.nativeConverged
		context.checkpoint("nativeVerified")
	end
	report.geometry = context.geometry(out)
	if not report.geometry.valid then
		return finish(mesh, "geometry")
	end
	if report.intersectionChecked then
		report.outputIntersections = context.audit(out, "outputIntersections")
		if not report.outputIntersections.complete or not report.outputIntersections.intersectionFree then
			return finish(mesh, "outputIntersections")
		end
	end
	if report.modifiedVertices > 0 then
		for _, face in out.faces do
			for _, corner in face.corners do
				visit(1)
				corner.tangent, corner.tangentSign = nil, nil
			end
		end
		if options.recalculateNormals ~= false then
			out, report.normals = context.normals(out)
		else
			out.revision += 1
		end
	end
	report.complete = report.linearConverged and report.nativeConverged
	report.applied = report.modifiedVertices > 0
	context.checkpoint("fairVerified")
	return finish(out, not report.linearConverged and "linearSolve" or "nativeResidual")
end
