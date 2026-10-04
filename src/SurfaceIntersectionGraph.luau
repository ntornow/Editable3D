-- Private certified graphs of three dependent parameters over one free parameter.
local U = require(script.Parent.Util)
local I = require(script.Parent.DirectedInterval)
local K = require(script.Parent.IntervalNewton3)
local G = {}
local function axes(free)
	local out = {}
	for axis = 1, 4 do
		if axis ~= free then
			table.insert(out, axis)
		end
	end
	return out
end
function G.step(box, free, data, evaluate, ctx)
	local dependent, domain, jacobian = axes(free), {}, {}
	for i, axis in dependent do
		domain[i] = box[axis]
	end
	for row = 1, 3 do
		jacobian[row] = {}
		for i, axis in dependent do
			jacobian[row][i] = data.j[row][axis]
		end
	end
	local function reduced(y)
		local p = table.clone(box)
		for i, axis in dependent do
			p[axis] = y[i]
		end
		return evaluate(p)
	end
	local result = K(domain, jacobian, reduced, ctx)
	if result.box then
		local contracted = table.clone(box)
		local image = table.clone(box)
		for i, axis in dependent do
			contracted[axis] = result.box[i]
			image[axis] = result.image[i]
		end
		result.box = contracted
		result.image = image
	end
	result.free, result.dependent = free, dependent
	return result
end
local function magnitude(x)
	return math.max(math.abs(x[1]), math.abs(x[2]))
end
local function width(box, dependent)
	local value = 0
	for _, axis in dependent do
		value = math.max(value, I.width(box[axis]))
	end
	return value
end
function G.refine(graph, range, evaluate, ctx, iterations)
	local box = table.clone(graph.box)
	box[graph.free] = range
	for _ = 1, iterations do
		local step = G.step(box, graph.free, evaluate(box), evaluate, ctx)
		assert(not step.excluded, "Certified surface intersection graph was excluded")
		if not step.box then
			break
		end
		local progress = width(step.box, graph.dependent) < width(box, graph.dependent) * 0.9
		if range[1] == range[2] then
			for _, axis in graph.dependent do
				progress = progress or I.width(step.box[axis]) < I.width(box[axis]) * 0.9
			end
		end
		box = step.box
		-- At a point, tightening any coordinate can improve the next Jacobian
		-- even when the widest coordinate has barely changed yet. Range boxes
		-- retain intrinsic widths, so avoid chasing their roundoff-level gains.
		if not progress then
			break
		end
	end
	return box
end
local function position(box, evaluate, origin)
	local data = evaluate(box)
	local bounds, coordinates = {}, {}
	for i, axis in { "X", "Y", "Z" } do
		local b = assert(I.intersect(data.a.box[i], data.b.box[i]), "Certified graph lost position enclosure")
		bounds[i] = I.add(b, { origin[axis], origin[axis] })
		if magnitude(bounds[i]) == math.huge then
			return nil
		end
		coordinates[i] = I.mid(bounds[i])
	end
	local p = Vector3.new(table.unpack(coordinates))
	if not U.vector(p) then
		return nil
	end
	local squared = { 0, 0 }
	for i, axis in { "X", "Y", "Z" } do
		squared = I.add(squared, I.square(I.sub(bounds[i], { p[axis], p[axis] })))
	end
	local parameters = {}
	for i, range in box do
		parameters[i] = I.mid(range)
	end
	return {
		position = p,
		positionBox = bounds,
		parameterBox = box,
		parameters = parameters,
		errorBound = I.sqrt({ 0, squared[2] })[2],
		certified = true,
	}
