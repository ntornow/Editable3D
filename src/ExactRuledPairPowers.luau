-- original-knot homogeneous endpoint curves for one restricted ruling.
local N = require(script.Parent.NURBS)
local C = require(script.Parent.Cyclic)
local extract = require(script.Parent.ExactCurvePower)
return function(source, requestedAxis, bounds, data)
	local R, P, ctx = data.R, data.P, data.ctx
	assert(source.kind == "surface" or source.kind == "cyclicSurface", "Rational ruled surface required")
	source.maxControls = data.limits.maxControls
	local a = source.kind == "cyclicSurface"
			and C.surfaceToNURBS(C.surface(source.control, source.degreeU, source.degreeV, source))
		or N.surface(source.control, source.degreeU, source.degreeV, source)
	local eligibleU, eligibleV = a.degreeU == 1 and #a.control == 2, a.degreeV == 1 and #a.control[1] == 2
	assert(requestedAxis == nil or requestedAxis == "U" or requestedAxis == "V", "Ruled axis must be U or V")
	local axis = requestedAxis and (requestedAxis == "U" and 1 or 2) or (eligibleV and 2 or 1)
	assert(
		axis == 1 and eligibleU or axis == 2 and eligibleV,
		"Ruled direction needs degree one and two controls"
	)
	local profile = 3 - axis
	local sides = {}
	for side = 1, 2 do
		local points, weights = {}, {}
		local count = profile == 1 and #a.control or #a.control[1]
		for i = 1, count do
			local u, v = profile == 1 and i or side, profile == 1 and side or i
			points[i], weights[i] = a.control[u][v], a.weights[u][v]
		end
		sides[side] = extract(
			N.curve(points, profile == 1 and a.degreeU or a.degreeV, {
				weights = weights,
				knots = profile == 1 and a.knotsU or a.knotsV,
				clamped = if profile == 1 then a.clampedU else a.clampedV,
				maxControls = data.limits.maxControls,
			}),
			R,
			P,
			ctx
		)
	end
	local one = R.number(1)
	local spans = {}
	for index, first in sides[1] do
		local second = sides[2][index]
		assert(R.equal(first.offset, second.offset) and R.equal(first.scale, second.scale))
		local endpoints = {}
		for side = 1, 2 do
			local t = bounds[axis][side]
			local h = {}
			for coordinate = 1, 4 do
				h[coordinate] =
					P.add(P.scale(first.h[coordinate], R.sub(one, t)), P.scale(second.h[coordinate], t))
			end
			endpoints[side] = h
		end
		spans[index] = {
			index = index,
			knotSpan = first.index,
			offset = first.offset,
			scale = first.scale,
			endpoints = endpoints,
			parameterRange = bounds[axis],
			weightBounds = {
				R.compare(first.weightBounds[1], second.weightBounds[1]) < 0 and first.weightBounds[1]
					or second.weightBounds[1],
				R.compare(first.weightBounds[2], second.weightBounds[2]) > 0 and first.weightBounds[2]
					or second.weightBounds[2],
			},
		}
	end
	local positionBounds = {}
	for coordinate, name in { "X", "Y", "Z" } do
		local low, high
		for _, row in a.control do
			for _, point in row do
				local value = R.number(point[name])
				if not low or R.compare(value, low) < 0 then
					low = value
				end
				if not high or R.compare(value, high) > 0 then
					high = value
				end
			end
		end
		positionBounds[coordinate] = { low, high }
	end
	return {
		spans = spans,
		linearAxis = axis,
		profileAxis = profile,
		ordinary = a,
		positionBounds = positionBounds,
	}
end
