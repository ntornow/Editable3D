local U = require(script.Parent.Util)
local S = {}
function S.stroke(mesh, samples, options)
	return require(script.Parent.BrushStroke)(mesh, samples, options)
end
function S.brush(mesh, center, options)
	assert(options == nil or type(options) == "table", "Brush options must be a table")
	options = table.clone(options or {})
	options.sampling = "dabs"
	return S.stroke(mesh, { { position = center, pressure = options.pressure } }, options)
end
function S.fair(mesh, selection, options)
	return require(script.Parent.Fairing)(mesh, selection, options)
end
function S.move(mesh, mask, delta)
	local out = mesh:clone()
	for id, p in out.vertices do
		out.vertices[id] = p + delta * U.weight(mask, id)
	end
	return out:recalculateNormals()
end
function S.inflate(mesh, mask, amount)
	local out = mesh:clone()
	local top = mesh:topology()
	local normals = {}
	for fid in mesh.faces do
		local n, a = mesh:faceNormal(fid)
		normals[fid] = n * a
	end
	for id, p in mesh.vertices do
		local n = Vector3.zero
		for _, fid in top.vertexFaces[id] do
			n += normals[fid]
		end
		out.vertices[id] = p + U.unit(n, Vector3.zero) * amount * U.weight(mask, id)
	end
	return out:recalculateNormals()
end
function S.flatten(mesh, mask, point, normal, strength)
	assert(normal.Magnitude > 0)
	normal = normal.Unit
	local out = mesh:clone()
	for id, p in mesh.vertices do
		out.vertices[id] = p
			- normal * ((p - point):Dot(normal) * U.weight(mask, id) * math.clamp(strength or 1, 0, 1))
	end
	return out:recalculateNormals()
end
function S.smooth(mesh, mask, iterations, options)
	options = options or {}
	U.integer(iterations or 1, 0)
	local out = mesh:clone()
	local top = mesh:topology()
	local boundary = {}
	for _, e in top.edges do
		if #e.faces == 1 then
			boundary[e.a] = true
			boundary[e.b] = true
		end
	end
	local function pass(alpha)
		local nextPos = {}
		for id, p in out.vertices do
			local sum = Vector3.zero
			local n = 0
			for neighbor in top.neighbors[id] do
				sum += out.vertices[neighbor]
				n += 1
			end
			local w = U.weight(mask, id)
			if options.pinBoundary ~= false and boundary[id] then
				w = 0
			end
			nextPos[id] = n > 0 and p + (sum / n - p) * alpha * w or p
		end
		out.vertices = nextPos
	end
	for _ = 1, iterations or 1 do
		pass(options.lambda or 0.5)
		if options.taubin ~= false then
			pass(options.mu or -0.53)
		end
	end
	return out:recalculateNormals()
end
function S.crease(mesh, mask, point, normal, width, depth, pinch)
	assert(width > 0 and normal.Magnitude > 0)
	normal = normal.Unit
	local out = mesh:clone()
	for id, p in mesh.vertices do
		local offset = p - point
		local radial = offset - normal * offset:Dot(normal)
		local w = math.exp(-radial:Dot(radial) / (2 * width * width)) * U.weight(mask, id)
		out.vertices[id] = p - normal * depth * w - radial * (pinch or 0) * w
	end
	return out:recalculateNormals()
end
function S.displace(mesh, field, mask)
	local out = mesh:clone()
	for id, p in mesh.vertices do
		local d = field(p, id)
		assert(U.vector(d))
		out.vertices[id] = p + d * U.weight(mask, id)
	end
	return out:recalculateNormals()
end
function S.symmetrize(mesh, axis, sourcePositive, tolerance)
	axis = axis or "X"
	assert(axis == "X" or axis == "Y" or axis == "Z")
	tolerance = tolerance or 1e-4
	local direction = axis == "X" and Vector3.xAxis or axis == "Y" and Vector3.yAxis or Vector3.zAxis
	local out = mesh:clone()
	local sources = {}
	for id, p in mesh.vertices do
		if (sourcePositive ~= false and p[axis] >= 0) or (sourcePositive == false and p[axis] <= 0) then
			sources[id] = p
		end
	end
	for id, p in out.vertices do
		if math.abs(p[axis]) <= tolerance then
			out.vertices[id] = p - direction * p[axis]
		elseif sources[id] == nil then
			local target = p - direction * 2 * p[axis]
			local best, dist = nil, math.huge
			for _, q in sources do
				local d = (q - target).Magnitude
				if d < dist then
					best = q
					dist = d
				end
			end
			if best then
				out.vertices[id] = best - direction * 2 * best[axis]
			end
		end
	end
	return out:recalculateNormals()
end
return S
