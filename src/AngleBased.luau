-- Bounded angle-space flattening, independent reconstruction, and native UV audits.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Connectivity = require(script.Parent.Connectivity)
local Optimizer = require(script.Parent.AngleOptimizer)
local Reconstruction = require(script.Parent.AngleReconstruction)
local NativeAudit = require(script.Parent.AngleNativeAudit)
local function vector(value)
	return typeof(value) == "Vector2" and U.finite(value.X) and U.finite(value.Y)
end
local function angle3(a, b, c)
	local x, y, z = b.X - a.X, b.Y - a.Y, b.Z - a.Z
	local u, v, w = c.X - a.X, c.Y - a.Y, c.Z - a.Z
	local cx, cy, cz = y * w - z * v, z * u - x * w, x * v - y * u
	return math.atan2(math.sqrt(cx * cx + cy * cy + cz * cz), x * u + y * v + z * w)
end
return function(source, settings)
	local options = U.copy(settings or {})
	local maxVertices = U.integer(options.maxVertices or 20000, 1)
	local maxFaces = U.integer(options.maxFaces or 40000, 1)
	local maxCorners = U.integer(options.maxCorners or 200000, 1)
	local maxTriangles = U.integer(options.maxTriangles or 40000, 1)
	local maxFaceVertices = U.integer(options.maxFaceVertices or 2000, 3)
	local maxWork = U.integer(options.maxWork or 50000000, 1)
	assert(
		U.count(source.vertices) <= maxVertices and U.count(source.faces) <= maxFaces,
		"Angle unwrap input allocation budget exceeded"
	)
	local corners = 0
	for _, face in source.faces do
		corners += #face.vertices
		assert(
			corners <= maxCorners and #face.vertices <= maxFaceVertices,
			"Angle unwrap corner budget exceeded"
		)
	end
	for _, name in { "cancelled", "checkpoint" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Angle unwrap callback must be a function"
		)
	end
	for _, name in { "requireComplete", "checkOverlaps" } do
		assert(options[name] == nil or type(options[name]) == "boolean", "Angle unwrap flags must be boolean")
	end
	local function positive(name, default)
		local value = options[name]
		if value == nil then
			value = default
		end
		assert(
			type(value) == "number" and U.finite(value) and value > 0,
			"Angle unwrap tolerances must be finite and positive"
		)
		return value
	end
	local minimum = positive("minimumAngle", 1e-8)
	assert(minimum < math.pi / 3, "Angle unwrap minimum angle must be below pi/3")
	local optimizerOptions = {
		minimumAngle = minimum,
		iterations = U.integer(options.iterations or 50, 0),
		constraintTolerance = positive("constraintTolerance", 1e-8),
		stationarityTolerance = positive("stationarityTolerance", 1e-8),
		lineSearchSteps = U.integer(options.lineSearchSteps or 32, 1),
		linear = {
			tolerance = positive("linearTolerance", 1e-10),
			absoluteTolerance = positive("linearAbsoluteTolerance", 1e-12),
			iterations = U.integer(options.linearIterations or 4000, 0),
		},
	}
	assert(
		optimizerOptions.iterations <= 500 and optimizerOptions.lineSearchSteps <= 64,
		"Angle unwrap iteration limit exceeded"
	)
	local reconstructionOptions = {
		tolerance = positive("reconstructionTolerance", 1e-10),
		absoluteTolerance = positive("reconstructionAbsoluteTolerance", 1e-12),
		iterations = U.integer(options.reconstructionIterations or 4000, 0),
	}
	local angleTolerance = positive("reconstructionAngleTolerance", 1e-5)
	local size = options.textureSize or Vector2.one
	assert(vector(size), "Finite angle unwrap texture size required")
	for _, value in { size.X, size.Y } do
		assert(
			value % 1 == 0 and value >= 1 and value <= 65536,
			"Angle unwrap texture dimensions must be integers in [1,65536]"
		)
	end
	local mesh = source:clone()
	A.validate(mesh)
	local work = 0
	local function visit(n)
		work += n or 1
		assert(work <= maxWork, "Angle unwrap work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Angle unwrap cancelled")
	end
	local function checkpoint(stage)
		visit(0)
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = work })
		end
	end
	checkpoint("begin")
	visit(U.count(mesh.vertices) + U.count(mesh.faces) + corners)
	local validation = Connectivity.analyze(mesh, { maxElements = maxVertices + maxFaces + maxCorners })
	assert(validation.valid, "Angle unwrap requires oriented manifold geometry")
	local report = {
		complete = false,
		overlapChecked = options.checkOverlaps ~= false,
		textureSize = size,
		triangles = {},
		pins = {},
	}
	local function finish(out, reason)
		report.work = work
		if not report.complete then
			report.reason = reason
		end
		assert(
			not options.requireComplete or report.complete,
			"Angle unwrap incomplete: " .. tostring(reason)
		)
		return out, report
	end
	if not next(mesh.faces) then
		assert(options.pins == nil or next(options.pins) == nil, "Empty angle unwrap cannot have pins")
		report.complete, report.angleConverged, report.reconstructionConverged, report.nativeOrientation =
			true, true, true, true
		if report.overlapChecked then
			report.overlapFree = true
		end
		return finish(mesh)
	end
	assert(
		#validation.components == 1
			and validation.components[1].eulerCharacteristic == 1
			and #validation.boundaryLoops == 1,
		"Angle unwrap requires one disk chart; cut seams first"
	)
	local boundary = {}
	for _, vertex in validation.boundaryLoops[1].vertices do
		boundary[vertex] = true
	end
	local used, incident, triangles, target = {}, {}, {}, {}
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		for _, indices in
			mesh:faceTriangles(
				fid,
				{ validateSimple = true, maxVertices = maxFaceVertices, maxWork = maxWork, _visit = visit }
			)
		do
			visit(1)
			assert(#triangles < maxTriangles, "Angle unwrap triangle allocation budget exceeded")
			local tri = { face.vertices[indices[1]], face.vertices[indices[2]], face.vertices[indices[3]] }
			table.insert(triangles, tri)
			table.insert(
				report.triangles,
				{ face = fid, corners = table.clone(indices), vertices = table.clone(tri) }
			)
			for i, id in tri do
				visit(1)
				used[id] = true
				incident[id] = incident[id] or {}
				local beta = angle3(
					mesh.vertices[id],
					mesh.vertices[tri[i % 3 + 1]],
					mesh.vertices[tri[(i + 1) % 3 + 1]]
				)
				assert(U.finite(beta) and beta > 0 and beta < math.pi, "Degenerate angle unwrap triangle")
				table.insert(target, beta)
				table.insert(incident[id], #target)
			end
		end
	end
	local fans = {}
	for _, id in U.keys(used) do
		if not boundary[id] then
			table.insert(fans, incident[id])
		end
	end
	local pins = options.pins
	if pins ~= nil then
		assert(
			type(pins) == "table" and U.count(pins) == 2,
			"Angle unwrap requires exactly two boundary pins"
		)
		for id, value in pins do
			assert(
				boundary[id] and vector(value),
				"Angle unwrap pins must be finite UVs on boundary vertices"
			)
		end
	else
		local ids = U.keys(boundary)
		local function farthest(id)
			local best, distance = id, -1
			local p = mesh.vertices[id]
			for _, other in ids do
				visit(1)
				local q = mesh.vertices[other]
				local d = (p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 + (p.Z - q.Z) ^ 2
				if d > distance then
					best, distance = other, d
				end
			end
			return best
		end
		local a = farthest(ids[1])
		local b = farthest(a)
		pins = { [a] = Vector2.zero, [b] = Vector2.new(1 / size.X, 0) }
	end
	local pinIds = U.keys(pins)
	local p0, p1 = pins[pinIds[1]], pins[pinIds[2]]
	assert(p0 ~= p1, "Angle unwrap pins must be distinct UV coordinates")
	report.pins = U.copy(pins)
	report.targetAngles = table.clone(target)
	checkpoint("anglePrepared")
	local optimized, optimization = Optimizer.solve(target, fans, optimizerOptions, visit, checkpoint)
	report.optimizedAngles, report.angleOptimization, report.angleConverged =
		optimized, optimization, optimization.converged
	local uv, reconstruction =
		Reconstruction.solve(U.keys(used), triangles, optimized, pinIds, reconstructionOptions, visit)
	report.reconstruction, report.reconstructionConverged = reconstruction, reconstruction.converged
	checkpoint("reconstructed")
	if not reconstruction.finite then
		return finish(mesh, "reconstructionNonfinite")
	end
	local dx, dy = (p1.X - p0.X) * size.X, (p1.Y - p0.Y) * size.Y
	local native = {}
	report.maximumNativeError = 0
	for _, id in U.keys(used) do
		visit(1)
		local x, y = uv[id][1], uv[id][2]
		local u, v = p0.X + (dx * x - dy * y) / size.X, p0.Y + (dy * x + dx * y) / size.Y
		local value = pins[id] or Vector2.new(u, v)
		if not vector(value) then
			return finish(mesh, "nativeOverflow")
		end
		native[id] = value
		local ex, ey = (value.X - u) * size.X, (value.Y - v) * size.Y
		report.maximumNativeError = math.max(report.maximumNativeError, math.sqrt(ex * ex + ey * ey))
	end
	local out = mesh:clone()
	for _, face in out.faces do
		for i, id in face.vertices do
			visit(1)
			if face.corners[i].uv ~= native[id] then
				face.corners[i].uv, face.corners[i].tangent, face.corners[i].tangentSign =
					native[id], nil, nil
			end
		end
	end
	local audit = NativeAudit.run(out, report.triangles, optimized, size, options, visit)
	for key, value in audit do
		report[key] = value
	end
	report.complete = report.angleConverged
		and report.reconstructionConverged
		and report.nativeOrientation
		and report.maximumAngleResidual <= angleTolerance
		and (not report.overlapChecked or report.overlapFree)
	checkpoint("nativeVerified")
	local reason = not report.angleConverged and "angleOptimization"
		or not report.reconstructionConverged and "reconstructionSolve"
		or not report.nativeOrientation and "nativeOrientation"
		or report.maximumAngleResidual > angleTolerance and "nativeAngleResidual"
		or not report.overlapFree and report.overlapChecked and "uvOverlap"
		or nil
	return finish(out, reason)
end
