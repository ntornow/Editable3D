-- Deterministic bounded rectangle packing, followed by native-coordinate audits.
local U = require(script.Parent.Util)
local Core = require(script.Parent.UVIslandCore)
local Edit = require(script.Parent.UVIslandEdit)
local Analysis = require(script.Parent.UVAnalysis)
local I = require(script.Parent.DirectedInterval)
local Pack = {}
local function intersects(a, b)
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end
local function contains(a, b)
	return a.x <= b.x and a.y <= b.y and a.x + a.w >= b.x + b.w and a.y + a.h >= b.y + b.h
end
local function split(free, used, context, maximum)
	local nextFree = {}
	local function insert(x, y, w, h)
		if w > 0 and h > 0 then
			assert(#nextFree < maximum, "UV free rectangle allocation budget exceeded")
			table.insert(nextFree, { x = x, y = y, w = w, h = h })
		end
	end
	for _, box in free do
		context.visit(1)
		if not intersects(box, used) then
			insert(box.x, box.y, box.w, box.h)
		else
			if used.x > box.x then
				insert(box.x, box.y, used.x - box.x, box.h)
			end
			if used.x + used.w < box.x + box.w then
				insert(used.x + used.w, box.y, box.x + box.w - used.x - used.w, box.h)
			end
			if used.y > box.y then
				insert(box.x, box.y, box.w, used.y - box.y)
			end
			if used.y + used.h < box.y + box.h then
				insert(box.x, used.y + used.h, box.w, box.y + box.h - used.y - used.h)
			end
		end
	end
	local retained = {}
	for i, box in nextFree do
		local redundant = false
		for j, other in nextFree do
			context.visit(1)
			if i ~= j and contains(other, box) and (not contains(box, other) or j < i) then
				redundant = true
				break
			end
		end
		if not redundant then
			table.insert(retained, box)
		end
	end
	return retained
end
local function lowerDifference(a, b)
	return a == b and 0 or I.sub(I.new(a), I.new(b))[1]
end
local function nativeBounds(mesh, island, size)
	local lo, hi = { math.huge, math.huge }, { -math.huge, -math.huge }
	for _, ref in island.corners do
		local uv = mesh.faces[ref.face].corners[ref.corner].uv
		lo[1], lo[2] = math.min(lo[1], uv.X * size.X), math.min(lo[2], uv.Y * size.Y)
		hi[1], hi[2] = math.max(hi[1], uv.X * size.X), math.max(hi[2], uv.Y * size.Y)
	end
	return { lo = lo, hi = hi, id = island.id }
end
function Pack.run(source, settings)
	local context = Core.prepare(source, settings)
	local options, size = context.options, context.size
	local minimum, maximum = options.minimum or Vector2.zero, options.maximum or Vector2.one
	assert(
		Core.vector(minimum) and Core.vector(maximum) and maximum.X > minimum.X and maximum.Y > minimum.Y,
		"UV pack region must have positive finite dimensions"
	)
	local bounds = {
		x = minimum.X * size.X,
		y = minimum.Y * size.Y,
		w = (maximum.X - minimum.X) * size.X,
		h = (maximum.Y - minimum.Y) * size.Y,
	}
	local margin = options.margin
	if margin == nil then
		margin = math.min(bounds.w, bounds.h) * 0.005
	end
	assert(
		type(margin) == "number" and U.finite(margin) and margin >= 0,
		"UV packing margin must be finite and nonnegative"
	)
	for _, name in { "rotate", "normalizeDensity" } do
		assert(options[name] == nil or type(options[name]) == "boolean", "UV packing flags must be boolean")
	end
	local iterations = U.integer(options.iterations or 32, 1)
	assert(iterations <= 64, "UV packing search iterations exceed 64")
	local maxRectangles = U.integer(options.maxFreeRectangles or 4096, 1)
	assert(
		options.scale == nil
			or type(options.scale) == "number" and U.finite(options.scale) and options.scale > 0,
		"UV packing scale must be finite and positive"
	)
	local maxIslands = U.integer(options.maxIslands or 2000, 1)
	assert(#context.islands <= maxIslands, "UV island allocation budget exceeded")
	local pins = options.pinnedIslands or {}
	assert(type(pins) == "table", "UV packing pins must be an island boolean set")
	for id, value in pins do
		assert(context.byId[id] and type(value) == "boolean", "Invalid UV packing pin")
	end
	local fixed, movable, moving = {}, {}, {}
	local area = 0
	for _, island in context.islands do
		assert(#island.missing == 0, "UV packing requires UVs on every obstacle and movable chart")
		if island.selected and not pins[island.id] then
			Edit.requireChart(island)
			local factor = options.normalizeDensity and 1 / island.density or 1
			local item = {
				island = island,
				factor = factor,
				w = (island.maximum[1] - island.minimum[1]) * size.X * factor,
				h = (island.maximum[2] - island.minimum[2]) * size.Y * factor,
			}
			area += item.w * item.h
			table.insert(movable, item)
			moving[island.id] = true
		else
			table.insert(fixed, nativeBounds(context.mesh, island, size))
		end
	end
	local report = {
		complete = true,
		applied = false,
		method = "boundingRectangles",
		margin = margin,
		textureSize = size,
		placements = {},
		movableIslands = #movable,
		fixedIslands = #fixed,
		attempts = 0,
		scale = 1,
		marginCertified = false,
	}
	local function failure(reason)
		report.complete, report.reason, report.work = false, reason, context.work
		assert(not options.requireComplete, "UV packing incomplete: " .. reason)
		return context.mesh:clone(), report
	end
	if #movable == 0 then
		report.marginCertified = true
		report.work = context.work
		return context.mesh:clone(), report
	end
	local input = Analysis.scan(context, true)
	for id in moving do
		if context.byId[id].mixedOrientation or input.internalOverlaps[id] then
			return failure("foldedIsland")
		end
	end
	table.sort(movable, function(a, b)
		local aa, bb = a.w * a.h, b.w * b.h
		if aa ~= bb then
			return aa > bb
		end
		if math.max(a.w, a.h) ~= math.max(b.w, b.h) then
			return math.max(a.w, a.h) > math.max(b.w, b.h)
		end
		return a.island.id < b.island.id
	end)
	-- A conservative float32-scale clearance helps the subsequent stored-UV audit.
	local guard = 2 ^ -21
		* math.max(
			math.abs(minimum.X * size.X),
			math.abs(minimum.Y * size.Y),
			math.abs(maximum.X * size.X),
			math.abs(maximum.Y * size.Y),
			bounds.w,
			bounds.h
		)
	local padding = margin + guard
	local free = { { x = bounds.x, y = bounds.y, w = bounds.w, h = bounds.h } }
	for _, box in fixed do
		free = split(free, {
			x = box.lo[1] - padding,
			y = box.lo[2] - padding,
			w = box.hi[1] - box.lo[1] + 2 * padding,
			h = box.hi[2] - box.lo[2] + 2 * padding,
		}, context, maxRectangles)
	end
	local function trial(scale)
		report.attempts += 1
		local spaces = table.clone(free)
		local placements = {}
		for _, item in movable do
			local best, score
			for _, box in spaces do
				for rotation = 0, (options.rotate == false and 0 or 1) do
					context.visit(1)
					local w = (rotation == 0 and item.w or item.h) * scale + 2 * padding
					local h = (rotation == 0 and item.h or item.w) * scale + 2 * padding
					if w <= box.w and h <= box.h then
						local candidate = {
							math.min(box.w - w, box.h - h),
							math.max(box.w - w, box.h - h),
							box.y,
							box.x,
							rotation,
						}
						local better = score == nil
						if score then
							for k = 1, #candidate do
								if candidate[k] ~= score[k] then
									better = candidate[k] < score[k]
									break
								end
							end
						end
						if better then
							best, score =
								{ x = box.x, y = box.y, w = w, h = h, rotation = rotation }, candidate
						end
					end
				end
			end
			if not best then
				return nil
			end
			placements[item.island.id] = best
			spaces = split(spaces, best, context, maxRectangles)
		end
		return placements
	end
	local placement, scale
	if options.scale ~= nil then
		scale = options.scale
		assert(
			type(scale) == "number" and U.finite(scale) and scale > 0,
			"UV packing scale must be finite and positive"
		)
		placement = trial(scale)
	else
		local low, high = 0, math.sqrt(bounds.w * bounds.h / area)
		assert(U.finite(high) and high > 0, "UV packing scale outside numerical range")
		placement = trial(high)
		if placement then
			scale = high
		else
			for _ = 1, iterations do
				local middle = (low + high) / 2
				local attempt = trial(middle)
				if attempt then
					low, scale, placement = middle, middle, attempt
				else
					high = middle
				end
			end
		end
	end
	if not placement then
		return failure("noPlacement")
	end
	context.checkpoint("packedRectangles")
	local plans = {}
	for _, item in movable do
		local id = item.island.id
		local box = placement[id]
		local factor = item.factor * scale
		local lo, hi = item.island.minimum, item.island.maximum
		plans[id] = {
			orientation = 1,
			expectedDensity = item.island.density * factor,
			map = function(x, y)
				local u, v = (x - lo[1]) * size.X * factor, (y - lo[2]) * size.Y * factor
				if box.rotation == 1 then
					u, v = (hi[2] - lo[2]) * size.Y * factor - v, u
				end
				return (box.x + padding + u) / size.X, (box.y + padding + v) / size.Y
			end,
		}
		table.insert(report.placements, { id = id, rotation = box.rotation * math.pi / 2, scale = factor })
	end
	local out, edit = Edit.apply(context, plans)
	report.nativeEdit, report.scale = edit, scale
	if not edit.complete then
		return failure(edit.reason)
	end
	local boxes = {}
	for _, island in context.islands do
		local box = nativeBounds(out, island, size)
		table.insert(boxes, box)
		if moving[island.id] then
			local distances = {
				lowerDifference(box.lo[1], minimum.X * size.X),
				lowerDifference(box.lo[2], minimum.Y * size.Y),
				lowerDifference(maximum.X * size.X, box.hi[1]),
				lowerDifference(maximum.Y * size.Y, box.hi[2]),
			}
			for _, distance in distances do
				if distance < margin then
					return failure("nativeBorderMargin")
				end
			end
		end
	end
	for i, a in boxes do
		for j = i + 1, #boxes do
			context.visit(1)
			local b = boxes[j]
			if moving[a.id] or moving[b.id] then
				local gap = math.max(
					lowerDifference(a.lo[1], b.hi[1]),
					lowerDifference(b.lo[1], a.hi[1]),
					lowerDifference(a.lo[2], b.hi[2]),
					lowerDifference(b.lo[2], a.hi[2])
				)
				if gap < 2 * margin then
					return failure("nativeIslandMargin")
				end
			end
		end
	end
	local audited = { triangles = {}, options = options, visit = context.visit }
	for _, island in context.islands do
		if moving[island.id] then
			for _, triangle in island.triangles do
				context.visit(1)
				local sourceTriangle = {
					triangle.vertices[1],
					triangle.vertices[2],
					triangle.vertices[3],
					face = triangle.face,
					corners = triangle.corners,
				}
				local measured = Core.measure(out, sourceTriangle, size)
				measured.island, measured.index = island.id, #audited.triangles + 1
				table.insert(audited.triangles, measured)
			end
		end
	end
	if Analysis.scan(audited, true).overlapCount > 0 then
		return failure("nativeInternalOverlap")
	end
	report.marginCertified = true
	report.applied = true
	context.checkpoint("packVerified")
	report.work = context.work
	return out, report
end
return Pack
