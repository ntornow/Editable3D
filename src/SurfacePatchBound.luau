-- Private homogeneous Bernstein bound for rational triangle interpolation.
return function(s)
	local p, q = s.degreeU, s.degreeV
	assert(#s.control == p + 1 and #s.control[1] == q + 1, "A single Bezier patch is required")
	local corners =
		{ { s.control[1][1], s.control[1][q + 1] }, { s.control[p + 1][1], s.control[p + 1][q + 1] } }
	local maximum, minimum = 0, math.huge
	for _, row in s.weights do
		for _, w in row do
			maximum = math.max(maximum, w)
		end
	end
	for _, row in s.weights do
		for _, w in row do
			minimum = math.min(minimum, w / maximum)
		end
	end
	local bound = 0
	-- H - W*bilinear has degree (p+1,q+1). Degree elevation and Bernstein products
	-- have the same binomial factors, leaving weighted control-to-corner differences.
	for i = 0, p + 1 do
		for j = 0, q + 1 do
			local x, y, z = 0, 0, 0
			for a = 0, 1 do
				for b = 0, 1 do
					local u, v = i - a, j - b
					if u >= 0 and u <= p and v >= 0 and v <= q then
						local factor = (a == 0 and (p + 1 - i) / (p + 1) or i / (p + 1))
							* (b == 0 and (q + 1 - j) / (q + 1) or j / (q + 1))
						local weight = s.weights[u + 1][v + 1] / maximum * factor
						local point, corner = s.control[u + 1][v + 1], corners[a + 1][b + 1]
						x += (point.X - corner.X) * weight
						y += (point.Y - corner.Y) * weight
						z += (point.Z - corner.Z) * weight
					end
				end
			end
			bound = math.max(bound, math.sqrt(x * x + y * y + z * z))
		end
	end
	local rational = minimum > 0 and bound / minimum or math.huge
	local warp = (corners[1][1] - corners[2][1] + corners[2][2] - corners[1][2]).Magnitude
	-- For any parametric triangle in this rectangle, interpolation error is at most
	-- twice the rational-to-bilinear deviation plus one quarter of bilinear twist.
	return 2 * rational + warp * 0.25, rational, warp
end
