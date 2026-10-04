-- Convert a proved algebraic direction to a native unit normal with an enclosure.
local I = require(script.Parent.DirectedInterval)
local U = require(script.Parent.Util)
return function(R, P, F, direction, tolerance, visit)
	local one, minus = R.number(1), R.number(-1)
	if F.reduce then
		direction = { F.reduce(direction[1]), F.reduce(direction[2]), F.reduce(direction[3]) }
	end
	local axis = 1
	for i = 2, 3 do
		local difference = P.add(
			P.product(direction[i], direction[i]),
			P.scale(P.product(direction[axis], direction[axis]), minus)
		)
		if F.sign(difference) > 0 then
			axis = i
		end
	end
	local sign = F.sign(direction[axis])
	assert(sign ~= 0, "Nonzero algebraic direction required")
	local denominator = sign > 0 and direction[axis] or P.scale(direction[axis], minus)
	local B = require(script.Parent.ExactPolynomialBounds)(R, P, visit)
	local enclose = require(script.Parent.ExactRationalBounds)(R, visit)
	while true do
		visit(1)
		local range = { F.root.low, F.root.high }
		local d = B.evaluate(denominator, range)
		if d[1].sign > 0 then
			local boxes = {}
			local good = true
			for i = 1, 3 do
				local b = B.intersect(B.divide(B.evaluate(direction[i], range), d), { minus, one })
				local lo, hi = enclose(b[1]), enclose(b[2])
				boxes[i] = { lo[1], hi[2] }
				if not U.finite(boxes[i][1]) or not U.finite(boxes[i][2]) then
					good = false
				end
			end
			if good then
				local length = { 0, 0 }
				for i = 1, 3 do
					local a, b = boxes[i][1], boxes[i][2]
					local low = a <= 0 and b >= 0 and 0 or math.min(a * a, b * b)
					local high = math.max(a * a, b * b)
					length = I.add(length, { math.max(0, I.down(low)), I.up(high) })
				end
				length = I.sqrt(length)
				if length[1] > 0 then
					local unit = {}
					local mid = {}
					for i = 1, 3 do
						unit[i] = I.div(boxes[i], length)
						mid[i] = unit[i][1] / 2 + unit[i][2] / 2
					end
					local magnitude = math.sqrt(mid[1] ^ 2 + mid[2] ^ 2 + mid[3] ^ 2)
					if magnitude > 0 then
						local normal = Vector3.new(mid[1] / magnitude, mid[2] / magnitude, mid[3] / magnitude)
						local native = { normal.X, normal.Y, normal.Z }
						local error = { 0, 0 }
						for i = 1, 3 do
							local radius = math.max(
								I.sub({ native[i], native[i] }, { unit[i][1], unit[i][1] })[2],
								I.sub({ unit[i][2], unit[i][2] }, { native[i], native[i] })[2]
							)
							error = I.add(error, I.mul({ radius, radius }, { radius, radius }))
						end
						local bound = I.sqrt(error)[2]
						if bound <= tolerance then
							return normal, bound
						end
					end
				end
			end
		end
		if not F.refine() then
			return nil, nil, "normalPrecision"
		end
	end
end
