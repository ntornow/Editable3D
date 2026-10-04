-- Private differentiable distortion energies in normalized texture coordinates.
local E = {}
function E.evaluate(coordinates, triangles, method, visit)
	local gradient = table.create(#coordinates, 0)
	local energy = 0
	for _, triangle in triangles do
		visit(1)
		local ids = triangle.nodes
		local x, y = {}, {}
		for i, id in ids do
			x[i], y[i] = coordinates[2 * id - 1], coordinates[2 * id]
		end
		local determinant = (x[2] - x[1]) * (y[3] - y[1]) - (y[2] - y[1]) * (x[3] - x[1])
		if determinant * triangle.orientation <= 0 then
			return math.huge, gradient
		end
		if method == "angle" then
			for i, id in ids do
				visit(1)
				local j, k = i % 3 + 1, (i + 1) % 3 + 1
				local ax, ay, bx, by = x[j] - x[i], y[j] - y[i], x[k] - x[i], y[k] - y[i]
				local theta = math.atan2(math.abs(ax * by - ay * bx), ax * bx + ay * by)
				local difference = theta - triangle.target[i]
				energy += triangle.weight * difference * difference
				local factor = 2 * triangle.weight * difference * triangle.orientation
				local al, bl = ax * ax + ay * ay, bx * bx + by * by
				local gx, gy, hx, hy =
					factor * ay / al, -factor * ax / al, -factor * by / bl, factor * bx / bl
				gradient[2 * ids[j] - 1] += gx
				gradient[2 * ids[j]] += gy
				gradient[2 * ids[k] - 1] += hx
				gradient[2 * ids[k]] += hy
				gradient[2 * id - 1] -= gx + hx
				gradient[2 * id] -= gy + hy
			end
		else
			local a, b, c, d = 0, 0, 0, 0
			for i in ids do
				visit(1)
				a += x[i] * triangle.gx[i]
				b += x[i] * triangle.gy[i]
				c += y[i] * triangle.gx[i]
				d += y[i] * triangle.gy[i]
			end
			local det = a * d - b * c
			local norm = a * a + b * b + c * c + d * d
			local scale = 1 + 1 / (det * det)
			energy += triangle.weight * norm * scale
			local factor = 2 * triangle.weight
			local cofactor = norm / (det * det * det)
			local ga, gb = factor * (a * scale - d * cofactor), factor * (b * scale + c * cofactor)
			local gc, gd = factor * (c * scale + b * cofactor), factor * (d * scale - a * cofactor)
			for i, id in ids do
				visit(1)
				gradient[2 * id - 1] += ga * triangle.gx[i] + gb * triangle.gy[i]
				gradient[2 * id] += gc * triangle.gx[i] + gd * triangle.gy[i]
			end
		end
	end
	return energy, gradient
end
return E
