-- Cancel unobservable poles using the exact vector resolvent numerator.
return function(R, P, polynomial, powers, visit)
	local common = polynomial
	local degree = #polynomial - 1
	assert(#powers >= degree)
	for axis in powers[1] or {} do
		local numerator = {}
		for k = 1, degree do
			if powers[k][axis].sign ~= 0 then
				local q = {}
				for j = k + 1, #polynomial do
					q[#q + 1] = polynomial[j]
				end
				numerator = P.add(numerator, P.scale(q, powers[k][axis]))
			end
		end
		visit(1)
		common = P.gcd(common, numerator)
		if #common == 1 then
			break
		end
	end
	local quotient, remainder = P.divide(polynomial, common)
	assert(#remainder == 0, "Observed recurrence pole cancellation failed")
	return quotient, common
end
