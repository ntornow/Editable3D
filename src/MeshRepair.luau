--!strict
-- Explicit cleanup, winding repair and bounded intersection arrangements.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local C = require(script.Parent.Connectivity)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Arrangement options pass through to ArrangementSnapshot, MeshArrangement and Intersections.
export type ArrangementOptions = { [string]: any }
export type CleanOptions = {
	areaTolerance: number?,
	maxElements: number?,
	removeLoose: boolean?,
	checkpoint: ((fraction: number) -> ())?,
	[string]: any,
}
export type OrientOptions = {
	maxWork: number?,
	outward: boolean?,
	checkpoint: ((fraction: number) -> ())?,
	[string]: any,
}
-- Reports carry operation-specific fields (validation, removed IDs, arrangement audits, ...).
export type RepairReport = { [string]: any }
local R = {}
function R.splitIntersections(mesh: Mesh, options: ArrangementOptions?): (Mesh, RepairReport)
	local copies
	copies, options = require(script.Parent.ArrangementSnapshot)({ mesh }, options)
	mesh = copies[1]
	local data = require(script.Parent.MeshArrangement)(mesh, options)
	local out, report = require(script.Parent.MeshArrangementBuild)(data, nil, true, options)
	assert(report.validation.valid, "Intersection splitting produced invalid source-sheet topology")
	report.arrangement, report.complete = data.report, true
	report.mode = "separate_sheets"
	report.work = data.getWork()
	return out, report
end
function R.resolveIntersections(mesh: Mesh, options: ArrangementOptions?): (Mesh, RepairReport)
	local copies
	copies, options = require(script.Parent.ArrangementSnapshot)({ mesh }, options)
	mesh = copies[1]
	local data = require(script.Parent.MeshArrangement)(mesh, options)
	local selection, classification = require(script.Parent.MeshWindingBoundary)(data, options)
	local conformity = require(script.Parent.MeshArrangementConform)(data, selection, options)
	local out, report = require(script.Parent.MeshArrangementBuild)(data, selection, false, options)
	local scan = table.clone((options :: ArrangementOptions).intersectionOptions or {})
	scan.maxWork = scan.maxWork or (options :: ArrangementOptions).maxWork
	scan.includeAdjacent, scan.includeContacts = false, true
	scan.checkpoint = scan.checkpoint or (options :: ArrangementOptions).checkpoint
	local _, audit = require(script.Parent.Intersections).mesh(out, scan)
	report.arrangement, report.classification, report.intersections = data.report, classification, audit
	report.conformity = conformity
	report.mode = "winding_boundary"
	report.work = data.getWork()
	report.empty = not next(out.faces)
	report.complete = report.validation.valid
		and (report.empty or report.validation.closed)
		and audit.complete
		and audit.intersectionFree
	if not report.complete then
		report.reason = not report.validation.valid and "invalid_topology"
			or not (report.empty or report.validation.closed) and "open_boundary"
			or not audit.complete and "incomplete_audit"
			or "remaining_intersections"
	end
	return out, report
