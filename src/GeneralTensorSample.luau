-- Internal outward native anchor enclosures for an exact algebraic tower sample.
local I = require(script.Parent.DirectedInterval)
local U = require(script.Parent.Util)
return function(prepared, cell)
	local data = prepared.data
	local R, B, ctx = data.R, data.B, data.ctx
	local enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local pairIndex = assert(prepared.owner(cell.originalSigns))
	local pair = prepared.pairs[pairIndex]
	local function bound(value, model)
		if not model.parent then
			return { value, value }
		end
		local parent = model.parent
		local range = model.value.bound(value, { parent.field.number(0), parent.field.number(1) })
		local low, high = bound(range[1], parent), bound(range[2], parent)
		return { low[1], high[2] }
	end
	local function evaluate(p, boxes)
		local out = { R.number(0), R.number(0) }
		for _, term in p do
			local value = { term.value, term.value }
			for axis, n in term.powers do
				for _ = 1, n do
					value = B.mul(value, boxes[axis])
				end
			end
			out = B.add(out, value)
		end
		return out
	end
	local function floating(range)
		return { enclose(range[1])[1], enclose(range[2])[2] }
	end
	local function calculate()
		local boxes = {}
		for axis, value in cell.values do
			boxes[axis] = bound(value, cell.model)
		end
		local output = {
			positionBox = {},
			parameterBox = {},
			parameters = {},
			parameterErrorBound = 0,
			certified = true,
			spanPair = pairIndex,
		}
		for original = 1, 4 do
			local box = B.intersect(boxes[prepared.inverseOrder[original]], data.bounds[original])
			local native = assert(I.intersect(floating(box), data.report.parameterBox[original]))
			output.parameterBox[original] = native
			output.parameters[original] = I.mid(native)
			local delta = I.sub(native, { I.mid(native), I.mid(native) })
			output.parameterErrorBound =
				math.max(output.parameterErrorBound, math.abs(delta[1]), math.abs(delta[2]))
		end
		local position
		for operand, index in { pair.a, pair.b } do
			local span = prepared.spans[operand][index]
			local h = {}
			for axis = 1, 4 do
				h[axis] = evaluate(span.h[axis], boxes)
			end
			h[4] = B.intersect(h[4], span.weightBounds)
			local p = {}
			for axis = 1, 3 do
				p[axis] = B.divide(h[axis], h[4])
			end
			if not position then
				position = p
			else
				for axis = 1, 3 do
					position[axis] = B.intersect(position[axis], p[axis])
				end
			end
		end
		local coordinates = {}
		for axis = 1, 3 do
			output.positionBox[axis] = floating(position[axis])
			coordinates[axis] = I.mid(output.positionBox[axis])
		end
		output.position = Vector3.new(table.unpack(coordinates))
		assert(U.vector(output.position), "General tensor native anchor is not finite")
		local square = { 0, 0 }
		for axis, name in { "X", "Y", "Z" } do
			square = I.add(
				square,
				I.square(I.sub(output.positionBox[axis], { output.position[name], output.position[name] }))
			)
		end
		square[1] = math.max(0, square[1])
		output.errorBound = I.sqrt(square)[2]
		output.accurate = output.errorBound <= data.limits.tolerance
			and output.parameterErrorBound <= data.limits.parameterTolerance
		return output
	end
	local out = calculate()
	for _ = 1, data.limits.iterations do
		if out.accurate then
			break
		end
		local model = cell.model
		local changed = false
		while model.parent do
			changed = model.value.refine() or changed
			model = model.parent
		end
		if not changed then
			break
		end
		out = calculate()
	end
	return out
end
