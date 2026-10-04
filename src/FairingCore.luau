-- Private immutable fairing inputs, constraints, allocation and shared audit budget.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Connectivity = require(script.Parent.Connectivity)
local Seams = require(script.Parent.AttributeSeams)
local F = {}
function F.prepare(source, selection, settings)
	local options = U.copy(settings or {})
	selection = selection ~= nil and U.copy(selection) or nil
	local maxVertices = U.integer(options.maxVertices or 20000, 1)
	local maxFaces = U.integer(options.maxFaces or 40000, 1)
	local maxCorners = U.integer(options.maxCorners or 200000, 1)
	local maxTriangles = U.integer(options.maxTriangles or 40000, 1)
	local maxFaceVertices = U.integer(options.maxFaceVertices or 2000, 3)
	local maxWork = U.integer(options.maxWork or 50000000, 1)
	assert(
		U.count(source.vertices) <= maxVertices and U.count(source.faces) <= maxFaces,
		"Fairing allocation budget exceeded"
	)
	local cornerCount, triangleCount = 0, 0
	for _, face in source.faces do
		cornerCount += #face.vertices
		triangleCount += #face.vertices - 2
		assert(
			cornerCount <= maxCorners and #face.vertices <= maxFaceVertices and triangleCount <= maxTriangles,
			"Fairing corner or triangle budget exceeded"
		)
	end
	local function positive(value, default, zero)
		if value == nil then
			value = default
		end
		assert(
			type(value) == "number" and U.finite(value) and (zero and value >= 0 or value > 0),
			"Invalid fairing numerical tolerance"
		)
		return value
	end
	local order = options.order or 2
	assert(order == 1 or order == 2, "Fairing order must be 1 or 2")
	local weights = options.weights or "cotangent"
	assert(weights == "cotangent" or weights == "uniform", "Unknown fairing weights")
	for _, name in
		{ "pinBoundary", "preserveSeams", "checkIntersections", "requireComplete", "recalculateNormals" }
	do
		assert(options[name] == nil or type(options[name]) == "boolean", "Fairing flags must be boolean")
	end
	for _, name in { "cancelled", "checkpoint" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Fairing callbacks must be functions"
		)
	end
	assert(
		options.intersectionOptions == nil or type(options.intersectionOptions) == "table",
		"Fairing intersection options must be a table"
	)
	local locks = options.lockAxes
	if locks == nil then
		locks = {}
	end
	assert(type(locks) == "table", "Fairing axis locks must be a boolean set")
	for name, value in locks do
		assert(
			(name == "X" or name == "Y" or name == "Z") and type(value) == "boolean",
			"Invalid fairing axis lock"
		)
	end
	local normalLimit = positive(options.normalLimit, math.pi / 2, true)
	assert(normalLimit <= math.pi, "Fairing normal limit must not exceed pi")
	if options.normalAngle ~= nil then
		assert(positive(options.normalAngle, math.pi, true) <= math.pi, "Invalid fairing normal angle")
	end
	local solver = {
		tolerance = positive(options.tolerance, 1e-10),
		absoluteTolerance = positive(options.absoluteTolerance, 1e-12),
		iterations = U.integer(options.iterations or 4000, 0),
		restartOnRefresh = false,
		lockAxes = locks,
	}
	local nativeTolerance = positive(options.nativeTolerance, 1e-6)
	local nativeAbsolute = positive(options.nativeAbsoluteTolerance, 1e-10)
	local energyTolerance = positive(options.energyTolerance, 1e-10, true)
	local mesh = source:clone()
	A.validate(mesh)
	local context = {
		mesh = mesh,
		options = options,
		order = order,
		weights = weights,
		solver = solver,
		work = 0,
		nativeTolerance = nativeTolerance,
		nativeAbsoluteTolerance = nativeAbsolute,
		energyTolerance = energyTolerance,
		normalLimit = normalLimit,
	}
	function context.visit(n)
		context.work += n or 1
		assert(context.work <= maxWork, "Fairing work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Fairing cancelled")
	end
	function context.checkpoint(stage)
		context.visit(0)
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = context.work })
		end
	end
	context.checkpoint("begin")
	context.visit(U.count(mesh.vertices) + U.count(mesh.faces) + cornerCount)
	local connectivity = Connectivity.analyze(mesh, { maxElements = maxVertices + maxFaces + 3 * maxCorners })
	assert(connectivity.valid, "Fairing requires finite oriented manifold geometry")
	for _, p in mesh.vertices do
		assert(U.vector(p), "Finite fairing positions required")
	end
	local topology = mesh:topology()
	local pins = options.pins
	if pins == nil then
		pins = {}
	end
	assert(type(pins) == "table", "Fairing pins must be a vertex boolean set")
	for id, value in pins do
		assert(mesh.vertices[id] and type(value) == "boolean", "Invalid fairing pin")
	end
	assert(selection == nil or type(selection) == "table", "Fairing selection must be a vertex set")
	if selection then
		assert(options.faces == nil, "Specify fairing vertices or faces, not both")
		for id, value in selection do
			assert(
				mesh.vertices[id] and (type(value) == "boolean" or value == 0 or value == 1),
				"Fairing selection must contain booleans or zero/one values"
			)
		end
	elseif options.faces ~= nil then
		assert(type(options.faces) == "table", "Fairing faces must be a boolean set")
		for id, value in options.faces do
			assert(mesh.faces[id] and type(value) == "boolean", "Invalid fairing face")
		end
		selection = {}
		for id, faces in topology.vertexFaces do
			local selected = #faces > 0
			for _, fid in faces do
				selected = selected and options.faces[fid] == true
			end
			selection[id] = selected
		end
	end
	context.visit(cornerCount + U.count(topology.edges))
	local protected = Seams.locked(mesh, topology, options)
	local boundary = {}
	for _, edge in topology.edges do
		context.visit(1)
		if #edge.faces == 1 then
			boundary[edge.a], boundary[edge.b] = true, true
		end
	end
	local fixed = {}
	for id in mesh.vertices do
		context.visit(1)
		fixed[id] = pins[id] == true
			or protected[id] == true
			or options.pinBoundary ~= false and boundary[id] == true
			or selection ~= nil and selection[id] ~= true and selection[id] ~= 1
	end
	local components, triangles = {}, {}
	for _, component in connectivity.components do
		local ids = U.keys(component.vertices)
		local faces = U.keys(component.faces)
		local lo = { math.huge, math.huge, math.huge }
		local hi = { -math.huge, -math.huge, -math.huge }
		local free, index = {}, {}
		for i, id in ids do
			context.visit(1)
			index[id] = i
			local p = mesh.vertices[id]
			for axis, name in { "X", "Y", "Z" } do
				lo[axis] = math.min(lo[axis], p[name])
				hi[axis] = math.max(hi[axis], p[name])
			end
			if not fixed[id] then
				table.insert(free, i)
			end
		end
		local span = math.max(hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3])
		assert(span > 0 and U.finite(span), "Invalid fairing component span")
		local points, localTriangles = {}, {}
		for i, id in ids do
			context.visit(1)
			local p = mesh.vertices[id]
			points[i] = { (p.X - lo[1]) / span, (p.Y - lo[2]) / span, (p.Z - lo[3]) / span }
		end
		for _, fid in faces do
			local face = mesh.faces[fid]
			for _, t in
				mesh:faceTriangles(fid, {
					validateSimple = true,
					maxVertices = maxFaceVertices,
					maxWork = maxWork,
					_visit = context.visit,
				})
			do
				context.visit(1)
				local global = { face.vertices[t[1]], face.vertices[t[2]], face.vertices[t[3]] }
				table.insert(localTriangles, { index[global[1]], index[global[2]], index[global[3]] })
				table.insert(triangles, global)
			end
		end
		table.insert(components, {
			id = faces[1],
			ids = ids,
			faces = faces,
			points = points,
			triangles = localTriangles,
			free = free,
			origin = lo,
			span = span,
		})
	end
	context.components, context.triangles = components, triangles
	require(script.Parent.SculptAudit).attach(context, {
		maxWork = maxWork,
		maxTriangles = maxTriangles,
		maxVertices = maxVertices,
		maxFaces = maxFaces,
		maxCorners = maxCorners,
	})
	context.checkpoint("prepared")
	return context
end
return F
