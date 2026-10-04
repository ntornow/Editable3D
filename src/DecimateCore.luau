-- Detached inputs, constraints, source quadrics and shared decimation budgets.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local D = require(script.Parent.DeformCore)
local C = require(script.Parent.Connectivity)
local Q = require(script.Parent.CollapseQuadric)
local G = require(script.Parent.PlanarReduceGeometry)
local Core = {}
function Core.normal(mesh, vertices)
	return G.plane(mesh, vertices, function() end)
end
function Core.prepare(input, targetFaces, settings)
	assert(settings == nil or type(settings) == "table", "Decimation options must be a table")
	local options = U.copy(settings or {})
	local limits = {}
	for name, default in
		{
			maxVertices = 20000,
			maxFaces = 40000,
			maxCorners = 200000,
			maxTriangles = 40000,
			maxFaceVertices = 2000,
			maxWork = 50000000,
		}
	do
		limits[name] = U.integer(options[name] == nil and default or options[name], 1)
	end
	assert(limits.maxFaceVertices >= 3, "Decimation face size limit must be at least three")
	assert(
		U.count(input.vertices) <= limits.maxVertices and U.count(input.faces) <= limits.maxFaces,
		"Decimation input allocation budget exceeded"
	)
	local corners, triangles = 0, 0
	for _, face in input.faces do
		corners += #face.vertices
		triangles += #face.vertices - 2
		assert(
			corners <= limits.maxCorners
				and triangles <= limits.maxTriangles
				and #face.vertices <= limits.maxFaceVertices,
			"Decimation face allocation budget exceeded"
		)
	end
	for _, name in
		{ "preserveBoundary", "preserveSeams", "checkIntersections", "recalculateNormals", "requireComplete" }
	do
		assert(options[name] == nil or type(options[name]) == "boolean", "Decimation flags must be boolean")
	end
	for _, name in { "cancelled", "checkpoint", "maskField" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Decimation callbacks must be functions"
		)
	end
	for _, name in { "maxError", "maxDeviation", "uvTolerance", "attributeTolerance", "weightFactor" } do
		if options[name] ~= nil then
			assert(D.scalar(options[name]) >= 0, "Decimation limits and weights must be nonnegative")
		end
	end
	assert(
		options.intersectionOptions == nil or type(options.intersectionOptions) == "table",
		"Decimation intersection options must be a table"
	)
	options.minimumNormalDot = D.scalar(options.minimumNormalDot == nil and 0.1 or options.minimumNormalDot)
	assert(
		options.minimumNormalDot >= -1 and options.minimumNormalDot <= 1,
		"Invalid decimation normal threshold"
	)
	options.weightFactor = options.weightFactor == nil and 1 or options.weightFactor
	options.placement = options.placement == nil and "segment" or options.placement
	assert(
		options.placement == "segment" or options.placement == "midpoint" or options.placement == "endpoints",
		"Unknown decimation placement"
	)
	if options.normalAngle ~= nil then
		assert(
			D.scalar(options.normalAngle) >= 0 and options.normalAngle <= math.pi,
			"Invalid decimation normal angle"
		)
	end
	assert(targetFaces == nil or options.ratio == nil, "Use a face target or a ratio, not both")
	if targetFaces == nil then
		assert(
			options.ratio ~= nil and D.scalar(options.ratio) >= 0 and options.ratio <= 1,
			"Decimation requires a face target or ratio in [0,1]"
		)
		targetFaces = math.floor(triangles * options.ratio)
	else
		U.integer(targetFaces, 0)
	end
	options.maxIterations = U.integer(options.maxIterations == nil and triangles or options.maxIterations, 0)
	local source = input:clone()
	A.validate(source)
	local context =
		{ input = source, options = options, limits = limits, work = 0, targetFaces = targetFaces }
	function context.visit(n)
		context.work += n or 1
		assert(context.work <= limits.maxWork, "Decimation work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Decimation cancelled")
	end
	function context.checkpoint(stage, extra)
		context.visit(0)
		if options.checkpoint then
			local status = { stage = stage, work = context.work, targetFaces = targetFaces }
			for k, v in extra or {} do
				status[k] = v
			end
			options.checkpoint(status)
		end
	end
	function context.connectivity(mesh)
		context.visit(U.count(mesh.vertices) + 10 * U.count(mesh.faces))
		return C.analyze(
			mesh,
			{ maxElements = limits.maxVertices + limits.maxFaces + 10 * limits.maxCorners }
		)
	end
	local pins, selected = options.pins == nil and {} or options.pins, options.faces
	assert(type(pins) == "table", "Decimation pins must be a vertex boolean set")
	for id, value in pins do
		assert(source.vertices[id] and type(value) == "boolean", "Invalid decimation pin")
	end
	if selected ~= nil then
		assert(type(selected) == "table", "Decimation face selection must be a boolean set")
		for id, value in selected do
			assert(source.faces[id] and type(value) == "boolean", "Invalid decimation face selection")
		end
	end
	if options.mask ~= nil then
		assert(type(options.mask) == "table", "Decimation mask must be a vertex dictionary")
		for id, value in options.mask do
			assert(source.vertices[id], "Unknown decimation mask vertex")
			D.weight(value)
		end
	end
	local group = options.group and assert(source.groups[options.group], "Missing decimation group")
	local channel = options.attribute
		and assert(source.attributes[options.attribute], "Missing decimation mask attribute")
	assert(
		not channel
			or channel.domain == "vertex"
				and (channel.dataType == "number" or channel.dataType == "boolean"),
		"Decimation mask attribute must be scalar vertex data"
	)
	context.checkpoint("begin")
	context.visit(U.count(source.vertices) + U.count(source.faces) + corners)
	assert(
		source:validate({ minimumFaceArea = 0 }).valid and context.connectivity(source).valid,
		"Decimation requires valid oriented manifold input"
	)
	local mesh = source:clone()
	mesh.faces, mesh.nextFace = {}, 1
	local maps = { face = {}, corner = {}, identity = { face = false, corner = false } }
	local faceOrigins = {}
	for _, fid in U.keys(source.faces) do
		local face = source.faces[fid]
		for _, t in
			source:faceTriangles(fid, {
				validateSimple = true,
				maxVertices = limits.maxFaceVertices,
				maxWork = limits.maxWork,
				_visit = context.visit,
			})
		do
			context.visit(1)
			local id = mesh:addFace(
				{ face.vertices[t[1]], face.vertices[t[2]], face.vertices[t[3]] },
				{ face.corners[t[1]], face.corners[t[2]], face.corners[t[3]] },
				face.material
			)
			maps.face[id], faceOrigins[id] = { { fid, 1 } }, fid
			for i, corner in t do
				maps.corner[id .. ":" .. i] = { { fid .. ":" .. corner, 1 } }
			end
		end
	end
	A.transfer(source, mesh, maps)
	context.mesh, context.faceOrigins = mesh, faceOrigins
	context.reference = context.connectivity(mesh)
	assert(
		context.reference.valid and mesh:validate({ minimumFaceArea = 0 }).valid,
		"Invalid decimation triangulation"
	)
	context.fixed, context.weights, context.quadrics, context.components = {}, {}, {}, {}
	context.representatives, context.clusters, context.normals = {}, {}, {}
	for _, id in U.keys(mesh.vertices) do
		context.visit(1)
		local weight = options.mask and D.weight(options.mask[id] == nil and 0 or options.mask[id]) or 1
		if group then
			weight *= D.weight(group[id] or 0)
		end
		if channel then
			weight *= D.weight(A.read(channel, id))
		end
		if options.maskField then
			weight *= D.weight(options.maskField(mesh.vertices[id], id))
		end
		context.weights[id], context.fixed[id] = weight, pins[id] == true or weight == 0
		context.representatives[id], context.clusters[id], context.quadrics[id] = id, { id }, Q.zero()
	end
	local vertexSharpness = mesh.attributes.subdivision_vertex_sharpness
	if vertexSharpness and options.preserveSeams ~= false then
		assert(
			vertexSharpness.domain == "vertex" and vertexSharpness.dataType == "number",
			"Decimation vertex sharpness requires numeric vertex data"
		)
		for id in mesh.vertices do
			context.visit(1)
			if A.read(vertexSharpness, id) > 0 then
				context.fixed[id] = true
			end
		end
	end
	if selected then
		for fid, face in source.faces do
			if not selected[fid] then
				for _, id in face.vertices do
					context.fixed[id] = true
				end
			end
		end
	end
	for index, component in context.reference.components do
		local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
		for id in component.vertices do
			context.visit(1)
			local p = mesh.vertices[id]
			for axis, value in { p.X, p.Y, p.Z } do
				lo[axis], hi[axis] = math.min(lo[axis], value), math.max(hi[axis], value)
			end
		end
		local span = math.max(hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3])
		assert(span > 0 and U.finite(span), "Invalid decimation component scale")
		local frame = { origin = lo, span = span, index = index }
		for id in component.vertices do
			context.components[id] = frame
		end
	end
	function context.coordinates(id, position)
		local frame = context.components[id]
		return {
			(position.X - frame.origin[1]) / frame.span,
			(position.Y - frame.origin[2]) / frame.span,
			(position.Z - frame.origin[3]) / frame.span,
		}
	end
	for fid, face in mesh.faces do
		context.visit(1)
		local normal = assert(Core.normal(mesh, face.vertices), "Degenerate decimation source triangle")
		context.normals[fid] = normal
		local a, b, c =
			context.coordinates(face.vertices[1], mesh.vertices[face.vertices[1]]),
			context.coordinates(face.vertices[2], mesh.vertices[face.vertices[2]]),
			context.coordinates(face.vertices[3], mesh.vertices[face.vertices[3]])
		local x, y, z = b[1] - a[1], b[2] - a[2], b[3] - a[3]
		local u, v, w = c[1] - a[1], c[2] - a[2], c[3] - a[3]
		local cx, cy, cz = y * w - z * v, z * u - x * w, x * v - y * u
		local largest = math.max(math.abs(cx), math.abs(cy), math.abs(cz))
		assert(largest > 0, "Decimation normalized triangle underflow")
		local length = largest * math.sqrt((cx / largest) ^ 2 + (cy / largest) ^ 2 + (cz / largest) ^ 2)
		local n = { cx / length, cy / length, cz / length }
		local q = Q.plane(n, -n[1] * a[1] - n[2] * a[2] - n[3] * a[3], length / 2)
		for _, id in face.vertices do
			context.quadrics[id] = Q.add(context.quadrics[id], q)
		end
	end
	function context.audit(object, stage)
		local config = U.copy(options.intersectionOptions or {})
		local callback, cancelled = config.checkpoint, config.cancelled
		local used = 0
		config.maxWork = math.min(config.maxWork or limits.maxWork, limits.maxWork - context.work)
		config.maxTriangles = math.min(config.maxTriangles or limits.maxTriangles, limits.maxTriangles)
		config.requireComplete = false
		config.checkpoint = function(status)
			assert(not cancelled or not cancelled(), "Decimation intersection audit cancelled")
			context.visit(math.max(0, (status.work or 0) - used))
			used = status.work or used
			if callback then
				callback(status)
			end
			context.checkpoint(stage)
		end
		local _, result = require(script.Parent.Intersections).mesh(object, config)
		assert(not cancelled or not cancelled(), "Decimation intersection audit cancelled")
		context.visit(math.max(0, (result.work or used) - used))
		return result
	end
	context.checkpoint("prepared")
	return context
end
return Core
