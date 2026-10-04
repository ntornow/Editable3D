-- Private control-net snapshots, masks, budgets and descriptor reconstruction.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local Core = {}
function Core.key(i, j)
	return i .. ":" .. j
end
function Core.scalar(value, message)
	assert(type(value) == "number" and U.finite(value), message or "Finite surface edit scalar required")
	return value
end
function Core.weight(value)
	if type(value) == "boolean" then
		return value and 1 or 0
	end
	Core.scalar(value, "Surface selection must be a scalar or boolean")
	assert(value >= 0 and value <= 1, "Surface selection weights must lie in [0,1]")
	return value
end
function Core.index(key, nu, nv)
	assert(type(key) == "string", "Surface control keys must be i:j strings")
	local a, b = key:match("^(%d+):(%d+)$")
	local i, j = tonumber(a), tonumber(b)
	assert(
		i and j and i >= 1 and i <= nu and j >= 1 and j <= nv and Core.key(i, j) == key,
		"Surface control index is missing or noncanonical"
	)
	return i, j
end
function Core.range(value, count)
	if value == nil then
		return 1, count
	end
	assert(typeof(value) == "Vector2", "Control range must be an inclusive Vector2")
	U.integer(value.X, 1)
	U.integer(value.Y, 1)
	assert(value.Y >= value.X and value.Y <= count, "Control range exceeds its grid direction")
	return value.X, value.Y
end
function Core.axis(axis)
	assert(axis == "U" or axis == "V", "Surface edit axis must be U or V")
	return axis == "U"
end
function Core.boundary(s, boundary)
	assert(
		boundary == "U0" or boundary == "U1" or boundary == "V0" or boundary == "V1",
		"Surface boundary must be U0/U1/V0/V1"
	)
	local axis = boundary:sub(1, 1)
	assert(not s["cyclic" .. axis], "A cyclic direction has no border; open or rotate its seam first")
	return axis == "U", boundary:sub(2) == "0"
end
function Core.prepare(surface, options)
	options = options or {}
	assert(
		type(surface) == "table" and (surface.kind == "surface" or surface.kind == "cyclicSurface"),
		"Rational or cyclic surface required"
	)
	local ctx = {
		options = options,
		maxControls = U.integer(options.maxControls or 10000, 1),
		maxWork = U.integer(options.maxWork or 2000000, 1),
		work = 0,
	}
	ctx.check = function(stage)
		assert(not options.cancelled or not options.cancelled(), "Surface edit cancelled")
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = ctx.work })
		end
	end
	ctx.visit = function(count)
		local old = ctx.work
		ctx.work += count or 1
		assert(ctx.work <= ctx.maxWork, "Surface edit work budget exceeded")
		if math.floor(old / 256) ~= math.floor(ctx.work / 256) then
			ctx.check("edit")
		end
	end
	ctx.budget = function(nu, nv, du, dv, cu, cv)
		assert(
			(nu + (cu and du or 0)) * (nv + (cv and dv or 0)) <= ctx.maxControls,
			"Surface expanded-control budget exceeded"
		)
	end
	ctx.check("begin")
	local config = table.clone(surface)
	config.maxControls = ctx.maxControls
	local s = surface.kind == "cyclicSurface"
			and C.surface(surface.control, surface.degreeU, surface.degreeV, config)
		or N.surface(surface.control, surface.degreeU, surface.degreeV, config)
	s.cyclicU, s.cyclicV = s.cyclicU == true, s.cyclicV == true
	ctx.source = s
	ctx.nu, ctx.nv = #s.control, #s.control[1]
	ctx.visit(ctx.nu * ctx.nv)
	if options.mask then
		assert(type(options.mask) == "table", "Surface mask must be a control dictionary")
		for key, value in options.mask do
			Core.index(key, ctx.nu, ctx.nv)
			Core.weight(value)
		end
	end
	ctx.strength = Core.scalar(options.strength == nil and 1 or options.strength)
	ctx.weight = function(i, j)
		local value = options.mask
				and Core.weight(options.mask[Core.key(i, j)] == nil and 0 or options.mask[Core.key(i, j)])
			or 1
		if options.invertMask then
			value = 1 - value
		end
		return value * ctx.strength
	end
	return s, ctx
end
function Core.build(s, p, w, ctx, changes)
	changes = changes or {}
	local config = table.clone(s)
	for _, axis in { "U", "V" } do
		if changes["reset" .. axis] then
			config["knots" .. axis], config["intervals" .. axis] = nil, nil
			config["clamped" .. axis] = true
		end
	end
	for key, value in changes do
		config[key] = value
	end
	config.weights, config.maxControls = w, ctx.maxControls
	ctx.budget(#p, #p[1], config.degreeU, config.degreeV, config.cyclicU, config.cyclicV)
	ctx.visit(#p * #p[1])
	return (config.cyclicU or config.cyclicV) and C.surface(p, config.degreeU, config.degreeV, config)
		or N.surface(p, config.degreeU, config.degreeV, config)
end
function Core.identity(s)
	local map = {}
	for i, row in s.control do
		for j in row do
			local key = Core.key(i, j)
			map[key] = key
		end
	end
	return map
end
function Core.finish(result, ctx, mapping, extra)
	local report = extra or {}
	report.complete, report.regularityChecked = true, false
	report.sourceControls = ctx.nu * ctx.nv
	report.controls = #result.control * #result.control[1]
	report.work = ctx.work
	report.sourceRefs = mapping
	ctx.check("finish")
	return result, report
end
function Core.pick(s, rows, columns, ctx, options, openedAxis)
	options = options or {}
	local changes = {}
	for _, entry in { { "U", rows, #s.control }, { "V", columns, #s.control[1] } } do
		local axis, list, total = entry[1], entry[2], entry[3]
		local full = #list == total
		for i, value in list do
			if value ~= i then
				full = false
			end
		end
		local degree = options["degree" .. axis] or s["degree" .. axis]
		if options.reduceDegree then
			degree = math.min(degree, #list - 1)
		end
		U.integer(degree, 1)
		assert(degree <= 17 and #list > degree, "Surface piece needs more controls than its degree")
		changes["degree" .. axis] = degree
		if not full or degree ~= s["degree" .. axis] or openedAxis == axis then
			changes["reset" .. axis] = true
			changes["cyclic" .. axis] = false
			changes["knots" .. axis] = options["knots" .. axis]
			if options["clamped" .. axis] ~= nil then
				changes["clamped" .. axis] = options["clamped" .. axis]
			end
		end
	end
	ctx.budget(
		#rows,
		#columns,
		changes.degreeU,
		changes.degreeV,
		s.cyclicU and not changes.resetU,
		s.cyclicV and not changes.resetV
	)
	local p, w, map = {}, {}, {}
	for i, a in rows do
		p[i], w[i] = {}, {}
		for j, b in columns do
			ctx.visit()
			p[i][j], w[i][j] = s.control[a][b], s.weights[a][b]
			map[Core.key(i, j)] = Core.key(a, b)
		end
	end
	return Core.build(s, p, w, ctx, changes), map
end
function Core.sequence(first, last)
	local out = {}
	for i = first, last do
		out[#out + 1] = i
	end
	return out
end
return Core
