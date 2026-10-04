-- Native anchors enclose the exact source surface at algebraic cell events.
local I = require(script.Parent.DirectedInterval)
local U = require(script.Parent.Util)
return function(span, F, tValue, data, linearAxis)
	local R, B = data.R, data.B
	local bounds, initial = data.bounds, data.report.parameterBox
	local enclose = data.enclose
	local profileAxis = 3 - linearAxis
	local function floatRange(range)
		return { enclose(range[1])[1], enclose(range[2])[2] }
	end
	local function calculate()
		local s = { F.root.low, F.root.high }
		local t = F.bound(tValue, bounds[linearAxis])
		local function evaluate(a, b)
			return B.add(B.evaluate(a, s), B.mul(t, B.evaluate(b, s)))
		end
		local h = {}
		for axis = 1, 4 do
			h[axis] = evaluate(span.a[axis], span.b[axis])
		end
		h[4] = B.intersect(h[4], span.weightBounds)
		local positions = {}
		for axis = 1, 3 do
			positions[axis] = B.divide(h[axis], h[4])
		end
		local parameters = {}
		parameters[profileAxis] =
			{ R.add(span.offset, R.mul(span.scale, s[1])), R.add(span.offset, R.mul(span.scale, s[2])) }
		parameters[linearAxis] = t
		parameters[3] = B.divide(evaluate(span.u[1], span.u[2]), h[4])
		parameters[4] = B.divide(evaluate(span.v[1], span.v[2]), h[4])
		local out = {
			positionBox = {},
			parameterBox = {},
			parameters = {},
			parameterErrorBound = 0,
			certified = true,
		}
		for i, range in parameters do
			range = B.intersect(range, bounds[i])
			local box = assert(I.intersect(floatRange(range), initial[i]))
			out.parameterBox[i], out.parameters[i] = box, I.mid(box)
			local delta = I.sub(box, { I.mid(box), I.mid(box) })
			out.parameterErrorBound =
				math.max(out.parameterErrorBound, math.abs(delta[1]), math.abs(delta[2]))
		end
		local coordinates = {}
		for axis, range in positions do
			out.positionBox[axis] = floatRange(range)
			coordinates[axis] = I.mid(out.positionBox[axis])
		end
		out.position = Vector3.new(table.unpack(coordinates))
		assert(U.vector(out.position), "Exact ruled native anchor is not finite")
		local square = { 0, 0 }
		for axis, name in { "X", "Y", "Z" } do
			square = I.add(
				square,
				I.square(I.sub(out.positionBox[axis], { out.position[name], out.position[name] }))
			)
		end
		square[1] = math.max(0, square[1])
		out.errorBound = I.sqrt(square)[2]
		out.accurate = out.errorBound <= data.limits.tolerance
			and out.parameterErrorBound <= data.limits.parameterTolerance
		if F.root.exact then
			out.parametersExact = {}
			out.positionExact = {}
			for i, range in parameters do
				assert(R.equal(range[1], range[2]))
				out.parametersExact[i] = range[1]
			end
			for i, range in positions do
				assert(R.equal(range[1], range[2]))
				out.positionExact[i] = range[1]
			end
		end
		return out
	end
	local out = calculate()
	for _ = 1, data.limits.iterations do
		if out.accurate or not F.refine() then
			break
		end
		out = calculate()
	end
	return out
end
