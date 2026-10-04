-- Explicit cleanup, winding repair and bounded intersection arrangements.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local C = require(script.Parent.Connectivity)
local R = {}
function R.splitIntersections(mesh, options)
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
function R.resolveIntersections(mesh, options)
	local copies
	copies, options = require(script.Parent.ArrangementSnapshot)({ mesh }, options)
	mesh = copies[1]
	local data = require(script.Parent.MeshArrangement)(mesh, options)
	local selection, classification = require(script.Parent.MeshWindingBoundary)(data, options)
	local conformity = require(script.Parent.MeshArrangementConform)(data, selection, options)
	local out, report = require(script.Parent.MeshArrangementBuild)(data, selection, false, options)
	local scan = table.clone(options.intersectionOptions or {})
	scan.maxWork = scan.maxWork or options.maxWork
	scan.includeAdjacent, scan.includeContacts = false, true
	scan.checkpoint = scan.checkpoint or options.checkpoint
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
function R.clean(mesh, options)
	options = options or {}
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
function R.orient(mesh, options)
	options = options or {}
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
	local function reverse(fid)
		local f = out.faces[fid]
		local vs, cs = {}, {}
		for i = #f.vertices, 1, -1 do
			table.insert(vs, f.vertices[i])
			table.insert(cs, U.copy(f.corners[i]))
			if cs[#cs].normal then
				cs[#cs].normal = -cs[#cs].normal
			end
			if cs[#cs].tangentSign then
				cs[#cs].tangentSign = -cs[#cs].tangentSign
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
return R
