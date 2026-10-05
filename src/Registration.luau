--!strict
-- Weighted proper-rotation / similarity fitting with Horn's quaternion formulation.
local U = require(script.Parent.Util)
local Q = require(script.Parent.Quaternion)
-- `scale` is read only by fit; rotation accepts the same table.
export type Options = { weights: { number }?, reference: CFrame?, scale: boolean? }
export type RotationReport = { ambiguous: boolean, eigenvalueMultiplicity: number }
export type FitResult = {
	frame: CFrame,
	scale: number,
	rms: number,
	maximumError: number,
	rotationAmbiguous: boolean,
	totalWeight: number,
}
local R = {}

local function checked(a: { Vector3 }, b: { Vector3 }, weights: { number }?): number
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

function R.rotation(source: { Vector3 }, target: { Vector3 }, options: Options?): (CFrame, RotationReport)
	local options: Options = options or {}
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

function R.fit(source: { Vector3 }, target: { Vector3 }, options: Options?): FitResult
	local options: Options = options or {}
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
	local a: { Vector3 }, b: { Vector3 } = {}, {}
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
export type ICPOptions = {
	initial: CFrame?,
	iterations: number?,
	maxDistance: number?,
	rigid: boolean?,
	sample: number?,
}
export type ICPReport = { rms: number, matched: number, iterations: number }
-- Exact translation between two copies of the same geometry (for example a mesh rebuilt from its
-- published asset, against a trimmed or moved copy of it): every triangle of `target` whose edge
-- vectors match a triangle of `source` votes for target - source at its first corner; the most
-- voted offset wins. Returns nil when no triangle matches. Works on soups (vertex ids differ).
function R.translation(
	source: any,
	target: any,
	options: { quantum: number?, limit: number? }?
): (Vector3?, number)
	local quantum = (options and options.quantum) or 0.002
	local limit = (options and options.limit) or 5000
	local function key(v: Vector3): string
		return string.format(
			"%d,%d,%d",
			math.round(v.X / quantum),
			math.round(v.Y / quantum),
			math.round(v.Z / quantum)
		)
	end
	local index: { [string]: Vector3 } = {}
	for _, t in source:triangles() do
		local a, b, c = source.vertices[t[1]], source.vertices[t[2]], source.vertices[t[3]]
		index[key(b - a) .. "|" .. key(c - a)] = a
	end
	local votes: { [string]: { offset: Vector3, count: number } } = {}
	local best: Vector3?, bestCount = nil, 0
	local seen = 0
	for _, t in target:triangles() do
		seen += 1
		if seen > limit then
			break
		end
		local a, b, c = target.vertices[t[1]], target.vertices[t[2]], target.vertices[t[3]]
		local anchor = index[key(b - a) .. "|" .. key(c - a)]
		if anchor then
			local offset = a - anchor
			local k = key(offset)
			local v = votes[k] or { offset = offset, count = 0 }
			v.count += 1
			votes[k] = v
			if v.count > bestCount then
				best, bestCount = v.offset, v.count
			end
		end
	end
	return best, bestCount
end
-- Iterative closest point: moves `source` (a Mesh or points) onto the surface of `target` (a Mesh or
-- a Spatial index). Translation only by default; rigid = true also solves the rotation (Horn).
-- Pairs further than maxDistance are ignored. Returns the transform to apply to the source.
function R.icp(source: any, target: any, options: ICPOptions?): (CFrame, ICPReport)
	local o: ICPOptions = options or {}
	local Spatial = require(script.Parent.Spatial)
	local index = if getmetatable(target) == Spatial then target else Spatial.new(target)
	local points: { Vector3 } = {}
	local stride = math.max(1, math.floor(o.sample or 1))
	if source.vertices then
		local i = 0
		for _, v in source.vertices do
			i += 1
			if i % stride == 0 then
				table.insert(points, v)
			end
		end
	else
		for i, v in source do
			if i % stride == 0 then
				table.insert(points, v)
			end
		end
	end
	local frame = o.initial or CFrame.identity
	local maxDistance = o.maxDistance or math.huge
	local rms, matched, iterations = math.huge, 0, 0
	for it = 1, o.iterations or 10 do
		iterations = it
		local from, to = {}, {}
		local sum = 0
		for _, p in points do
			local q = frame:PointToWorldSpace(p)
			local hit = index:closest(q, maxDistance)
			if hit then
				table.insert(from, q)
				table.insert(to, hit.position)
				sum += hit.distance * hit.distance
			end
		end
		matched = #from
		if matched == 0 then
			break
		end
		rms = math.sqrt(sum / matched)
		local step: CFrame
		if o.rigid then
			step = R.fit(from, to).frame
		else
			local d = Vector3.zero
			for i, q in from do
				d += to[i] - q
			end
			step = CFrame.new(d / matched)
		end
		frame = step * frame
		if
			step.Position.Magnitude < 1e-7
			and (not o.rigid or (step.LookVector - Vector3.new(0, 0, -1)).Magnitude < 1e-9)
		then
			break
		end
	end
	return frame, { rms = rms, matched = matched, iterations = iterations }
end
return R
