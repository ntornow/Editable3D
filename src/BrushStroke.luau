-- Ordered sculpt dabs with simultaneous symmetry images and final geometry gates.
local U = require(script.Parent.Util)
local D = require(script.Parent.DeformCore)
local Samples = require(script.Parent.BrushSamples)
local Core = require(script.Parent.BrushCore)
local names = { "X", "Y", "Z" }
local function vertexNormals(mesh, context)
	local sums = {}
	for _, fid in U.keys(mesh.faces) do
		context.visit(1)
		local normal, area = mesh:faceNormal(fid)
		for _, id in mesh.faces[fid].vertices do
			context.visit(1)
			local sum = sums[id] or { 0, 0, 0 }
			for axis, name in names do
				sum[axis] += normal[name] * area
			end
			sums[id] = sum
		end
	end
	for id, sum in sums do
		context.visit(1)
		local size = Samples.length(sum[1], sum[2], sum[3])
		if size > 0 then
			for axis = 1, 3 do
				sum[axis] /= size
			end
		else
			sums[id] = nil
		end
	end
	return sums
end
local function smoothing(mesh, context, id)
	local p, result, count = mesh.vertices[id], { 0, 0, 0 }, 0
	for _, neighbor in U.keys(context.topology.neighbors[id]) do
		context.visit(1)
		count += 1
		local q = mesh.vertices[neighbor]
		for axis, name in names do
			result[axis] += q[name] - p[name]
		end
	end
	if count > 0 then
		for axis = 1, 3 do
			result[axis] /= count
		end
	end
	return result
