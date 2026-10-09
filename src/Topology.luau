--!strict
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
type Face = Types.Face
type Corner = Types.Corner
-- A correspondence reference: { sourceKey, weight }. Keys are vertex IDs, face IDs,
-- edge keys or "face:corner" strings depending on the domain.
export type Ref = { any }
-- Face-ID set: a selected face maps to any truthy value.
export type FaceSet = { [number]: any }
local T = {}
local function ref(key: any, weight: number?): Ref
	return { key, weight or 1 }
end
local function cornerKey(fid: number, i: number): string
	return fid .. ":" .. i
end
local function mixCorners(face: Face, references: { Ref }): Corner
	local result: { [string]: any }, fields: { [string]: boolean } = {}, {}
	for _, pair in references do
		for field in face.corners[pair[1]] :: any do
			fields[field] = true
		end
	end
	for field in fields do
		local channel: any, refs: { Ref } = nil, {}
		for _, pair in references do
			local value = (face.corners[pair[1]] :: any)[field]
			if value ~= nil then
				local kind = typeof(value)
				channel = channel
					or {
						dataType = kind,
						values = {},
						interpolation = (kind == "boolean" or kind == "string") and "nearest" or "linear",
					}
				channel.values[pair[1]] = value
				table.insert(refs, pair)
			end
		end
		result[field] = A.blend(channel, refs)
	end
	return result :: Corner
end
function T.triangulate(mesh: Mesh): Mesh
	local out = mesh:clone()
	out.faces = {}
	out.nextFace = 1
	local maps = { face = {}, corner = {}, identity = { face = false, corner = false } }
	for _, t in mesh:triangles() do
		local f = mesh.faces[t.face]
		local fid = out:addFace(
			{ t[1], t[2], t[3] },
			{ f.corners[t.corners[1]], f.corners[t.corners[2]], f.corners[t.corners[3]] },
			f.material
		)
		maps.face[fid] = { ref(t.face) }
		for i, c in t.corners do
			maps.corner[cornerKey(fid, i)] = { ref(cornerKey(t.face, c)) }
		end
	end
	return A.transfer(mesh, out, maps)
