-- A fixed point of conforming local patch coarsening with retained frontier samples.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Seams = require(script.Parent.AttributeSeams)
local G = require(script.Parent.PlanarReduceGeometry)
local Overlay = require(script.Parent.GridPatchOverlay)
local Mesh = require(script.Parent.Mesh)
local L = {}
function L.topology(source, target, work, limit)
	local C = require(script.Parent.Connectivity)
	work(
		U.count(source.vertices)
			+ 10 * U.count(source.faces)
			+ U.count(target.vertices)
			+ 10 * U.count(target.faces)
	)
	local before = C.analyze(source, { maxElements = limit })
	assert(before.valid, "Transition coarsening requires valid oriented source topology")
	local after = C.analyze(target, { maxElements = limit })
	if not after.valid or #before.components ~= #after.components then
		return false
	end
	local owners = {}
	for i, component in before.components do
		for fid in component.faces do
			owners[fid] = i
		end
	end
	local seen = {}
	for _, component in after.components do
		local owner
		for fid in component.faces do
			work(1)
			local index = owners[fid]
			if not index or owner and owner ~= index then
				return false
			end
			owner = index
		end
		if seen[owner] then
			return false
		end
		seen[owner] = true
		local original = before.components[owner]
		if
			original.eulerCharacteristic ~= component.eulerCharacteristic
			or original.boundaryLoops ~= component.boundaryLoops
		then
			return false
		end
	end
	return true
