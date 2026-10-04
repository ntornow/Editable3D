-- Private weighted point/weight edits on independent rational control nets.
local Core = require(script.Parent.SurfaceEditCore)
local U = require(script.Parent.Util)
local P = {}
local function mapped(s, ctx, operation)
	assert(type(operation) == "function", "Surface edit callback required")
	local p, w = {}, {}
	local report = { modifiedControls = 0, modifiedWeights = 0, maximumDisplacement = 0 }
	for i, row in s.control do
		p[i], w[i] = {}, {}
		for j, point in row do
			ctx.visit()
			local weight, influence = s.weights[i][j], ctx.weight(i, j)
			p[i][j], w[i][j] = point, weight
			if influence ~= 0 then
				local target, newWeight = operation(point, weight, i, j)
				assert(U.vector(target), "Surface edit returned a nonfinite control")
				newWeight = newWeight == nil and weight or newWeight
				assert(
					type(newWeight) == "number" and U.finite(newWeight) and newWeight > 0,
					"Positive finite rational weights required"
				)
				p[i][j] = influence == 1 and target or point:Lerp(target, influence)
				w[i][j] = influence == 1 and newWeight or weight + (newWeight - weight) * influence
				if p[i][j] ~= point then
					report.modifiedControls += 1
				end
				if w[i][j] ~= weight then
					report.modifiedWeights += 1
				end
				report.maximumDisplacement = math.max(report.maximumDisplacement, (p[i][j] - point).Magnitude)
			end
		end
	end
	return Core.finish(Core.build(s, p, w, ctx), ctx, Core.identity(s), report)
end
function P.map(surface, operation, options)
	local s, ctx = Core.prepare(surface, options)
	return mapped(s, ctx, operation)
end
function P.select(surface, selector, options)
	local s, ctx = Core.prepare(surface, options)
	selector = selector or {}
	if type(selector) == "function" then
		selector = { predicate = selector }
	end
	assert(type(selector) == "table", "Surface selector must be a predicate or table")
	local a, b = Core.range(selector.u, ctx.nu)
	local c, d = Core.range(selector.v, ctx.nv)
	assert(
		selector.predicate == nil or type(selector.predicate) == "function",
		"Surface selection predicate must be a function"
	)
	if selector.boundary and selector.boundary ~= "all" then
		Core.boundary(s, selector.boundary)
	end
	local mask = {}
	for i, row in s.control do
		for j, point in row do
			ctx.visit()
			local selected = i >= a and i <= b and j >= c and j <= d
			if selector.boundary then
				local sides = {
					U0 = not s.cyclicU and i == 1,
					U1 = not s.cyclicU and i == ctx.nu,
					V0 = not s.cyclicV and j == 1,
					V1 = not s.cyclicV and j == ctx.nv,
				}
				selected = selected
					and (
						selector.boundary == "all" and (sides.U0 or sides.U1 or sides.V0 or sides.V1)
						or sides[selector.boundary]
					)
			end
			if selected then
				local value = selector.predicate
						and Core.weight(selector.predicate(point, s.weights[i][j], i, j))
					or 1
				value *= ctx.weight(i, j)
				Core.weight(value)
				if value > 0 then
					mask[Core.key(i, j)] = value
				end
			end
		end
	end
	ctx.check("finish")
	return mask
end
function P.transform(surface, frame, options)
	options = options or {}
	assert(typeof(frame) == "CFrame", "Surface transform must be a CFrame")
	for _, v in { frame:GetComponents() } do
		Core.scalar(v)
	end
	local scale = options.scale or Vector3.one
	local pivot = options.pivot or Vector3.zero
	assert(U.vector(scale) and U.vector(pivot), "Finite surface scale and pivot required")
	return P.map(surface, function(point, weight)
		return pivot + frame:VectorToWorldSpace((point - pivot) * scale) + frame.Position, weight
	end, options)
end
function P.weights(surface, values, options)
	options = options or {}
	local s, ctx = Core.prepare(surface, options)
	local mode = options.mode or "set"
	assert(mode == "set" or mode == "multiply", "Surface weight mode must be set or multiply")
	local function positive(value)
		assert(
			type(value) == "number" and U.finite(value) and value > 0,
			"Positive finite weight edit required"
		)
	end
	if type(values) == "table" then
		for key, value in values do
			Core.index(key, ctx.nu, ctx.nv)
			positive(value)
		end
	elseif type(values) ~= "function" then
		positive(values)
	end
	return mapped(s, ctx, function(p, w, i, j)
		local value
		if type(values) == "function" then
			value = values(w, i, j, p)
		elseif type(values) == "table" then
			value = values[Core.key(i, j)]
		else
			value = values
		end
		if value == nil then
			return p, w
		end
		positive(value)
		return p, mode == "multiply" and w * value or value
	end)
