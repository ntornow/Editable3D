-- Bounded disk-region dissolving with original-source data correspondence.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Seams = require(script.Parent.AttributeSeams)
local G = require(script.Parent.PlanarReduceGeometry)
return function(source, angleLimit, settings)
	local options = U.copy(settings or {})
	assert(
		type(angleLimit) == "number" and U.finite(angleLimit) and angleLimit >= 0 and angleLimit < math.pi / 2,
		"Planar angle limit must lie in [0, pi/2)"
	)
	local maxVertices = U.integer(options.maxVertices or 250000, 1)
	local maxFaces = U.integer(options.maxFaces or 250000, 1)
	local maxCorners = U.integer(options.maxCorners or 1000000, 1)
	local maxFaceVertices = U.integer(options.maxFaceVertices or 2000, 3)
	local maxWork = U.integer(options.maxWork or 20000000, 1)
	local maxMerges = U.integer(options.maxMerges or maxFaces, 0)
	assert(
		U.count(source.vertices) <= maxVertices and U.count(source.faces) <= maxFaces,
		"Planar input allocation budget exceeded"
	)
	local corners = 0
	for _, face in source.faces do
		corners += #face.vertices
		assert(
			corners <= maxCorners and #face.vertices <= maxFaceVertices,
			"Planar input corner budget exceeded"
		)
	end
	for _, name in { "preserveSeams", "checkIntersections", "requireComplete", "dissolveBoundaries" } do
		assert(options[name] == nil or type(options[name]) == "boolean", "Planar flags must be boolean")
	end
	for _, name in { "uvTolerance", "attributeTolerance" } do
		assert(
			options[name] == nil
				or type(options[name]) == "number" and U.finite(options[name]) and options[name] >= 0,
			"Planar attribute tolerances must be finite and nonnegative"
		)
	end
	local mesh = source:clone()
	A.validate(mesh)
	local report = {
		merges = 0,
		initialFaces = U.count(mesh.faces),
		maximumPlaneDeviation = 0,
		maximumAngle = 0,
		regions = {},
		sourceFaceToOutput = {},
		blocked = {},
		intersectionChecked = options.checkIntersections ~= false,
	}
	local work = 0
	local function visit(n)
		work += n or 1
		assert(work <= maxWork, "Planar reduction work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Planar reduction cancelled")
	end
	local function checkpoint(stage)
		visit(0)
		if options.checkpoint then
			options.checkpoint({
				stage = stage,
				work = work,
				merges = report.merges,
				faces = report.initialFaces - report.merges,
			})
		end
	end
	checkpoint("begin")
	visit(U.count(mesh.vertices) + U.count(mesh.faces) + corners)
	local connectivity = require(script.Parent.Connectivity).analyze(mesh)
	assert(
		next(connectivity.nonmanifoldEdges) == nil
			and next(connectivity.windingEdges) == nil
			and next(connectivity.nonmanifoldVertices) == nil
			and next(connectivity.duplicateFaces) == nil
			and next(connectivity.zeroLengthEdges) == nil,
		"Planar reduction requires an oriented manifold source"
	)
	local lo, hi = mesh:bounds()
	local diagonal = math.sqrt((hi.X - lo.X) ^ 2 + (hi.Y - lo.Y) ^ 2 + (hi.Z - lo.Z) ^ 2)
	local maximumDeviation = options.maxPlaneDeviation
	if maximumDeviation == nil then
		maximumDeviation = diagonal * math.sin(angleLimit) * 0.5
	end
	assert(
		type(maximumDeviation) == "number" and U.finite(maximumDeviation) and maximumDeviation >= 0,
		"Planar deviation must be finite and nonnegative"
	)
	local selection = {}
	if options.faces then
		assert(type(options.faces) == "table", "Planar face selection must be a boolean set")
		for fid, value in options.faces do
			assert(mesh.faces[fid] and type(value) == "boolean", "Invalid planar face selection")
			selection[fid] = value
		end
	else
		for fid in mesh.faces do
			selection[fid] = true
		end
	end
	local function audit(object, stage)
		local config = U.copy(options.intersectionOptions or {})
		local callback = config.checkpoint
		local previous = 0
		config.maxWork = math.min(config.maxWork or maxWork, maxWork - work)
		config.checkpoint = function(status)
			local used = status.work or 0
			visit(math.max(0, used - previous))
			previous = used
			if callback then
				callback(status)
			end
			checkpoint(stage)
		end
		local _, result = require(script.Parent.Intersections).mesh(object, config)
		visit(math.max(0, (result.work or previous) - previous))
		return result
	end
	if report.intersectionChecked then
		report.inputIntersections = audit(mesh, "inputIntersections")
		assert(
			report.inputIntersections.complete and report.inputIntersections.intersectionFree,
			"Planar source intersection audit failed or incomplete"
		)
	end
	local regions, normals, triangles, owner = {}, {}, {}, {}
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		local refs = {}
		for i in face.vertices do
			refs[i] = { fid, i }
		end
		regions[fid] = {
			loop = table.clone(face.vertices),
			corners = refs,
			faces = { fid },
			selected = selection[fid] == true,
		}
		normals[fid] = assert(G.plane(mesh, face.vertices, visit), "Degenerate source face")
		triangles[fid] = mesh:faceTriangles(
			fid,
			{ validateSimple = true, maxVertices = maxFaceVertices, maxWork = maxWork, _visit = visit }
		)
		owner[fid] = fid
	end
	local protected = {}
	local topology = mesh:topology()
	if options.preserveSeams ~= false then
		local names = { sharp_edge = true, uv_seam = true, subdivision_edge_sharpness = true }
		for _, name in options.seamAttributes or {} do
			assert(mesh.attributes[name], "Missing planar seam attribute")
			names[name] = true
		end
		for name in names do
			local channel = mesh.attributes[name]
			if channel then
				assert(
					channel.domain == "edge"
						and (channel.dataType == "number" or channel.dataType == "boolean"),
					"Planar seam fields require numeric or boolean edges"
				)
				for key in topology.edges do
					visit(1)
					local value = A.read(channel, key)
					if value == true or type(value) == "number" and value > 0 then
						protected[key] = true
					end
				end
			end
		end
		for key, edge in topology.edges do
			visit(1)
			if #edge.faces == 2 then
				local a, b = edge.faces[1], edge.faces[2]
				for _, vertex in { edge.a, edge.b } do
					if
						not Seams.same(
							mesh,
							a,
							table.find(mesh.faces[a].vertices, vertex),
							b,
							table.find(mesh.faces[b].vertices, vertex),
							options
						)
					then
						protected[key] = true
					end
				end
			end
		end
	end
	local finished = false
	while true do
		local candidates, seen = {}, {}
		for key, edge in topology.edges do
			visit(1)
			if #edge.faces == 2 then
				local a, b = owner[edge.faces[1]], owner[edge.faces[2]]
				local pair = U.edge(a, b)
				if a ~= b and not seen[pair] and regions[a].selected and regions[b].selected then
					seen[pair] = true
					table.insert(candidates, { a = math.min(a, b), b = math.max(a, b), key = key })
				end
			end
		end
		table.sort(candidates, function(a, b)
			return a.a == b.a and a.b < b.b or a.a < b.a
		end)
		local accepted
		report.blocked = {}
		for _, pair in candidates do
			local region, reason = G.union(regions[pair.a], regions[pair.b], protected, visit)
			if region then
				local valid
				valid, reason = G.accept(
					mesh,
					region,
					normals,
					angleLimit,
					maximumDeviation,
					maxFaceVertices,
					visit,
					triangles
				)
				if valid then
					accepted = { a = pair.a, b = pair.b, region = region }
					break
				end
			end
			report.blocked[reason] = (report.blocked[reason] or 0) + 1
		end
		if not accepted then
			finished = true
			break
		end
		if report.merges == maxMerges then
			break
		end
		local region = accepted.region
		region.selected = true
		regions[accepted.a], regions[accepted.b] = region, nil
		for _, fid in region.faces do
			owner[fid] = accepted.a
		end
		report.merges += 1
		checkpoint("merge")
	end
	local boundary = { complete = true, removed = 0, maximumDeviation = 0, paths = {} }
	if options.dissolveBoundaries then
		local boundaryOptions = table.clone(options)
		boundaryOptions.maxBoundaryRemovals = U.integer(options.maxBoundaryRemovals or maxVertices, 0)
		boundaryOptions.angleLimit, boundaryOptions.maxPlaneDeviation, boundaryOptions.maxFaceVertices =
			angleLimit, maximumDeviation, maxFaceVertices
		boundaryOptions.maxBoundaryDeviation = options.maxBoundaryDeviation or maximumDeviation
		assert(
			type(boundaryOptions.maxBoundaryDeviation) == "number"
				and U.finite(boundaryOptions.maxBoundaryDeviation)
				and boundaryOptions.maxBoundaryDeviation >= 0,
			"Boundary deviation must be finite and nonnegative"
		)
		boundary = require(script.Parent.PlanarBoundaryReduce)(
			mesh,
			regions,
			normals,
			triangles,
			boundaryOptions,
			visit,
			checkpoint
		)
	end
	local out = mesh:clone()
	out.faces = {}
	local maps = { face = {}, corner = {}, edge = {} }
	for _, fid in U.keys(regions) do
		local region = regions[fid]
		local face =
			{ vertices = table.clone(region.loop), corners = {}, material = mesh.faces[fid].material }
		local weighted = {}
		local maximumArea = 0
		for _, sourceId in region.faces do
			maximumArea = math.max(maximumArea, normals[sourceId].area)
		end
		for _, sourceId in region.faces do
			table.insert(weighted, { sourceId, normals[sourceId].area / maximumArea })
			report.sourceFaceToOutput[sourceId] = fid
		end
		maps.face[fid] = weighted
		for i, ref in region.corners do
			face.corners[i] = U.copy(mesh.faces[ref[1]].corners[ref[2]])
			maps.corner[fid .. ":" .. i] = { { ref[1] .. ":" .. ref[2], 1 } }
		end
		out.faces[fid] = face
		for i, a in region.loop do
			local b = region.loop[i % #region.loop + 1]
			local key = U.edge(a, b)
			local path = boundary.paths[key]
			if path and #path > 2 then
				local refs, total = {}, 0
				for j = 1, #path - 1 do
					local p, q = mesh.vertices[path[j]], mesh.vertices[path[j + 1]]
					local length = math.sqrt((q.X - p.X) ^ 2 + (q.Y - p.Y) ^ 2 + (q.Z - p.Z) ^ 2)
					table.insert(refs, { U.edge(path[j], path[j + 1]), length })
					total += length
				end
				for _, ref in refs do
					ref[2] /= total
				end
				maps.edge[key] = refs
			end
		end
		report.regions[fid] = table.clone(region.faces)
		report.maximumPlaneDeviation = math.max(report.maximumPlaneDeviation, region.deviation or 0)
		report.maximumAngle = math.max(report.maximumAngle, region.angle or 0)
	end
	A.transfer(mesh, out, maps)
	out:removeUnused()
	A.validate(out)
	for fid in out.faces do
		local face = out.faces[fid]
		local plane = assert(G.plane(out, face.vertices, visit), "Degenerate reduced face")
		local normal = Vector3.new(plane.x, plane.y, plane.z)
		for _, corner in face.corners do
			corner.normal = normal
			corner.tangent = nil
		end
		out:faceTriangles(
			fid,
			{ validateSimple = true, maxVertices = maxFaceVertices, maxWork = maxWork, _visit = visit }
		)
	end
	if report.intersectionChecked then
		report.outputIntersections = audit(out, "outputIntersections")
	end
	report.validation = out:validate()
	report.finalFaces = U.count(out.faces)
	report.boundaryRemoved, report.maximumBoundaryDeviation = boundary.removed, boundary.maximumDeviation
	report.complete = report.validation.valid
		and finished
		and boundary.complete
		and (
			not report.intersectionChecked
			or report.outputIntersections.complete and report.outputIntersections.intersectionFree
		)
	report.success = report.complete
	report.reason = not report.validation.valid and "invalidOutput"
		or not finished and "maxMerges"
		or not boundary.complete and "maxBoundaryRemovals"
		or report.complete and "constrainedFixedPoint"
		or "outputIntersections"
	report.work, report.maps, report.maxPlaneDeviation, report.angleLimit =
		work, maps, maximumDeviation, angleLimit
	checkpoint("complete")
	assert(not options.requireComplete or report.complete, "Planar reduction incomplete: " .. report.reason)
	return out, report
end
