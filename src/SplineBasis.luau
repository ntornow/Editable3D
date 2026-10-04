-- Private polynomial B-spline values and normalized first/second derivatives.
local U = require(script.Parent.Util)
return function(n, p, knots, t)
	assert(U.finite(t) and t >= 0 and t <= 1, "Normalized parameter must be in [0,1]")
	local scale = knots[n + 1] - knots[p + 1]
	local u = knots[p + 1] + t * scale
	local b, d, dd = {}, {}, {}
	for i = 1, n + p do
		b[i] = (
			(t == 1 and knots[i] < u and knots[i + 1] >= u) or (t ~= 1 and u >= knots[i] and u < knots[i + 1])
		)
				and 1
			or 0
		d[i], dd[i] = 0, 0
	end
	for degree = 1, p do
		local nb, nd, ndd = {}, {}, {}
		for i = 1, n + p - degree do
			local a, c = knots[i + degree] - knots[i], knots[i + degree + 1] - knots[i + 1]
			local x, y = a > 0 and (u - knots[i]) / a or 0, c > 0 and (knots[i + degree + 1] - u) / c or 0
			nb[i] = x * b[i] + y * b[i + 1]
			nd[i] = x * d[i] + y * d[i + 1] + (a > 0 and b[i] / a or 0) - (c > 0 and b[i + 1] / c or 0)
			ndd[i] = x * dd[i]
				+ y * dd[i + 1]
				+ (a > 0 and 2 * d[i] / a or 0)
				- (c > 0 and 2 * d[i + 1] / c or 0)
		end
		b, d, dd = nb, nd, ndd
	end
	for i = 1, n do
		d[i] *= scale
		dd[i] *= scale * scale
	end
	return b, d, dd
end
