-- Private fixed-reference, area-weighted plane quadrics and segment placement.
local Q = {}
function Q.zero()
	return { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
end
function Q.plane(normal, offset, weight)
	local x, y, z = normal[1], normal[2], normal[3]
	return {
		x * x * weight,
		x * y * weight,
		x * z * weight,
		y * y * weight,
		y * z * weight,
		z * z * weight,
		x * offset * weight,
		y * offset * weight,
		z * offset * weight,
		offset * offset * weight,
	}
end
function Q.add(a, b)
	local result = {}
	for i = 1, 10 do
		result[i] = a[i] + b[i]
	end
	return result
end
function Q.value(q, p)
	local x, y, z = p[1], p[2], p[3]
	return x * (q[1] * x + 2 * q[2] * y + 2 * q[3] * z + 2 * q[7])
		+ y * (q[4] * y + 2 * q[5] * z + 2 * q[8])
		+ z * (q[6] * z + 2 * q[9])
		+ q[10]
end
function Q.segment(q, a, b)
	local x, y, z = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local ax, ay, az =
		q[1] * x + q[2] * y + q[3] * z, q[2] * x + q[4] * y + q[5] * z, q[3] * x + q[5] * y + q[6] * z
	local curvature = x * ax + y * ay + z * az
	local slope = a[1] * ax + a[2] * ay + a[3] * az + q[7] * x + q[8] * y + q[9] * z
	local t = curvature > 0 and math.clamp(-slope / curvature, 0, 1) or 0.5
	local point = { a[1] + t * x, a[2] + t * y, a[3] + t * z }
	return point, t, Q.value(q, point)
end
return Q
