--!strict
-- Least-squares Cauchy-Riemann parameterization with fixed boundary pins.
-- Original implementation of the LSCM formulation (Levy et al., SIGGRAPH 2002).
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Boundary vertex id to pinned UV.
export type Pins = { [number]: Vector2 }
export type Options = {
	maxVertices: number?,
	pins: Pins?,
	tolerance: number?,
	iterations: number?,
	cancelled: (() -> boolean)?,
	yieldEvery: number?,
}
export type DistortionReport = {
	maxAngleRadians: number,
	meanAngleRadians: number,
	positiveTriangles: number,
	negativeTriangles: number,
	flippedTriangles: number,
	degenerateTriangles: number,
}
export type Report = {
	iterations: number,
	residual: number,
	relativeResidual: number,
	converged: boolean,
	pins: Pins,
	conformalEnergy: number,
	distortion: DistortionReport,
}
type Row = { indices: { number }, values: { number }, rhs: number }
local C = {}
local function dot(a: { number }, b: { number }): number
	local total = 0
	for i, v in a do
		total += v * b[i]
	end
	return total
end
local function disk(mesh: Mesh): { [number]: boolean }
	local report = mesh:validate()
	assert(report.valid and report.windingErrors == 0, "LSCM requires a consistently oriented manifold chart")
	local topology = mesh:topology()
	local boundary: { [number]: boolean }, nextVertex: { [number]: number }, used: { [number]: boolean } =
		{}, {}, {}
	for _, f in mesh.faces do
		for _, id in f.vertices do
			used[id] = true
		end
	end
	assert(U.count(used) == U.count(mesh.vertices), "Remove unused vertices before LSCM")
	for _, e in topology.edges do
		if #e.faces == 1 then
			local a, b = e.a, e.b
			if e.directions[1] < 0 then
				a, b = b, a
			end
			assert(not nextVertex[a], "Nonmanifold boundary")
			nextVertex[a] = b
			boundary[a] = true
		end
	end
	assert(U.count(boundary) >= 3, "Closed chart needs seams before LSCM")
	local start = U.keys(boundary)[1]
	local seen: { [number]: boolean }, id: number = {}, start
	repeat
		assert(id and not seen[id], "Broken boundary")
		seen[id] = true
		id = nextVertex[id]
	until id == start
	assert(U.count(seen) == U.count(boundary), "LSCM expects one boundary loop")
	local visited: { [number]: boolean }, queue: { number } = { [start] = true }, { start }
	local cursor = 1
	while cursor <= #queue do
		local v = queue[cursor]
		cursor += 1
		for neighbor in topology.neighbors[v] do
			if not visited[neighbor] then
				visited[neighbor] = true
				table.insert(queue, neighbor)
			end
		end
	end
	assert(#queue == U.count(mesh.vertices), "LSCM chart must be connected")
	assert(
		U.count(mesh.vertices) - U.count(topology.edges) + U.count(mesh.faces) == 1,
		"LSCM chart must be a topological disk"
	)
	return boundary
end
local function defaultPins(mesh: Mesh, boundary: { [number]: boolean }): Pins
	local ids = U.keys(boundary)
	local a = ids[1]
	local function farthest(v: number): (number, number)
		local best, distance = v, -1
		for _, other in ids do
			local d = (mesh.vertices[v] - mesh.vertices[other]).Magnitude
			if d > distance then
				best, distance = other, d
			end
		end
		return best, distance
	end
	a = farthest(a)
	local b, distance = farthest(a)
	assert(distance > 1e-10, "Collapsed chart")
	return { [a] = Vector2.zero, [b] = Vector2.new(distance, 0) }
end
function C.lscm(mesh: Mesh, options: Options?): (Mesh, Report)
	local options: Options = options or {}
	local boundary = disk(mesh)
	local ids = U.keys(mesh.vertices)
	assert(#ids <= (options.maxVertices or 20000), "LSCM vertex budget exceeded")
	local pins = options.pins or defaultPins(mesh, boundary)
	assert(U.count(pins) >= 2, "LSCM requires at least two pins")
	local first: Vector2?, separated = nil, false
	for id, uv in pins do
		assert(mesh.vertices[id] and boundary[id], "Pin must name a boundary vertex")
		assert(typeof(uv) == "Vector2" and U.finite(uv.X) and U.finite(uv.Y), "Pin UV must be finite")
		if first then
			separated = separated or (uv - first).Magnitude > 1e-10
		else
			first = uv
		end
	end
	assert(separated, "Pins must not all coincide")
	local index: { [number]: number }, unknown = {}, 0
	for _, id in ids do
		if not pins[id] then
			index[id] = unknown + 1
			unknown += 2
		end
	end
	local rows: { Row } = {}
	local function row(vertices: { number }, uc: { number }, vc: { number })
		local r: Row = { indices = {}, values = {}, rhs = 0 }
		for i, id in vertices do
			if pins[id] then
				r.rhs -= uc[i] * pins[id].X + vc[i] * pins[id].Y
			else
				table.insert(r.indices, index[id])
				table.insert(r.values, uc[i])
				table.insert(r.indices, index[id] + 1)
				table.insert(r.values, vc[i])
			end
		end
		table.insert(rows, r)
	end
	for _, t in mesh:triangles() do
		local a, b, c = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
		local ab, ac = b - a, c - a
		local length = ab.Magnitude
		local twiceArea = ab:Cross(ac).Magnitude
		assert(length > 1e-12 and twiceArea > 1e-14, "Degenerate LSCM triangle")
		local x = ab:Dot(ac) / length
		local y = twiceArea / length
		local scale = math.sqrt(twiceArea / 2) / twiceArea
		local gx = { -y * scale, y * scale, 0 }
		local gy = { (x - length) * scale, -x * scale, length * scale }
		local negativeGy = { -gy[1], -gy[2], -gy[3] }
		row({ t[1], t[2], t[3] }, gx, negativeGy)
		row({ t[1], t[2], t[3] }, gy, gx)
	end
	local rhs, diagonal = table.create(unknown, 0), table.create(unknown, 0)
	for _, r in rows do
		for j, id in r.indices do
			local value = r.values[j]
			rhs[id] += value * r.rhs
			diagonal[id] += value * value
		end
	end
	local function multiply(x: { number }): { number }
		local out = table.create(unknown, 0)
		for _, r in rows do
			local v = 0
			for j, id in r.indices do
				v += r.values[j] * x[id]
			end
			for j, id in r.indices do
				out[id] += r.values[j] * v
			end
		end
		return out
	end
	local x: { number }, r: { number }, z: { number }, p: { number } =
		table.create(unknown, 0), table.clone(rhs), {}, {}
	for i = 1, unknown do
		assert(diagonal[i] > 1e-20, "Singular LSCM chart")
		z[i] = r[i] / diagonal[i]
		p[i] = z[i]
	end
	local rz = dot(r, z)
	local initial = math.sqrt(dot(rhs, rhs))
	local tolerance = options.tolerance or 1e-8
	assert(U.finite(tolerance) and tolerance > 0, "Positive tolerance required")
	local threshold = tolerance * math.max(initial, 1e-12)
	local residual, iterations = initial, 0
	local limit = U.integer(options.iterations or math.max(100, math.min(unknown * 2, 4000)), 1)
	for iteration = 1, limit do
		if residual <= threshold then
			break
		end
		local ap = multiply(p)
		local denominator = dot(p, ap)
		if denominator <= 0 then
			break
		end
		local alpha = rz / denominator
		for i = 1, unknown do
			x[i] += alpha * p[i]
			r[i] -= alpha * ap[i]
		end
		if iteration % 32 == 0 then
			local ax = multiply(x)
			for i = 1, unknown do
				r[i] = rhs[i] - ax[i]
			end
			assert(not options.cancelled or not options.cancelled(), "LSCM cancelled")
			if options.yieldEvery then
				task.wait()
			end
		end
		residual = math.sqrt(dot(r, r))
		iterations = iteration
		for i = 1, unknown do
			z[i] = r[i] / diagonal[i]
		end
		local nextRz = dot(r, z)
		if rz <= 0 then
			break
		end
		local beta = nextRz / rz
		for i = 1, unknown do
			p[i] = z[i] + beta * p[i]
		end
		rz = nextRz
	end
	local uv: { [number]: Vector2 } = {}
	for _, id in ids do
		uv[id] = pins[id] or Vector2.new(x[index[id]], x[index[id] + 1])
	end
	local out = mesh:clone()
	for _, f in out.faces do
		for i, id in f.vertices do
			f.corners[i].uv = uv[id]
		end
	end
	local energy = 0
	for _, equation in rows do
		local value = -equation.rhs
		for j, id in equation.indices do
			value += equation.values[j] * x[id]
		end
		energy += value * value
	end
	local distortion = C.distortion(out)
	return out,
		{
			iterations = iterations,
			residual = residual,
			relativeResidual = residual / math.max(initial, 1e-12),
			converged = residual <= threshold,
			pins = U.copy(pins),
			conformalEnergy = energy,
			distortion = distortion,
		}
end
function C.distortion(mesh: Mesh): DistortionReport
	local maxAngle, sumAngle, count = 0, 0, 0
	local positive, negative, degenerate = 0, 0, 0
	for _, t in mesh:triangles() do
		local f = mesh.faces[t.face]
		local uv: { Vector2 } = {}
		for i = 1, 3 do
			uv[i] = assert(f.corners[t.corners[i]].uv, "Missing UV")
		end
		local a, b = uv[2] - uv[1], uv[3] - uv[1]
		local area = a.X * b.Y - a.Y * b.X
		if math.abs(area) < 1e-14 then
			degenerate += 1
		elseif area > 0 then
			positive += 1
		else
			negative += 1
		end
		for i = 1, 3 do
			local j, k = i % 3 + 1, (i + 1) % 3 + 1
			local p = mesh.vertices[t[j]] - mesh.vertices[t[i]]
			local q = mesh.vertices[t[k]] - mesh.vertices[t[i]]
			local u, v = uv[j] - uv[i], uv[k] - uv[i]
			if p.Magnitude * q.Magnitude * u.Magnitude * v.Magnitude > 1e-20 then
				local angle3 = math.acos(math.clamp(p:Dot(q) / (p.Magnitude * q.Magnitude), -1, 1))
				local angle2 = math.acos(math.clamp(u:Dot(v) / (u.Magnitude * v.Magnitude), -1, 1))
				local errorAngle = math.abs(angle3 - angle2)
				maxAngle = math.max(maxAngle, errorAngle)
				sumAngle += errorAngle
				count += 1
			end
		end
	end
	return {
		maxAngleRadians = maxAngle,
		meanAngleRadians = count > 0 and sumAngle / count or 0,
		positiveTriangles = positive,
		negativeTriangles = negative,
		flippedTriangles = math.min(positive, negative),
		degenerateTriangles = degenerate,
	}
end
return C