end
local function internalConstraint(mesh, top, group, options, work)
	if options.keepVertices[group.center] then
		return "keepCenter"
	end
	if options.preserveSeams == false then
		return nil
	end
	local vertexSharpness = mesh.attributes.subdivision_vertex_sharpness
	if vertexSharpness and A.read(vertexSharpness, group.center) > 0 then
		return "featureCenter"
	end
	local names = { sharp_edge = true, uv_seam = true, subdivision_edge_sharpness = true }
	for _, name in options.seamAttributes or {} do
		names[name] = true
	end
	for e in top.neighbors[group.center] do
		local key = U.edge(group.center, e)
		for name in names do
			work(1)
			local channel = mesh.attributes[name]
			if channel then
				local value = A.read(channel, key)
				if value == true or type(value) == "number" and value > 0 then
					return "feature"
				end
			end
		end
		local edge = top.edges[key]
		assert(#edge.faces == 2, "Grid center reached boundary")
		local a, b = edge.faces[1], edge.faces[2]
		for _, v in { group.center, e } do
			work(1)
			if
				not Seams.same(
					mesh,
					a,
					table.find(mesh.faces[a].vertices, v),
					b,
					table.find(mesh.faces[b].vertices, v),
					options
				)
			then
				return "seam"
			end
		end
	end
	return nil
end
local function mustKeep(mesh, e, ends, options, work)
	if options.keepVertices[e] then
		return true
	end
	if options.preserveSeams == false then
		return false
	end
	local sharp = mesh.attributes.subdivision_vertex_sharpness
	if sharp and A.read(sharp, e) > 0 then
		return true
	end
	for _, channel in mesh.attributes do
		if channel.domain == "edge" then
			work(1)
			if A.read(channel, U.edge(ends[1], e)) ~= A.read(channel, U.edge(e, ends[2])) then
				return true
			end
		end
	end
	return false
end
local function polygon(mesh, group, phase, keep)
	local loop, refs, uv = {}, {}, {}
	local chart = { { 0, 0 }, { 4, 0 }, { 4, 4 }, { 0, 4 } }
	uv[group.center] = { 2, 2 }
	for i, a in group.loop do
		local b = group.loop[i % 4 + 1]
		local e = phase.coarseEdges[U.edge(a, b)]
		uv[a] = chart[i]
		uv[e] = { (chart[i][1] + chart[i % 4 + 1][1]) / 2, (chart[i][2] + chart[i % 4 + 1][2]) / 2 }
		table.insert(loop, a)
		refs[a] = group.cornerRefs[a]
		if keep[e] then
			table.insert(loop, e)
			for _, fid in group.faces do
				local index = table.find(mesh.faces[fid].vertices, e)
				if index then
					refs[e] = { fid, index }
					break
				end
			end
		end
	end
	return { center = group.center, faces = group.faces, loop = loop, cornerRefs = refs }, uv
end
local function geometry(mesh, group, uv, triangles, options, work)
	local plane = G.plane(mesh, group.loop, work)
	if not plane or not G.polygon(mesh, group.loop, plane, work) then
		return nil, "coarsePolygon"
	end
	local temporary = Mesh.new()
	temporary.vertices = mesh.vertices
	local fid = temporary:addFace(group.loop)
	local triangulation = temporary:faceTriangles(
		fid,
		{ validateSimple = true, maxVertices = 8, maxWork = 10000, _visit = work }
	)
	local source, target = {}, {}
	for _, old in group.faces do
		local f = mesh.faces[old]
		for _, t in triangles[old] do
			local entry = { ids = {}, uv = {} }
			for i, index in t do
				local id = f.vertices[index]
				entry.ids[i], entry.uv[i] = id, assert(uv[id])
			end
			local a, b, c = entry.uv[1], entry.uv[2], entry.uv[3]
			assert(
				(b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]) == 4,
				"Fine grid triangle chart mismatch"
			)
			table.insert(source, entry)
		end
	end
	assert(#source == 8, "A fine patch must contain eight source triangles")
	for _, t in triangulation do
		local entry = { ids = {}, uv = {} }
		for i, index in t do
			local id = group.loop[index]
			entry.ids[i], entry.uv[i] = id, uv[id]
		end
		table.insert(target, entry)
	end
	local bound, overlay = Overlay.bound(source, target, mesh.vertices, work)
	if not bound then
		return nil, overlay
	end
	if bound > options.maxDeviation then
		return nil, "deviation"
	end
	local minimumDot = 1
	for _, pair in overlay.overlaps do
		local a, b = G.plane(mesh, source[pair[1]].ids, work), G.plane(mesh, target[pair[2]].ids, work)
		if not a or not b then
			return nil, "degenerate"
		end
		local dot = math.clamp(a.x * b.x + a.y * b.y + a.z * b.z, -1, 1)
		minimumDot = math.min(minimumDot, dot)
		if dot < options.minimumNormalDot then
			return nil, "normal"
		end
	end
	for _, pair in overlay.flapPairs do
		local a, b = G.plane(mesh, source[pair[1]].ids, work), G.plane(mesh, target[pair[2]].ids, work)
		if not a then
			return nil, "degenerate"
		end
		-- A geometrically degenerate boundary ear has no area or normal to constrain.
		if b then
			local dot = math.clamp(a.x * b.x + a.y * b.y + a.z * b.z, -1, 1)
			minimumDot = math.min(minimumDot, dot)
			if dot < options.minimumNormalDot then
				return nil, "normal"
			end
		end
	end
	return {
		group = group,
		plane = plane,
		errorBound = bound,
		minimumNormalDot = minimumDot,
		overlaySamples = overlay.samples,
	}
end
function L.accept(mesh, top, phase, triangles, options, selection, work)
	local active, rejections, selectedFaces = {}, {}, 0
	local statuses = {}
	for _, group in phase.groups do
		local selected = 0
		for _, fid in group.faces do
			if selection[fid] then
				selected += 1
			end
		end
		selectedFaces += selected
		if selected > 0 then
			local why = selected ~= 4 and "partialPatch"
				or internalConstraint(mesh, top, group, options, work)
			statuses[group.center] =
				{ selectedFaces = selected, faces = table.clone(group.faces), reason = why }
			if why then
				rejections[why] = (rejections[why] or 0) + 1
			else
				active[group.center] = true
			end
		end
	end
	local keptByData = {}
	for e, ends in phase.edgeEnds do
		keptByData[e] = mustKeep(mesh, e, ends, options, work)
	end
	local records, keep, rounds = {}, {}, 0
	while next(active) do
		rounds += 1
		assert(rounds <= #phase.groups + 1, "Grid frontier fixed point failed")
		keep = table.clone(keptByData)
		for e in phase.edgeEnds do
			for v in top.neighbors[e] do
				work(1)
				if phase.roles[v] == 3 and not active[v] then
					keep[e] = true
				end
			end
		end
		local failed = {}
		records = {}
		for _, group in phase.groups do
			if not active[group.center] then
				continue
			end
			local candidate, uv = polygon(mesh, group, phase, keep)
			local record, why = geometry(mesh, candidate, uv, triangles, options, work)
			if record then
				table.insert(records, record)
			else
				failed[group.center] = true
				statuses[group.center].reason = why
				rejections[why] = (rejections[why] or 0) + 1
			end
		end
		if not next(failed) then
			break
		end
		for center in failed do
			active[center] = nil
		end
	end
	if not next(active) then
		records = {}
	end
	local removed, edgeEnds, old = {}, {}, {}
	local maximum, minimumDot, transitionPolygons = 0, 1, 0
	for _, record in records do
		local group = record.group
		removed[group.center] = true
		statuses[group.center].accepted = true
		maximum = math.max(maximum, record.errorBound)
		minimumDot = math.min(minimumDot, record.minimumNormalDot)
		if #group.loop > 4 then
			transitionPolygons += 1
		end
	end
	for e, ends in phase.edgeEnds do
		if not keep[e] then
			local used = false
			for v in top.neighbors[e] do
				if active[v] then
					used = true
				end
			end
			if used then
				removed[e] = true
				edgeEnds[e] = ends
			end
		end
	end
	for id in phase.roles do
		if not removed[id] then
			table.insert(old, id)
		end
	end
	table.sort(old)
	local acceptedPhase = table.clone(phase)
	acceptedPhase.old, acceptedPhase.edgeEnds = old, edgeEnds
	return {
		phase = acceptedPhase,
		groups = records,
		errorBound = maximum,
		minimumNormalDot = minimumDot,
		selectedFaces = selectedFaces,
		coveredSelectedFaces = #records * 4,
		rejections = rejections,
		patches = statuses,
		transitionPolygons = transitionPolygons,
		frontierRounds = rounds,
	}
end
return L
