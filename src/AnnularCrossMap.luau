-- Linear Bernstein cross-product extraction on a scalar invariant subspace.
return function(R, P, masks, basis, sector, visit, allocate)
	local zero = R.number(0)
	local dimension = #basis
	local pairs = {}
	for i = 1, dimension - 1 do
		for j = i + 1, dimension do
			pairs[#pairs + 1] = { i, j }
		end
	end
	if allocate then
		allocate(108 * #pairs + 72 * dimension)
	end
	local function compose(row)
		local out = {}
		for i, b in basis do
			local x = zero
			for j, w in row do
				x = R.add(x, R.mul(w, b.value[j]))
			end
			out[i] = x
		end
		return out
	end
	local choose = { { 1 }, { 1, 1 }, { 1, 2, 1 }, { 1, 3, 3, 1 }, { 1, 4, 6, 4, 1 }, { 1, 5, 10, 10, 5, 1 } }
	local rows = {}
	for _, patch in masks.patches do
		if patch.sector ~= sector then
			continue
		end
		local du, dv = {}, {}
		for i = 1, 3 do
			du[i] = {}
			for j = 1, 4 do
				du[i][j] = compose(patch.du[i][j])
			end
		end
		for i = 1, 4 do
			dv[i] = {}
			for j = 1, 3 do
				dv[i][j] = compose(patch.dv[i][j])
			end
		end
		local result = {}
		for i = 1, 6 do
			result[i] = {}
			for j = 1, 6 do
				result[i][j] = table.create(#pairs, zero)
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
						local u, v = du[i + 1][j + 1], dv[k + 1][l + 1]
						local sum = result[i + k + 1][j + l + 1]
						for t, pair in pairs do
							local a, b = pair[1], pair[2]
							sum[t] = R.add(sum[t], R.mul(weight, R.sub(R.mul(u[a], v[b]), R.mul(u[b], v[a]))))
						end
					end
				end
			end
		end
		for i = 1, 6 do
			for j = 1, 6 do
				rows[#rows + 1] = result[i][j]
			end
		end
	end
	assert(#rows == 108)
	local function apply(values)
		local out = {}
		for _, row in rows do
			for axis = 1, 3 do
				local value = {}
				for i, w in row do
					if w.sign ~= 0 then
						value = P.add(value, P.scale(values[(i - 1) * 3 + axis], w))
					end
				end
				out[#out + 1] = value
			end
		end
		return out
	end
	return apply, rows
end
