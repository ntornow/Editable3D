-- Original raw knots to exact basis powers on every positive knot span.
return function(source, degree, count, R, P, ctx)
	local knots = {}
	ctx.allocate(#source)
	for i, value in source do
		knots[i] = R.number(value)
	end
	local one = R.number(1)
	local start, width = knots[degree + 1], R.sub(knots[count + 1], knots[degree + 1])
	local spans = {}
	for span = degree + 1, count do
		if source[span] >= source[span + 1] then
			continue
		end
		assert(#spans < ctx.maxPieces, "Exact spline span budget exceeded")
		local lo, delta = knots[span], R.sub(knots[span + 1], knots[span])
		local previous = { [span] = { one } }
		for d = 1, degree do
			local nextValues = {}
			for i = span - d, span do
				local value = {}
				local a, b = previous[i], previous[i + 1]
				if a then
					local denominator = R.sub(knots[i + d], knots[i])
					if denominator.sign ~= 0 then
						value = P.product(
							a,
							{ R.div(R.sub(lo, knots[i]), denominator), R.div(delta, denominator) }
						)
					end
				end
				if b then
					local denominator = R.sub(knots[i + d + 1], knots[i + 1])
					if denominator.sign ~= 0 then
						value = P.add(
							value,
							P.product(b, {
								R.div(R.sub(knots[i + d + 1], lo), denominator),
								R.neg(R.div(delta, denominator)),
							})
						)
					end
				end
				nextValues[i] = value
			end
			previous = nextValues
		end
		table.insert(spans, {
			index = span,
			basis = previous,
			offset = R.div(R.sub(lo, start), width),
			scale = R.div(delta, width),
		})
		ctx.visit(1)
	end
	return spans
end
