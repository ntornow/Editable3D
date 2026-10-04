-- Private local-frame modifier kernels. Public entry points live in Deform.
local U = require(script.Parent.Util)
local Core = require(script.Parent.DeformCore)
local Q = require(script.Parent.Quaternion)
local function simple(mesh, mode, amount, options)
	options = options or {}
	Core.scalar(amount)
	assert(
		mode == "twist" or mode == "bend" or mode == "taper" or mode == "stretch",
		"Unknown simple deformation mode"
	)
	local axis, u, v = Core.axis(options.axis)
	local ctx = Core.prepare(mesh, options)
	local lo, hi = ctx.range(axis, options.range)
	local pivot = Core.scalar(options.pivot or 0)
	local span = hi - lo
	local radial = options.radialAxis or (axis == "X" and "Y" or "X")
	assert(Core.axes[radial] and radial ~= axis, "Bend radial axis must differ from its longitudinal axis")
	return ctx.run(function(p, _, w)
		local clamped = math.clamp(p[axis], lo, hi)
		local s = clamped - pivot
		local values = {}
		if mode == "twist" then
			local a = amount * s / span
			local c, sn = math.cos(a), math.sin(a)
			values[u], values[v] = p[u] * c - p[v] * sn, p[u] * sn + p[v] * c
		elseif mode == "taper" then
			local scale = 1 + amount * s / span
			values[u], values[v] = p[u] * scale, p[v] * scale
		elseif mode == "stretch" then
			local scale = 1 - amount + 4 * amount * (s / span) ^ 2
			values[u], values[v], values[axis] =
				p[u] * scale, p[v] * scale, pivot + (p[axis] - pivot) * (1 + amount)
		elseif amount ~= 0 then
			local k = amount / span
			local a = k * s
			local c, sn = math.cos(a), math.sin(a)
			local d = p[axis] - clamped
			values[radial] = p[radial] * c - 2 * math.sin(a / 2) ^ 2 / k - d * sn
			values[axis] = pivot + sn / k + p[radial] * sn + d * c
		end
		return p:Lerp(Core.replace(p, values), w)
	end)
end
local function shear(mesh, factor, options)
	options = options or {}
	Core.scalar(factor)
	local axis = Core.axis(options.axis or "X")
	local direction = Core.axis(options.direction or (axis == "Y" and "Z" or "Y"))
	assert(axis ~= direction, "Shear axis and direction must differ")
	local pivot = Core.scalar(options.pivot or 0)
	local ctx = Core.prepare(mesh, options)
	local lo, hi = -math.huge, math.huge
	if options.range then
		lo, hi = ctx.range(direction, options.range)
	end
	return ctx.run(function(p, _, w)
		return Core.replace(p, { [axis] = p[axis] + w * factor * (math.clamp(p[direction], lo, hi) - pivot) })
	end)
end
local function cast(mesh, shape, options)
	options = options or {}
	assert(shape == "sphere" or shape == "cylinder" or shape == "cuboid", "Unknown cast shape")
	local axis = Core.axis(options.axis or "Y")
	local size = options.size or 1
	if type(size) == "number" then
		Core.scalar(size)
		size = Vector3.one * size
	end
	assert(
		U.vector(size) and math.min(size.X, size.Y, size.Z) > 0,
		"Positive finite cast dimensions required"
	)
	local radius = Core.scalar(options.radius or 0)
	assert(radius >= 0, "Nonnegative cast influence radius required")
	for key, value in options.axes or {} do
		assert(Core.axes[key] and type(value) == "boolean", "Cast axes must be X/Y/Z booleans")
	end
	local ctx = Core.prepare(mesh, options)
	ctx.report.singularVertices = 0
	ctx.report.radiusExcluded = 0
	Core.validateFalloff(options.falloff)
	return ctx.run(function(p, _, w)
		local distance = p.Magnitude
		if radius > 0 then
			if distance > radius then
				ctx.report.radiusExcluded += 1
				return p
			end
			if options.falloff then
				w *= Core.falloff(options.falloff, distance / radius)
			end
		end
		local scaled = p / size
		if shape == "cylinder" then
			scaled = Core.replace(scaled, { [axis] = 0 })
		end
		local divisor = shape == "cuboid"
				and math.max(math.abs(scaled.X), math.abs(scaled.Y), math.abs(scaled.Z))
			or scaled.Magnitude
		if divisor == 0 then
			ctx.report.singularVertices += 1
			return p
		end
		local projected = p / divisor
		local values = {}
		for name in Core.axes do
			if (not options.axes or options.axes[name]) and (shape ~= "cylinder" or name ~= axis) then
				values[name] = projected[name]
			end
		end
		return p:Lerp(Core.replace(p, values), w)
	end)
end
local function warp(mesh, from, to, options)
	options = options or {}
	Core.frame(from)
	Core.frame(to)
	local radius = Core.scalar(options.radius or 0)
	assert(radius >= 0, "Nonnegative warp radius required")
	Core.validateFalloff(options.falloff)
	local ctx = Core.prepare(mesh, options)
	local a, b = Q.fromCFrame(from), Q.fromCFrame(to)
	return ctx.run(function(p, _, w)
		local original = ctx.frame:PointToWorldSpace(p)
		if radius > 0 then
			local d = (original - from.Position).Magnitude
			if d >= radius then
				return p
			end
			w *= Core.falloff(options.falloff, d / radius)
		end
		local localPoint = from:PointToObjectSpace(original)
		local result
		if options.preserveRotation == false then
			result = original:Lerp(to:PointToWorldSpace(localPoint), w)
		else
			result = Q.toCFrame(Q.slerp(a, b, w), from.Position:Lerp(to.Position, w))
				:PointToWorldSpace(localPoint)
		end
		return ctx.frame:PointToObjectSpace(result)
	end)
end
local function taper(mesh, profile, options)
	options = options or {}
	local ctx = Core.prepare(mesh, options)
	local axis, u, v = Core.axis(options.axis)
	local lo, hi = ctx.range(axis, options.range)
	local outside = options.outside or "clamp"
	assert(outside == "clamp" or outside == "error", "Taper outside mode must be clamp or error")
	local evaluate = require(script.Parent.DeformProfile)(profile, ctx)
	return ctx.run(function(p, _, w)
		local t = (p[axis] - lo) / (hi - lo)
		assert(outside ~= "error" or t >= 0 and t <= 1, "Taper point lies outside its source range")
		local scale = evaluate(math.clamp(t, 0, 1))
		return p:Lerp(Core.replace(p, { [u] = p[u] * scale.X, [v] = p[v] * scale.Y }), w)
	end)
end
return { simple = simple, shear = shear, cast = cast, warp = warp, taper = taper }
