-- Exact homogeneous tensor powers from the original stored control lattice.
local basisPower = require(script.Parent.ExactSplineBasisPower)
return function(source, R, P, ctx)
	local us = basisPower(source.knotsU, source.degreeU, #source.control, R, P, ctx)
	local vs = basisPower(source.knotsV, source.degreeV, #source.control[1], R, P, ctx)
	assert(#us * #vs <= ctx.maxPieces, "Exact surface span budget exceeded")
	local controls = {}
	ctx.allocate(4 * #source.control * #source.control[1])
	for i, row in source.control do
		controls[i] = {}
		for j, point in row do
			local weight = R.number(source.weights[i][j])
			controls[i][j] = {
				R.mul(R.number(point.X), weight),
				R.mul(R.number(point.Y), weight),
				R.mul(R.number(point.Z), weight),
				weight,
			}
		end
	end
	local spans = {}
	for iu, u in us do
		for iv, v in vs do
			local h = { {}, {}, {}, {} }
			local minWeight, maxWeight
			for i, bu in u.basis do
				for j, bv in v.basis do
					local control = controls[i][j]
					if not minWeight or R.compare(control[4], minWeight) < 0 then
						minWeight = control[4]
					end
					if not maxWeight or R.compare(control[4], maxWeight) > 0 then
						maxWeight = control[4]
					end
					for axis = 1, 4 do
						for power, value in bv do
							h[axis][power] =
								P.add(h[axis][power] or {}, P.scale(bu, R.mul(value, control[axis])))
						end
					end
				end
			end
			for _, p in h do
				while #p > 0 and #p[#p] == 0 do
					table.remove(p)
				end
			end
			table.insert(spans, {
				index = #spans + 1,
				indices = { iu, iv },
				knotSpans = { u.index, v.index },
				h = h,
				offset = { u.offset, v.offset },
				scale = { u.scale, v.scale },
				weightBounds = { minWeight, maxWeight },
			})
			ctx.visit(1)
		end
	end
	return spans
end
