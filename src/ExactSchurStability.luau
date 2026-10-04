-- Exact real Schur-Cohn reflection recursion; coefficients are ascending.
return function(R, polynomial, visit)
	local p = table.clone(polynomial)
	local reflections = {}
	while #p > 1 do
		visit(1)
		local constant, leading = p[1], p[#p]
		assert(leading.sign ~= 0, "Schur polynomial has zero leading coefficient")
		local reflection = R.div(constant, leading)
		reflections[#reflections + 1] = reflection
		if R.compare(R.mul(constant, constant), R.mul(leading, leading)) >= 0 then
			return false, reflections, #p - 1
		end
		local next = {}
		-- Division by the positive leading scale preserves the roots and limits growth.
		local denominator = R.sub(R.mul(leading, leading), R.mul(constant, constant))
		for i = 2, #p do
			visit(1)
			next[i - 1] = R.div(R.sub(R.mul(leading, p[i]), R.mul(constant, p[#p - i + 1])), denominator)
		end
		assert(R.equal(next[#next], R.number(1)))
		p = next
	end
	return true, reflections
end
