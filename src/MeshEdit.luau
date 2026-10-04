--!strict
-- Polygon modeling operations with stable surviving IDs and typed correspondence.
local U = require(script.Parent.Util)
local Core = require(script.Parent.MeshEditCore)
local C = require(script.Parent.Connectivity)
local Loops = require(script.Parent.MeshLoops)
local P = require(script.Parent.Predicates)
local A = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Selections map face IDs (or edge keys / vertex IDs for bevels) to true or a positive weight.
export type Selection = { [any]: boolean | number }
-- Operator reports carry operation-specific fields: correspondence maps, added/replaced IDs,
-- validation and per-operator results. See MESH_EDITING.md for each operator's fields.
export type EditReport = { [string]: any }
-- Options pass through to the shared edit budget (maxVertices, maxFaces, checkpoint, ...)
-- and to operator-specific settings.
export type EditOptions = { [string]: any }
export type PokeOptions = { center: string?, offset: number?, [string]: any }
export type QuadOptions = {
	maxAngle: number?,
	maxCornerAngle: number?,
	attributeTolerance: number?,
	maxCandidates: number?,
	delimitAttributes: boolean?,
	[string]: any,
}
local E = {}
function E.bevelEdges(
	mesh: Mesh,
	selected: Selection,
	width: number,
	options: EditOptions?
): (Mesh, EditReport)
	return require(script.Parent.MeshBevel)(mesh, selected, width, options, "edges")
end
function E.bevelVertices(
	mesh: Mesh,
	selected: Selection,
	width: number,
	options: EditOptions?
): (Mesh, EditReport)
	return require(script.Parent.MeshBevel)(mesh, selected, width, options, "vertices")
end
-- Stroke records are described in MESH_EDITING.md.
function E.knife(mesh: Mesh, strokes: { any }, options: EditOptions?): (Mesh, EditReport)
	return require(script.Parent.MeshKnife)(mesh, strokes, options)
end
function E.knifeNetwork(mesh: Mesh, strokes: { any }, options: EditOptions?): (Mesh, EditReport)
	return require(script.Parent.MeshKnifeNetwork)(mesh, strokes, options)
end
function E.bisect(mesh: Mesh, origin: Vector3, normal: Vector3, options: EditOptions?): (Mesh, EditReport)
	return require(script.Parent.MeshBisect)(mesh, origin, normal, options)
end
function E.gridFill(mesh: Mesh, boundary: { number }, span: number, options: EditOptions?): (Mesh, EditReport)
	return require(script.Parent.MeshGridFill)(mesh, boundary, span, options)
end
function E.spin(
	mesh: Mesh,
	profile: { number },
	origin: Vector3,
	axis: Vector3,
	angle: number,
	steps: number,
	options: EditOptions?
): (Mesh, EditReport)
	return require(script.Parent.MeshSpin)(mesh, profile, origin, axis, angle, steps, options)
end
function E.screw(
	mesh: Mesh,
	profile: { number },
	origin: Vector3,
	axis: Vector3,
	turns: number,
	pitch: number,
	steps: number,
	options: EditOptions?
): (Mesh, EditReport)
	assert(type(turns) == "number" and U.finite(turns) and turns ~= 0, "Nonzero finite turns required")
	assert(type(pitch) == "number" and U.finite(pitch), "Finite screw pitch required")
	local config = table.clone(options or {})
	config.rise = turns * pitch
	return E.spin(mesh, profile, origin, axis, turns * 2 * math.pi, steps, config)
end
function E.insetRegion(
	mesh: Mesh,
	selected: Selection,
	width: number,
	options: EditOptions?
): (Mesh, EditReport)
	return require(script.Parent.RegionInset)(mesh, selected, width, options)
end
function E.extrudeFaces(
	mesh: Mesh,
	selected: Selection,
	distance: number,
	options: EditOptions?
): (Mesh, EditReport)
	assert(
		type(distance) == "number" and U.finite(distance) and distance ~= 0,
		"Nonzero finite extrusion distance required"
	)
	local faces = Core.selection(mesh, selected)
	local edit = Core.begin(mesh, options)
	edit.report.tops, edit.report.sides = {}, {}
	for _, fid in faces do
		local f, top, refs = mesh.faces[fid], {} :: { number }, {}
		local offset = mesh:faceNormal(fid) * distance
		for i, v in f.vertices do
			top[i] = edit.vertex(mesh.vertices[v] + offset, { { v, 1 } })
			refs[i] = { { fid, i, 1 } }
		end
		edit.face(top, refs, f.material, { { fid, 1 } }, fid)
		edit.report.tops[fid], edit.report.sides[fid] = top, {}
		for i, a in f.vertices do
			local j = i % #f.vertices + 1
			local b = f.vertices[j]
			local side = edit.face(
				{ a, b, top[j], top[i] },
				{ refs[i], refs[j], refs[j], refs[i] },
				f.material,
				{ { fid, 1 } }
			)
			table.insert(edit.report.sides[fid], side)
			edit.maps.edge[U.edge(top[i], top[j])] = { { U.edge(a, b), 1 } :: { any } }
		end
	end
	return edit.finish()