end
function P.smooth(surface, iterations, options)
	local s, ctx = Core.prepare(surface, options)
	options = options or {}
	iterations = U.integer(iterations or 1, 0)
	assert(
		iterations <= U.integer(options.maxIterations or 1000, 0),
		"Surface smoothing iteration budget exceeded"
	)
	local factor = Core.weight(options.factor == nil and 0.5 or options.factor)
	local p, w = s.control, s.weights
	local neighbors = {}
	for i, row in p do
		neighbors[i] = {}
		for j in row do
			local list, seen = {}, {}
			for _, delta in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
				local a, b = i + delta[1], j + delta[2]
				if s.cyclicU then
					a = (a - 1) % ctx.nu + 1
				end
				if s.cyclicV then
					b = (b - 1) % ctx.nv + 1
				end
				local key = Core.key(a, b)
				if a >= 1 and a <= ctx.nu and b >= 1 and b <= ctx.nv and not seen[key] then
					seen[key] = true
					list[#list + 1] = { a, b }
				end
			end
			neighbors[i][j] = list
		end
	end
	for _ = 1, iterations do
		local nextP, nextW = {}, {}
		for i, row in p do
			nextP[i], nextW[i] = {}, {}
			for j, point in row do
				ctx.visit()
				local influence = factor * ctx.weight(i, j)
				Core.weight(influence)
				if
					options.pinBoundary ~= false
					and (
						(not s.cyclicU and (i == 1 or i == ctx.nu))
						or (not s.cyclicV and (j == 1 or j == ctx.nv))
					)
				then
					influence = 0
				end
				local x, y, z, weight = 0, 0, 0, 0
				for _, index in neighbors[i][j] do
					ctx.visit()
					local a, b = index[1], index[2]
					x += p[a][b].X - point.X
					y += p[a][b].Y - point.Y
					z += p[a][b].Z - point.Z
					weight += w[a][b] / #neighbors[i][j]
				end
				local fraction = influence / #neighbors[i][j]
				nextP[i][j] = influence == 0 and point
					or Vector3.new(point.X + x * fraction, point.Y + y * fraction, point.Z + z * fraction)
				nextW[i][j] = options.smoothWeights
						and (influence == 1 and weight or w[i][j] + (weight - w[i][j]) * influence)
					or w[i][j]
			end
		end
		p, w = nextP, nextW
	end
	local report =
		{ iterations = iterations, modifiedControls = 0, modifiedWeights = 0, maximumDisplacement = 0 }
	for i, row in p do
		for j, point in row do
			if point ~= s.control[i][j] then
				report.modifiedControls += 1
			end
			if w[i][j] ~= s.weights[i][j] then
				report.modifiedWeights += 1
			end
			report.maximumDisplacement =
				math.max(report.maximumDisplacement, (point - s.control[i][j]).Magnitude)
		end
	end
	return Core.finish(Core.build(s, p, w, ctx), ctx, Core.identity(s), report)
end
function P.deform(surface, operation, options)
	local s, ctx = Core.prepare(surface, options)
	assert(type(operation) == "function", "Control-mesh deformation callback required")
	local mesh = require(script.Parent.Mesh).new()
	local mapping, values = {}, {}
	for i, row in s.control do
		for j, p in row do
			ctx.visit()
			local id = mesh:addVertex(p)
			mapping[Core.key(i, j)] = id
			values[id] = s.weights[i][j]
		end
	end
	mesh.attributes.surface_weight =
		{ domain = "vertex", dataType = "number", default = 1, interpolation = "linear", values = values }
	local posed, operatorReport = operation(mesh, table.clone(mapping))
	assert(
		type(posed) == "table"
			and type(posed.vertices) == "table"
			and type(posed.faces) == "table"
			and not next(posed.faces),
		"Control deformation must return a point-only mesh"
	)
	assert(
		not operatorReport
			or type(operatorReport) == "table"
				and operatorReport.complete ~= false
				and operatorReport.success ~= false
				and operatorReport.converged ~= false,
		"Surface deformation operator reported an incomplete result"
	)
	assert(U.count(posed.vertices) == ctx.nu * ctx.nv, "Control deformation changed vertex count")
	local A = require(script.Parent.AttributeCore)
	A.validate(posed)
	local channel = assert(posed.attributes.surface_weight, "Control deformation lost rational weights")
	assert(
		channel.domain == "vertex" and channel.dataType == "number",
		"Control weight channel schema changed"
	)
	for _, id in mapping do
		assert(
			U.vector(posed.vertices[id]),
			"Control deformation changed vertex IDs or returned invalid coordinates"
		)
		local weight = A.read(channel, id)
		assert(
			type(weight) == "number" and U.finite(weight) and weight > 0,
			"Control deformation returned invalid rational weights"
		)
	end
	local result, report = mapped(s, ctx, function(_, _, i, j)
		local id = mapping[Core.key(i, j)]
		return assert(posed.vertices[id], "Control deformation changed vertex IDs"), A.read(channel, id)
	end)
	report.operator = operatorReport
	return result, report
end
return P
