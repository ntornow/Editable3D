-- Private immutable-source deformation context, scalar masks and bounded work.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local axes = { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis }
local function scalar(value, message)
	assert(type(value) == "number" and U.finite(value), message or "Finite deformation scalar required")
	return value
end
local function frame(value)
	assert(typeof(value) == "CFrame", "Deformation frame must be a CFrame")
	for _, v in { value:GetComponents() } do
		scalar(v, "Finite deformation frame required")
	end
	return value
end
local function weight(value)
	if type(value) == "boolean" then
		return value and 1 or 0
	end
	scalar(value, "Finite scalar or boolean deformation mask required")
	assert(value >= 0 and value <= 1, "Deformation mask values must lie in [0,1]")
	return value
end
local function axis(value, signed)
	value = value or "Y"
	local sign = 1
	if signed and type(value) == "string" and value:sub(1, 1) == "-" then
		sign, value = -1, value:sub(2)
	end
	assert(axes[value], "Deformation axis must be X, Y or Z")
	local u = value == "X" and "Y" or value == "Y" and "Z" or "X"
	local v = value == "X" and "Z" or value == "Y" and "X" or "Y"
	return value, u, v, sign
end
local function replace(p, values)
	return Vector3.new(values.X or p.X, values.Y or p.Y, values.Z or p.Z)
end
local function validateFalloff(kind)
	assert(
		kind == nil
			or type(kind) == "function"
			or kind == "constant"
			or kind == "linear"
			or kind == "smooth"
			or kind == "smoother"
			or kind == "sharp"
			or kind == "sharper"
			or kind == "root"
			or kind == "sphere"
			or kind == "inverseSquare",
		"Unknown deformation falloff"
	)
end
local function falloff(kind, t)
	t = math.clamp(t, 0, 1)
	if type(kind) == "function" then
		return weight(kind(t))
	end
	kind = kind or "smooth"
	if kind == "constant" then
		return 1
	end
	if kind == "linear" then
		return 1 - t
	end
	if kind == "smooth" then
		return U.smooth(1 - t)
	end
	if kind == "smoother" then
		local x = 1 - t
		return x * x * x * (x * (6 * x - 15) + 10)
	end
	if kind == "sharp" then
		return (1 - t) ^ 2
	end
	if kind == "sharper" then
		return (1 - t) ^ 4
	end
	if kind == "root" then
		return math.sqrt(1 - t)
	end
	if kind == "sphere" then
		return math.sqrt(math.max(0, 1 - t * t))
	end
	if kind == "inverseSquare" then
		return 1 - t * t
	end
	assert(false, "Unknown deformation falloff")
end
local function prepare(mesh, options)
	options = options or {}
	A.validate(mesh)
	assert(mesh:validate().valid, "Deformation requires valid source topology")
	local ctx = {
		frame = frame(options.frame or CFrame.identity),
		ids = U.keys(mesh.vertices),
		points = {},
		weights = {},
		options = options,
	}
	assert(#ctx.ids <= U.integer(options.maxVertices or 200000, 0), "Deformation vertex budget exceeded")
	local maxWork = U.integer(options.maxWork or 2000000, 1)
	local report = {
		complete = false,
		vertices = #ctx.ids,
		modifiedVertices = 0,
		maskedVertices = 0,
		maximumDisplacement = 0,
		work = 0,
	}
	ctx.report = report
	ctx.checkpoint = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Deformation cancelled")
		if options.checkpoint then
			options.checkpoint({
				stage = stage or "deform",
				work = report.work,
				vertices = #ctx.ids,
				modifiedVertices = report.modifiedVertices,
			})
		end
	end
	ctx.visit = function()
		report.work += 1
		assert(report.work <= maxWork, "Deformation work budget exceeded")
		if report.work % 256 == 0 then
			ctx.checkpoint()
		end
	end
	ctx.checkpoint("begin")
	local strength = scalar(options.strength == nil and 1 or options.strength)
	local group = options.group and assert(mesh.groups[options.group], "Missing deformation group")
	local channel = options.attribute
		and assert(mesh.attributes[options.attribute], "Missing deformation mask channel")
	if channel then
		assert(
			channel.domain == "vertex" and (channel.dataType == "number" or channel.dataType == "boolean"),
			"Deformation mask channel must be scalar vertex data"
		)
	end
	if options.mask then
		assert(type(options.mask) == "table", "Deformation mask must be a vertex dictionary")
		for id, value in options.mask do
			assert(mesh.vertices[id], "Deformation mask refers to missing vertex")
			weight(value)
		end
	end
	assert(
		options.maskField == nil or type(options.maskField) == "function",
		"Deformation maskField must be a function"
	)
	for name, value in options.lockAxes or {} do
		assert(axes[name] and type(value) == "boolean", "Axis locks must be X/Y/Z booleans")
	end
	for _, id in ctx.ids do
		ctx.visit()
		local p = mesh.vertices[id]
		ctx.points[id] = ctx.frame:PointToObjectSpace(p)
		local w = options.mask and weight(options.mask[id] == nil and 0 or options.mask[id]) or 1
		if group then
			w *= weight(group[id] or 0)
		end
		if channel then
			w *= weight(A.read(channel, id))
		end
		if options.invertMask then
			w = 1 - w
		end
		if options.maskField then
			w *= weight(options.maskField(p, id))
		end
		ctx.weights[id] = w * strength
	end
	ctx.range = function(name, explicit)
		if explicit then
			assert(
				typeof(explicit) == "Vector2"
					and U.finite(explicit.X)
					and U.finite(explicit.Y)
					and explicit.Y > explicit.X,
				"Increasing finite deformation range required"
			)
			return explicit.X, explicit.Y
		end
		local lo, hi = math.huge, -math.huge
		for _, p in ctx.points do
			lo, hi = math.min(lo, p[name]), math.max(hi, p[name])
		end
		assert(hi > lo, "Deformation source extent is zero; supply a range")
		return lo, hi
	end
	ctx.run = function(callback)
		local out = mesh:clone()
		for _, id in ctx.ids do
			ctx.visit()
			local p, w = ctx.points[id], ctx.weights[id]
			if w == 0 then
				report.maskedVertices += 1
				continue
			end
			local q = callback(p, id, w)
			assert(U.vector(q), "Deformation returned a nonfinite position")
			local locked = {}
			for name, value in options.lockAxes or {} do
				if value then
					locked[name] = p[name]
				end
			end
			q = replace(q, locked)
			if q ~= p then
				out.vertices[id] = ctx.frame:PointToWorldSpace(q)
				assert(U.vector(out.vertices[id]), "Deformation position overflow")
				local d = (out.vertices[id] - mesh.vertices[id]).Magnitude
				if d > 0 then
					report.modifiedVertices += 1
				end
				report.maximumDisplacement = math.max(report.maximumDisplacement, d)
			end
		end
		if options.recalculateNormals ~= false then
			out:recalculateNormals(options.normalAngle)
		end
		A.validate(out)
		report.validation = out:validate()
		report.complete = report.validation.valid
		assert(
			report.complete or options.allowInvalid == true,
			"Deformation collapsed geometry at native precision"
		)
		out.revision += 1
		ctx.checkpoint("finish")
		return out, report
	end
	return ctx
end
return {
	prepare = prepare,
	scalar = scalar,
	frame = frame,
	weight = weight,
	axis = axis,
	axes = axes,
	replace = replace,
	falloff = falloff,
	validateFalloff = validateFalloff,
}
