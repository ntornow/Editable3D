-- Immutable stroke inputs, constraints and bounded shared geometry context.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local D = require(script.Parent.DeformCore)
local C = require(script.Parent.Connectivity)
local B = {}
function B.prepare(source, input, settings)
	if settings == nil then
		settings = {}
	end
	assert(type(settings) == "table", "Stroke options must be a table")
	local detailBase = settings.detailBase
	assert(detailBase == nil or type(detailBase) == "table", "Stroke detail base must be a mesh")
	local options = table.clone(settings)
	options.detailBase = nil
	options = U.copy(options)
	local limits = {
		maxVertices = U.integer(options.maxVertices == nil and 20000 or options.maxVertices, 1),
		maxFaces = U.integer(options.maxFaces == nil and 40000 or options.maxFaces, 1),
		maxCorners = U.integer(options.maxCorners == nil and 200000 or options.maxCorners, 1),
		maxTriangles = U.integer(options.maxTriangles == nil and 40000 or options.maxTriangles, 1),
		maxWork = U.integer(options.maxWork == nil and 50000000 or options.maxWork, 1),
	}
	local maxFaceVertices = U.integer(options.maxFaceVertices == nil and 2000 or options.maxFaceVertices, 3)
	assert(
		U.count(source.vertices) <= limits.maxVertices and U.count(source.faces) <= limits.maxFaces,
		"Stroke allocation budget exceeded"
	)
	local corners, triangleCount = 0, 0
	for _, face in source.faces do
		corners += #face.vertices
		triangleCount += #face.vertices - 2
		assert(
			corners <= limits.maxCorners
				and triangleCount <= limits.maxTriangles
				and #face.vertices <= maxFaceVertices,
			"Stroke face allocation budget exceeded"
		)
	end
	assert(
		type(input) == "table"
			and #input <= U.integer(options.maxSamples == nil and 10000 or options.maxSamples, 1),
		"Stroke sample budget exceeded"
	)
	input = U.copy(input)
	local mesh = source:clone()
	local working = mesh:clone()
	if detailBase then
		assert(
			U.count(detailBase.vertices) == U.count(mesh.vertices)
				and U.count(detailBase.faces) == U.count(mesh.faces),
			"Stroke detail base must preserve topology"
		)
		for fid, face in mesh.faces do
			local other = detailBase.faces[fid]
			assert(other and #other.vertices == #face.vertices, "Stroke detail base face mismatch")
			for i, id in face.vertices do
				assert(other.vertices[i] == id, "Stroke detail base connectivity mismatch")
			end
		end
		for id in mesh.vertices do
			assert(U.vector(detailBase.vertices[id]), "Invalid stroke detail base position")
			working.vertices[id] = detailBase.vertices[id]
		end
	end
	A.validate(mesh)
	local context = {
		mesh = mesh,
		working = working,
		base = table.clone(working.vertices),
		options = options,
		work = 0,
		detailPreserved = detailBase ~= nil,
	}
	function context.visit(n)
		context.work += n or 1
		assert(context.work <= limits.maxWork, "Stroke work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Stroke cancelled")
	end
	function context.checkpoint(stage)
		context.visit(0)
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = context.work })
		end
	end
	for _, name in { "cancelled", "checkpoint", "maskField" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Stroke callbacks must be functions"
		)
	end
	for _, name in
		{
			"pinBoundary",
			"preserveSeams",
			"pressureSize",
			"pressureStrength",
			"includeEnd",
			"feather",
			"frontFace",
			"checkIntersections",
			"recalculateNormals",
			"requireComplete",
		}
	do
		assert(options[name] == nil or type(options[name]) == "boolean", "Stroke flags must be boolean")
	end
	assert(
		options.intersectionOptions == nil or type(options.intersectionOptions) == "table",
		"Stroke intersection options must be a table"
	)
	local locks = options.lockAxes
	if locks == nil then
		locks = {}
	end
	assert(type(locks) == "table", "Stroke locks must be an axis boolean set")
	for name, value in locks do
		assert(
			(name == "X" or name == "Y" or name == "Z") and type(value) == "boolean",
			"Invalid stroke lock axis"
		)
	end
	context.locks = locks
	context.normalLimit = D.scalar(options.normalLimit == nil and math.pi / 2 or options.normalLimit)
	assert(context.normalLimit >= 0 and context.normalLimit <= math.pi, "Invalid stroke normal limit")
	if options.normalAngle ~= nil then
		assert(
			D.scalar(options.normalAngle) >= 0 and options.normalAngle <= math.pi,
			"Invalid stroke normal angle"
		)
	end
	D.validateFalloff(options.falloff)
	context.mode = options.brush == nil and "draw" or options.brush
	assert(
		context.mode == "draw"
			or context.mode == "inflate"
			or context.mode == "move"
			or context.mode == "flatten"
			or context.mode == "pinch"
			or context.mode == "smooth"
			or context.mode == "crease",
		"Unknown sculpt brush"
	)
	context.shape = options.shape == nil and "sphere" or options.shape
	assert(context.shape == "sphere" or context.shape == "projected", "Unknown stroke influence shape")
	context.strength = D.scalar(options.strength == nil and 0.1 or options.strength)
	if context.mode == "flatten" or context.mode == "smooth" then
		assert(
			context.strength >= 0 and context.strength <= 1,
			"Flatten and smooth strength must be in [0,1]"
		)
	end
	context.pinch = D.scalar(options.pinch == nil and 0.5 or options.pinch)
	context.checkpoint("begin")
	context.visit(U.count(mesh.vertices) + U.count(mesh.faces) + corners)
	assert(
		C.analyze(mesh, { maxElements = limits.maxVertices + limits.maxFaces + 3 * limits.maxCorners }).valid,
		"Stroke requires oriented manifold geometry"
	)
	assert(
		mesh:validate({ minimumFaceArea = 0 }).valid and working:validate({ minimumFaceArea = 0 }).valid,
		"Stroke requires valid positive-area source and detail base"
	)
	local top = mesh:topology()
	context.topology, context.ids = top, U.keys(mesh.vertices)
	local pins = options.pins
	if pins == nil then
		pins = {}
	end
	assert(type(pins) == "table", "Stroke pins must be a vertex boolean set")
	for id, value in pins do
		assert(mesh.vertices[id] and type(value) == "boolean", "Invalid stroke pin")
	end
	local protected = {}
	if options.preserveSeams then
		protected = require(script.Parent.AttributeSeams).locked(mesh, top, options)
	end
	if options.pinBoundary then
		for _, edge in top.edges do
			context.visit(1)
			if #edge.faces == 1 then
				protected[edge.a], protected[edge.b] = true, true
			end
		end
	end
	local group = options.group and assert(mesh.groups[options.group], "Missing stroke group")
	local channel = options.attribute
		and assert(mesh.attributes[options.attribute], "Missing stroke mask attribute")
	if channel then
		assert(
			channel.domain == "vertex" and (channel.dataType == "number" or channel.dataType == "boolean"),
			"Stroke mask attribute must be scalar vertex data"
		)
	end
	if options.mask ~= nil then
		assert(type(options.mask) == "table", "Stroke mask must be a vertex dictionary")
		for id, value in options.mask do
			assert(mesh.vertices[id], "Unknown stroke mask vertex")
			D.weight(value)
		end
	end
	context.weights = {}
	for _, id in context.ids do
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
		context.weights[id] = (pins[id] or protected[id]) and 0 or weight
	end
	local triangles = {}
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		if detailBase then
			working:faceTriangles(fid, {
				validateSimple = true,
				maxVertices = maxFaceVertices,
				maxWork = limits.maxWork,
				_visit = context.visit,
			})
		end
		for _, t in
			mesh:faceTriangles(fid, {
				validateSimple = true,
				maxVertices = maxFaceVertices,
				maxWork = limits.maxWork,
				_visit = context.visit,
			})
		do
			context.visit(1)
			table.insert(triangles, { face.vertices[t[1]], face.vertices[t[2]], face.vertices[t[3]] })
		end
	end
	context.triangles = triangles
	require(script.Parent.SculptAudit).attach(context, limits)
	context.dabs, context.sampling =
		require(script.Parent.BrushSamples).prepare(input, options, context.visit)
	context.copies, context.copyCount = require(script.Parent.BrushSymmetry).build(options, context.visit)
	context.radius = options.radius or 1
	assert(
		options.adjustStrengthForSpacing == nil or type(options.adjustStrengthForSpacing) == "boolean",
		"Stroke spacing strength flag must be boolean"
	)
	assert(
		not options.adjustStrengthForSpacing or context.sampling.sampling == "spaced",
		"Spacing strength requires spaced sampling"
	)
	for i, dab in context.dabs do
		dab.exposure = 1
		if options.adjustStrengthForSpacing and context.sampling.length > 0 then
			local left = i == 1 and 0 or 0.5 * (context.dabs[i - 1].arc + dab.arc)
			local right = i == #context.dabs and context.sampling.length
				or 0.5 * (dab.arc + context.dabs[i + 1].arc)
			dab.exposure = (right - left) / context.radius
			assert(U.finite(dab.exposure), "Stroke exposure overflow")
		end
	end
	if
		context.mode == "draw"
		or context.mode == "flatten"
		or context.mode == "pinch"
		or context.mode == "crease"
		or context.shape == "projected"
		or options.frontFace
	then
		for _, dab in context.dabs do
			assert(dab.normal, "This stroke requires an explicit sample or option normal")
		end
	end
	context.checkpoint("prepared")
	return context
end
return B
