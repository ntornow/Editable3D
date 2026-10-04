local Camera = {}
function Camera.new(frame, fov, width, height)
	assert(fov > 0 and fov < 179 and width > 0 and height > 0)
	return {
		frame = frame,
		fov = fov,
		width = width,
		height = height,
		principal = Vector2.new(width / 2, height / 2),
	}
end
function Camera.project(camera, point)
	local p = camera.frame:PointToObjectSpace(point)
	if p.Z >= -1e-8 then
		return nil, -p.Z
	end
	local focal = camera.height / (2 * math.tan(math.rad(camera.fov) / 2))
	return camera.principal + Vector2.new(p.X, -p.Y) * focal / -p.Z, -p.Z
end
function Camera.ray(camera, pixel)
	local focal = camera.height / (2 * math.tan(math.rad(camera.fov) / 2))
	local p = pixel - camera.principal
	return camera.frame.Position,
		camera.frame:VectorToWorldSpace(Vector3.new(p.X / focal, -p.Y / focal, -1).Unit)
end
function Camera.compare(camera, landmarks)
	local total, weight, errors = 0, 0, {}
	for i, l in landmarks do
		local p = Camera.project(camera, l.point)
		local w = l.weight or 1
		local e = p and (p - l.pixel).Magnitude or math.huge
		total += e * e * w
		weight += w
		errors[i] = e
	end
	return { rms = math.sqrt(total / math.max(weight, 1e-12)), errors = errors }
end
local function solve(matrix, rhs)
	local n = #rhs
	for col = 1, n do
		local pivot = col
		for row = col + 1, n do
			if math.abs(matrix[row][col]) > math.abs(matrix[pivot][col]) then
				pivot = row
			end
		end
		if math.abs(matrix[pivot][col]) < 1e-16 then
			return nil
		end
		matrix[col], matrix[pivot] = matrix[pivot], matrix[col]
		rhs[col], rhs[pivot] = rhs[pivot], rhs[col]
		local div = matrix[col][col]
		for j = col, n do
			matrix[col][j] /= div
		end
		rhs[col] /= div
		for row = 1, n do
			if row ~= col then
				local f = matrix[row][col]
				for j = col, n do
					matrix[row][j] -= matrix[col][j] * f
				end
				rhs[row] -= rhs[col] * f
			end
		end
	end
	return rhs
end
function Camera.fit(initial, landmarks, options)
	options = options or {}
	assert(#landmarks >= 4, "Camera fit needs at least four nondegenerate correspondences")
	local camera = table.clone(initial)
	local dimension = options.fitFov == false and 6 or 7
	local lambda = options.damping or 0.01
	local function move(c, d)
		local r = table.clone(c)
		r.frame = CFrame.new(d[1] or 0, d[2] or 0, d[3] or 0)
			* c.frame
			* CFrame.Angles(d[4] or 0, d[5] or 0, d[6] or 0)
		r.fov = math.clamp(c.fov + (d[7] or 0), 5, 150)
		return r
	end
	local function residual(c)
		local r = {}
		for _, l in landmarks do
			local p = Camera.project(c, l.point)
			local diff = p and p - l.pixel or Vector2.new(100000, 100000)
			local weight = math.sqrt(l.weight or 1)
			table.insert(r, diff.X * weight)
			table.insert(r, diff.Y * weight)
		end
		return r
	end
	local iterations = 0
	for step = 1, options.iterations or 40 do
		iterations = step
		local r = residual(camera)
		local jac = {}
		for k = 1, dimension do
			local delta = table.create(7, 0)
			local epsilon = k <= 3 and (options.positionEpsilon or 0.001) or k <= 6 and 0.0001 or 0.001
			delta[k] = epsilon
			local perturbed = residual(move(camera, delta))
			jac[k] = {}
			for i, value in r do
				jac[k][i] = (perturbed[i] - value) / epsilon
			end
		end
		local matrix, rhs = {}, {}
		for a = 1, dimension do
			matrix[a] = {}
			rhs[a] = 0
			for i, value in r do
				rhs[a] -= jac[a][i] * value
			end
			for b = 1, dimension do
				local sum = 0
				for i = 1, #r do
					sum += jac[a][i] * jac[b][i]
				end
				matrix[a][b] = sum
			end
			matrix[a][a] += lambda * math.max(matrix[a][a], 1)
		end
		local delta = solve(matrix, rhs)
		if not delta then
			break
		end
		local candidate = move(camera, delta)
		local old = Camera.compare(camera, landmarks).rms
		local new = Camera.compare(candidate, landmarks).rms
		if new < old then
			camera = candidate
			lambda = math.max(lambda * 0.3, 1e-10)
			if old - new < (options.tolerance or 1e-7) then
				break
			end
		else
			lambda *= 10
		end
	end
	local report = Camera.compare(camera, landmarks)
	report.iterations = iterations
	return camera, report
end
return Camera
