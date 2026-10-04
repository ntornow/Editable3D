-- Homogeneous plane equation and inverse affine U/V coordinate forms.
return function(s, R)
	assert(
		s.degreeU == 1 and s.degreeV == 1 and #s.control == 2 and #s.control[1] == 2,
		"Exact plane contacts require a degree-one 2x2 affine second patch"
	)
	for _, row in s.weights do
		for _, w in row do
			assert(w == s.weights[1][1], "Affine second patch requires constant weights")
		end
	end
	local zero, one = R.number(0), R.number(1)
	local origin, u, v = {}, {}, {}
	for axis, name in { "X", "Y", "Z" } do
		local a, b, c, d =
			R.number(s.control[1][1][name]),
			R.number(s.control[2][1][name]),
			R.number(s.control[1][2][name]),
			R.number(s.control[2][2][name])
		assert(R.equal(R.add(a, d), R.add(b, c)), "Second patch controls do not form an exact parallelogram")
		origin[axis], u[axis], v[axis] = a, R.sub(b, a), R.sub(c, a)
	end
	local plane = {
		R.sub(R.mul(u[2], v[3]), R.mul(u[3], v[2])),
		R.sub(R.mul(u[3], v[1]), R.mul(u[1], v[3])),
		R.sub(R.mul(u[1], v[2]), R.mul(u[2], v[1])),
		zero,
	}
	local uf, vf = { zero, zero, zero, zero }, { zero, zero, zero, zero }
	local found = false
	for _, axes in { { 1, 2 }, { 1, 3 }, { 2, 3 } } do
		local a, b = axes[1], axes[2]
		local determinant = R.sub(R.mul(u[a], v[b]), R.mul(u[b], v[a]))
		if determinant.sign ~= 0 then
			local inv = R.div(one, determinant)
			uf[a], uf[b] = R.mul(v[b], inv), R.neg(R.mul(v[a], inv))
			vf[a], vf[b] = R.neg(R.mul(u[b], inv)), R.mul(u[a], inv)
			found = true
			break
		end
	end
	assert(found, "Affine second patch must have rank two")
	for _, form in { plane, uf, vf } do
		for axis = 1, 3 do
			form[4] = R.sub(form[4], R.mul(form[axis], origin[axis]))
		end
	end
	return { plane = plane, u = uf, v = vf }
end
