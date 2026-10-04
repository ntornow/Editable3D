-- Native anchors with rational enclosures for a nested algebraic parameter pair.
local I = require(script.Parent.DirectedInterval)
local U = require(script.Parent.Util)
return function(span, event, point, data)
	local R, P, B = data.R, data.P, data.B
	local root, lift = event.root, event.lift
	local tRoot = point.root
	local function floatRange(range)
		return { data.enclose(range[1])[1], data.enclose(range[2])[2] }
	end
	local function evaluate(p, s, t)
		local out = { R.number(0), R.number(0) }
		for i = #p, 1, -1 do
			out = B.add(B.mul(out, t), B.evaluate(p[i], s))
		end
		return out
	end
	local function calculate()
		local s = { root.low, root.high }
		local t = { lift.asRational(tRoot.low), lift.asRational(tRoot.high) }
		local h = {}
		for axis = 1, 4 do
			h[axis] = evaluate(span.h[axis], s, t)
		end
		h[4] = B.intersect(h[4], span.weightBounds)
		local positions = {}
		for axis = 1, 3 do
			positions[axis] = B.divide(h[axis], h[4])
		end
		local parameters = {}
		for axis, range in { s, t } do
			parameters[axis] = {
				R.add(span.offset[axis], R.mul(span.scale[axis], range[1])),
				R.add(span.offset[axis], R.mul(span.scale[axis], range[2])),
			}
		end
		parameters[3], parameters[4] =
			B.divide(evaluate(span.u, s, t), h[4]), B.divide(evaluate(span.v, s, t), h[4])
		local out = {
			positionBox = {},
			parameterBox = {},
			parameters = {},
			parameterErrorBound = 0,
			certified = true,
		}
		for axis, range in parameters do
			range = B.intersect(range, data.bounds[axis])
			local box = assert(I.intersect(floatRange(range), data.report.parameterBox[axis]))
			out.parameterBox[axis], out.parameters[axis] = box, I.mid(box)
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
		assert(U.vector(out.position), "Exact tensor native anchor is not finite")
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
		if root.exact and tRoot.exact then
			out.parametersExact, out.positionExact = {}, {}
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
		if out.accurate then
			break
		end
		local changed = false
		if not root.exact and root.depth < data.isolation.maxDepth then
			P.refine(root.analysis, root, data.isolation)
			changed = true
		end
		if not tRoot.exact and tRoot.depth < lift.isolation.maxDepth then
			lift.polynomial.refine(tRoot.analysis, tRoot, lift.isolation)
			changed = true
		end
		if not changed then
			break
		end
		out = calculate()
	end
	return out
end
