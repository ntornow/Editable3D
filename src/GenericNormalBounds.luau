-- Internal native enclosure for a direction in an ordered algebraic tower.
local I = require(script.Parent.DirectedInterval)
local U = require(script.Parent.Util)
return function(R, K, direction, bound, refine, tolerance, visit)
	local P = require(script.Parent.ExactPolynomialRoots)(R, visit, 128)
	local B = require(script.Parent.ExactPolynomialBounds)(R, P, visit)
	local enclose = require(script.Parent.ExactRationalBounds)(R, visit)
	local axis = 1
	for i = 2, 3 do
		if K.compare(K.mul(direction[i], direction[i]), K.mul(direction[axis], direction[axis])) > 0 then
			axis = i
		end
	end
	assert(direction[axis].sign ~= 0)
	local denominator = direction[axis].sign > 0 and direction[axis] or K.neg(direction[axis])
	local scaled = {}
	for i, v in direction do
		scaled[i] = K.div(v, denominator)
	end
	local minus, one = R.number(-1), R.number(1)
	while true do
		visit(1)
		local boxes = {}
		local good = true
		for i, v in scaled do
			local b = bound(v)
			if not b then
				good = false
				break
			end
			b = B.intersect(b, { minus, one })
			local lo, hi = enclose(b[1]), enclose(b[2])
			boxes[i] = { lo[1], hi[2] }
			if not U.finite(boxes[i][1]) or not U.finite(boxes[i][2]) then
				good = false
				break
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
					local errorBound = I.sqrt(error)[2]
					if errorBound <= tolerance then
						return normal, errorBound
					end
				end
			end
		end
		if not refine() then
			return nil, nil, "normalPrecision"
		end
	end
end
