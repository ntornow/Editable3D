-- Weighted proper-rotation / similarity fitting with Horn's quaternion formulation.
local U = require(script.Parent.Util)
local Q = require(script.Parent.Quaternion)
local R = {}

local function checked(a, b, weights)
	assert(#a > 0 and #a == #b, "Corresponding nonempty point arrays required")
	if weights then
		assert(#weights == #a, "Weight count mismatch")
	end
	local total = 0
	for i, p in a do
		assert(U.vector(p) and U.vector(b[i]), "Finite corresponding vectors required")
		local w = weights and weights[i] or 1
		assert(U.finite(w) and w >= 0, "Weights must be finite and nonnegative")
		total += w
	end
	assert(U.finite(total) and total > 0, "Finite positive total weight required")
	return total
end

function R.rotation(source, target, options)
	options = options or {}
	local weights = options.weights
	local total = checked(source, target, weights)
	local s = table.create(9, 0)
	for i, a in source do
		local b, w = target[i], (weights and weights[i] or 1) / total
		local av, bv = { a.X, a.Y, a.Z }, { b.X, b.Y, b.Z }
		for j = 1, 3 do
			for k = 1, 3 do
				s[(j - 1) * 3 + k] += w * av[j] * bv[k]
			end
		end
	end
	-- A common covariance scale cannot change the fitted rotation. Normalize
	-- before applying eigensolver tolerances, including for tiny input vectors.
	local covarianceScale = 0
	for _, value in s do
		assert(U.finite(value), "Registration covariance exceeded the numerical range")
		covarianceScale = math.max(covarianceScale, math.abs(value))
	end
	if covarianceScale > 0 then
		for i = 1, 9 do
			s[i] /= covarianceScale
		end
	end
	local xx, xy, xz, yx, yy, yz, zx, zy, zz = table.unpack(s)
	local a = {
		{ xx + yy + zz, yz - zy, zx - xz, xy - yx },
		{ yz - zy, xx - yy - zz, xy + yx, zx + xz },
		{ zx - xz, xy + yx, -xx + yy - zz, yz + zy },
		{ xy - yx, zx + xz, yz + zy, -xx - yy + zz },
	}
	local v = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }
	local scale = 0
	for i = 1, 4 do
		for j = 1, 4 do
			scale = math.max(scale, math.abs(a[i][j]))
		end
	end
	for _ = 1, 64 do
		local p, q, largest = 1, 2, 0
		for i = 1, 3 do
			for j = i + 1, 4 do
				if math.abs(a[i][j]) > largest then
					p, q, largest = i, j, math.abs(a[i][j])
				end
			end
		end
		if largest <= math.max(1e-30, scale * 1e-14) then
			break
		end
		local tau = (a[q][q] - a[p][p]) / (2 * a[p][q])
		local t = (tau >= 0 and 1 or -1) / (math.abs(tau) + math.sqrt(1 + tau * tau))
		local c, sn = 1 / math.sqrt(1 + t * t), t / math.sqrt(1 + t * t)
		local off = a[p][q]
		a[p][p] -= t * off
		a[q][q] += t * off
		a[p][q] = 0
		a[q][p] = 0
		for k = 1, 4 do
			if k ~= p and k ~= q then
				local x, y = a[k][p], a[k][q]
				a[k][p] = c * x - sn * y
				a[p][k] = a[k][p]
				a[k][q] = sn * x + c * y
				a[q][k] = a[k][q]
			end
			local x, y = v[k][p], v[k][q]
			v[k][p] = c * x - sn * y
			v[k][q] = sn * x + c * y
		end
	end
	local largest, best = -math.huge, 1
	for i = 1, 4 do
		if a[i][i] > largest then
			largest, best = a[i][i], i
		end
	end
	local reference = Q.fromCFrame(options.reference or CFrame.identity)
	local ref = { reference[4], reference[1], reference[2], reference[3] }
	local q, multiplicity = { 0, 0, 0, 0 }, 0
	for j = 1, 4 do
		if largest - a[j][j] <= math.max(1e-30, scale * 1e-10) then
			multiplicity += 1
			local dot = 0
			for i = 1, 4 do
				dot += ref[i] * v[i][j]
			end
			for i = 1, 4 do
				q[i] += dot * v[i][j]
			end
		end
	end
	if q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2 < 1e-20 then
		for i = 1, 4 do
			q[i] = v[i][best]
		end
	end
	return Q.toCFrame({ q[2], q[3], q[4], q[1] }),
		{ ambiguous = multiplicity > 1, eigenvalueMultiplicity = multiplicity }
end

function R.fit(source, target, options)
	options = options or {}
	local weights = options.weights
	local total = checked(source, target, weights)
	local sx, sy, sz, tx, ty, tz = 0, 0, 0, 0, 0, 0
	for i, a in source do
		local b, w = target[i], (weights and weights[i] or 1) / total
		sx += a.X * w
		sy += a.Y * w
		sz += a.Z * w
		tx += b.X * w
		ty += b.Y * w
		tz += b.Z * w
	end
	local ca, cb = Vector3.new(sx, sy, sz), Vector3.new(tx, ty, tz)
	local a, b = {}, {}
	for i, p in source do
		a[i] = p - ca
		b[i] = target[i] - cb
	end
	local rotation, report = R.rotation(a, b, options)
	local scale = 1
	if options.scale then
		local numerator, denominator = 0, 0
		for i, p in a do
			local w = (weights and weights[i] or 1) / total
			if w > 0 then
				local q, t = rotation:VectorToWorldSpace(p), b[i]
				numerator += w * (q.X * t.X + q.Y * t.Y + q.Z * t.Z)
				denominator += w * (p.X * p.X + p.Y * p.Y + p.Z * p.Z)
			end
		end
		assert(denominator > 1e-20, "Similarity scale is undefined for coincident source points")
		scale = numerator / denominator
		assert(U.finite(scale) and scale > 1e-12, "Positive similarity scale could not be fitted")
	end
	local frame = CFrame.new(cb - rotation:VectorToWorldSpace(ca) * scale) * rotation
	local squared, maximum = 0, 0
	for i, p in source do
		local w = (weights and weights[i] or 1) / total
		if w > 0 then
			local d = (frame:PointToWorldSpace(p * scale) - target[i]).Magnitude
			squared += w * d * d
			maximum = math.max(maximum, d)
		end
	end
	return {
		frame = frame,
		scale = scale,
		rms = math.sqrt(squared),
		maximumError = maximum,
		rotationAmbiguous = report.ambiguous,
		totalWeight = total,
	}
end
return R
