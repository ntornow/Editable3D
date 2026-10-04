-- Original stored knots/controls to exact homogeneous powers on each raw span.
-- No rounded knot insertion or native Vector3 arithmetic enters coefficients.
return function(source, R, P, ctx)
	local one = R.number(1)
	local knots = {}
	ctx.allocate(#source.knots + 4 * #source.points)
	for i, value in source.knots do
		knots[i] = R.number(value)
	end
	local controls = {}
	for i, point in source.points do
		local weight = R.number(source.weights[i])
		controls[i] = {
			R.mul(R.number(point.X), weight),
			R.mul(R.number(point.Y), weight),
			R.mul(R.number(point.Z), weight),
			weight,
		}
	end
	local degree, count = source.degree, #source.points
	local start, width = knots[degree + 1], R.sub(knots[count + 1], knots[degree + 1])
	local spans = {}
	for span = degree + 1, count do
		if source.knots[span] >= source.knots[span + 1] then
			continue
		end
		assert(#spans < ctx.maxPieces, "Exact spline span budget exceeded")
		local lo, delta = knots[span], R.sub(knots[span + 1], knots[span])
		local previous = { [span] = { one } }
		for d = 1, degree do
			local nextValues = {}
			for i = span - d, span do
				local polynomial = {}
				local a, b = previous[i], previous[i + 1]
				if a then
					local den = R.sub(knots[i + d], knots[i])
					if den.sign ~= 0 then
						polynomial = P.product(a, { R.div(R.sub(lo, knots[i]), den), R.div(delta, den) })
					end
				end
				if b then
					local den = R.sub(knots[i + d + 1], knots[i + 1])
					if den.sign ~= 0 then
						polynomial = P.add(
							polynomial,
							P.product(
								b,
								{ R.div(R.sub(knots[i + d + 1], lo), den), R.neg(R.div(delta, den)) }
							)
						)
					end
				end
				nextValues[i] = polynomial
			end
			previous = nextValues
		end
		local h = { {}, {}, {}, {} }
		for i, basis in previous do
			for axis = 1, 4 do
				h[axis] = P.add(h[axis], P.scale(basis, controls[i][axis]))
			end
		end
		assert(#h[4] > 0, "Missing positive weight polynomial")
		local minWeight, maxWeight = controls[span - degree][4], controls[span - degree][4]
		for i = span - degree, span do
			if R.compare(controls[i][4], minWeight) < 0 then
				minWeight = controls[i][4]
			end
			if R.compare(controls[i][4], maxWeight) > 0 then
				maxWeight = controls[i][4]
			end
		end
		table.insert(spans, {
			index = span,
			h = h,
			offset = R.div(R.sub(lo, start), width),
			scale = R.div(delta, width),
			weightBounds = { minWeight, maxWeight },
		})
		ctx.visit(1)
	end
	return spans
end
