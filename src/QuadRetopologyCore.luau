-- Detached inputs and bounded shared work for all retopology stages.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local C = require(script.Parent.Connectivity)
local Q = require(script.Parent.QuadGeometry)
local Core = {}
function Core.prepare(input, target, settings)
	assert(settings == nil or type(settings) == "table", "Quad retopology options must be a table")
	local options = U.copy(settings or {})
	local limits = {}
	for name, default in
		{
			maxVertices = 20000,
			maxFaces = 40000,
			maxCorners = 160000,
			maxTriangles = 80000,
			maxFaceVertices = 2000,
			maxWork = 50000000,
			maxAttributes = 256,
			maxDataEntries = 1000000,
		}
	do
		limits[name] = U.integer(options[name] == nil and default or options[name], 1)
	end
	local context = { options = options, limits = limits, work = 0 }
	function context.allocation(vertices, faces, corners, triangles)
		assert(
			vertices <= limits.maxVertices
				and faces <= limits.maxFaces
				and corners <= limits.maxCorners
				and triangles <= limits.maxTriangles,
			"Quad retopology allocation budget exceeded"
		)
	end
	local corners, triangles = 0, 0
	for _, face in input.faces do
		corners += #face.vertices
		triangles += #face.vertices - 2
		assert(#face.vertices <= limits.maxFaceVertices, "Quad retopology face size budget exceeded")
	end
	context.allocation(U.count(input.vertices), U.count(input.faces), corners, triangles)
	local entries = 0
	assert(
		U.count(input.attributes or {}) <= limits.maxAttributes,
		"Quad retopology attribute budget exceeded"
	)
	for _, channel in input.attributes or {} do
		entries += U.count(channel.values)
	end
	for _, group in input.groups or {} do
		entries += U.count(group)
		for id, value in group do
			assert(
				input.vertices[id] and type(value) == "number" and U.finite(value),
				"Invalid quad source group weight"
			)
		end
	end
	for id, weight in input.weights or {} do
		assert(input.vertices[id], "Quad source skin refers to a missing vertex")
		entries += U.count(weight)
		for _, value in weight do
			assert(
				type(value) == "number" and U.finite(value) and value >= 0,
				"Invalid quad source skin weight"
			)
		end
	end
	for _, face in input.faces do
		for _, corner in face.corners do
			entries += U.count(corner)
		end
	end
	assert(entries <= limits.maxDataEntries, "Quad retopology data budget exceeded")
	for _, name in { "checkIntersections", "requireComplete", "coarsen" } do
		assert(
			options[name] == nil or type(options[name]) == "boolean",
			"Quad retopology flags must be boolean"
		)
	end
	for _, name in { "cancelled", "checkpoint" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Quad retopology callbacks must be functions"
		)
	end
	assert(
		target == nil
			or type(target) == "function"
			or type(target) == "number" and U.finite(target) and target > 0,
		"Quad target length must be positive finite or a function"
	)
	for name, default in { maxDepth = 16, maxSplits = 5000, maxCoarsenIterations = 500 } do
		options[name] = U.integer(options[name] == nil and default or options[name], 0)
	end
	assert(options.maxDepth <= 24, "Quad refinement depth must not exceed 24")
	for name, default in
		{
			featureAngle = math.pi / 4,
			maxNormalAngle = math.pi / 3,
			minimumScaledJacobian = 0.1,
			maximumAspectRatio = 10,
			minimumEdgeRatio = 0,
			maximumEdgeRatio = 4 / 3,
			splitThreshold = 4 / 3,
			uvTolerance = 0,
			attributeTolerance = 0,
		}
	do
		options[name] = options[name] == nil and default or options[name]
		assert(
			type(options[name]) == "number" and U.finite(options[name]) and options[name] >= 0,
			"Invalid quad retopology numeric option"
		)
	end
	assert(
		options.featureAngle < math.pi / 2 and options.maxNormalAngle < math.pi / 2,
		"Quad feature and normal angles must be below pi/2"
	)
	assert(
		options.minimumScaledJacobian <= 1 and options.maximumAspectRatio >= 1,
		"Invalid quad shape target"
	)
	assert(
		options.maximumEdgeRatio > 0
			and options.minimumEdgeRatio <= options.maximumEdgeRatio
			and options.splitThreshold > 0,
		"Invalid quad density range"
	)
	assert(
		options.intersectionOptions == nil or type(options.intersectionOptions) == "table",
		"Quad intersection options must be a table"
	)
	if options.targetTriangles ~= nil then
		U.integer(options.targetTriangles, 0)
	end
	if options.normalAngle ~= nil then
		assert(
			type(options.normalAngle) == "number"
				and U.finite(options.normalAngle)
				and options.normalAngle >= 0
				and options.normalAngle <= math.pi,
			"Invalid quad normal angle"
		)
	end
	local source = input:clone()
	A.validate(source)
	options._featureChannels = { sharp_edge = true, uv_seam = true, subdivision_edge_sharpness = true }
	assert(
		options.seamAttributes == nil or type(options.seamAttributes) == "table",
		"Quad seam attributes must be an array"
	)
	for _, name in options.seamAttributes or {} do
		assert(type(name) == "string" and source.attributes[name], "Missing quad seam attribute")
		options._featureChannels[name] = true
	end
	for name in options._featureChannels do
		local channel = source.attributes[name]
		assert(
			not channel
				or channel.domain == "edge"
					and (channel.dataType == "number" or channel.dataType == "boolean"),
			"Quad feature channels require numeric or boolean edge data"
		)
	end
	options.normalAngle = options.normalAngle or options.featureAngle
	context.input = source
	local pins = options.pins or {}
	assert(type(pins) == "table", "Quad pins must be a vertex boolean set")
	for id, value in pins do
		assert(source.vertices[id] and type(value) == "boolean", "Invalid quad pin")
	end
	options.pins = pins
	local diagonal = 0
	if next(source.vertices) then
		local lo, hi = source:bounds()
		diagonal = Q.length(lo, hi)
	end
	options.maxDeviation = options.maxDeviation == nil and diagonal * 0.01 or options.maxDeviation
	assert(
		type(options.maxDeviation) == "number"
			and U.finite(options.maxDeviation)
			and options.maxDeviation >= 0,
		"Quad deviation must be finite and nonnegative"
	)
	context.remainingDeviation = options.maxDeviation
	function context.visit(n)
		context.work += n or 1
		assert(context.work <= limits.maxWork, "Quad retopology work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Quad retopology cancelled")
	end
	function context.checkpoint(stage, extra)
		context.visit(0)
		if options.checkpoint then
			local status = { stage = stage, work = context.work }
			for k, v in extra or {} do
				status[k] = v
			end
			options.checkpoint(status)
			context.visit(0)
		end
	end
	context.target = target
			and function(p)
				context.visit(1)
				local value = type(target) == "function" and target(p) or target
				assert(
					type(value) == "number" and U.finite(value) and value > 0,
					"Quad density field must return positive finite lengths"
				)
				context.visit(0)
				return value
			end
		or nil
	function context.transfer(from, to, maps)
		-- Charge bounded whole-domain passes for schema validation and interpolation.
		context.visit(
			(U.count(from.attributes) + 1)
				* (
					U.count(from.vertices)
					+ U.count(to.vertices)
					+ 20 * (U.count(from.faces) + U.count(to.faces))
				)
		)
		A.transfer(from, to, maps)
	end
	function context.connectivity(mesh)
		context.visit(U.count(mesh.vertices) + 20 * U.count(mesh.faces))
		return C.analyze(
			mesh,
			{ maxElements = limits.maxVertices + limits.maxFaces + 10 * limits.maxCorners }
		)
	end
	function context.signature(mesh)
		local report = context.connectivity(mesh)
		if not report.valid then
			return nil, report
		end
		local parts = {}
		for _, part in report.components do
			table.insert(parts, part.eulerCharacteristic .. ":" .. part.boundaryLoops)
		end
		table.sort(parts)
		return table.concat(parts, "/"), report
	end
	function context.audit(mesh, stage)
		local config = U.copy(options.intersectionOptions or {})
		local callback, cancelled = config.checkpoint, config.cancelled
		local used = 0
		config.maxWork = math.min(config.maxWork or limits.maxWork, limits.maxWork - context.work)
		config.maxTriangles = math.min(config.maxTriangles or limits.maxTriangles, limits.maxTriangles)
		config.requireComplete = false
		config.cancelled = function()
			return options.cancelled and options.cancelled() or cancelled and cancelled()
		end
		config.checkpoint = function(status)
			assert(not config.cancelled(), "Quad retopology intersection audit cancelled")
			context.visit(math.max(0, (status.work or 0) - used))
			used = status.work or used
			if callback then
				callback(status)
			end
			context.checkpoint(stage)
		end
		local _, report = require(script.Parent.Intersections).mesh(mesh, config)
		assert(not config.cancelled(), "Quad retopology intersection audit cancelled")
		context.visit(math.max(0, (report.work or used) - used))
		return report
	end
	function context.normals(mesh)
		local remaining = limits.maxWork - context.work
		assert(remaining >= 1, "Quad retopology work budget exceeded")
		local used = 0
		local config = {
			angle = options.normalAngle,
			minimumFaceArea = 0,
			maxWork = remaining,
			maxElements = limits.maxVertices + limits.maxFaces + 10 * limits.maxCorners,
		}
		config.checkpoint = function(fraction)
			local total = math.floor(fraction * remaining + 0.5)
			context.visit(math.max(0, total - used))
			used = total
			context.checkpoint("normals")
		end
		local out, report = require(script.Parent.Normals).recalculate(mesh, config)
		context.visit(math.max(0, report.work - used))
		return out, report
	end
	context.checkpoint("begin")
	context.visit(U.count(source.vertices) + corners + entries)
	assert(source:validate({ minimumFaceArea = 0 }).valid, "Quad retopology requires valid input")
	context.reference, context.inputTopology = context.signature(source)
	assert(context.reference, "Quad retopology requires oriented manifold input")
	return context
end
function Core.triangulate(source, context)
	local out = source:clone()
	out.faces = {}
	local maps = { face = {}, corner = {}, identity = { face = false, corner = false } }
	for _, fid in U.keys(source.faces) do
		local f = source.faces[fid]
		for _, tri in
			source:faceTriangles(fid, {
				validateSimple = true,
				maxVertices = context.limits.maxFaceVertices,
				maxWork = context.limits.maxWork,
				_visit = context.visit,
			})
		do
			context.visit(1)
			local id = out:addFace(
				{ f.vertices[tri[1]], f.vertices[tri[2]], f.vertices[tri[3]] },
				{ f.corners[tri[1]], f.corners[tri[2]], f.corners[tri[3]] },
				f.material
			)
			maps.face[id] = { { fid, 1 } }
			for i, corner in tri do
				maps.corner[id .. ":" .. i] = { { fid .. ":" .. corner, 1 } }
			end
		end
	end
	context.transfer(source, out, maps)
	return out, maps
end
function Core.quality(mesh, context)
	local result = {
		shapeMet = true,
		densityMet = true,
		minimumScaledJacobian = 1,
		maximumAspectRatio = 1,
		minimumAngle = math.pi,
		maximumAngle = 0,
		minimumEdgeRatio = math.huge,
		maximumEdgeRatio = 0,
		badFaces = 0,
		shortEdges = 0,
		longEdges = 0,
	}
	for _, fid in U.keys(mesh.faces) do
		local shape = Q.shape(mesh, mesh.faces[fid].vertices, context.visit)
		if not shape then
			return nil, "invalidQuadShape"
		end
		result.minimumScaledJacobian = math.min(result.minimumScaledJacobian, shape.minimumScaledJacobian)
		result.maximumAspectRatio = math.max(result.maximumAspectRatio, shape.aspectRatio)
		result.minimumAngle = math.min(result.minimumAngle, shape.minimumAngle)
		result.maximumAngle = math.max(result.maximumAngle, shape.maximumAngle)
		if
			shape.minimumScaledJacobian < context.options.minimumScaledJacobian
			or shape.aspectRatio > context.options.maximumAspectRatio
		then
			result.badFaces += 1
		end
	end
	if context.target then
		context.visit(U.count(mesh.vertices) + 4 * U.count(mesh.faces))
		local top = mesh:topology()
		for _, key in U.keys(top.edges) do
			local e = top.edges[key]
			local ratio = Q.length(mesh.vertices[e.a], mesh.vertices[e.b])
				/ context.target(Q.mean(mesh, { e.a, e.b }))
			result.minimumEdgeRatio = math.min(result.minimumEdgeRatio, ratio)
			result.maximumEdgeRatio = math.max(result.maximumEdgeRatio, ratio)
			if ratio < context.options.minimumEdgeRatio then
				result.shortEdges += 1
			end
			if ratio > context.options.maximumEdgeRatio then
				result.longEdges += 1
			end
		end
	end
	if result.minimumEdgeRatio == math.huge then
		result.minimumEdgeRatio = nil
	end
	result.shapeMet = result.badFaces == 0
	result.densityMet = result.shortEdges == 0 and result.longEdges == 0
	return result
end
return Core
