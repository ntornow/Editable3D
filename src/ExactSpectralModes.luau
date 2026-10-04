-- Internal full Jordan expansion of a vector sequence from its exact recurrence.
return function(R, polynomial, powers, ctx, options)
	local K, embed, roots, report = require(script.Parent.SplitRealSpectrum)(R, polynomial, ctx, options)
	local P = require(script.Parent.ExactPolynomialRoots)(K, ctx.visit, ctx.maxDegree or 128, ctx.allocate)
	local zero, one = K.number(0), K.number(1)
	local p = {}
	for i, q in polynomial do
		p[i] = embed(q)
	end
	local initial = {}
	for j, row in powers do
		initial[j] = {}
		for i, q in row do
			initial[j][i] = embed(q)
		end
	end
	local modes = {}
	for _, root in roots do
		local lambda, m = root.value, root.multiplicity
		if lambda.sign == 0 then
			continue
		end
		local linear = { K.neg(lambda), one }
		local q = p
		for _ = 1, m do
			q = P.quotient(q, linear)
		end
		local taylor = {}
		local derivative = q
		local factorial = one
		for j = 0, m - 1 do
			if j > 0 then
				derivative = P.derivative(derivative)
				factorial = K.mul(factorial, K.number(j))
			end
			taylor[j + 1] = K.div(P.evaluate(derivative, lambda), factorial)
		end
		local inverse = { K.div(one, taylor[1]) }
		for j = 1, m - 1 do
			local sum = zero
			for i = 1, j do
				sum = K.add(sum, K.mul(taylor[i + 1], inverse[j - i + 1]))
			end
			inverse[j + 1] = K.neg(K.mul(inverse[1], sum))
		end
		local inversePolynomial = {}
		local power = { one }
		for _, coefficient in inverse do
			inversePolynomial = P.add(inversePolynomial, P.scale(power, coefficient))
			power = P.product(power, linear)
		end
		local projector = P.product(q, inversePolynomial)
		local generalized = projector
		local coefficients = {}
		for i in initial[1] do
			coefficients[i] = table.create(m, zero)
		end
		local binomial = { one }
		local lambdaPower = one
		for j = 0, m - 1 do
			for axis in initial[1] do
				local value = zero
				for k, coefficient in generalized do
					value = K.add(value, K.mul(coefficient, initial[k][axis]))
				end
				value = K.div(value, lambdaPower)
				for k, coefficient in binomial do
					coefficients[axis][k] = K.add(coefficients[axis][k], K.mul(value, coefficient))
				end
			end
			local _, nextGeneralized = P.divide(P.product(generalized, linear), p)
			generalized = nextGeneralized
			binomial = P.scale(P.product(binomial, { K.number(-j), one }), K.div(one, K.number(j + 1)))
			lambdaPower = K.mul(lambdaPower, lambda)
		end
		table.insert(modes, { base = lambda, coefficients = coefficients, multiplicity = m })
	end
	return K, embed, modes, report
end
