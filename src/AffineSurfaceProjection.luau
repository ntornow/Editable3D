-- Certify when one degree-one patch has a unique affine correspondence for every
-- point on the other control hull, strictly inside its requested parameter box.
local I = require(script.Parent.DirectedInterval)
local X = require(script.Parent.ExpansionArithmetic)
return function(a, b, initial, ctx)
	local function candidate(plane, other, offset)
		if plane.degreeU ~= 1 or plane.degreeV ~= 1 or #plane.control ~= 2 or #plane.control[1] ~= 2 then
			return nil
		end
		local weight = plane.weights[1][1]
		for _, row in plane.weights do
			for _, value in row do
				if value ~= weight then
					return nil
				end
			end
		end
		local p, q, r, s = plane.control[1][1], plane.control[2][1], plane.control[1][2], plane.control[2][2]
		for _, axis in { "X", "Y", "Z" } do
			-- All operands are native Float32 coordinates. Expansion sums decide
			-- the parallelogram identity exactly, without a planarity tolerance.
			if X.sign(X.subtract(X.add({ p[axis] }, { s[axis] }), X.add({ q[axis] }, { r[axis] }))) ~= 0 then
				return nil
			end
		end
		ctx.visit(100)
		for _, axes in { { "X", "Y" }, { "X", "Z" }, { "Y", "Z" } } do
			local du, dv = {}, {}
			for i, axis in axes do
				du[i] = I.sub(I.new(q[axis]), I.new(p[axis]))
				dv[i] = I.sub(I.new(r[axis]), I.new(p[axis]))
			end
			local determinant = I.sub(I.mul(du[1], dv[2]), I.mul(du[2], dv[1]))
			if I.zero(determinant) then
				continue
			end
			local bounds, inside = {}, true
			for _, row in other.control do
				for _, point in row do
					local x = I.sub(I.new(point[axes[1]]), I.new(p[axes[1]]))
					local y = I.sub(I.new(point[axes[2]]), I.new(p[axes[2]]))
					local values = {
						I.div(I.sub(I.mul(x, dv[2]), I.mul(y, dv[1])), determinant),
						I.div(I.sub(I.mul(du[1], y), I.mul(du[2], x)), determinant),
					}
					for i, range in values do
						bounds[i] = bounds[i] and I.hull(bounds[i], range) or range
						inside = inside
							and range[1] > initial[offset + i][1]
							and range[2] < initial[offset + i][2]
					end
					ctx.visit(24)
				end
			end
			if inside then
				return {
					surface = offset == 0 and "A" or "B",
					fixedAxes = { offset + 1, offset + 2 },
					searchAxes = offset == 0 and { 3, 4 } or { 1, 2 },
					projectedParameterBox = bounds,
					certified = true,
				}
			end
		end
		return nil
	end
	return candidate(b.source, a.source, 2) or candidate(a.source, b.source, 0)
end