end
function E.poke(mesh: Mesh, selected: Selection, options: PokeOptions?): (Mesh, EditReport)
	local options: PokeOptions = options or {}
	local mode, offset = options.center or "median", options.offset or 0
	assert(mode == "median" or mode == "area", "Poke center must be median or area")
	assert(type(offset) == "number" and U.finite(offset), "Finite poke offset required")
	local faces = Core.selection(mesh, selected)
	local edit = Core.begin(mesh, options)
	edit.report.centers, edit.report.faceMap = {}, {}
	for _, fid in faces do
		local f = mesh.faces[fid]
		local weights = table.create(#f.vertices, mode == "median" and 1 / #f.vertices or 0)
		if mode == "area" then
			local total = 0
			for _, triangle in mesh:faceTriangles(fid) do
				local a, b, c =
					mesh.vertices[f.vertices[triangle[1]]],
					mesh.vertices[f.vertices[triangle[2]]],
					mesh.vertices[f.vertices[triangle[3]]]
				local area = (b - a):Cross(c - a).Magnitude / 2
				total += area
				for _, i in triangle do
					weights[i] += area / 3
				end
			end
			assert(total > 0, "Degenerate poke source")
			for i, w in weights do
				weights[i] = w / total
			end
		end
		local origin = mesh.vertices[f.vertices[1]]
		local x, y, z = 0, 0, 0
		local vr, cr = {}, {}
		for i, v in f.vertices do
			local p, w = mesh.vertices[v], weights[i]
			x += (p.X - origin.X) * w
			y += (p.Y - origin.Y) * w
			z += (p.Z - origin.Z) * w
			table.insert(vr, { v, w })
			table.insert(cr, { fid, i, w })
		end
		local normal = mesh:faceNormal(fid)
		local center = origin + Vector3.new(x, y, z)
		local axis = math.abs(normal.X) > math.abs(normal.Y)
				and (math.abs(normal.X) > math.abs(normal.Z) and "X" or "Z")
			or (math.abs(normal.Y) > math.abs(normal.Z) and "Y" or "Z")
		local function project(p: Vector3): Vector2
			return axis == "X" and Vector2.new(p.Y, p.Z)
				or (axis == "Y" and Vector2.new(p.Z, p.X) or Vector2.new(p.X, p.Y))
		end
		local sign = (normal :: any)[axis] > 0 and 1 or -1
		for i, a in f.vertices do
			local b = f.vertices[i % #f.vertices + 1]
			assert(
				P.orient2D(project(mesh.vertices[a]), project(mesh.vertices[b]), project(center)) * sign > 0,
				"Poke center is outside the strict polygon kernel"
			)
		end
		local id = edit.vertex(center + normal * offset, vr)
		edit.report.centers[fid], edit.report.faceMap[fid] = id, {}
		for i, a in f.vertices do
			local j = i % #f.vertices + 1
			local nf = edit.face(
				{ a, f.vertices[j], id },
				{ { { fid, i, 1 } }, { { fid, j, 1 } }, cr },
				f.material,
				{ { fid, 1 } },
				i == 1 and fid or nil
			)
			table.insert(edit.report.faceMap[fid], nf)
		end
	end
	return edit.finish()
end
local function cutPositions(cuts: (number | { number })?): { number }
	if cuts == nil then
		cuts = 1
	end
	local result: { number } = {}
	if type(cuts) == "number" then
		U.integer(cuts, 1)
		assert(cuts <= 128, "Loop cut count exceeds 128")
		for i = 1, cuts do
			result[i] = i / (cuts + 1)
		end
	else
		assert(type(cuts) == "table" and #cuts >= 1 and #cuts <= 128, "Loop cut parameters required")
		local cuts = cuts :: { number }
		for i, t in cuts do
			assert(
				type(t) == "number" and U.finite(t) and t > 0 and t < 1 and (i == 1 or t > cuts[i - 1]),
				"Loop cut parameters must increase strictly inside (0,1)"
			)
			result[i] = t
		end
	end
	return result
end
-- cuts is a count (default 1) or strictly increasing parameters inside (0,1).
function E.loopCut(
	mesh: Mesh,
	edgeKey: string,
	cuts: (number | { number })?,
	options: EditOptions?
): (Mesh, EditReport)
	local options: EditOptions = options or {}
	local positions = cutPositions(cuts)
	local ring = Loops.edgeRing(mesh, edgeKey, options)
	assert(ring.complete and #ring.faces > 0, "Loop cut requires a complete nonempty quad strip")
	local edit = Core.begin(mesh, options)
	local index = C.index(mesh, options)
	local rails, splitFaces = {}, {}
	local first = index.edges[ring.edges[1]]
	rails[ring.edges[1]] = { a = first.a, b = first.b }
	for i, fid in ring.faces do
		local face = index.faces[fid]
		local current = rails[ring.edges[i]]
		local function otherNeighbor(v, exclude)
			local j = assert(table.find(face.vertices, v))
			local a, b = face.vertices[(j - 2) % 4 + 1], face.vertices[j % 4 + 1]
			assert(a == exclude or b == exclude, "Quad strip incidence mismatch")
			return a == exclude and b or a
		end
		local a, b = otherNeighbor(current.a, current.b), otherNeighbor(current.b, current.a)
		local key = ring.edges[i % #ring.edges + 1]
		assert(key == U.edge(a, b), "Quad strip ordering mismatch")
		if rails[key] then
			assert(rails[key].a == a and rails[key].b == b, "Loop cut has a twisted seam")
		else
			rails[key] = { a = a, b = b }
		end
		splitFaces[fid] = true
	end
	edit.report.ring, edit.report.rails, edit.report.loops, edit.report.faceMap = ring, rails, {}, {}
	for j = 1, #positions do
		edit.report.loops[j] = {}
	end
	for _, key in ring.edges do
		local rail = rails[key]
		rail.vertices, rail.parameters = {}, table.clone(positions)
		local previous = rail.a
		for j, t in positions do
			local id = edit.vertex(
				mesh.vertices[rail.a]:Lerp(mesh.vertices[rail.b], t),
				{ { rail.a, 1 - t }, { rail.b, t } }
			)
			rail.vertices[j] = id
			table.insert(edit.report.loops[j], id)
			edit.maps.edge[U.edge(previous, id)] = { { key, 1 } }
			previous = id
		end
		edit.maps.edge[U.edge(previous, rail.b)] = { { key, 1 } }
	end
	local function sequence(fid, i, j)
		local face = mesh.faces[fid]
		local a, b = face.vertices[i], face.vertices[j]
		local rail = assert(rails[U.edge(a, b)])
		local vertices, refs = { a }, { { { fid, i, 1 } } }
		for k = 1, #positions do
			local n = a == rail.a and k or #positions - k + 1
			local t = a == rail.a and positions[n] or 1 - positions[n]
			table.insert(vertices, rail.vertices[n])
			table.insert(refs, { { fid, i, 1 - t }, { fid, j, t } })
		end
		table.insert(vertices, b)
		table.insert(refs, { { fid, j, 1 } })
		return vertices, refs
	end
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		if splitFaces[fid] then
			local i: number = nil :: any
			for k, v in f.vertices do
				if rails[U.edge(v, f.vertices[k % 4 + 1])] then
					i = k
					break
				end
			end
			local j, k, l = i % 4 + 1, (i + 1) % 4 + 1, (i + 2) % 4 + 1
			local a, ar = sequence(fid, i, j)
			local b, br = sequence(fid, l, k)
			edit.report.faceMap[fid] = {}
			for band = 1, #a - 1 do
				local nf = edit.face(
					{ a[band], a[band + 1], b[band + 1], b[band] },
					{ ar[band], ar[band + 1], br[band + 1], br[band] },
					f.material,
					{ { fid, 1 } },
					band == 1 and fid or nil
				)
				table.insert(edit.report.faceMap[fid], nf)
			end
		else
			local vs, refs, changed = {}, {}, false
			for i, v in f.vertices do
				local j = i % #f.vertices + 1
				if rails[U.edge(v, f.vertices[j])] then
					local a, ar = sequence(fid, i, j)
					for k = 1, #a - 1 do
						table.insert(vs, a[k])
						table.insert(refs, ar[k])
					end
					changed = true
				else
					table.insert(vs, v)
					table.insert(refs, { { fid, i, 1 } })
				end
			end
			if changed then
				edit.face(vs, refs, f.material, { { fid, 1 } }, fid)
			end
		end
		edit.checkpoint()
	end
	return edit.finish()
end
-- targets maps each moving vertex ID to the adjacent vertex it slides toward.
function E.slideVertices(
	mesh: Mesh,
	targets: { [number]: number },
	factor: number,
	options: EditOptions?
): (Mesh, EditReport)
	assert(
		type(factor) == "number" and U.finite(factor) and factor >= 0 and factor < 1,
		"Slide factor must be in [0,1)"
	)
	local edit = Core.begin(mesh, options)
	local index = C.index(mesh, options)
	for _, id in U.keys(targets) do
		local target = targets[id]
		assert(
			mesh.vertices[id] and mesh.vertices[target] and index.edges[U.edge(id, target)],
			"Slide target must be an adjacent vertex"
		)
		edit.out:setPosition(id, mesh.vertices[id]:Lerp(mesh.vertices[target], factor))
		for _, ck in index.vertices[id].corners do
			edit.report.replacedFaces[index.corners[ck].face] = true
		end
		edit.checkpoint()
	end
	if not options or options.allowInversion ~= true then
		for fid in mesh.faces do
			assert(edit.out:faceNormal(fid):Dot(mesh:faceNormal(fid)) > 0, "Vertex slide inverted a face")
		end
	end
	return edit.finish()
end
-- Values are attribute payloads of any supported type.
local function sameValue(a: any, b: any, epsilon: number): boolean
	if typeof(a) ~= typeof(b) then
		return false
	end
	if a == b then
		return true
	end
	if type(a) == "number" then
		return math.abs(a - b) <= epsilon
	end
	if typeof(a) == "Vector2" or typeof(a) == "Vector3" then
		return (a - b).Magnitude <= epsilon
	end
	if typeof(a) == "Color3" then
		return math.max(math.abs(a.R - b.R), math.abs(a.G - b.G), math.abs(a.B - b.B)) <= epsilon
	end
	return false
end
function E.trianglesToQuads(mesh: Mesh, selected: Selection, options: QuadOptions?): (Mesh, EditReport)
	local options: QuadOptions = options or {}
	local faces = Core.selection(mesh, selected)
	local chosen = {}
	for _, fid in faces do
		chosen[fid] = true
	end
	local edit = Core.begin(mesh, options)
	local index = C.index(mesh, options)
	local angle = options.maxAngle or math.rad(30)
	local shapeAngle = options.maxCornerAngle or math.rad(165)
	local epsilon = options.attributeTolerance or 1e-6
	assert(
		type(angle) == "number" and U.finite(angle) and angle >= 0 and angle < math.pi / 2,
		"Quad normal angle must be in [0,pi/2)"
	)
	assert(
		type(shapeAngle) == "number"
			and U.finite(shapeAngle)
			and shapeAngle >= math.pi / 2
			and shapeAngle < math.pi,
		"Quad corner angle must be in [pi/2,pi)"
	)
	assert(
		type(epsilon) == "number" and U.finite(epsilon) and epsilon >= 0,
		"Nonnegative attribute tolerance required"
	)
	local maxCandidates = U.integer(options.maxCandidates or 500000, 1)
	local candidates, rejected = {}, {}
	local function reject(reason)
		rejected[reason] = (rejected[reason] or 0) + 1
	end
	for _, key in U.keys(index.edges) do
		local edge = index.edges[key]
		if #edge.faces ~= 2 then
			continue
		end
		local fa, fb = edge.faces[1], edge.faces[2]
		if not chosen[fa] or not chosen[fb] then
			continue
		end
		local a, b = mesh.faces[fa], mesh.faces[fb]
		if #a.vertices ~= 3 or #b.vertices ~= 3 then
			continue
		end
		if a.material ~= b.material then
			reject("material")
			continue
		end
		local na, areaA = mesh:faceNormal(fa)
		local nb, areaB = mesh:faceNormal(fb)
		if na:Dot(nb) < math.cos(angle) - 1e-7 then
			reject("angle")
			continue
		end
		local boundary: { [number]: number | false }, refs: { [number]: { { number } } } = {}, {}
		for _, fid in { fa, fb } do
			local f = mesh.faces[fid]
			for i, v in f.vertices do
				refs[v] = refs[v] or {}
				table.insert(refs[v], { fid, i, fid == fa and areaA or areaB })
				local nextV = f.vertices[i % 3 + 1]
				if U.edge(v, nextV) ~= key then
					if boundary[v] then
						boundary[v] = false
					else
						boundary[v] = nextV
					end
				end
			end
		end
		if U.count(refs) ~= 4 then
			reject("topology")
			continue
		end
		local loop: { number } = {}
		local start: number = U.keys(refs)[1]
		local v: (number | false)? = start
		for _ = 1, 4 do
			if not v or table.find(loop, v :: number) then
				break
			end
			table.insert(loop, v :: number)
			v = boundary[v :: number]
		end
		if #loop ~= 4 or v ~= start then
			reject("topology")
			continue
		end
		local delimited = false
		if options.delimitAttributes ~= false then
			for _, channel in mesh.attributes or {} :: { [string]: Types.Channel } do
				if channel.domain == "edge" and A.read(channel, key) ~= channel.default then
					delimited = true
					break
				end
				if
					channel.domain == "face"
					and not sameValue(A.read(channel, fa), A.read(channel, fb), epsilon)
				then
					delimited = true
					break
				end
				if channel.domain == "corner" then
					for _, id in { edge.a, edge.b } do
						local r, s = refs[id][1], refs[id][2]
						if
							not sameValue(
								A.read(channel, r[1] .. ":" .. r[2]),
								A.read(channel, s[1] .. ":" .. s[2]),
								epsilon
							)
						then
							delimited = true
							break
						end
					end
				end
			end
			for _, id in { edge.a, edge.b } do
				local r, s = refs[id][1], refs[id][2]
				local c, d = mesh.faces[r[1]].corners[r[2]], mesh.faces[s[1]].corners[s[2]]
				for field, value in c do
					if not sameValue(value, d[field], epsilon) then
						delimited = true
						break
					end
				end
				for field, value in d do
					if not sameValue(value, c[field], epsilon) then
						delimited = true
						break
					end
				end
			end
		end
		if delimited then
			reject("attributes")
			continue
		end
		local normal = (na + nb).Unit
		local axis = math.abs(normal.X) > math.abs(normal.Y)
				and (math.abs(normal.X) > math.abs(normal.Z) and "X" or "Z")
			or (math.abs(normal.Y) > math.abs(normal.Z) and "Y" or "Z")
		local function project(p: Vector3): Vector2
			return axis == "X" and Vector2.new(p.Y, p.Z)
				or (axis == "Y" and Vector2.new(p.Z, p.X) or Vector2.new(p.X, p.Y))
		end
		local score, convex = 0, true
		for i, id in loop do
			local p = mesh.vertices[id]
			local previous, nextPoint = mesh.vertices[loop[(i - 2) % 4 + 1]], mesh.vertices[loop[i % 4 + 1]]
			if
				P.orient2D(project(previous), project(p), project(nextPoint))
					* ((normal :: any)[axis] > 0 and 1 or -1)
				<= 0
			then
				convex = false
				break
			end
			local theta = math.acos(math.clamp((previous - p).Unit:Dot((nextPoint - p).Unit), -1, 1))
			if theta > shapeAngle or theta < math.pi - shapeAngle then
				convex = false
				break
			end
			score += (theta - math.pi / 2) ^ 2
		end
		if not convex then
			reject("shape")
			continue
		end
		assert(#candidates < maxCandidates, "Quad candidate budget exceeded")
		table.insert(candidates, {
			key = key,
			a = fa,
			b = fb,
			loop = loop,
			refs = refs,
			score = score,
			areaA = areaA,
			areaB = areaB,
		})
		edit.checkpoint()
	end
	table.sort(candidates, function(a, b)
		return a.score < b.score or (a.score == b.score and a.key < b.key)
	end)
	local used, pairs = {}, {}
	for _, candidate in candidates do
		local fa, fb = candidate.a, candidate.b
		if used[fa] or used[fb] then
			reject("matching")
			continue
		end
		used[fa], used[fb] = true, true
		local keep, drop = math.min(fa, fb), math.max(fa, fb)
		local cornerRefs = {}
		for i, id in candidate.loop do
			cornerRefs[i] = candidate.refs[id]
		end
		edit.face(
			candidate.loop,
			cornerRefs,
			mesh.faces[fa].material,
			{ { fa, candidate.areaA }, { fb, candidate.areaB } },
			keep
		)
		edit.out.faces[drop] = nil
		table.insert(pairs, { faces = { fa, fb }, result = keep, edge = candidate.key })
	end
	edit.report.pairs, edit.report.rejected, edit.report.candidates = pairs, rejected, #candidates
	return edit.finish()
end
return E
