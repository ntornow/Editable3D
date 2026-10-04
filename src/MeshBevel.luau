-- Transactional selected edge/vertex bevel with profile strips and explicit junction patches.
local U = require(script.Parent.Util)
local C = require(script.Parent.Connectivity)
local P = require(script.Parent.Predicates)
local B = require(script.Parent.BevelCore)
return function(mesh, selected, width, options, mode)
	options = options or {}
	assert(type(selected) == "table", "Bevel selection dictionary required")
	local state = B.prepare(mesh, width, options)
	local edit, index = state.edit, state.index
	local chosen, affected, openVertex = {}, {}, {}
	for _, key in U.keys(selected) do
		local value = selected[key]
		assert(
			(mode == "edges" and index.edges[key] or mode == "vertices" and index.vertices[key]),
			"Unknown bevel selection element"
		)
		assert(
			type(value) == "boolean"
				or type(value) == "number" and U.finite(value) and value >= 0 and value <= 1,
			"Bevel selection weights must be in [0,1]"
		)
		local weight = type(value) == "boolean" and (value and 1 or 0) or value
		if weight > 0 then
			chosen[key] = width * weight
			if mode == "edges" then
				local e = index.edges[key]
				assert(#e.faces == 2, "Edge bevel requires exactly two incident faces")
				affected[e.a] = math.max(affected[e.a] or 0, chosen[key])
				affected[e.b] = math.max(affected[e.b] or 0, chosen[key])
			else
				affected[key] = chosen[key]
			end
		end
	end
	for v in affected do
		for _, key in index.vertices[v].edges do
			if #index.edges[key].faces == 1 then
				openVertex[v] = true
			end
		end
		state.owner[v], state.refs[v] = v, { { v, 1 } }
		state.offsets[v] = Vector3.zero
	end
	local paths, proposals, retained = {}, {}, {}
	local definitions, originalSegments, spheres = {}, {}, {}
	local report = edit.report
	report.strips, report.joins, report.joinLoops, report.openJoins, report.sphericalJoins, report.mergedVertices =
		{}, {}, {}, {}, {}, {}
	report.maximumMiter = 0
	report.triangulatedJoins = {}
	report.patchRings = {}
	local function emit(vs, cr, material, fr, keep)
		local fid = edit.face(vs, cr, material, fr, keep)
		definitions[fid] = { vertices = table.clone(vs), corners = cr, material = material, faces = fr }
		return fid
	end
	local function pointPath(id, cr)
		return { ids = { id }, refs = { cr } }
	end
	local function endpoint(v, neighbor, amount, fid)
		local id, cr = state.edgePoint(v, neighbor, amount, fid)
		return pointPath(id, cr)
	end
	-- Offset corners adjacent to selected edges before constructing zero-edge sectors.
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		paths[fid] = {}
		for i, v in f.vertices do
			local cr = { { fid, i, 1 } }
			state.cornerRefs[v] = state.cornerRefs[v] or cr
			if not affected[v] then
				paths[fid][i] = pointPath(v, cr)
				continue
			end
			local data = state.face(fid)
			local previous, nextV = f.vertices[(i - 2) % #f.vertices + 1], f.vertices[i % #f.vertices + 1]
			local before, after = U.edge(previous, v), U.edge(v, nextV)
			local left, right = mode == "edges" and chosen[before], mode == "edges" and chosen[after]
			if mode == "vertices" then
				local a, ar = state.edgePoint(v, previous, affected[v], fid)
				local b, br = state.edgePoint(v, nextV, affected[v], fid)
				local ids, refs = state.curve(v, a, b, data.normal, ar, br)
				paths[fid][i] = { ids = ids, refs = refs }
			elseif left and right then
				local n1 = data.normal:Cross((mesh.vertices[v] - mesh.vertices[previous]).Unit)
				local n2 = data.normal:Cross((mesh.vertices[nextV] - mesh.vertices[v]).Unit)
				local dot = n1:Dot(n2)
				local determinant = 1 - dot * dot
				local delta
				if determinant > 1e-10 then
					delta = n1 * ((left - dot * right) / determinant)
						+ n2 * ((right - dot * left) / determinant)
				else
					assert(
						dot > 0 and math.abs(left - right) <= width * 1e-6,
						"Incompatible parallel bevel offsets"
					)
					delta = (n1 + n2).Unit * ((left + right) / 2)
				end
				local miter = delta.Magnitude / math.max(left, right)
				assert(miter <= (options.miterLimit or 16), "Bevel miter exceeds limit")
				report.maximumMiter = math.max(report.maximumMiter, miter)
				local p = mesh.vertices[v] + delta
				local vr, refs = state.interpolate(fid, p)
				paths[fid][i] = pointPath(state.vertex(p, vr, refs, v, delta), refs)
			elseif left or right then
				local neighbor = left and nextV or previous
				local edge = left and after or before
				local direction = left and (mesh.vertices[v] - mesh.vertices[previous]).Unit
					or (mesh.vertices[nextV] - mesh.vertices[v]).Unit
				local inward = data.normal:Cross(direction)
				local denominator = (mesh.vertices[neighbor] - mesh.vertices[v]).Unit:Dot(inward)
				local offset = left or right
				proposals[v] = proposals[v] or {}
				if denominator > 1e-7 then
					local distance = offset / denominator
					paths[fid][i] = endpoint(v, neighbor, distance, fid)
					proposals[v][edge] = math.max(proposals[v][edge] or 0, distance)
				else
					-- A reflex/straight termination cannot slide forward on its other edge.
					local p = mesh.vertices[v] + inward * offset
					local vr, refs = state.interpolate(fid, p)
					local id = state.vertex(p, vr, refs, v, inward * offset)
					paths[fid][i] = left and { ids = { id, v }, refs = { refs, cr } }
						or { ids = { v, id }, refs = { cr, refs } }
					retained[v] = retained[v] or {}
					retained[v][edge] = true
				end
			end
			state.visit()
		end
	end
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		for i, v in f.vertices do
			if not paths[fid][i] then
				local ids, refs = {}, {}
				for _, neighbor in { f.vertices[(i - 2) % #f.vertices + 1], f.vertices[i % #f.vertices + 1] } do
					local key = U.edge(v, neighbor)
					local id, cr
					if retained[v] and retained[v][key] then
						id, cr = v, { { fid, i, 1 } }
					else
						id, cr = state.edgePoint(v, neighbor, (proposals[v] or {})[key] or affected[v], fid)
					end
					if ids[#ids] ~= id then
						table.insert(ids, id)
						table.insert(refs, cr)
					end
				end
				paths[fid][i] = { ids = ids, refs = refs }
			end
		end
	end
	for key, cuts in state.edgeCuts do
		table.sort(cuts, function(a, b)
			return a.t < b.t
		end)
		local e = index.edges[key]
		local fromA, fromB = 0, 1
		for _, cut in cuts do
			if state.owner[cut.id] == e.a then
				fromA = math.max(fromA, cut.t)
			else
				fromB = math.min(fromB, cut.t)
			end
		end
		assert(fromA < fromB, "Bevel endpoint regions overlap along a source edge")
	end
	local function parameter(key, id, a, b)
		if id == a then
			return 0
		elseif id == b then
			return 1
		end
		for _, cut in state.edgeCuts[key] or {} do
			if cut.id == id then
				return a < b and cut.t or 1 - cut.t
			end
		end
		error("Bevel edge correspondence missing")
	end
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		local vs, crs, changed = {}, {}, false
		for i, v in f.vertices do
			local path = paths[fid][i]
			changed = changed or affected[v] ~= nil
			for j, id in path.ids do
				table.insert(vs, id)
				table.insert(crs, path.refs[j])
			end
			local j = i % #f.vertices + 1
			local nextV = f.vertices[j]
			local key = U.edge(v, nextV)
			local first, last = path.ids[#path.ids], paths[fid][j].ids[1]
			if mode == "edges" and chosen[key] then
				assert(
					(edit.out.vertices[last] - edit.out.vertices[first]):Dot(
						mesh.vertices[nextV] - mesh.vertices[v]
					) > 0,
					"Bevel consumes or reverses a face rail"
				)
				edit.maps.edge[U.edge(first, last)] = { { key, 1 } }
			else
				local low, high = parameter(key, first, v, nextV), parameter(key, last, v, nextV)
				assert(low < high, "Bevel consumes a face edge")
				local interior = {}
				for _, cut in state.edgeCuts[key] or {} do
					local t = v < nextV and cut.t or 1 - cut.t
					if t > low and t < high then
						table.insert(interior, { id = cut.id, t = t })
					end
				end
				table.sort(interior, function(a, b)
					return a.t < b.t
				end)
				local previous = first
				for _, cut in interior do
					table.insert(vs, cut.id)
					table.insert(crs, { { fid, i, 1 - cut.t }, { fid, j, cut.t } })
					local segment = U.edge(previous, cut.id)
					edit.maps.edge[segment] = { { key, 1 } }
					originalSegments[segment] = key
					previous = cut.id
				end
				local segment = U.edge(previous, last)
				edit.maps.edge[segment] = { { key, 1 } }
				originalSegments[segment] = key
			end
		end
		if changed then
			emit(vs, crs, f.material, { { fid, 1 } }, fid)
			assert(edit.out:faceNormal(fid):Dot(mesh:faceNormal(fid)) > 0, "Bevel reverses a source face")
		else
			definitions[fid] = {
				vertices = table.clone(f.vertices),
				corners = crs,
				material = f.material,
				faces = { { fid, 1 } },
			}
		end
		state.visit()
	end
	if mode == "edges" then
		for _, key in U.keys(chosen) do
			local edge = index.edges[key]
			local h, k = index.corners[edge.corners[1]], index.corners[edge.corners[2]]
			local a, b = h.vertex, h.to
			local pa, pb = paths[h.face][h.index], paths[h.face][h.index % #mesh.faces[h.face].vertices + 1]
			local qa, qb = paths[k.face][k.index % #mesh.faces[k.face].vertices + 1], paths[k.face][k.index]
			local axis = (mesh.vertices[b] - mesh.vertices[a]).Unit
			local railA, refsA, sphereA =
				state.curve(a, pa.ids[#pa.ids], qa.ids[1], axis, pa.refs[#pa.refs], qa.refs[1])
			local railB, refsB, sphereB =
				state.curve(b, pb.ids[1], qb.ids[#qb.ids], axis, pb.refs[1], qb.refs[#qb.refs])
			if sphereA then
				spheres[a] = spheres[a] or {}
				table.insert(spheres[a], sphereA)
			end
			if sphereB then
				spheres[b] = spheres[b] or {}
				table.insert(spheres[b], sphereB)
			end
			report.strips[key] = {}
			for step = 1, state.segments do
				local t = (step - 0.5) / state.segments
				local material = options.material or mesh.faces[t <= 0.5 and h.face or k.face].material
				local fid = emit(
					{ railB[step], railA[step], railA[step + 1], railB[step + 1] },
					{ refsB[step], refsA[step], refsA[step + 1], refsB[step + 1] },
					material,
					{ { h.face, 1 - t }, { k.face, t } }
				)
				table.insert(report.strips[key], fid)
			end
			for i = 1, #railA do
				edit.maps.edge[U.edge(railA[i], railB[i])] = { { key, 1 } }
			end
			state.visit()
		end
	end
	-- Coincident junction samples are shared, while their face corners retain separate data.
	local boundary = C.index(edit.out, options)
	local byOwner = {}
	for key in boundary.boundary do
		local edge = boundary.edges[key]
		for _, id in { edge.a, edge.b } do
			local v = state.owner[id]
			if v then
				byOwner[v] = byOwner[v] or {}
				byOwner[v][id] = true
			end
		end
	end
	local remap, mergeCounts = {}, {}
	for _, v in U.keys(byOwner) do
		local representatives = {}
		for _, id in U.keys(byOwner[v]) do
			local found
			for _, other in representatives do
				state.visit()
				if edit.out.vertices[id] == edit.out.vertices[other] then
					found = other
					break
				end
			end
			if found then
				remap[id] = found
				report.mergedVertices[id] = found
				mergeCounts[found] = (mergeCounts[found] or 1) + 1
				state.refs[found] = B.mix(
					state.refs[found] or { { found, 1 } },
					state.refs[id] or { { id, 1 } },
					1 / mergeCounts[found]
				)
				state.cornerRefs[found] =
					B.mixCorners(state.cornerRefs[found], state.cornerRefs[id], 1 / mergeCounts[found])
				edit.maps.vertex[found] = state.refs[found]
			else
				table.insert(representatives, id)
			end
		end
	end
	if next(remap) then
		for fid, d in definitions do
			local vs, cr = {}, {}
			for i, id in d.vertices do
				id = remap[id] or id
				if vs[#vs] ~= id then
					table.insert(vs, id)
					table.insert(cr, d.corners[i])
				end
			end
			if vs[1] == vs[#vs] then
				table.remove(vs)
				table.remove(cr)
			end
			assert(#vs >= 3, "Bevel junction welding collapses a face")
			emit(vs, cr, d.material, d.faces, fid)
		end
		local nextMap, nextOriginal = {}, {}
		for _, key in U.keys(edit.maps.edge) do
			local refs = edit.maps.edge[key]
			local ids = string.split(key, ":")
			local a, b = tonumber(ids[1]), tonumber(ids[2])
			a, b = remap[a] or a, remap[b] or b
			if a ~= b then
				local destination = U.edge(a, b)
				nextMap[destination] = nextMap[destination] and B.mix(nextMap[destination], refs, 0.5) or refs
				if originalSegments[key] then
					nextOriginal[destination] = originalSegments[key]
				end
			end
		end
		edit.maps.edge = nextMap
		report.maps.edge = nextMap
		originalSegments = nextOriginal
	end
	-- Insert collinear profile samples into facing junction chords before closing holes.
	boundary = C.index(edit.out, options)
	local inserts = {}
	for key in boundary.boundary do
		local edge = boundary.edges[key]
		local v = state.owner[edge.a]
		if v and state.owner[edge.b] == v then
			local a, b = edit.out.vertices[edge.a], edit.out.vertices[edge.b]
			local d = b - a
			local denominator = d:Dot(d)
			for _, id in U.keys(byOwner[v] or {}) do
				state.visit()
				if not remap[id] and id ~= edge.a and id ~= edge.b then
					local p = edit.out.vertices[id]
					local t = (p - a):Dot(d) / denominator
					if t > 0 and t < 1 and (p - a - d * t).Magnitude <= width * 1e-6 then
						inserts[key] = inserts[key] or {}
						table.insert(inserts[key], { id = id, t = t })
					end
				end
			end
			if inserts[key] then
				table.sort(inserts[key], function(x, y)
					return x.t < y.t
				end)
			end
		end
	end
	for fid, d in definitions do
		local vs, cr, changed = {}, {}, false
		for i, a in d.vertices do
			local j = i % #d.vertices + 1
			local b = d.vertices[j]
			local key = U.edge(a, b)
			table.insert(vs, a)
			table.insert(cr, d.corners[i])
			local cuts = inserts[key]
			if cuts then
				changed = true
				local previous = a
				for k = 1, #cuts do
					local cut = cuts[a < b and k or #cuts - k + 1]
					local t = a < b and cut.t or 1 - cut.t
					table.insert(vs, cut.id)
					table.insert(cr, B.mixCorners(d.corners[i], d.corners[j], t))
					if edit.maps.edge[key] then
						edit.maps.edge[U.edge(previous, cut.id)] = edit.maps.edge[key]
					end
					previous = cut.id
				end
				if edit.maps.edge[key] then
					edit.maps.edge[U.edge(previous, b)] = edit.maps.edge[key]
				end
			end
		end
		if changed then
			emit(vs, cr, d.material, d.faces, fid)
		end
	end
	boundary = C.index(edit.out, options)
	local junctions = {}
	for key in boundary.boundary do
		local edge = boundary.edges[key]
		local v = state.owner[edge.a]
		local original = originalSegments[key]
		if v and state.owner[edge.b] == v and not (original and #index.edges[original].faces == 1) then
			local h = boundary.corners[edge.corners[1]]
			junctions[v] = junctions[v] or { next = {}, incoming = {} }
			local graph = junctions[v]
			assert(not graph.next[h.to] and not graph.incoming[h.vertex], "Bevel junction boundary branches")
			graph.next[h.to], graph.incoming[h.vertex] = h.vertex, true
		end
	end
	for _, v in U.keys(junctions) do
		local graph = junctions[v]
		local closed = true
		for id in graph.next do
			closed = closed and graph.incoming[id] ~= nil
		end
		for id in graph.incoming do
			closed = closed and graph.next[id] ~= nil
		end
		if not closed then
			assert(openVertex[v], "Closed-source bevel junction has an open chain")
			report.openJoins[v] = true
			continue
		end
		local seen = {}
		report.joins[v], report.joinLoops[v] = {}, {}
		for _, start in U.keys(graph.next) do
			if seen[start] then
				continue
			end
			local loop, cr, id = {}, {}, start
			repeat
				assert(id and not seen[id], "Bevel junction traversal failed")
				seen[id] = true
				table.insert(loop, id)
				table.insert(cr, assert(state.cornerRefs[id]))
				id = graph.next[id]
			until id == start
			assert(#loop >= 3, "Bevel junction has fewer than three vertices")
			table.insert(report.joinLoops[v], loop)
			local sourceFaces = {}
			for _, ck in index.vertices[v].corners do
				sourceFaces[index.corners[ck].face] = true
			end
			local fr = {}
			for _, fid in U.keys(sourceFaces) do
				table.insert(fr, { fid, 1 })
			end
			local material = options.material or mesh.faces[fr[1][1]].material
			local cap = emit(loop, cr, material, fr)
			if state.join == "cutoff" or #loop == 3 then
				table.insert(report.joins[v], cap)
				continue
			end
			local origin = mesh.vertices[v]
			local delta = Vector3.zero
			local vr, centerRefs = {}, {}
			for i, vertex in loop do
				delta += (state.offsets[vertex] or (edit.out.vertices[vertex] - origin)) / #loop
				for _, r in state.refs[vertex] or { { vertex, 1 } } do
					table.insert(vr, { r[1], r[2] / #loop })
				end
				for _, r in cr[i] do
					table.insert(centerRefs, { r[1], r[2], r[3] / #loop })
				end
			end
			local center = origin + delta
			local roundSphere
			if state.segments > 1 and spheres[v] and #spheres[v] >= 3 then
				local sphere = spheres[v][1]
				local compatible = true
				for _, other in spheres[v] do
					compatible = compatible
						and (other.offset - sphere.offset).Magnitude <= width * 1e-5
						and math.abs(other.radius - sphere.radius) <= width * 1e-5
				end
				if compatible and (delta - sphere.offset).Magnitude > 0 then
					delta = sphere.offset + (delta - sphere.offset).Unit * sphere.radius
					center = origin + delta
					report.sphericalJoins[v] = true
					roundSphere = sphere
				end
			end
			local project = B.project(edit.out:faceNormal(cap))
			local polygon = {}
			for i, vertex in loop do
				polygon[i] = project(edit.out.vertices[vertex])
			end
			local sign = P.polygonOrientation(polygon)
			local inKernel = true
			for i, p in polygon do
				inKernel = inKernel and P.orient2D(p, polygon[i % #polygon + 1], project(center)) * sign > 0
			end
			if not inKernel then
				local triangles = edit.out:faceTriangles(cap, {
					validateSimple = true,
					maxVertices = options.maxFaceVertices or 2000,
					maxWork = options.maxFaceWork or 5000000,
				})
				for i, tri in triangles do
					table.insert(
						report.joins[v],
						emit(
							{ loop[tri[1]], loop[tri[2]], loop[tri[3]] },
							{ cr[tri[1]], cr[tri[2]], cr[tri[3]] },
							material,
							fr,
							i == 1 and cap or nil
						)
					)
				end
				report.triangulatedJoins[v] = true
				continue
			end
			local middle = state.vertex(center, vr, centerRefs, v, delta)
			local rings = options.patchRings or (roundSphere and math.ceil(state.segments / 2) or 1)
			U.integer(rings, 1)
			assert(rings <= 64, "Bevel patch ring limit is 64")
			report.patchRings[v] = rings
			local previous, previousRefs
			local firstFace = true
			for level = 1, rings do
				local ring, ringRefs = {}, {}
				local t = level / rings
				for i, vertex in loop do
					if level == rings then
						ring[i], ringRefs[i] = vertex, cr[i]
					else
						local targetOffset = state.offsets[vertex] or (edit.out.vertices[vertex] - origin)
						local localPoint = delta:Lerp(targetOffset, t)
						if roundSphere then
							local a = (delta - roundSphere.offset).Unit
							local b = (targetOffset - roundSphere.offset).Unit
							local angle = math.acos(math.clamp(a:Dot(b), -1, 1))
							local direction = angle > 1e-7
									and (a * (math.sin((1 - t) * angle) / math.sin(angle)) + b * (math.sin(
										t * angle
									) / math.sin(angle)))
								or a
							localPoint = roundSphere.offset + direction * roundSphere.radius
						end
						local refs = B.mix(vr, state.refs[vertex] or { { vertex, 1 } }, t)
						ringRefs[i] = B.mixCorners(centerRefs, cr[i], t)
						ring[i] = state.vertex(origin + localPoint, refs, ringRefs[i], v, localPoint)
					end
				end
				for i, vertex in ring do
					local j = i % #ring + 1
					local vs = previous and { vertex, ring[j], previous[j], previous[i] }
						or { vertex, ring[j], middle }
					local refs = previous and { ringRefs[i], ringRefs[j], previousRefs[j], previousRefs[i] }
						or { ringRefs[i], ringRefs[j], centerRefs }
					table.insert(report.joins[v], emit(vs, refs, material, fr, firstFace and cap or nil))
					firstFace = false
				end
				previous, previousRefs = ring, ringRefs
			end
		end
		state.visit()
	end
	state.prune()
	for _, corners in paths do
		for _, path in corners do
			for i, id in path.ids do
				path.ids[i] = remap[id] or id
			end
		end
	end
	report.cornerPaths = paths
	report.work = state.work()
	report.mode = mode
	local result, final = edit.finish()
	if mesh:validate().closed then
		assert(result:validate().closed, "Bevel opened a closed source")
	end
	return result, final
end
