-- native bounds for a selected feasible Cramer fiber vertex.
local I = require(script.Parent.DirectedInterval)
local U = require(script.Parent.Util)
return function(span, profileRoot, lift, fiberRoot, case, data, first, second)
	local R, P, B = data.R, data.P, data.B
	local zero, one = R.number(0), R.number(1)
	local unit = { zero, one }
	local function floatRange(range)
		return { data.enclose(range[1])[1], data.enclose(range[2])[2] }
	end
	local function evaluate(p, s, t)
		local out = { zero, zero }
		for i = #p, 1, -1 do
			out = B.add(B.mul(out, t), B.evaluate(p[i], s))
		end
		return out
	end
	local function fraction(n, d)
		if d[1].sign <= 0 and d[2].sign >= 0 then
			return unit
		end
		if d[2].sign < 0 then
			n, d = B.neg(n), B.neg(d)
		end
		return B.intersect(B.divide(n, d), unit)
	end
	local function calculate()
		local s = { profileRoot.low, profileRoot.high }
		local t = { lift.asRational(fiberRoot.low), lift.asRational(fiberRoot.high) }
		local d = evaluate(case.determinant, s, t)
		local affine = { fraction(evaluate(case.alpha, s, t), d), fraction(evaluate(case.beta, s, t), d) }
		local parameters, positions = {}, {}
		for operand, range in { s, t } do
			local source = span.sources[operand]
			local info = operand == 1 and first or second
			local offset = (operand - 1) * 2
			parameters[offset + info.profileAxis] = {
				R.add(source.offset, R.mul(source.scale, range[1])),
				R.add(source.offset, R.mul(source.scale, range[2])),
			}
			local a = affine[operand]
			local complement = { R.sub(one, a[2]), R.sub(one, a[1]) }
			local h0, h1 = source.endpoints[1], source.endpoints[2]
			local w0 = B.intersect(B.evaluate(h0[4], range), source.weightBounds)
			local w1 = B.intersect(B.evaluate(h1[4], range), source.weightBounds)
			local inverseDenominator =
				B.intersect(B.add(B.mul(w1, complement), B.mul(w0, a)), source.weightBounds)
			local localParameter = B.intersect(B.divide(B.mul(w0, a), inverseDenominator), unit)
			local width = R.sub(source.parameterRange[2], source.parameterRange[1])
			parameters[offset + info.linearAxis] = {
				R.add(source.parameterRange[1], R.mul(width, localParameter[1])),
				R.add(source.parameterRange[1], R.mul(width, localParameter[2])),
			}
			if operand == 1 then
				for coordinate = 1, 3 do
					local x0 = B.divide(B.evaluate(h0[coordinate], range), w0)
					local x1 = B.divide(B.evaluate(h1[coordinate], range), w1)
					positions[coordinate] = B.intersect(
						B.add(B.mul(complement, x0), B.mul(a, x1)),
						first.positionBounds[coordinate]
					)
				end
			end
		end
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
			local error = I.sub(box, { I.mid(box), I.mid(box) })
			out.parameterErrorBound =
				math.max(out.parameterErrorBound, math.abs(error[1]), math.abs(error[2]))
		end
		local coordinates = {}
		for axis, range in positions do
			out.positionBox[axis] = floatRange(range)
			coordinates[axis] = I.mid(out.positionBox[axis])
		end
		out.position = Vector3.new(table.unpack(coordinates))
		assert(U.vector(out.position), "Ruled pair native anchor exceeds native range")
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
		if profileRoot.exact and fiberRoot.exact then
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
		if not profileRoot.exact and profileRoot.depth < data.isolation.maxDepth then
			P.refine(profileRoot.analysis, profileRoot, data.isolation)
			changed = true
		end
		if not fiberRoot.exact and fiberRoot.depth < lift.isolation.maxDepth then
			lift.polynomial.refine(fiberRoot.analysis, fiberRoot, lift.isolation)
			changed = true
		end
		if not changed then
			break
		end
		out = calculate()
	end
	return out
end
