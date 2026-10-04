--!strict
-- Polygon authoring mesh. IDs are monotonically allocated, never array indices.
-- Each face owns its corner attributes; UV/normal discontinuities are explicit.
local U = require(script.Parent.Util)
local Attributes = require(script.Parent.AttributeCore)
local Connectivity = require(script.Parent.Connectivity)
local Predicates = require(script.Parent.Predicates)
local Types = require(script.Parent.Types)
export type Mesh = Types.Mesh
export type Face = Types.Face
export type Corner = Types.Corner
type Self = Mesh
local Mesh = {}
Mesh.__index = Mesh
function Mesh.new(): Mesh
	return setmetatable({
		vertices = {},
		faces = {},
		weights = {},
		groups = {},
		attributes = {},
		nextVertex = 1,
		nextFace = 1,
		revision = 0,
	}, Mesh) :: any
end
function Mesh.addVertex(self: Self, position: Vector3): number
	assert(U.vector(position), "Vertex must be finite Vector3")
	local id = self.nextVertex
	self.nextVertex += 1
	self.vertices[id] = position
	self.revision += 1
	return id
end
function Mesh.addFace(self: Self, vertices: { number }, corners: { Corner }?, material: number?): number
	assert(#vertices >= 3, "Face needs at least three vertices")
	local seen = {}
	for _, id in vertices do
		assert(self.vertices[id] and not seen[id], "Missing or repeated face vertex")
		seen[id] = true
	end
	assert(corners == nil or #corners == #vertices, "Corner count mismatch")
	local id = self.nextFace
	self.nextFace += 1
	local copiedCorners: { Corner } = {}
	for i = 1, #vertices do
		copiedCorners[i] = corners and U.copy(corners[i]) or {}
	end
	self.faces[id] = {
		vertices = table.clone(vertices),
		corners = copiedCorners,
		material = material or 1,
	}
	self.revision += 1
	return id
end
function Mesh.setPosition(self: Self, id: number, p: Vector3)
	assert(self.vertices[id] and U.vector(p), "Invalid position/vertex")
	self.vertices[id] = p
	self.revision += 1
end
function Mesh.removeFace(self: Self, id: number)
	assert(self.faces[id], "Unknown face")
	self.faces[id] = nil
	Attributes.prune(self)
	self.revision += 1
end
function Mesh.removeUnused(self: Self): Mesh
	local used = {}
	for _, f in self.faces do
		for _, v in f.vertices do
			used[v] = true
		end
	end
	for v in self.vertices do
		if not used[v] then
			self.vertices[v] = nil
			self.weights[v] = nil
			for _, g in self.groups do
				g[v] = nil
			end
		end
	end
	Attributes.prune(self)
	self.revision += 1
	return self
end
function Mesh.clone(self: Self): Mesh
	local m = Mesh.new()
	for k, v in self :: any do
		(m :: any)[k] = U.copy(v)
	end
	return m
end
function Mesh.bounds(self: Self): (Vector3, Vector3)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	assert(next(self.vertices), "Empty mesh has no bounds")
	for _, p in self.vertices do
		lo = lo:Min(p)
		hi = hi:Max(p)
	end
	return lo, hi
end
function Mesh.faceNormal(self: Self, id: number): (Vector3, number)
	local vs = assert(self.faces[id]).vertices
	local origin = self.vertices[vs[1]]
	local nx, ny, nz, permanent = 0, 0, 0, 0
	for i, id in vs do
		local p, q = self.vertices[id], self.vertices[vs[i % #vs + 1]]
		local px, py, pz = p.X - origin.X, p.Y - origin.Y, p.Z - origin.Z
		local qx, qy, qz = q.X - origin.X, q.Y - origin.Y, q.Z - origin.Z
		nx += py * qz - pz * qy
		ny += pz * qx - px * qz
		nz += px * qy - py * qx
		permanent += math.abs(py * qz) + math.abs(pz * qy) + math.abs(pz * qx) + math.abs(px * qz) + math.abs(
			px * qy
		) + math.abs(py * qx)
	end
	if math.max(math.abs(nx), math.abs(ny), math.abs(nz)) <= permanent * 2 ^ -45 then
		local yz, zx, xy = {}, {}, {}
		for i, id in vs do
			local p = self.vertices[id]
			yz[i] = Vector2.new(p.Y, p.Z)
			zx[i] = Vector2.new(p.Z, p.X)
			xy[i] = Vector2.new(p.X, p.Y)
		end
		local _, ax = Predicates.polygonOrientation(yz)
		local _, ay = Predicates.polygonOrientation(zx)
		local _, az = Predicates.polygonOrientation(xy)
		nx, ny, nz = ax * 2, ay * 2, az * 2
	end
	local length = math.sqrt(nx * nx + ny * ny + nz * nz)
	if length == 0 then
		return Vector3.zero, 0
	end
	return Vector3.new(nx / length, ny / length, nz / length), length * 0.5
end

function Mesh.topology(self: Self): Types.MeshTopology
	local edges: { [string]: Types.TopologyEdge } = {}
	local neighbors: { [number]: { [number]: boolean } } = {}
	local vertexFaces: { [number]: { number } } = {}
	for v in self.vertices do
		neighbors[v] = {}
		vertexFaces[v] = {}
	end
	for _, fid in U.keys(self.faces) do
		local f = self.faces[fid]
		for i, a in f.vertices do
			local b = f.vertices[i % #f.vertices + 1]
			local key = U.edge(a, b)
			local e = edges[key] or { a = math.min(a, b), b = math.max(a, b), faces = {}, directions = {} }
			edges[key] = e
			table.insert(e.faces, fid)
			table.insert(e.directions, a < b and 1 or -1)
			neighbors[a][b] = true
			neighbors[b][a] = true
			table.insert(vertexFaces[a], fid)
		end
	end
	return { edges = edges, neighbors = neighbors, vertexFaces = vertexFaces }
end
-- Ear clipping supports simple planar concave polygons. Returns corner indices.
function Mesh.faceTriangles(self: Self, fid: number, options: Types.TriangulationOptions?): { { number } }
	local f = assert(self.faces[fid])
	local options: Types.TriangulationOptions = options or {}
	assert(#f.vertices <= (options.maxVertices or 2000), "Face triangulation vertex budget exceeded")
	local n = self:faceNormal(fid)
	assert(n.Magnitude > 0, "Degenerate polygon")
	local ax = math.abs(n.X)
	local ay = math.abs(n.Y)
	local az = math.abs(n.Z)
	local pts = {}
	for i, id in f.vertices do
		local p = self.vertices[id]
		pts[i] = ax >= ay and ax >= az and Vector2.new(p.Y, p.Z)
			or (ay >= az and Vector2.new(p.Z, p.X) or Vector2.new(p.X, p.Y))
	end
	if #pts == 3 then
		return { { 1, 2, 3 } }
	end
	local sign = Predicates.polygonOrientation(pts)
	assert(sign ~= 0, "Degenerate projected polygon")
	local work = 0
	local function visit()
		work += 1
		assert(work <= (options.maxWork or 5000000), "Face triangulation work budget exceeded")
		local onVisit, checkpoint = options._visit, options.checkpoint
		if onVisit then
			onVisit()
		end
		if work % 256 == 0 and checkpoint then
			checkpoint(work / (options.maxWork or 5000000))
		end
	end
	local function cross(a, b, c)
		visit()
		return Predicates.orient2D(a, b, c)
	end
	if options.validateSimple then
		for i, a in pts do
			for j = i + 1, #pts do
				if j ~= i % #pts + 1 and i ~= j % #pts + 1 then
					visit()
					local hit =
						Predicates.intersectSegments2D(a, pts[i % #pts + 1], pts[j], pts[j % #pts + 1])
					assert(hit.kind == "none", "Projected polygon is not simple")
				end
			end
		end
	end
	local ring: { number } = {}
	for i = 1, #pts do
		ring[i] = i
	end
	local out: { { number } } = {}
	while #ring > 3 do
		local cut = false
		for j, b in ring do
			local a = ring[(j - 2) % #ring + 1]
			local c = ring[j % #ring + 1]
			if cross(pts[a], pts[b], pts[c]) * sign > 0 then
				local inside = false
				for _, k in ring do
					if k ~= a and k ~= b and k ~= c then
						if
							cross(pts[a], pts[b], pts[k]) * sign >= 0
							and cross(pts[b], pts[c], pts[k]) * sign >= 0
							and cross(pts[c], pts[a], pts[k]) * sign >= 0
						then
							inside = true
							break
						end
					end
				end
				if not inside then
					table.insert(out, { a, b, c })
					table.remove(ring, j)
					cut = true
					break
				end
			end
		end
		assert(cut, "Cannot triangulate degenerate or self-intersecting polygon")
	end
	assert(cross(pts[ring[1]], pts[ring[2]], pts[ring[3]]) * sign > 0, "Final polygon triangle is degenerate")
	table.insert(out, ring)
	return out
end
function Mesh.triangles(self: Self): { Types.Triangle }
	local r: { Types.Triangle } = {}
	for _, fid in U.keys(self.faces) do
		local f = self.faces[fid]
		for _, c in self:faceTriangles(fid) do
			table.insert(r, { f.vertices[c[1]], f.vertices[c[2]], f.vertices[c[3]], face = fid, corners = c })
		end
	end
	return r
end
function Mesh.volume(self: Self, origin: Vector3?): number
	assert(origin == nil or U.vector(origin), "Finite volume origin required")
	if not next(self.vertices) then
		return 0
	end
	if not origin then
		local closed = true
		for _, edge in self:topology().edges do
			if #edge.faces ~= 2 or edge.directions[1] == edge.directions[2] then
				closed = false
				break
			end
		end
		-- Open pieces retain a common world origin so their oriented tetrahedra add.
		origin = closed and self.vertices[U.keys(self.vertices)[1]] or Vector3.zero
	end
	local origin = origin :: Vector3
	local sum, compensation = 0, 0
	for _, t in self:triangles() do
		local a, b, c = self.vertices[t[1]], self.vertices[t[2]], self.vertices[t[3]]
		local ax, ay, az = a.X - origin.X, a.Y - origin.Y, a.Z - origin.Z
		local bx, by, bz = b.X - origin.X, b.Y - origin.Y, b.Z - origin.Z
		local cx, cy, cz = c.X - origin.X, c.Y - origin.Y, c.Z - origin.Z
		local value = (ax * (by * cz - bz * cy) + ay * (bz * cx - bx * cz) + az * (bx * cy - by * cx)) / 6
		local adjusted = value - compensation
		local nextSum = sum + adjusted
		compensation = (nextSum - sum) - adjusted
		sum = nextSum
	end
	return sum
end

function Mesh.validate(self: Self, options: Types.ValidateOptions?): Types.ValidationReport
	local minimumFaceArea = (options or {} :: Types.ValidateOptions).minimumFaceArea
	if minimumFaceArea == nil then
		minimumFaceArea = 1e-12
	end
	assert(
		type(minimumFaceArea) == "number" and U.finite(minimumFaceArea) and minimumFaceArea >= 0,
		"Minimum face area must be finite and nonnegative"
	)
	local errors: { string } = {}
	local valid = true
	local boundary, nonmanifold, winding, degenerate = 0, 0, 0, 0
	for id, p in self.vertices do
		if not U.vector(p) then
			table.insert(errors, "Nonfinite vertex " .. id)
			valid = false
		end
	end
	for id, f in self.faces do
		local seen = {}
		for _, v in f.vertices do
			if not self.vertices[v] or seen[v] then
				valid = false
				table.insert(errors, "Invalid face " .. id)
			end
			seen[v] = true
		end
		if #f.vertices < 3 or #f.corners ~= #f.vertices then
			valid = false
			table.insert(errors, "Malformed face " .. id)
		end
	end
	if valid then
		for _, e in self:topology().edges do
			if #e.faces == 1 then
				boundary += 1
			elseif #e.faces > 2 then
				nonmanifold += 1
			elseif e.directions[1] == e.directions[2] then
				winding += 1
			end
		end
		for id in self.faces do
			local _, area = self:faceNormal(id)
			if not U.finite(area) or area <= 0 or area < minimumFaceArea then
				degenerate += 1
			end
		end
	end
	if valid then
		local ok, err = pcall(Attributes.validate, self)
		if not ok then
			table.insert(errors, tostring(err))
		end
	end
	local connectivity: any = valid and Connectivity.analyze(self) or nil
	local badVertices = connectivity and U.count(connectivity.nonmanifoldVertices) or 0
	local duplicates = connectivity and U.count(connectivity.duplicateFaces) or 0
	local zeroEdges = connectivity and U.count(connectivity.zeroLengthEdges) or 0
	local validSurface = #errors == 0
		and nonmanifold == 0
		and winding == 0
		and degenerate == 0
		and badVertices == 0
		and duplicates == 0
		and zeroEdges == 0
	return {
		valid = validSurface,
		errors = errors,
		vertices = U.count(self.vertices),
		faces = U.count(self.faces),
		boundaryEdges = boundary,
		nonmanifoldEdges = nonmanifold,
		nonmanifoldVertices = badVertices,
		duplicateFaces = duplicates,
		zeroLengthEdges = zeroEdges,
		looseVertices = connectivity and U.count(connectivity.looseVertices) or 0,
		eulerCharacteristic = connectivity and connectivity.eulerCharacteristic or nil,
		surfaceComponents = connectivity and #connectivity.components or nil,
		windingErrors = winding,
		degenerateFaces = degenerate,
		closed = validSurface and boundary == 0 and next(self.faces) ~= nil,
	}
end
function Mesh.recalculateNormals(self: Self, angle: number?, sharpEdges: { [string]: boolean }?): Mesh
	local angle: number = angle or math.pi
	assert(
		type(angle) == "number" and U.finite(angle) and angle >= 0 and angle <= math.pi,
		"Normal angle must be in [0,pi]"
	)
	local t = self:topology()
	if sharpEdges == nil then
		local channel = (self.attributes or {} :: { [string]: Types.Channel }).sharp_edge
		if channel then
			assert(
				channel.domain == "edge" and channel.dataType == "boolean",
				"Sharp normal attribute must be edge boolean"
			)
			Attributes.validate(self)
			local fromChannel: { [string]: boolean } = {}
			for key in t.edges do
				fromChannel[key] = Attributes.read(channel, key)
			end
			sharpEdges = fromChannel
		end
	else
		assert(type(sharpEdges) == "table", "Sharp edges must be a selection table")
		for key, value in sharpEdges do
			assert(t.edges[key] and type(value) == "boolean", "Invalid sharp edge selection")
		end
	end
	local normals: { [number]: Vector3 }, areas: { [number]: number } = {}, {}
	local threshold = math.cos(angle)
	for id in self.faces do
		normals[id], areas[id] = self:faceNormal(id)
	end
	for id, f in self.faces do
		for i, v in f.vertices do
			local n = Vector3.zero
			local candidates = t.vertexFaces[v]
			if sharpEdges then
				candidates = { id }
				local seen, cursor = { [id] = true }, 1
				while cursor <= #candidates do
					local current = self.faces[candidates[cursor]]
					cursor += 1
					local index = table.find(current.vertices, v) :: number
					for _, neighbor in
						{
							current.vertices[index % #current.vertices + 1],
							current.vertices[(index - 2) % #current.vertices + 1],
						}
					do
						local key = U.edge(v, neighbor)
						if not sharpEdges[key] then
							for _, other in t.edges[key].faces do
								if
									not seen[other]
									and normals[id]:Dot(normals[other]) >= threshold - 1e-8
								then
									seen[other] = true
									table.insert(candidates, other)
								end
							end
						end
					end
				end
			end
			for _, other in candidates do
				if normals[id]:Dot(normals[other]) >= threshold - 1e-8 then
					n += normals[other] * areas[other]
				end
			end
			f.corners[i].normal = U.unit(n, normals[id])
		end
	end
	self.revision += 1
	return self
end
return Mesh
