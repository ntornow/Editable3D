-- Private interval Krawczyk operator. An arbitrary numerical inverse is validated
-- by the outward-rounded residual matrix and the contraction inclusion test.
local I = require(script.Parent.DirectedInterval)
local function inverse(jacobian, ctx)
	local a = {}
	for i = 1, 3 do
		a[i] = {}
		local scale = 0
		for j = 1, 3 do
			local x = jacobian[i][j]
			if math.abs(x[1]) == math.huge or math.abs(x[2]) == math.huge then
				return nil
			end
			a[i][j] = I.mid(x)
			scale = math.max(scale, math.abs(a[i][j]))
		end
		if scale == 0 then
			return nil
		end
		for j = 1, 3 do
			a[i][j] /= scale
			a[i][j + 3] = (i == j and 1 or 0) / scale
		end
	end
	for column = 1, 3 do
		local pivot = column
		for row = column + 1, 3 do
			if math.abs(a[row][column]) > math.abs(a[pivot][column]) then
				pivot = row
			end
		end
		if math.abs(a[pivot][column]) < 1e-14 then
			return nil
		end
		a[column], a[pivot] = a[pivot], a[column]
		local divisor = a[column][column]
		for j = 1, 6 do
			a[column][j] /= divisor
		end
		for row = 1, 3 do
			if row ~= column then
				local factor = a[row][column]
				for j = 1, 6 do
					a[row][j] -= factor * a[column][j]
				end
			end
		end
	end
	local out = {}
	for i = 1, 3 do
		out[i] = {}
		for j = 1, 3 do
			local x = a[i][j + 3]
			if x ~= x or math.abs(x) == math.huge then
				return nil
			end
			out[i][j] = x
		end
	end
	ctx.visit(150)
	return out
end
return function(box, jacobian, evaluate, ctx)
	local c = inverse(jacobian, ctx)
	if not c then
		return { singular = true }
	end
	local middle, point = {}, {}
	for i = 1, 3 do
		middle[i] = I.mid(box[i])
		point[i] = { middle[i], middle[i] }
	end
	local value = evaluate(point).f
	local krawczyk, residual, norm = {}, {}, 0
	for i = 1, 3 do
		residual[i] = {}
		local center = { middle[i], middle[i] }
		for j = 1, 3 do
			center = I.sub(center, I.mul({ c[i][j], c[i][j] }, value[j]))
		end
		local rowNorm = 0
		for j = 1, 3 do
			local r = I.new(i == j and 1 or 0)
			for k = 1, 3 do
				r = I.sub(r, I.mul({ c[i][k], c[i][k] }, jacobian[k][j]))
			end
			rowNorm = I.up(rowNorm + math.max(math.abs(r[1]), math.abs(r[2])))
			residual[i][j] = r
			center = I.add(center, I.mul(r, I.sub(box[j], { middle[j], middle[j] })))
		end
		norm = math.max(norm, rowNorm)
		krawczyk[i] = center
	end
	ctx.visit(200)
	local clipped, contained = {}, true
	for i = 1, 3 do
		clipped[i] = I.intersect(box[i], krawczyk[i])
		if not clipped[i] then
			return { excluded = true, norm = norm }
		end
		contained = contained and krawczyk[i][1] >= box[i][1] and krawczyk[i][2] <= box[i][2]
	end
	return {
		box = clipped,
		image = krawczyk,
		unique = norm < 1 and contained,
		norm = norm,
		inverse = c,
		residual = residual,
	}
end