end
function T.join(meshes: { Mesh }): Mesh
	local out = Mesh.new()
	for _, m in meshes do
		local map = {}
		local maps = {
			vertex = {},
			edge = {},
			face = {},
			corner = {},
			identity = { vertex = false, edge = false, face = false, corner = false },
		}
		for _, id in U.keys(m.vertices) do
			map[id] = out:addVertex(m.vertices[id])
			maps.vertex[map[id]] = { ref(id) }
			out.weights[map[id]] = U.copy(m.weights[id])
		end
		for _, id in U.keys(m.faces) do
			local f = m.faces[id]
			local v = {}
			for _, a in f.vertices do
				table.insert(v, map[a])
			end
			local fid = out:addFace(v, f.corners, f.material)
			maps.face[fid] = { ref(id) }
			for i, a in f.vertices do
				maps.corner[cornerKey(fid, i)] = { ref(cornerKey(id, i)) }
				local b = f.vertices[i % #f.vertices + 1]
				maps.edge[U.edge(map[a], map[b])] = { ref(U.edge(a, b)) }
			end
		end
		A.transfer(m, out, maps, true)
		for name, g in m.groups do
			out.groups[name] = out.groups[name] or {}
			for id, w in g do
				out.groups[name][map[id]] = w
			end
		end
	end
	return out
end
-- A sheet from a grid of points: rows[r][c] is a Vector3 or false (a hole). Every cell whose four
-- corners exist becomes two triangles (split along the shorter diagonal), so a masked grid gives a
-- sheet with an arbitrary outline: a re-surfaced panel over part of a figure, a terrain patch, a
-- height field sampled along curved rows (each row following a hem, say). Corner UVs are
-- (c - 1) / (columns - 1), (r - 1) / (rows - 1) unless options.uv(r, c, position) supplies them.
-- Faces wind counter-clockwise seen from the side where rows advance up and columns advance right
-- (the +Z side for rows along +Y and columns along +X); pass flip = true for the other side.
-- options.normal(r, c, position) sets every corner's normal (made unit) instead of leaving normals to
-- recalculateNormals or Roblox.toModel: compute them over the whole grid when one surface is cut into
-- several sheets (one texture each), so the cuts don't show as shading seams.
-- Vertices that no cell uses are not added.
export type GridSheetOptions = {
	uv: ((number, number, Vector3) -> Vector2)?,
	normal: ((number, number, Vector3) -> Vector3)?,
	flip: boolean?,
}
function T.gridSheet(rows: { { Vector3 | false } }, options: GridSheetOptions?): Mesh
	local o: GridSheetOptions = options or {}
	local nr = #rows
	assert(nr >= 2, "gridSheet needs at least two rows")
	local nc = #rows[1]
	assert(nc >= 2, "gridSheet needs at least two columns")
	for r = 2, nr do
		assert(#rows[r] == nc, "gridSheet rows must have matching lengths")
	end
	local out = Mesh.new()
	local ids: { [number]: number } = {}
	local function vid(r: number, c: number): number
		local k = (r - 1) * nc + c
		local id = ids[k]
		if not id then
			id = out:addVertex(rows[r][c] :: Vector3)
			ids[k] = id
		end
		return id
	end
	local function uv(r: number, c: number): Vector2
		if o.uv then
			return o.uv(r, c, rows[r][c] :: Vector3)
		end
		return Vector2.new((c - 1) / (nc - 1), (r - 1) / (nr - 1))
	end
	-- explicit vertex normals (unit), shared by every corner of the vertex: sheets cut from one larger grid
	-- then join without the shading seam that per-sheet recalculated normals leave along the cut
	local function normal(r: number, c: number): Vector3
		local n = (o.normal :: (number, number, Vector3) -> Vector3)(r, c, rows[r][c] :: Vector3)
		return if n.Magnitude > 1e-12 then n.Unit else n
	end
	local function tri(a: { number }, b: { number }, c: { number })
		local pa = rows[a[1]][a[2]] :: Vector3
		local pb = rows[b[1]][b[2]] :: Vector3
		local pc = rows[c[1]][c[2]] :: Vector3
		if (pb - pa):Cross(pc - pa).Magnitude <= 1e-12 then
			return
		end
		local va, vb, vc = vid(a[1], a[2]), vid(b[1], b[2]), vid(c[1], c[2])
		local ca, cb, cc = { uv = uv(a[1], a[2]) }, { uv = uv(b[1], b[2]) }, { uv = uv(c[1], c[2]) }
		if o.normal then
			ca.normal, cb.normal, cc.normal = normal(a[1], a[2]), normal(b[1], b[2]), normal(c[1], c[2])
		end
		if o.flip then
			out:addFace({ va, vc, vb }, { ca, cc, cb })
		else
			out:addFace({ va, vb, vc }, { ca, cb, cc })
		end
	end
	for r = 1, nr - 1 do
		for c = 1, nc - 1 do
			local p00, p01 = rows[r][c], rows[r][c + 1]
			local p10, p11 = rows[r + 1][c], rows[r + 1][c + 1]
			if p00 and p01 and p10 and p11 then
				local a, b, d, e = { r, c }, { r, c + 1 }, { r + 1, c }, { r + 1, c + 1 }
				if
					((p11 :: Vector3) - (p00 :: Vector3)).Magnitude
					<= ((p01 :: Vector3) - (p10 :: Vector3)).Magnitude
				then
					tri(a, b, e)
					tri(a, e, d)
				else
					tri(a, b, d)
					tri(b, e, d)
				end
			end
		end
	end
	return out
end
export type GridSectorOptions = {
	sectors: { number }?,
	inset: number?,
	flip: boolean?,
	normal: ((number, number, Vector3) -> Vector3)?,
}
export type GridSector = {
	mesh: Mesh,
	first: number,
	last: number,
	toGrid: (Vector2) -> (number, number),
}
-- A grid of points (as gridSheet) cut into sheets by column ranges, each with its own UV rectangle: one texture
-- per sector, for a surface too large for one map (a robe, a sleeve all round an arm). sectors lists the column
-- boundaries (1-based, ascending, first 1 and last the column count; default { 1, columns }); neighbouring sectors
-- share their boundary column. Each sector's UVs fill [inset, 1 - inset] (inset in UV units, default 0, so baked
-- padding has room): u along its columns, v along the rows. toGrid(uv) inverts that mapping to the fractional
-- (row, column) of the whole grid, so a bake shader can sample per-vertex tables there (Bake.gridSample) instead
-- of reconstructing a parametrisation from positions. normal(r, c, position) and flip are passed to gridSheet with
-- whole-grid indices, so normals computed over the full grid join without seams.
function T.gridSectors(rows: { { Vector3 | false } }, options: GridSectorOptions?): { GridSector }
	local o: GridSectorOptions = options or {}
	local nr = #rows
	assert(nr >= 2, "gridSectors needs at least two rows")
	local nc = #rows[1]
	assert(nc >= 2, "gridSectors needs at least two columns")
	local bounds = o.sectors or { 1, nc }
	assert(
		#bounds >= 2 and bounds[1] == 1 and bounds[#bounds] == nc,
		"gridSectors bounds must run from 1 to the column count"
	)
	local inset = o.inset or 0
	assert(inset >= 0 and inset < 0.5, "gridSectors inset must be in [0, 0.5)")
	local span = 1 - 2 * inset
	local out: { GridSector } = {}
	for k = 1, #bounds - 1 do
		local first, last = bounds[k], bounds[k + 1]
		assert(last > first, "gridSectors bounds must ascend")
		local sub: { { Vector3 | false } } = table.create(nr)
		for r = 1, nr do
			local row: { Vector3 | false } = table.create(last - first + 1)
			for c = first, last do
				row[c - first + 1] = rows[r][c]
			end
			sub[r] = row
		end
		local sheetOptions: GridSheetOptions = {
			flip = o.flip,
			uv = function(r: number, c: number, _p: Vector3): Vector2
				return Vector2.new(inset + span * (c - 1) / (last - first), inset + span * (r - 1) / (nr - 1))
			end,
		}
		local normal = o.normal
		if normal then
			sheetOptions.normal = function(r: number, c: number, p: Vector3): Vector3
				return normal(r, first + c - 1, p)
			end
		end
		local mesh = T.gridSheet(sub, sheetOptions)
		table.insert(out, {
			mesh = mesh,
			first = first,
			last = last,
			toGrid = function(uv: Vector2): (number, number)
				return 1 + (uv.Y - inset) / span * (nr - 1), first + (uv.X - inset) / span * (last - first)
			end,
		})
	end
	return out
end
function T.extract(mesh: Mesh, faces: FaceSet): Mesh
	local out = mesh:clone()
	for id in out.faces do
		if not faces[id] then
			out.faces[id] = nil
		end
	end
	return out:removeUnused()
end
function T.components(mesh: Mesh): { Mesh }
	local top = mesh:topology()
	local seen = {}
	local result = {}
	for _, root in U.keys(mesh.faces) do
		if not seen[root] then
			local set = { [root] = true }
			local queue = { root }
			seen[root] = true
			local i = 1
			while i <= #queue do
				local f = mesh.faces[queue[i]]
				i += 1
				for _, v in f.vertices do
					for _, nextId in top.vertexFaces[v] do
						if not seen[nextId] then
							seen[nextId] = true
							set[nextId] = true
							table.insert(queue, nextId)
						end
					end
				end
			end
			table.insert(result, T.extract(mesh, set))
		end
	end
	return result
end
export type ComponentInfo = { index: number, centroid: Vector3, count: number, min: Vector3, max: Vector3 }
-- Connected pieces of a mesh as labels on its vertices, with coincident vertices welded: faces join their corners,
-- and vertices closer than `tolerance` (default 1e-4) join each other, so a triangle soup or a mesh split at UV
-- seams still labels each solid piece once. Returns the label of every vertex id and, per label (numbered in order
-- of first vertex id), its centroid, vertex count and bounds. Unlike Topology.components, nothing is copied.
function T.componentLabels(
	mesh: Mesh,
	options: { tolerance: number? }?
): ({ [number]: number }, { ComponentInfo })
	local tolerance = options and options.tolerance or 1e-4
	assert(tolerance >= 0, "Invalid weld tolerance")
	local parent: { [number]: number } = {}
	local function find(i: number): number
		local r = i
		while parent[r] ~= r do
			r = parent[r]
		end
		while parent[i] ~= r do
			local nextId = parent[i]
			parent[i] = r
			i = nextId
		end
		return r
	end
	local function join(a: number, b: number)
		local ra, rb = find(a), find(b)
		if ra ~= rb then
			parent[rb] = ra
		end
	end
	local ids = U.keys(mesh.vertices)
	table.sort(ids)
	for _, id in ids do
		parent[id] = id
	end
	for _, f in mesh.faces do
		for k = 2, #f.vertices do
			join(f.vertices[1], f.vertices[k])
		end
	end
	if tolerance > 0 then
		local cell = tolerance
		-- numeric cell keys (a collision only adds candidates: distances are checked)
		local grid: { [number]: { number } } = {}
		local function keyOf(x: number, y: number, z: number): number
			return x * 73856093 + y * 19349663 + z * 83492791
		end
		for _, id in ids do
			local p = mesh.vertices[id]
			local cx, cy, cz = math.floor(p.X / cell), math.floor(p.Y / cell), math.floor(p.Z / cell)
			for dx = -1, 1 do
				for dy = -1, 1 do
					for dz = -1, 1 do
						local list = grid[keyOf(cx + dx, cy + dy, cz + dz)]
						if list then
							for _, other in list do
								if (mesh.vertices[other] - p).Magnitude <= tolerance then
									join(other, id)
								end
							end
						end
					end
				end
			end
			local k = keyOf(cx, cy, cz)
			local list = grid[k]
			if not list then
				list = {}
				grid[k] = list
			end
			table.insert(list, id)
		end
	end
	local labels: { [number]: number } = {}
	local infos: { ComponentInfo } = {}
	local labelOf: { [number]: number } = {}
	local sums: { Vector3 } = {}
	for _, id in ids do
		local r = find(id)
		local label: number = labelOf[r] or 0
		local p = mesh.vertices[id]
		if label == 0 then
			label = #infos + 1
			labelOf[r] = label
			infos[label] = { index = label, centroid = Vector3.zero, count = 0, min = p, max = p }
			sums[label] = Vector3.zero
		end
		labels[id] = label
		local info = infos[label]
		info.count += 1
		info.min = info.min:Min(p)
		info.max = info.max:Max(p)
		sums[label] += p
	end
	for label, info in infos do
		info.centroid = sums[label] / info.count
	end
	return labels, infos
end
function T.reverse(mesh: Mesh): Mesh
	local out = mesh:clone()
	local maps = { corner = {}, identity = { corner = false } }
	for fid, f in out.faces do
		local v, c = {}, {}
		for i = #f.vertices, 1, -1 do
			table.insert(v, f.vertices[i])
			local corner = U.copy(f.corners[i])
			if corner.normal then
				corner.normal = -corner.normal
			end
			if corner.tangentSign then
				corner.tangentSign = -corner.tangentSign
			end
			table.insert(c, corner)
			maps.corner[cornerKey(fid, #c)] = { ref(cornerKey(fid, i)) }
		end
		f.vertices = v
		f.corners = c
	end
	out.revision += 1
	return A.transfer(mesh, out, maps)
end
function T.weld(mesh: Mesh, tolerance: number): (Mesh, { [number]: number })
	assert(tolerance > 0, "Positive tolerance required")
	local out = mesh:clone()
	local buckets: { [string]: { number } }, map: { [number]: number } = {}, {}
	local maps = { vertex = {}, edge = {}, corner = {}, identity = { edge = false, corner = false } }
	local function bucketKey(x: number, y: number, z: number): string
		return x .. "," .. y .. "," .. z
	end
	for _, id in U.keys(out.vertices) do
		local p = out.vertices[id]
		local x, y, z = math.floor(p.X / tolerance), math.floor(p.Y / tolerance), math.floor(p.Z / tolerance)
		local found: number?
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					for _, other in (buckets[bucketKey(x + dx, y + dy, z + dz)] or {}) :: { number } do
						if
							(p - out.vertices[other]).Magnitude <= tolerance and (not found or other < found)
						then
							found = other
						end
					end
				end
			end
		end
		map[id] = found or id
		maps.vertex[map[id]] = maps.vertex[map[id]] or {}
		table.insert(maps.vertex[map[id]], ref(id))
		if not found then
			local k = bucketKey(x, y, z)
			buckets[k] = buckets[k] or {}
			table.insert(buckets[k], id)
		end
	end
	for fid, f in out.faces do
		local v, c, seen = {}, {}, {}
		for i, id in f.vertices do
			local a = map[id]
			if not seen[a] then
				seen[a] = true
				table.insert(v, a)
				table.insert(c, f.corners[i])
				maps.corner[cornerKey(fid, #v)] = { ref(cornerKey(fid, i)) }
			end
		end
		if #v < 3 then
			out.faces[fid] = nil
			for i = 1, #v do
				maps.corner[cornerKey(fid, i)] = nil
			end
		else
			f.vertices = v
			f.corners = c
		end
	end
	local surviving = A.keys(out, "edge")
	local sourceEdges = mesh:topology().edges
	for _, key in U.keys(sourceEdges) do
		local e = sourceEdges[key]
		local nextKey = U.edge(map[e.a], map[e.b])
		if surviving[nextKey] then
			maps.edge[nextKey] = maps.edge[nextKey] or {}
			table.insert(maps.edge[nextKey], ref(key))
		end
	end
	A.transfer(mesh, out, maps)
	for _, g in out.groups do
		for id, w in table.clone(g) do
			g[map[id]] = math.max(g[map[id]] or 0, w)
		end
	end
	return out:removeUnused():recalculateNormals(), map
end
function T.extrude(mesh: Mesh, selected: FaceSet, offset: Vector3): (Mesh, { [number]: number })
	assert(U.vector(offset))
	local out = mesh:clone()
	-- Boundary entries are { a, b, sourceFace, cornerIndex }, or false once shared.
	local map: { [number]: number }, boundary: { [string]: { number } | false } = {}, {}
	local maps = { vertex = {}, edge = {}, face = {}, corner = {} }
	for _, fid in U.keys(selected) do
		if selected[fid] then
			local f = assert(mesh.faces[fid], "Unknown selected face")
			for i, a in f.vertices do
				if not map[a] then
					map[a] = out:addVertex(mesh.vertices[a] + offset)
					out.weights[map[a]] = U.copy(mesh.weights[a])
					maps.vertex[map[a]] = { ref(a) }
				end
				local b = f.vertices[i % #f.vertices + 1]
				local k = U.edge(a, b)
				if boundary[k] then
					boundary[k] = false
				else
					boundary[k] = { a, b, fid, i }
				end
			end
		end
	end
	for fid in selected do
		if selected[fid] then
			local f = mesh.faces[fid]
			for i, a in f.vertices do
				local b = f.vertices[i % #f.vertices + 1]
				maps.edge[U.edge(map[a], map[b])] = { ref(U.edge(a, b)) }
			end
		end
	end
	for fid in selected do
		if selected[fid] then
			local f = out.faces[fid]
			for i, v in f.vertices do
				f.vertices[i] = map[v]
			end
		end
	end
	for _, edge in boundary do
		if edge then
			local entry = edge :: { number }
			local a, b = entry[1], entry[2]
			local sourceId, i = entry[3], entry[4]
			local face = mesh.faces[sourceId]
			local j = i % #face.vertices + 1
			local fid = out:addFace(
				{ a, b, map[b], map[a] },
				{ face.corners[i], face.corners[j], face.corners[j], face.corners[i] },
				face.material
			)
			maps.face[fid] = { ref(sourceId) }
			for k, c in { i, j, j, i } do
				maps.corner[cornerKey(fid, k)] = { ref(cornerKey(sourceId, c)) }
			end
		end
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	return out:removeUnused():recalculateNormals(), map
end
function T.insetFaces(mesh: Mesh, selected: FaceSet, fraction: number): Mesh
	assert(fraction > 0 and fraction < 1, "Inset fraction must be between zero and one")
	local out = mesh:clone()
	local maps = { vertex = {}, edge = {}, face = {}, corner = {} }
	for _, fid in U.keys(selected) do
		if selected[fid] then
			local f = mesh.faces[fid]
			local center = Vector3.zero
			for _, v in f.vertices do
				center += mesh.vertices[v]
			end
			center /= #f.vertices
			local inner, innerCorners, innerRefs = {}, {}, {}
			for i, v in f.vertices do
				inner[i] = out:addVertex(mesh.vertices[v]:Lerp(center, fraction))
				local vertexRefs, cornerRefs, localRefs = {}, {}, {}
				for j, other in f.vertices do
					local weight = fraction / #f.vertices + (i == j and 1 - fraction or 0)
					table.insert(vertexRefs, ref(other, weight))
					table.insert(cornerRefs, ref(cornerKey(fid, j), weight))
					table.insert(localRefs, ref(j, weight))
				end
				maps.vertex[inner[i]] = vertexRefs
				innerRefs[i] = cornerRefs
				innerCorners[i] = mixCorners(f, localRefs)
				maps.corner[cornerKey(fid, i)] = cornerRefs
			end
			out.faces[fid].vertices = inner
			out.faces[fid].corners = innerCorners
			for i, a in f.vertices do
				local j = i % #f.vertices + 1
				local ringId = out:addFace(
					{ a, f.vertices[j], inner[j], inner[i] },
					{ f.corners[i], f.corners[j], innerCorners[j], innerCorners[i] },
					f.material
				)
				maps.face[ringId] = { ref(fid) }
				maps.corner[cornerKey(ringId, 1)] = { ref(cornerKey(fid, i)) }
				maps.corner[cornerKey(ringId, 2)] = { ref(cornerKey(fid, j)) }
				maps.corner[cornerKey(ringId, 3)] = innerRefs[j]
				maps.corner[cornerKey(ringId, 4)] = innerRefs[i]
				maps.edge[U.edge(inner[i], inner[j])] = { ref(U.edge(a, f.vertices[j])) }
			end
		end
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	return out:recalculateNormals()
end
function T.bridge(mesh: Mesh, loopA: { number }, loopB: { number }): Mesh
	assert(#loopA == #loopB and #loopA >= 3, "Bridge requires equally sampled loops")
	local out = mesh:clone()
	for i, a in loopA do
		local j = i % #loopA + 1
		out:addFace({ a, loopA[j], loopB[j], loopB[i] })
	end
	return out:recalculateNormals()
end
function T.fill(mesh: Mesh, loop: { number }): Mesh
	local out = mesh:clone()
	out:addFace(loop)
	return out:recalculateNormals()
end
function T.splitEdge(mesh: Mesh, a: number, b: number, t: number?): (Mesh, number)
	local t: number = t or 0.5
	assert(t > 0 and t < 1)
	assert(mesh:topology().edges[U.edge(a, b)], "Edge not found")
	local out = mesh:clone()
	local id = out:addVertex(mesh.vertices[a]:Lerp(mesh.vertices[b], t))
	local maps = {
		vertex = { [id] = { ref(a, 1 - t), ref(b, t) } },
		edge = { [U.edge(a, id)] = { ref(U.edge(a, b)) }, [U.edge(id, b)] = { ref(U.edge(a, b)) } },
		corner = {},
		identity = { corner = false },
	}
	for fid, f in out.faces do
		local inserted = nil

		for i, v in f.vertices do
			local j = i % #f.vertices + 1
			local w = f.vertices[j]
			if (v == a and w == b) or (v == b and w == a) then
				local fct = v == a and t or 1 - t
				inserted = { i, j, fct }
				local corner = {}
				for k, x in f.corners[i] do
					local y = f.corners[j][k]
					if
						y
						and (
							typeof(x) == "Vector2"
							or typeof(x) == "Vector3"
							or typeof(x) == "Color3"
							or type(x) == "number"
						)
					then
						corner[k] = U.mix(x, y, fct)
					end
				end
				table.insert(f.vertices, i + 1, id)
				table.insert(f.corners, i + 1, corner)
				break
			end
		end
		for k = 1, #f.vertices do
			if inserted and k == inserted[1] + 1 then
				maps.corner[cornerKey(fid, k)] = {
					ref(cornerKey(fid, inserted[1]), 1 - inserted[3]),
					ref(cornerKey(fid, inserted[2]), inserted[3]),
				}
			else
				local old = inserted and k > inserted[1] + 1 and k - 1 or k
				maps.corner[cornerKey(fid, k)] = { ref(cornerKey(fid, old)) }
			end
		end
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	return out:recalculateNormals(), id
end
function T.dissolveEdge(mesh: Mesh, a: number, b: number): Mesh
	local edge = mesh:topology().edges[U.edge(a, b)]
	assert(edge and #edge.faces == 2, "Dissolve requires two incident faces")
	local fa, fb = mesh.faces[edge.faces[1]], mesh.faces[edge.faces[2]]
	assert(fa.material == fb.material, "Material boundary cannot be dissolved")
	local na = mesh:faceNormal(edge.faces[1])
	local nb = mesh:faceNormal(edge.faces[2])
	assert(na:Dot(nb) > 1 - 1e-6, "Dissolve requires coplanar faces")
	local successors, corners, cornerRefs = {}, {}, {}
	for k, f in { fa, fb } do
		for i, v in f.vertices do
			local nextId = f.vertices[i % #f.vertices + 1]
			if U.edge(v, nextId) ~= U.edge(a, b) then
				assert(not successors[v], "Faces share more than one edge")
				successors[v] = nextId
				corners[v] = f.corners[i]
				cornerRefs[v] = cornerKey(edge.faces[k], i)
			end
		end
	end
	local start = U.keys(successors)[1]
	local loop, attrs, seen = {}, {}, {}
	local current = start
	repeat
		assert(current and not seen[current], "Boundary does not form a single loop")
		seen[current] = true
		table.insert(loop, current)
		table.insert(attrs, corners[current])
		current = successors[current]
	until current == start
	assert(#loop == U.count(successors), "Dissolve would produce holes")
	local out = mesh:clone()
	out.faces[edge.faces[1]] = nil
	out.faces[edge.faces[2]] = nil
	local fid = out:addFace(loop, attrs, fa.material)
	local maps = { face = { [fid] = { ref(edge.faces[1]), ref(edge.faces[2]) } }, corner = {} }
	for i, v in loop do
		maps.corner[cornerKey(fid, i)] = { ref(cornerRefs[v]) }
	end
	A.transfer(mesh, out, maps)
	return out:removeUnused():recalculateNormals()
end
-- Closes hairline cracks across a set of meshes. Vertices join the nearest cluster seed within
-- `tolerance` (seeds are taken in order, as in `weld`, so no vertex moves further than about
-- `tolerance`), then move to their cluster's average. Corners and UVs are kept, so baked textures
-- still fit. Faces that collapse are removed. Use it on chunks of one surface whose shared corners
-- drifted apart (for example, parts deformed separately), then call Normals.unify.
function T.snap(meshes: { Mesh }, tolerance: number): ({ Mesh }, number, number)
	assert(tolerance > 0, "Positive tolerance required")
	local refs: { { mesh: number, id: number, p: Vector3 } } = {}
	for mi, m in meshes do
		for _, id in U.keys(m.vertices) do
			table.insert(refs, { mesh = mi, id = id, p = m.vertices[id] })
		end
	end
	local seeds: { Vector3 } = {}
	local sums: { Vector3 }, counts: { number } = {}, {}
	local buckets: { [string]: { number } } = {}
	local assigned = table.create(#refs, 0)
	for i, r in refs do
		local x, y, z =
			math.floor(r.p.X / tolerance), math.floor(r.p.Y / tolerance), math.floor(r.p.Z / tolerance)
		local best: number?, distance = nil, tolerance
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local list: { number } = buckets[(x + dx) .. "," .. (y + dy) .. "," .. (z + dz)] or {}
					for _, c in list do
						local d = (seeds[c] - r.p).Magnitude
						if d <= distance then
							best, distance = c, d
						end
					end
				end
			end
		end
		local cluster: number
		if best then
			cluster = best
		else
			cluster = #seeds + 1
			seeds[cluster], sums[cluster], counts[cluster] = r.p, Vector3.zero, 0
			local k = x .. "," .. y .. "," .. z
			buckets[k] = buckets[k] or {}
			table.insert(buckets[k], cluster)
		end
		assigned[i] = cluster
		sums[cluster] += r.p
		counts[cluster] += 1
	end
	local out: { Mesh } = {}
	for mi, m in meshes do
		out[mi] = m:clone()
	end
	local moved = 0
	for i, r in refs do
		local target = sums[assigned[i]] / counts[assigned[i]]
		if target ~= r.p then
			out[r.mesh].vertices[r.id] = target
			moved += 1
		end
	end
	local removed = 0
	for mi, m in out do
		for _, fid in U.keys(m.faces) do
			local vs = m.faces[fid].vertices
			local a, area = m.vertices[vs[1]], 0
			for k = 2, #vs - 1 do
				area += (m.vertices[vs[k]] - a):Cross(m.vertices[vs[k + 1]] - a).Magnitude
			end
			if area <= 1e-12 then
				m.faces[fid] = nil
				removed += 1
			end
		end
		out[mi] = m:removeUnused()
	end
	return out, moved, removed
end
return T
