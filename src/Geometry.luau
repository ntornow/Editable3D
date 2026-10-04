local Mesh = require(script.Parent.Mesh)
local Topology = require(script.Parent.Topology)
local Deform = require(script.Parent.Deform)
local U = require(script.Parent.Util)
local G = {}
function G.scatter(mesh, count, seed, density)
	U.integer(count, 0)
	local triangles = mesh:triangles()
	local cumulative = {}
	local total = 0
	for i, t in triangles do
		local a, b, c = mesh.vertices[t[1]], mesh.vertices[t[2]], mesh.vertices[t[3]]
		local area = (b - a):Cross(c - a).Magnitude / 2
		total += area
		cumulative[i] = total
	end
	assert(total > 0 or count == 0)
	local random = Random.new(seed or 0)
	local points = {}
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
function G.instance(mesh, transforms)
	local instances = {}
	for _, frame in transforms do
		table.insert(instances, Deform.transform(mesh, frame))
	end
	return Topology.join(instances)
end
function G.assignMaterial(mesh, faces, slot)
	U.integer(slot, 1)
	local out = mesh:clone()
	for id, selected in faces do
		if selected then
			assert(out.faces[id]).material = slot
		end
	end
	return out
end
function G.vertexColors(mesh, field)
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
function G.group(mesh, name, mask)
	local out = mesh:clone()
	out.groups[name] = {}
	for id, w in mask do
		assert(out.vertices[id])
		out.groups[name][id] = math.clamp(w, 0, 1)
	end
	return out
end
function G.parametric(fn, uSegments, vSegments, wrapU, wrapV)
	U.integer(uSegments, 1)
	U.integer(vSegments, 1)
	local m = Mesh.new()
	local rows = {}
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
return G
