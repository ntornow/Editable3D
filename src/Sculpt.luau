--!strict
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Vertex ID to weight in [0,1]; nil selects every vertex at full weight.
type Mask = { [number]: number }
-- Brush, stroke and fairing options are validated by BrushStroke and Fairing.
type Options = { [string]: any }
export type SmoothOptions = { pinBoundary: boolean?, lambda: number?, taubin: boolean?, mu: number? }
local S = {}
function S.stroke(mesh: Mesh, samples: { { [string]: any } }, options: Options?)
	return require(script.Parent.BrushStroke)(mesh, samples, options)
end
function S.brush(mesh: Mesh, center: Vector3, options: Options?)
	assert(options == nil or type(options) == "table", "Brush options must be a table")
	local options: Options = table.clone(options or {})
	options.sampling = "dabs"
	return S.stroke(mesh, { { position = center, pressure = options.pressure } }, options)
end
function S.fair(mesh: Mesh, selection: { [any]: any }?, options: Options?)
	return require(script.Parent.Fairing)(mesh, selection, options)
end
function S.move(mesh: Mesh, mask: Mask?, delta: Vector3): Mesh
	local out = mesh:clone()
	for id, p in out.vertices do
		out.vertices[id] = p + delta * U.weight(mask, id)
	end
	return out:recalculateNormals()
end
function S.inflate(mesh: Mesh, mask: Mask?, amount: number): Mesh
	local out = mesh:clone()
	local top = mesh:topology()
	local normals: { [number]: Vector3 } = {}
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
function S.flatten(mesh: Mesh, mask: Mask?, point: Vector3, normal: Vector3, strength: number?): Mesh
	assert(normal.Magnitude > 0)
	normal = normal.Unit
	local out = mesh:clone()
	for id, p in mesh.vertices do
		out.vertices[id] = p
			- normal * ((p - point):Dot(normal) * U.weight(mask, id) * math.clamp(strength or 1, 0, 1))
	end
	return out:recalculateNormals()
end
function S.smooth(mesh: Mesh, mask: Mask?, iterations: number?, options: SmoothOptions?): Mesh
	local options: SmoothOptions = options or {}
	U.integer(iterations or 1, 0)
	local out = mesh:clone()
	local top = mesh:topology()
	local boundary: { [number]: boolean } = {}
	for _, e in top.edges do
		if #e.faces == 1 then
			boundary[e.a] = true
			boundary[e.b] = true
		end
	end
	local function pass(alpha: number)
		local nextPos: { [number]: Vector3 } = {}
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
-- Boundary-curve smoothing: straightens the open edges of a sheet without shrinking it. Each
-- boundary vertex moves toward the mean of its two neighbours along the boundary loop (Taubin
-- lambda/mu pairs, so loops keep their length); vertices where several boundary runs meet keep
-- their place. A sheet cut along a diagonal through a regular grid has a staircase edge, which
-- `smooth` cannot fix because it pins the boundary. rings > 0 then relaxes that many rings of
-- interior vertices next to the boundary (plain Taubin, boundary pinned), so the strip behind the
-- edge follows the straightened curve. Returns the mesh and the number of boundary vertices moved.
export type BoundarySmoothOptions = { lambda: number?, mu: number?, rings: number?, ringIterations: number? }
function S.smoothBoundary(
	mesh: Mesh,
	mask: Mask?,
	iterations: number?,
	options: BoundarySmoothOptions?
): (Mesh, number)
	local options: BoundarySmoothOptions = options or {}
	U.integer(iterations or 1, 0)
	U.integer(options.rings or 0, 0)
	local out = mesh:clone()
	local top = mesh:topology()
	local along: { [number]: { number } } = {}
	for _, e in top.edges do
		if #e.faces == 1 then
			along[e.a] = along[e.a] or {}
			along[e.b] = along[e.b] or {}
			table.insert(along[e.a], e.b)
			table.insert(along[e.b], e.a)
		end
	end
	local movable: { [number]: number } = {}
	local count = 0
	for id, ns in along do
		local w = U.weight(mask, id)
		if #ns == 2 and w > 0 then
			movable[id] = w
			count += 1
		end
	end
	local function pass(alpha: number)
		local nextPos: { [number]: Vector3 } = {}
		for id, w in movable do
			local ns = along[id]
			local p = out.vertices[id]
			nextPos[id] = p + ((out.vertices[ns[1]] + out.vertices[ns[2]]) / 2 - p) * alpha * w
		end
		for id, p in nextPos do
			out.vertices[id] = p
		end
	end
	for _ = 1, iterations or 1 do
		pass(options.lambda or 0.5)
		pass(options.mu or -0.53)
	end
	local rings = options.rings or 0
	if rings > 0 then
		local ring: { [number]: number } = {}
		local frontier: { number } = {}
		for id in along do
			table.insert(frontier, id)
		end
		for _ = 1, rings do
			local nextFrontier: { number } = {}
			for _, id in frontier do
				for neighbor in top.neighbors[id] do
					if not along[neighbor] and not ring[neighbor] then
						ring[neighbor] = U.weight(mask, neighbor)
						table.insert(nextFrontier, neighbor)
					end
				end
			end
			frontier = nextFrontier
		end
		out = S.smooth(out, ring, options.ringIterations or 3)
	end
	return out:recalculateNormals(), count
end
function S.crease(
	mesh: Mesh,
	mask: Mask?,
	point: Vector3,
	normal: Vector3,
	width: number,
	depth: number,
	pinch: number?
): Mesh
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
function S.displace(mesh: Mesh, field: (position: Vector3, id: number) -> Vector3, mask: Mask?): Mesh
	local out = mesh:clone()
	for id, p in mesh.vertices do
		local d = field(p, id)
		assert(U.vector(d))
		out.vertices[id] = p + d * U.weight(mask, id)
	end
	return out:recalculateNormals()
end
function S.symmetrize(
	mesh: Mesh,
	axis: ("X" | "Y" | "Z")?,
	sourcePositive: boolean?,
	tolerance: number?
): Mesh
	local axis: "X" | "Y" | "Z" = axis or "X"
	assert(axis == "X" or axis == "Y" or axis == "Z")
	local tolerance: number = tolerance or 1e-4
	local direction = axis == "X" and Vector3.xAxis or axis == "Y" and Vector3.yAxis or Vector3.zAxis
	local out = mesh:clone()
	-- axis is asserted to be "X", "Y" or "Z" above; component reads go through any.
	local sources: { [number]: Vector3 } = {}
	for id, p in mesh.vertices do
		if
			(sourcePositive ~= false and (p :: any)[axis] >= 0)
			or (sourcePositive == false and (p :: any)[axis] <= 0)
		then
			sources[id] = p
		end
	end
	for id, p in out.vertices do
		if math.abs((p :: any)[axis]) <= tolerance then
			out.vertices[id] = p - direction * (p :: any)[axis]
		elseif (sources[id] :: Vector3?) == nil then
			local target = p - direction * 2 * (p :: any)[axis]
			local best: Vector3?, dist = nil, math.huge
			for _, q in sources do
				local d = (q - target).Magnitude
				if d < dist then
					best = q
					dist = d
				end
			end
			if best then
				local mirrored: Vector3 = best
				-- axis is "X", "Y" or "Z" (asserted above).
				out.vertices[id] = mirrored - direction * 2 * (mirrored :: any)[axis]
			end
		end
	end
	return out:recalculateNormals()
end
return S
