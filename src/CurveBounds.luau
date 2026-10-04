-- Bounds on a single positive rational Bezier segment. Scalar differences retain
-- double arithmetic after reading native float positions.
local function distance(a, b)
	local x, y, z = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return math.sqrt(x * x + y * y + z * z)
end
local function length(c)
	local lower, upper = distance(c.points[1], c.points[#c.points]), 0
	for i = 2, #c.points do
		upper += distance(c.points[i - 1], c.points[i])
	end
	return lower, math.max(lower, upper)
end
local function choose(n, k)
	local r = 1
	for i = 1, k do
		r *= (n - i + 1) / i
	end
	return r
end
local function tangent(c)
	local p, origin = c.degree, c.points[1]
	local w, h, maximum = {}, {}, 0
	for _, weight in c.weights do
		maximum = math.max(maximum, weight)
	end
	for i, point in c.points do
		w[i] = c.weights[i] / maximum
		assert(w[i] > 0, "Rational weight ratio underflow")
		h[i] = { (point.X - origin.X) * w[i], (point.Y - origin.Y) * w[i], (point.Z - origin.Z) * w[i] }
	end
	local numerator = {}
	for k = 0, 2 * p - 1 do
		local v = { 0, 0, 0 }
		for i = math.max(0, k - p), math.min(p - 1, k) do
			local j = k - i
			local factor = p * choose(p - 1, i) * choose(p, j) / choose(2 * p - 1, k)
			for axis = 1, 3 do
				v[axis] += factor * ((h[i + 2][axis] - h[i + 1][axis]) * w[j + 1] - (w[i + 2] - w[i + 1]) * h[j + 1][axis])
			end
		end
		table.insert(numerator, v)
	end
	local last = c.points[#c.points]
	local chord = { last.X - origin.X, last.Y - origin.Y, last.Z - origin.Z }
	local d = distance(last, origin)
	local angle, nonzero = 0, false
	for _, v in numerator do
		local magnitude = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
		if magnitude > 0 then
			nonzero = true
			if d == 0 then
				return math.pi, false
			end
			local cosine = (v[1] * chord[1] + v[2] * chord[2] + v[3] * chord[3]) / (magnitude * d)
			-- A cone with half-angle below pi/2 is convex; positive Bernstein
			-- combinations cannot leave it. Wider cones provide no such proof.
			if cosine <= 0 then
				return math.pi, false
			end
			angle = math.max(angle, math.acos(math.clamp(cosine, -1, 1)))
		end
	end
	return angle, not nonzero
end
return { length = length, tangent = tangent }
