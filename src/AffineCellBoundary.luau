-- Exact ordered boundary of a convex point set of affine dimension at most two.
-- Higher dimensional polytopes retain their full vertex representation.
return function(points, dimension, R, visit)
	if dimension < 0 then
		return {}, {}
	end
	if dimension > 2 then
		return nil
	end
	if dimension == 0 then
		return { 1 }, {}
	end
	local x, y
	for axis = 1, #points[1] do
		for i = 2, #points do
			if not R.equal(points[i][axis], points[1][axis]) then
				x = axis
				break
			end
		end
		if x then
			break
		end
	end
	assert(x, "Nonconstant affine coordinate missing")
	local function cross(a, b, c, second)
		return R.sub(
			R.mul(R.sub(b[x], a[x]), R.sub(c[second], a[second])),
			R.mul(R.sub(b[second], a[second]), R.sub(c[x], a[x]))
		)
	end
	if dimension == 2 then
		for axis = 1, #points[1] do
			if axis == x then
				continue
			end
			for i = 2, #points do
				for j = i + 1, #points do
					if cross(points[1], points[i], points[j], axis).sign ~= 0 then
						y = axis
						break
					end
				end
				if y then
					break
				end
			end
			if y then
				break
			end
		end
		assert(y, "Independent affine projection missing")
	end
	local order = {}
	for i = 1, #points do
		order[i] = i
	end
	table.sort(order, function(i, j)
		visit(1)
		local first = R.compare(points[i][x], points[j][x])
		if first ~= 0 then
			return first < 0
		end
		if y then
			local second = R.compare(points[i][y], points[j][y])
			if second ~= 0 then
				return second < 0
			end
		end
		return i < j
	end)
	if dimension == 1 then
		return { order[1], order[#order] }, { x }
	end
	local unique = {}
	for _, index in order do
		local previous = unique[#unique]
		if
			not previous
			or not R.equal(points[index][x], points[previous][x])
			or not R.equal(points[index][y], points[previous][y])
		then
			table.insert(unique, index)
		end
	end
	local function half(first, last, step)
		local out = {}
		for i = first, last, step do
			local index = unique[i]
			while #out >= 2 and cross(points[out[#out - 1]], points[out[#out]], points[index], y).sign <= 0 do
				table.remove(out)
			end
			table.insert(out, index)
		end
		table.remove(out)
		return out
	end
	local boundary = half(1, #unique, 1)
	for _, index in half(#unique, 1, -1) do
		table.insert(boundary, index)
	end
	return boundary, { x, y }
end
