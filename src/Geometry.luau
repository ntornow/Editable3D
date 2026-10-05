--!strict
local Mesh = require(script.Parent.Mesh)
local Topology = require(script.Parent.Topology)
local Deform = require(script.Parent.Deform)
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
export type ScatterPoint = { position: Vector3, normal: Vector3, face: number, barycentric: Vector3 }
export type ScatterReport = { requested: number, generated: number, attempts: number }
local G = {}
function G.scatter(
	mesh: Mesh,
	count: number,
	seed: number?,
	density: ((Vector3) -> number)?
): ({ ScatterPoint }, ScatterReport)
	U.integer(count, 0)
	local triangles = mesh:triangles()
	local cumulative: { number } = {}
	local total = 0
	for i, t in triangles do
		local a, b, c = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
		local area = (b - a):Cross(c - a).Magnitude / 2
		total += area
		cumulative[i] = total
	end
	assert(total > 0 or count == 0)
	local random = Random.new(seed or 0)
	local points: { ScatterPoint } = {}
	local attempts = 0
	while #points < count and attempts < math.max(count * 100, 100) do
		attempts += 1
		local target = random:NextNumber() * total
		local lo, hi = 1, #triangles
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if cumulative[mid] < target then
				lo = mid + 1
			else
				hi = mid
			end
		end
		local t = triangles[lo]
		local a, b, c = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
		local r = math.sqrt(random:NextNumber())
		local s = random:NextNumber()
		local weights = Vector3.new(1 - r, r * (1 - s), r * s)
		local p = a * weights.X + b * weights.Y + c * weights.Z
		if not density or random:NextNumber() < math.clamp(density(p), 0, 1) then
			table.insert(
				points,
				{ position = p, normal = U.unit((b - a):Cross(c - a)), face = t.face, barycentric = weights }
			)
		end
	end
	return points, { requested = count, generated = #points, attempts = attempts }
end
function G.instance(mesh: Mesh, transforms: { CFrame }): Mesh
	local instances: { Mesh } = {}
	for _, frame in transforms do
		table.insert(instances, Deform.transform(mesh, frame))
	end
	return Topology.join(instances)
end
function G.assignMaterial(mesh: Mesh, faces: { [number]: boolean }, slot: number): Mesh
	U.integer(slot, 1)
	local out = mesh:clone()
	for id, selected in faces do
		if selected then
			assert(out.faces[id]).material = slot
		end
	end
	return out
end
function G.vertexColors(mesh: Mesh, field: (Vector3, number) -> (Color3, number?)): Mesh
	local out = mesh:clone()
	for _, f in out.faces do
		for i, id in f.vertices do
			local color, alpha = field(out.vertices[id], id)
			f.corners[i].color = color
			f.corners[i].alpha = alpha or 1
		end
	end
	return out
end
function G.group(mesh: Mesh, name: string, mask: { [number]: number }): Mesh
	local out = mesh:clone()
	out.groups[name] = {}
	for id, w in mask do
		assert(out.vertices[id])
		out.groups[name][id] = math.clamp(w, 0, 1)
	end
	return out
end
function G.parametric(
	fn: (number, number) -> Vector3,
	uSegments: number,
	vSegments: number,
	wrapU: boolean?,
	wrapV: boolean?
): Mesh
	U.integer(uSegments, 1)
	U.integer(vSegments, 1)
	local m = Mesh.new()
	local rows: { [number]: { [number]: number } } = {}
	local nu, nv = wrapU and uSegments or uSegments + 1, wrapV and vSegments or vSegments + 1
	for i = 0, nu - 1 do
		rows[i] = {}
		for j = 0, nv - 1 do
			rows[i][j] = m:addVertex(fn(i / uSegments, j / vSegments))
		end
	end
	for i = 0, uSegments - 1 do
		for j = 0, vSegments - 1 do
			local a, b = (i + 1) % nu, (j + 1) % nv
			m:addFace({ rows[i][j], rows[a][j], rows[a][b], rows[i][b] }, {
				{ uv = Vector2.new(i / uSegments, j / vSegments) },
				{ uv = Vector2.new((i + 1) / uSegments, j / vSegments) },
				{ uv = Vector2.new((i + 1) / uSegments, (j + 1) / vSegments) },
				{ uv = Vector2.new(i / uSegments, (j + 1) / vSegments) },
			})
		end
	end
	return m:recalculateNormals()
end
export type PrincipalAxes = { center: Vector3, axes: { Vector3 }, variances: { number }, frame: CFrame }
-- Area-weighted principal axes of a surface: centre, axes sorted by decreasing variance and a
-- right-handed frame (X = largest spread, Z = smallest, which is the normal of a flat object).
-- Use it to measure the pose of a slab, a limb or any elongated part before re-posing it.
function G.principalAxes(mesh: Mesh): PrincipalAxes
	local total, center = 0, Vector3.zero
	local tris: { { p: { Vector3 }, area: number } } = {}
	for _, t in mesh:triangles() do
		local a, b, c = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
		local area = (b - a):Cross(c - a).Magnitude / 2
		if area > 0 then
			table.insert(tris, { p = { a, b, c }, area = area })
			total += area
			center += (a + b + c) / 3 * area
		end
	end
	assert(total > 0, "Principal axes need a surface with area")
	center /= total
	-- covariance of the uniform distribution over each triangle (exact second moments)
	local m = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
	for _, t in tris do
		local p = { t.p[1] - center, t.p[2] - center, t.p[3] - center }
		local s = p[1] + p[2] + p[3]
		for i = 1, 3 do
			for j = 1, 3 do
				local ax = { "X", "Y", "Z" }
				local sum = 0
				for k = 1, 3 do
					sum += (p[k] :: any)[ax[i]] * (p[k] :: any)[ax[j]]
				end
				m[i][j] += t.area * (sum + (s :: any)[ax[i]] * (s :: any)[ax[j]]) / 12
			end
		end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			m[i][j] /= total
		end
	end
	-- Jacobi eigen-decomposition of the symmetric 3x3 covariance
	local v = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
	for _ = 1, 50 do
		local p, q, largest = 1, 2, math.abs(m[1][2])
		if math.abs(m[1][3]) > largest then
			p, q, largest = 1, 3, math.abs(m[1][3])
		end
		if math.abs(m[2][3]) > largest then
			p, q, largest = 2, 3, math.abs(m[2][3])
		end
		if largest < 1e-14 then
			break
		end
		local theta = (m[q][q] - m[p][p]) / (2 * m[p][q])
		local t = (theta >= 0 and 1 or -1) / (math.abs(theta) + math.sqrt(theta * theta + 1))
		local c = 1 / math.sqrt(t * t + 1)
		local sn = t * c
		for k = 1, 3 do
			local mkp, mkq = m[k][p], m[k][q]
			m[k][p], m[k][q] = c * mkp - sn * mkq, sn * mkp + c * mkq
		end
		for k = 1, 3 do
			local mpk, mqk = m[p][k], m[q][k]
			m[p][k], m[q][k] = c * mpk - sn * mqk, sn * mpk + c * mqk
		end
		for k = 1, 3 do
			local vkp, vkq = v[k][p], v[k][q]
			v[k][p], v[k][q] = c * vkp - sn * vkq, sn * vkp + c * vkq
		end
	end
	local order = { 1, 2, 3 }
	table.sort(order, function(a, b)
		return m[a][a] > m[b][b]
	end)
	local axes, variances = {}, {}
	for i, k in order do
		axes[i] = Vector3.new(v[1][k], v[2][k], v[3][k]).Unit
		variances[i] = m[k][k]
	end
	local z = axes[1]:Cross(axes[2]).Unit
	axes[3] = z
	return {
		center = center,
		axes = axes,
		variances = variances,
		frame = CFrame.fromMatrix(center, axes[1], axes[2], z),
	}
end
return G