end
return function(source, input, settings)
	local context = Core.prepare(source, input, settings)
	local mesh, working, options = context.mesh, context.working, context.options
	local report = {
		complete = false,
		applied = false,
		brush = context.mode,
		shape = context.shape,
		sampling = context.sampling,
		symmetryCopies = context.copyCount,
		dabsApplied = 0,
		vertexWrites = 0,
		modifiedVertices = 0,
		maximumDisplacement = 0,
		maximumNativeError = 0,
		intersectionChecked = options.checkIntersections ~= false,
		detailPreserved = context.detailPreserved,
	}
	local function finish(out, reason)
		report.work = context.work
		if reason then
			report.reason = reason
			report.candidateModifiedVertices = report.modifiedVertices
			report.candidateMaximumDisplacement = report.maximumDisplacement
			report.modifiedVertices, report.maximumDisplacement = 0, 0
		else
			report.complete = true
			report.applied = report.modifiedVertices > 0
		end
		assert(not options.requireComplete or report.complete, "Stroke incomplete: " .. tostring(reason))
		return out, report
	end
	if report.intersectionChecked then
		report.inputIntersections = context.audit(mesh, "inputIntersections")
		if not report.inputIntersections.complete or not report.inputIntersections.intersectionFree then
			return finish(mesh, "inputIntersections")
		end
	end
	local function store(values)
		for i = 1, 3 do
			if not U.finite(values[i]) then
				return nil
			end
		end
		local value = Vector3.new(values[1], values[2], values[3])
		if not U.vector(value) then
			return nil
		end
		report.maximumNativeError = math.max(
			report.maximumNativeError,
			Samples.length(value.X - values[1], value.Y - values[2], value.Z - values[3])
		)
		return value
	end
	for _, dab in context.dabs do
		context.checkpoint("dab")
		local images = context.copies(dab)
		local radius = context.radius * (options.pressureSize and dab.pressure or 1)
		local pressure = options.pressureStrength ~= false and dab.pressure or 1
		local amplitude = context.strength * pressure
		if context.mode == "smooth" or context.mode == "flatten" then
			amplitude = amplitude == 1 and (dab.exposure > 0 and 1 or 0)
				or 1 - math.exp(dab.exposure * math.log(1 - amplitude))
		else
			amplitude *= dab.exposure
		end
		if radius == 0 or amplitude == 0 then
			continue
		end
		local normals = (context.mode == "inflate" or options.frontFace) and vertexNormals(working, context)
			or nil
		local nextPositions = {}
		for _, id in context.ids do
			context.visit(1)
			local mask = context.weights[id]
			if mask == 0 then
				continue
			end
			local p = working.vertices[id]
			local sum, total, largest = { 0, 0, 0 }, 0, 0
			local smooth
			for _, image in images do
				context.visit(1)
				local offset = { p.X - image.position[1], p.Y - image.position[2], p.Z - image.position[3] }
				local normal = image.normal
				local height = normal
						and (offset[1] * normal[1] + offset[2] * normal[2] + offset[3] * normal[3])
					or 0
				local radial = table.clone(offset)
				if context.shape == "projected" then
					for axis = 1, 3 do
						radial[axis] -= normal[axis] * height
					end
				end
				local distance = Samples.length(radial[1], radial[2], radial[3])
				if distance >= radius then
					continue
				end
				if options.frontFace then
					local n = normals[id]
					if not n or n[1] * normal[1] + n[2] * normal[2] + n[3] * normal[3] <= 0 then
						continue
					end
				end
				local weight = D.falloff(options.falloff, distance / radius)
				if weight == 0 then
					continue
				end
				local delta = {}
				if context.mode == "draw" or context.mode == "inflate" then
					local n = context.mode == "inflate"
							and assert(normals[id], "Stroke vertex normal is missing or cancels")
						or normal
					for axis = 1, 3 do
						delta[axis] = n[axis] * radius * amplitude
					end
				elseif context.mode == "move" then
					for axis = 1, 3 do
						delta[axis] = image.delta[axis] * amplitude
					end
				elseif context.mode == "flatten" then
					for axis = 1, 3 do
						delta[axis] = -normal[axis] * height * amplitude
					end
				elseif context.mode == "smooth" then
					smooth = smooth or smoothing(working, context, id)
					for axis = 1, 3 do
						delta[axis] = smooth[axis] * amplitude
					end
				else
					for axis = 1, 3 do
						local lateral = offset[axis] - normal[axis] * height
						delta[axis] = context.mode == "pinch" and -lateral * amplitude
							or (-normal[axis] * radius - lateral * context.pinch) * amplitude
					end
				end
				for axis = 1, 3 do
					sum[axis] += delta[axis] * weight
				end
				total += weight
				largest = math.max(largest, weight)
			end
			if total > 0 then
				local factor = mask * (options.feather ~= false and largest / total or 1)
				local values = {}
				for axis, name in names do
					values[axis] = p[name] + (context.locks[name] and 0 or sum[axis] * factor)
				end
				local value = store(values)
				if not value then
					return finish(mesh, "nativeOverflow")
				end
				nextPositions[id] = value
				if value ~= p then
					report.vertexWrites += 1
				end
			end
		end
		for id, value in nextPositions do
			working.vertices[id] = value
		end
		report.dabsApplied += 1
	end
	local out = mesh:clone()
	for _, id in context.ids do
		context.visit(1)
		local original, base, actual = mesh.vertices[id], context.base[id], working.vertices[id]
		local values = {}
		for axis, name in names do
			values[axis] = original[name] == base[name] and actual[name]
				or original[name] + (actual[name] - base[name])
		end
		local value = store(values)
		if not value then
			return finish(mesh, "nativeOverflow")
		end
		out.vertices[id] = value
		if value ~= original then
			report.modifiedVertices += 1
			report.maximumDisplacement = math.max(
				report.maximumDisplacement,
				Samples.length(value.X - original.X, value.Y - original.Y, value.Z - original.Z)
			)
		end
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
				context.visit(1)
				corner.tangent, corner.tangentSign = nil, nil
			end
		end
		if options.recalculateNormals ~= false then
			out, report.normals = context.normals(out)
		else
			out.revision += 1
		end
	end
	context.checkpoint("strokeVerified")
	return finish(out)
end
