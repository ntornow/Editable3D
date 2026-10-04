-- Exact Bernstein derivative-cross coefficients on selected fundamental annuli.
return function(R, masks, points, sector, visit)
	local zero = R.number(0)
	local function vector(row)
		local out = { zero, zero, zero }
		for i, x in row do
			for axis = 1, 3 do
				out[axis] = R.add(out[axis], R.mul(x, points[i][axis]))
			end
		end
		return out
	end
	local function cross(a, b)
		return {
			R.sub(R.mul(a[2], b[3]), R.mul(a[3], b[2])),
			R.sub(R.mul(a[3], b[1]), R.mul(a[1], b[3])),
			R.sub(R.mul(a[1], b[2]), R.mul(a[2], b[1])),
		}
	end
	local choose = { { 1 }, { 1, 1 }, { 1, 2, 1 }, { 1, 3, 3, 1 }, { 1, 4, 6, 4, 1 }, { 1, 5, 10, 10, 5, 1 } }
	local out = {}
	for _, patch in masks.patches do
		if patch.sector ~= sector then
			continue
		end
		local du, dv = {}, {}
		for i = 1, 3 do
			du[i] = {}
			for j = 1, 4 do
				du[i][j] = vector(patch.du[i][j])
			end
		end
		for i = 1, 4 do
			dv[i] = {}
			for j = 1, 3 do
				dv[i][j] = vector(patch.dv[i][j])
			end
		end
		local result = {}
		for i = 1, 6 do
			result[i] = {}
			for j = 1, 6 do
				result[i][j] = { zero, zero, zero }
			end
		end
		for i = 0, 2 do
			for j = 0, 3 do
				for k = 0, 3 do
					for l = 0, 2 do
						visit(1)
						local weight = R.div(
							R.number(
								choose[3][i + 1] * choose[4][k + 1] * choose[4][j + 1] * choose[3][l + 1]
							),
							R.number(choose[6][i + k + 1] * choose[6][j + l + 1])
						)
						local value = cross(du[i + 1][j + 1], dv[k + 1][l + 1])
						local sum = result[i + k + 1][j + l + 1]
						for axis = 1, 3 do
							sum[axis] = R.add(sum[axis], R.mul(weight, value[axis]))
						end
					end
				end
			end
		end
		for i = 1, 6 do
			for j = 1, 6 do
				for axis = 1, 3 do
					out[#out + 1] = result[i][j][axis]
				end
			end
		end
	end
	assert(#out == 324, "Expected three bidegree-five annular cross products")
	return out
end