end
-- The original contraction bounds (I-C*J) on the whole isolating domain.
-- Thus g' = -C*F_t + (I-C*J)*g' has a validated Neumann-series bound.
local function tangent(graph, box, evaluate, ctx)
	local data, q, largest = evaluate(box), {}, 0
	local localStep = G.step(box, graph.free, data, evaluate, ctx)
	-- A new residual on the smaller sampling box improves the derivative bound.
	-- Inclusion is unnecessary here: existence came from the parent graph.
	local proof = localStep.norm and localStep.norm < graph.norm and localStep.inverse and localStep or graph
	for row = 1, 3 do
		local sum = { 0, 0 }
		for k = 1, 3 do
			sum = I.sub(sum, I.mul(I.new(proof.inverse[row][k]), data.j[k][graph.free]))
		end
		q[row], largest = sum, math.max(largest, magnitude(sum))
	end
	local bound = I.div({ 0, largest }, I.sub({ 1, 1 }, I.new(proof.norm)))[2]
	if bound == math.huge then
		return nil
	end
	local derivative = { { -bound, bound }, { -bound, bound }, { -bound, bound } }
	for _ = 1, 8 do
		local nextValues = {}
		for row = 1, 3 do
			local sum = q[row]
			for k = 1, 3 do
				sum = I.add(sum, I.mul(proof.residual[row][k], derivative[k]))
			end
			nextValues[row] =
				assert(I.intersect(derivative[row], sum), "Certified graph lost derivative enclosure")
		end
		derivative = nextValues
	end
	local parameters = { [graph.free] = { 1, 1 } }
	for i, axis in graph.dependent do
		parameters[axis] = derivative[i]
	end
	local world = {}
	for k = 1, 3 do
		local sum = { 0, 0 }
		for axis = 1, 2 do
			local d = I.div(
				I.sub(data.a.derivatives[axis][k], I.mul(data.a.box[k], data.a.derivatives[axis][4])),
				data.a.value[4]
			)
			sum = I.add(sum, I.mul(d, parameters[axis]))
		end
		world[k] = sum
	end
	ctx.visit(350)
	return world, parameters
end
function G.sample(graph, evaluate, origin, ctx, options)
	local samples, cache, segments = {}, {}, {}
	local range = graph.box[graph.free]
	local function endpoint(t)
		if cache[t] then
			return cache[t]
		end
		local box = G.refine(graph, { t, t }, evaluate, ctx, options.maxIterations)
		local p = position(box, evaluate, origin)
		if not p then
			return nil
		end
		p.parameter, p.parameterErrorBound = t, 0
		for i = 1, 4 do
			local delta = I.sub(box[i], I.new(p.parameters[i]))
			p.parameterErrorBound = math.max(p.parameterErrorBound, magnitude(delta))
		end
		p.accurate = p.errorBound <= options.tolerance
			and width(box, graph.dependent) <= options.parameterTolerance
		cache[t] = p
		return p
	end
	local stack = { { range = range, depth = 0 } }
	local complete, maximum = true, 0
	while #stack > 0 do
		ctx.check("sample")
		local node = table.remove(stack)
		local first, last = endpoint(node.range[1]), endpoint(node.range[2])
		if not first or not last then
			ctx.segments -= #segments
			return { certified = true, accurate = false, reason = "precision", samples = {}, segments = {} }
		end
		local box = G.refine(graph, node.range, evaluate, ctx, options.maxIterations)
		local derivative, parameterDerivative = tangent(graph, box, evaluate, ctx)
		local bound = math.huge
		if derivative then
			local squared = { 0, 0 }
			local scale = I.mul(I.sub(I.new(node.range[2]), I.new(node.range[1])), { 0.25, 0.25 })
			for axis = 1, 3 do
				local error = I.mul(scale, { 0, I.width(derivative[axis]) })
				squared = I.add(squared, I.square(error))
			end
			bound = I.add(I.sqrt({ 0, squared[2] }), I.new(math.max(first.errorBound, last.errorBound)))[2]
		end
		local accurate = first.accurate and last.accurate and bound <= options.tolerance
		local middle = I.mid(node.range)
		local reason
		if not accurate then
			if not first.accurate or not last.accurate then
				reason = "precision"
			elseif node.depth >= options.maxDepth then
				reason = "depth"
			elseif ctx.segments + #stack + 2 > options.maxSegments then
				reason = "segments"
			elseif middle <= node.range[1] or middle >= node.range[2] then
				reason = "precision"
			else
				table.insert(stack, { range = { middle, node.range[2] }, depth = node.depth + 1 })
				table.insert(stack, { range = { node.range[1], middle }, depth = node.depth + 1 })
				continue
			end
		end
		ctx.segments += 1
		maximum = math.max(maximum, bound)
		complete = complete and accurate
		if #samples == 0 then
			table.insert(samples, first)
		end
		table.insert(samples, last)
		table.insert(segments, {
			first = #samples - 1,
			last = #samples,
			parameterRange = node.range,
			parameterBox = box,
			tangentBox = derivative,
			parameterDerivativeBox = parameterDerivative,
			errorBound = bound,
			certified = true,
			accurate = accurate,
			reason = reason,
		})
	end
	return {
		certified = true,
		accurate = complete,
		samples = samples,
		segments = segments,
		errorBound = maximum,
	}
end
G.position = position
G.tangent = tangent
return G