end
function R.clean(mesh: Mesh, options: CleanOptions?): (Mesh, RepairReport)
	local options: CleanOptions = options or {}
	local tolerance = options.areaTolerance or 1e-12
	assert(
		type(tolerance) == "number" and U.finite(tolerance) and tolerance >= 0,
		"Nonnegative finite area tolerance required"
	)
	local maxElements = U.integer(options.maxElements or 2000000, 1)
	assert(U.count(mesh.vertices) + U.count(mesh.faces) <= maxElements, "Cleanup element budget exceeded")
	if options.checkpoint then
		options.checkpoint(0)
	end
	local out = mesh:clone()
	local report = { removedFaces = {}, removedVertices = {} }
	local work = 0
	for _, fid in U.keys(out.faces) do
		local f = out.faces[fid]
		local seen, reason = {}, nil
		if #f.vertices < 3 or #f.vertices ~= #f.corners then
			reason = "malformed"
		end
		for _, v in f.vertices do
			work += 1
			assert(work <= maxElements, "Cleanup element budget exceeded")
			if not U.vector(out.vertices[v]) or seen[v] then
				reason = "invalid_vertex"
			end
			seen[v] = true
		end
		if not reason then
			local _, area = out:faceNormal(fid)
			if area <= tolerance then
				reason = "zero_area"
			end
			for i, v in f.vertices do
				if out.vertices[v] == out.vertices[f.vertices[i % #f.vertices + 1]] then
					reason = "zero_edge"
				end
			end
		end
		if reason then
			out.faces[fid] = nil
			report.removedFaces[fid] = reason
		end
		if options.checkpoint and work % 256 == 0 then
			options.checkpoint(work / maxElements)
		end
	end
	-- Invalid isolated positions cannot enter a connectivity index.
	for v, p in out.vertices do
		if not U.vector(p) then
			out.vertices[v] = nil
			out.weights[v] = nil
			for _, g in out.groups do
				g[v] = nil
			end
			report.removedVertices[v] = true
		end
	end
	local index = C.index(out, options)
	for fid in index.duplicateFaces do
		out.faces[fid] = nil
		report.removedFaces[fid] = "duplicate"
	end
	if options.removeLoose ~= false then
		local old = table.clone(out.vertices)
		out:removeUnused()
		for id in old do
			if not out.vertices[id] then
				report.removedVertices[id] = true
			end
		end
	end
	for id in out.weights do
		if not out.vertices[id] then
			out.weights[id] = nil
		end
	end
	for _, group in out.groups do
		for id in group do
			if not out.vertices[id] then
				group[id] = nil
			end
		end
	end
	A.prune(out)
	A.validate(out)
	out:recalculateNormals()
	report.validation = out:validate()
	report.complete = report.validation.valid
	return out, report
end
function R.orient(mesh: Mesh, options: OrientOptions?): (Mesh, RepairReport)
	local options: OrientOptions = options or {}
	local index = C.index(mesh, options)
	A.validate(mesh)
	local maxWork = U.integer(options.maxWork or 2000000, 1)
	if options.checkpoint then
		options.checkpoint(0)
	end
	for _, e in index.edges do
		assert(#e.faces <= 2, "Winding repair requires at most two faces per edge")
	end
	local flipped, components, work = {}, {}, 0
	for _, seed in U.keys(mesh.faces) do
		if flipped[seed] ~= nil then
			continue
		end
		local queue, cursor, closed = { seed }, 1, true
		flipped[seed] = false
		while cursor <= #queue do
			local fid = queue[cursor]
			cursor += 1
			for _, ck in index.faces[fid].corners do
				work += 1
				assert(work <= maxWork, "Winding repair work budget exceeded")
				local h = index.corners[ck]
				local edge = index.edges[h.edge]
				if #edge.faces == 1 then
					closed = false
					continue
				end
				local other = index.corners[edge.corners[1] == ck and edge.corners[2] or edge.corners[1]]
				local wanted = flipped[fid] ~= (h.vertex == other.vertex)
				if flipped[other.face] == nil then
					flipped[other.face] = wanted
					table.insert(queue, other.face)
				else
					assert(flipped[other.face] == wanted, "Mesh component is not consistently orientable")
				end
			end
			if options.checkpoint and work % 256 == 0 then
				options.checkpoint(work / maxWork)
			end
		end
		table.insert(components, { faces = queue, closed = closed })
	end
	local out = mesh:clone()
	local function reverse(fid: number)
		local f = out.faces[fid]
		local vs, cs = {}, {}
		for i = #f.vertices, 1, -1 do
			table.insert(vs, f.vertices[i])
			table.insert(cs, U.copy(f.corners[i]))
			if cs[#cs].normal then
				cs[#cs].normal = -(cs[#cs].normal :: Vector3)
			end
			if cs[#cs].tangentSign then
				cs[#cs].tangentSign = -(cs[#cs].tangentSign :: number)
			end
		end
		f.vertices, f.corners = vs, cs
	end
	for fid, flip in flipped do
		if flip then
			reverse(fid)
		end
	end
	for _, component in components do
		if component.closed and options.outward ~= false then
			local part = out:clone()
			part.faces = {}
			for _, fid in component.faces do
				part.faces[fid] = U.copy(out.faces[fid])
			end
			local volume = part:volume(out.vertices[out.faces[component.faces[1]].vertices[1]])
			component.volume = math.abs(volume)
			if volume < 0 then
				for _, fid in component.faces do
					reverse(fid)
					flipped[fid] = not flipped[fid]
				end
			end
		end
	end
	local maps = { corner = {} }
	local changed = {}
	for fid, flip in flipped do
		if flip then
			changed[fid] = true
			local n = #mesh.faces[fid].vertices
			for i = 1, n do
				maps.corner[fid .. ":" .. i] = { { fid .. ":" .. (n - i + 1), 1 } }
			end
		end
	end
	A.transfer(mesh, out, maps)
	out:recalculateNormals()
	local validation = out:validate()
	return out,
		{ flipped = changed, components = components, validation = validation, complete = validation.valid }
end
export type AuditOptions = {
	weld: number?,
	crack: number?,
	fold: number?,
	overlap: number?,
	stride: number?,
	limit: number?,
}
export type AuditReport = {
	faces: number,
	vertices: number,
	weldedVertices: number,
	boundaryEdges: number,
	nonManifoldEdges: number,
	crackEdges: number,
	degenerateFaces: number,
	duplicateFaces: number,
	foldedEdges: number,
	isolatedFaces: number,
	overlapFaces: number,
	closed: boolean,
	signedVolume: number,
	insideOut: boolean,
	samples: { [string]: { number } },
}
-- One-call health check of a mesh (soups included: corners are welded by position first).
-- boundary/non-manifold edges; crack edges (boundary edges with another boundary edge within
-- `crack`, i.e. hairline cracks); degenerate and duplicate faces; folded edges (adjacent faces
-- turned more than acos(fold) against each other, i.e. crumpled or flipped triangles); isolated
-- faces (no shared edge: a sign of interleaved chunks or an unwelded soup); co-facing
-- self-overlap within `overlap` (sampled every `stride` faces); signed volume, and insideOut when
-- the mesh is closed with negative volume. `samples` lists up to `limit` face ids per problem.
function R.audit(mesh: Mesh, options: AuditOptions?): AuditReport
	local o: AuditOptions = options or {}
	local weldTol = o.weld or 1e-4
	local crackTol = o.crack or 0.06
	local foldCos = o.fold or -0.3
	local limit = o.limit or 20
	local Topology = require(script.Parent.Topology) :: any
	local nv, nf = 0, 0
	for _ in mesh.vertices do
		nv += 1
	end
	for _ in mesh.faces do
		nf += 1
	end
	local w = Topology.weld(mesh, weldTol)
	local wv = 0
	for _ in w.vertices do
		wv += 1
	end
	local samples: { [string]: { number } } = {}
	local function note(kind: string, id: number)
		local list = samples[kind] or {}
		samples[kind] = list
		if #list < limit then
			table.insert(list, id)
		end
	end
	-- edges of the welded mesh
	local edgeFaces: { [string]: { number } } = {}
	local degenerate, volume = 0, 0
	local normals: { [number]: Vector3 } = {}
	local seen: { [string]: boolean } = {}
	local duplicates = 0
	for fid, f in w.faces do
		local vs = f.vertices
		local a = w.vertices[vs[1]]
		local n = Vector3.zero
		for i = 2, #vs - 1 do
			local b, c = w.vertices[vs[i]], w.vertices[vs[i + 1]]
			n += (b - a):Cross(c - a)
			volume += a:Dot(b:Cross(c)) / 6
		end
		if n.Magnitude < 1e-12 then
			degenerate += 1
			note("degenerate", fid)
		else
			normals[fid] = n.Unit
		end
		local sorted = table.clone(vs)
		table.sort(sorted)
		local key = table.concat(sorted, ",")
		if seen[key] then
			duplicates += 1
			note("duplicate", fid)
		end
		seen[key] = true
		for i = 1, #vs do
			local x, y = vs[i], vs[i % #vs + 1]
			local k = if x < y then x .. "|" .. y else y .. "|" .. x
			edgeFaces[k] = edgeFaces[k] or {}
			table.insert(edgeFaces[k], fid)
		end
	end
	local boundary, nonManifold, folded = 0, 0, 0
	local shared: { [number]: number } = {}
	local boundaryEdges: { { Vector3 } } = {}
	for k, fs in edgeFaces do
		if #fs == 1 then
			boundary += 1
			local a, b = string.match(k, "^(%d+)|(%d+)$")
			table.insert(
				boundaryEdges,
				{ w.vertices[tonumber(a) :: number], w.vertices[tonumber(b) :: number] }
			)
		elseif #fs > 2 then
			nonManifold += 1
			note("nonManifold", fs[1])
		else
			shared[fs[1]] = (shared[fs[1]] or 0) + 1
			shared[fs[2]] = (shared[fs[2]] or 0) + 1
			local n1, n2 = normals[fs[1]], normals[fs[2]]
			if n1 and n2 and n1:Dot(n2) < foldCos then
				folded += 1
				note("folded", fs[1])
			end
		end
	end
	local isolated = 0
	for fid in w.faces do
		if not shared[fid] then
			isolated += 1
			note("isolated", fid)
		end
	end
	-- cracks: boundary edges whose midpoint lies within crackTol of another boundary edge
	local cell = math.max(crackTol, 1e-3) * 4
	local grid: { [string]: { number } } = {}
	local function gkey(p: Vector3): string
		return math.floor(p.X / cell) .. "," .. math.floor(p.Y / cell) .. "," .. math.floor(p.Z / cell)
	end
	for i, e in boundaryEdges do
		local k = gkey((e[1] + e[2]) / 2)
		grid[k] = grid[k] or {}
		table.insert(grid[k], i)
	end
	local cracks = 0
	for i, e in boundaryEdges do
		local m = (e[1] + e[2]) / 2
		local cx, cy, cz = math.floor(m.X / cell), math.floor(m.Y / cell), math.floor(m.Z / cell)
		local found = false
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local list: { number } = grid[(cx + dx) .. "," .. (cy + dy) .. "," .. (cz + dz)] or {}
					for _, j in list do
						if j ~= i then
							local o2 = boundaryEdges[j]
							local m2 = (o2[1] + o2[2]) / 2
							if (m2 - m).Magnitude <= crackTol and (m2 - m).Magnitude > 1e-9 then
								found = true
							end
						end
					end
				end
			end
		end
		if found then
			cracks += 1
		end
	end
	-- co-facing self-overlap (sampled): a face centroid lying on a non-adjacent face
	local overlap = 0
	if o.overlap and o.overlap > 0 then
		local Spatial = require(script.Parent.Spatial) :: any
		local index = Spatial.new(w)
		local stride = math.max(1, math.floor(o.stride or 1))
		local i = 0
		for fid, f in w.faces do
			i += 1
			local n = normals[fid]
			if n and i % stride == 0 then
				local vs = f.vertices
				local c = Vector3.zero
				for _, v in vs do
					c += w.vertices[v]
				end
				c /= #vs
				-- probe just above the face: another co-facing face within `overlap` above it
				local hit = index:raycast(c + n * 1e-4, n, o.overlap)
				if hit and hit.face ~= fid and hit.normal:Dot(n) > 0.8 then
					overlap += 1
					note("overlap", fid)
				end
			end
		end
	end
	local closed = boundary == 0 and nonManifold == 0
	return {
		faces = nf,
		vertices = nv,
		weldedVertices = wv,
		boundaryEdges = boundary,
		nonManifoldEdges = nonManifold,
		crackEdges = cracks,
		degenerateFaces = degenerate,
		duplicateFaces = duplicates,
		foldedEdges = folded,
		isolatedFaces = isolated,
		overlapFaces = overlap,
		closed = closed,
		signedVolume = volume,
		insideOut = closed and volume < 0,
		samples = samples,
	}
end
-- Removes spikes and pits: a vertex that sits off the plane of its mesh neighbourhood (positions
-- within `rings` edge rings, default 2, grown up to `maxRings` until `minNeighbours` are found) by
-- more than `distance` and more than `ratio` times the neighbours' own spread off that plane moves
-- to the middle of its edge ring, projected onto that plane; repeated `iterations` times (spikes
-- often come in pairs). The neighbourhood is topological, so a vertex pushed far off the surface
-- still finds the surface it belongs to. Positions are matched by `weld`, so every split copy of a
-- vertex (soups, UV seams) moves together and topology, corners and UVs are kept. Deviations of
-- `maxMove` or more are left alone (real layered geometry, not noise). Returns the mesh and
-- { spikes, moved (vertex ids), maxMove }.
export type DespikeOptions = {
	distance: number?,
	ratio: number?,
	rings: number?,
	maxRings: number?,
	minNeighbours: number?,
	iterations: number?,
	maxMove: number?,
	weld: number?,
}
local function smallestAxis(m: { { number } }): Vector3
	-- Jacobi rotations on a symmetric 3x3 matrix; returns the eigenvector of the smallest eigenvalue
	local a = { { m[1][1], m[1][2], m[1][3] }, { m[2][1], m[2][2], m[2][3] }, { m[3][1], m[3][2], m[3][3] } }
	local v = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }
	for _ = 1, 24 do
		local p, q, big = 1, 2, math.abs(a[1][2])
		if math.abs(a[1][3]) > big then
			p, q, big = 1, 3, math.abs(a[1][3])
		end
		if math.abs(a[2][3]) > big then
			p, q, big = 2, 3, math.abs(a[2][3])
		end
		if big < 1e-14 then
			break
		end
		local theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
		local t = (if theta >= 0 then 1 else -1) / (math.abs(theta) + math.sqrt(theta * theta + 1))
		local c = 1 / math.sqrt(t * t + 1)
		local sn = t * c
		for k = 1, 3 do
			local akp, akq = a[k][p], a[k][q]
			a[k][p], a[k][q] = c * akp - sn * akq, sn * akp + c * akq
		end
		for k = 1, 3 do
			local apk, aqk = a[p][k], a[q][k]
			a[p][k], a[q][k] = c * apk - sn * aqk, sn * apk + c * aqk
		end
		for k = 1, 3 do
			local vkp, vkq = v[k][p], v[k][q]
			v[k][p], v[k][q] = c * vkp - sn * vkq, sn * vkp + c * vkq
		end
	end
	local best = 1
	for i = 2, 3 do
		if a[i][i] < a[best][best] then
			best = i
		end
	end
	return Vector3.new(v[1][best], v[2][best], v[3][best])
end
function R.despike(mesh: Mesh, options: DespikeOptions?): (Mesh, RepairReport)
	local o: DespikeOptions = options or {}
	local distance = o.distance or 0.3
	local ratio = o.ratio or 4
	local rings = o.rings or 2
	local maxRings = o.maxRings or 4
	local minNeighbours = o.minNeighbours or 8
	local maxMove = o.maxMove or 2
	local weld = o.weld or 1e-4
	-- unique positions and their adjacency (through any face, so soups connect by position)
	local keyOf: { [number]: number } = {}
	local unique: { Vector3 } = {}
	local index: { [string]: number } = {}
	for id, v in mesh.vertices do
		local k =
			string.format("%d,%d,%d", math.round(v.X / weld), math.round(v.Y / weld), math.round(v.Z / weld))
		local i = index[k]
		if not i then
			table.insert(unique, v)
			i = #unique
			index[k] = i
		end
		keyOf[id] = i
	end
	local adjacent: { [number]: { [number]: boolean } } = {}
	for _, f in mesh.faces do
		local vs = f.vertices
		for i = 1, #vs do
			local a, b = keyOf[vs[i]], keyOf[vs[i % #vs + 1]]
			if a ~= b then
				adjacent[a] = adjacent[a] or {}
				adjacent[b] = adjacent[b] or {}
				adjacent[a][b] = true
				adjacent[b][a] = true
			end
		end
	end
	local function neighbourhood(i: number): { number }
		local seen: { [number]: boolean } = { [i] = true }
		local frontier: { number } = { i }
		local out: { number } = {}
		local depth = 0
		while depth < maxRings and #frontier > 0 do
			depth += 1
			local nextFrontier: { number } = {}
			for _, a in frontier do
				local around: { [number]: boolean } = adjacent[a] or {}
				for b in around do
					if not seen[b] then
						seen[b] = true
						table.insert(out, b)
						table.insert(nextFrontier, b)
					end
				end
			end
			frontier = nextFrontier
			if depth >= rings and #out >= minNeighbours then
				break
			end
		end
		return out
	end
	local P = table.clone(unique)
	local n = #P
	local fixed: { [number]: boolean } = {}
	local spikes = 0
	local largest = 0
	local hoods: { [number]: { number } } = {}
	for _ = 1, o.iterations or 4 do
		local moves: { [number]: Vector3 } = {}
		for i = 1, n do
			local nb = hoods[i]
			if not nb then
				nb = neighbourhood(i)
				hoods[i] = nb
			end
			if #nb >= minNeighbours then
				local p = P[i]
				local c = Vector3.zero
				for _, j in nb do
					c += P[j]
				end
				c /= #nb
				local m = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
				for _, j in nb do
					local d = P[j] - c
					m[1][1] += d.X * d.X
					m[1][2] += d.X * d.Y
					m[1][3] += d.X * d.Z
					m[2][2] += d.Y * d.Y
					m[2][3] += d.Y * d.Z
					m[3][3] += d.Z * d.Z
				end
				m[2][1], m[3][1], m[3][2] = m[1][2], m[1][3], m[2][3]
				local normal = smallestAxis(m)
				local spread = 0
				for _, j in nb do
					spread += ((P[j] - c):Dot(normal)) ^ 2
				end
				spread = math.sqrt(spread / #nb)
				local off = (p - c):Dot(normal)
				if
					math.abs(off) > distance
					and math.abs(off) > ratio * spread
					and math.abs(off) < maxMove
				then
					-- to the middle of its own ring (where a vertex of a regular mesh sits), on the plane
					local ring, k = Vector3.zero, 0
					local around: { [number]: boolean } = adjacent[i] or {}
					for j in around do
						ring += P[j]
						k += 1
					end
					local base = if k > 0 then ring / k else p
					moves[i] = base - normal * (base - c):Dot(normal)
				end
			end
		end
		if next(moves) == nil then
			break
		end
		for i, q in moves do
			largest = math.max(largest, (q - unique[i]).Magnitude)
			P[i] = q
			if not fixed[i] then
				fixed[i] = true
				spikes += 1
			end
		end
	end
	local out = mesh:clone()
	local moved: { number } = {}
	for id, i in keyOf do
		if fixed[i] then
			out:setPosition(id, P[i])
			table.insert(moved, id)
		end
	end
	return out, { spikes = spikes, moved = moved, maxMove = largest }
end
-- Untangles crumpled and flipped triangles: vertices on folded edges (adjacent faces turned more
-- than acos(fold) against each other) and their neighbours `rings` deep are moved toward their
-- neighbours' average, repeating until no fold remains or `iterations` is reached. Works on
-- soups (welds by position first; the result is welded, corners and UVs kept). Boundary
-- vertices stay put. Returns the mesh and { folds before, folds after, moved vertices }.
export type UnfoldOptions =
	{ fold: number?, iterations: number?, rings: number?, weld: number?, step: number? }
function R.unfold(mesh: Mesh, options: UnfoldOptions?): (Mesh, RepairReport)
	local o: UnfoldOptions = options or {}
	local foldCos = o.fold or -0.3
	local rings = o.rings or 2
	local step = o.step or 0.5
	local Topology = require(script.Parent.Topology) :: any
	local w = Topology.weld(mesh, o.weld or 1e-4)
	local neighbours: { [number]: { [number]: boolean } } = {}
	local edgeFaces: { [string]: { number } } = {}
	for fid, f in w.faces do
		local vs = f.vertices
		for i = 1, #vs do
			local x, y = vs[i], vs[i % #vs + 1]
			neighbours[x] = neighbours[x] or {}
			neighbours[y] = neighbours[y] or {}
			neighbours[x][y] = true
			neighbours[y][x] = true
			local k = if x < y then x .. "|" .. y else y .. "|" .. x
			edgeFaces[k] = edgeFaces[k] or {}
			table.insert(edgeFaces[k], fid)
		end
	end
	local boundary: { [number]: boolean } = {}
	for k, fs in edgeFaces do
		if #fs ~= 2 then
			local a, b = string.match(k, "^(%d+)|(%d+)$")
			boundary[tonumber(a) :: number] = true
			boundary[tonumber(b) :: number] = true
		end
	end
	local function folds(): { [number]: boolean }
		local normals = {}
		for fid, f in w.faces do
			local vs = f.vertices
			local a = w.vertices[vs[1]]
			local n = Vector3.zero
			for i = 2, #vs - 1 do
				n += (w.vertices[vs[i]] - a):Cross(w.vertices[vs[i + 1]] - a)
			end
			normals[fid] = if n.Magnitude > 1e-12 then n.Unit else nil
		end
		local verts = {}
		for k, fs in edgeFaces do
			if #fs == 2 then
				local n1, n2 = normals[fs[1]], normals[fs[2]]
				if n1 and n2 and n1:Dot(n2) < foldCos then
					for _, fid in fs do
						for _, v in w.faces[fid].vertices do
							verts[v] = true
						end
					end
				end
			end
		end
		return verts
	end
	local function count(t: { [number]: boolean }): number
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	local start = folds()
	local before = count(start)
	local movedSet: { [number]: boolean } = {}
	local current = start
	local iterations = 0
	for it = 1, o.iterations or 30 do
		if next(current) == nil then
			break
		end
		iterations = it
		local region = table.clone(current)
		for _ = 1, rings do
			local grow = {}
			for v in region do
				local adjacent: { [number]: boolean } = neighbours[v] or {}
				for u in adjacent do
					grow[u] = true
				end
			end
			for u in grow do
				region[u] = true
			end
		end
		local nextPos = {}
		for v in region do
			if not boundary[v] then
				local sum, n = Vector3.zero, 0
				local adjacent: { [number]: boolean } = neighbours[v] or {}
				for u in adjacent do
					sum += w.vertices[u]
					n += 1
				end
				if n > 0 then
					nextPos[v] = w.vertices[v]:Lerp(sum / n, step)
				end
			end
		end
		for v, p in nextPos do
			w.vertices[v] = p
			movedSet[v] = true
		end
		current = folds()
	end
	w.revision += 1
	return w:recalculateNormals(),
		{ before = before, after = count(current), moved = count(movedSet), iterations = iterations }
end
return R
