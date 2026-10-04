-- Private two-sided shell with measured joins and explicit source correspondence.
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
return function(mesh, thickness, options, detailed)
	options = options or {}
	assert(
		type(thickness) == "number" and U.finite(thickness) and thickness > 0,
		"Positive finite shell thickness required"
	)
	local offset = options.offset or 0
	assert(
		type(offset) == "number" and U.finite(offset) and offset >= -1 and offset <= 1,
		"Shell offset must lie in [-1,1]"
	)
	A.validate(mesh)
	assert(mesh:validate().valid, "Solidify requires valid oriented source topology")
	local join = options.join or (detailed and "miter" or "normal")
	assert(join == "normal" or join == "miter", "Shell join must be normal or miter")
	assert(
		options.joinWeighting == nil or options.joinWeighting == "angle" or options.joinWeighting == "uniform",
		"Unknown shell join weighting"
	)
	local miterLimit = options.miterLimit or 4
	assert(U.finite(miterLimit) and miterLimit >= 1, "Finite shell miter limit of at least one required")
	local maxOffsetError = options.maxOffsetError or math.max(thickness * 0.05, 1e-6)
	assert(
		U.finite(maxOffsetError) and maxOffsetError >= 0,
		"Finite nonnegative shell offset tolerance required"
	)
	local rankTolerance = options.rankTolerance or 1e-12
	assert(
		U.finite(rankTolerance) and rankTolerance > 0 and rankTolerance < 1,
		"Shell rank tolerance must lie in (0,1)"
	)
	local planarityTolerance = options.planarityTolerance or math.max(thickness * 1e-4, 1e-6)
	assert(
		U.finite(planarityTolerance) and planarityTolerance >= 0,
		"Finite nonnegative shell planarity tolerance required"
	)
	local checked = options.checkIntersections
	if checked == nil then
		checked = detailed == true
	end
	assert(type(checked) == "boolean", "Shell checkIntersections must be boolean")
	assert(
		options.requireComplete == nil or type(options.requireComplete) == "boolean",
		"Shell requireComplete must be boolean"
	)
	local strict = detailed or join == "miter" or options.checkIntersections == true
	assert(not strict or next(mesh.faces), "Shell requires source faces")
	local report = {
		complete = false,
		join = join,
		maximumOffsetError = 0,
		maximumMiter = 0,
		miterLimitExceeded = 0,
		orientationFailures = 0,
		closedComponents = 0,
		ranks = { 0, 0, 0 },
		intersectionChecked = checked == true,
		top = {},
		bottom = {},
		componentVolumes = {},
		maximumSourcePlanarityError = 0,
	}
	local topology = mesh:topology()
	local boundary = 0
	for _, edge in topology.edges do
		if #edge.faces == 1 then
			boundary += 1
		end
	end
	assert(
		U.count(mesh.vertices) * 2 <= U.integer(options.maxVertices or 500000, 1),
		"Solidify vertex budget exceeded"
	)
	assert(
		U.count(mesh.faces) * 2 + boundary <= U.integer(options.maxFaces or 500000, 1),
		"Solidify face budget exceeded"
	)
	local maxWork = U.integer(options.maxWork or 2000000, 1)
	local work = 0
	assert(not options.cancelled or not options.cancelled(), "Solidify cancelled")
	local function visit()
		work += 1
		assert(work <= maxWork, "Solidify work budget exceeded")
		if work % 256 == 0 then
			assert(not options.cancelled or not options.cancelled(), "Solidify cancelled")
			if options.checkpoint then
				options.checkpoint({ stage = "build", work = work, maxWork = maxWork })
			end
		end
	end
	if options.checkpoint then
		options.checkpoint({ stage = "begin", work = 0, maxWork = maxWork })
	end
	local function audit(object, stage)
		local config = table.clone(options.intersectionOptions or {})
		local caller = config.checkpoint
		config.checkpoint = function(progress)
			assert(not options.cancelled or not options.cancelled(), "Solidify cancelled")
			if caller then
				caller(progress)
			end
			if options.checkpoint then
				options.checkpoint({ stage = stage, work = work, intersectionWork = progress.work })
			end
		end
		local _, result = require(script.Parent.Intersections).mesh(object, config)
		return result
	end
	if checked then
		report.inputIntersections = audit(mesh, "inputIntersections")
		assert(
			report.inputIntersections.complete and report.inputIntersections.intersectionFree,
			"Shell requires an intersection-free source and a complete input audit"
		)
	end
	local out = Mesh.new()
	local normals, faceNormals, top, bottom = {}, {}, {}, {}
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = { vertex = false, edge = false, face = false, corner = false },
	}
	for fid, face in mesh.faces do
		local n, area = mesh:faceNormal(fid)
		faceNormals[fid] = n
		local origin = mesh.vertices[face.vertices[1]]
		for _, v in face.vertices do
			local p = mesh.vertices[v]
			local error = math.abs((p.X - origin.X) * n.X + (p.Y - origin.Y) * n.Y + (p.Z - origin.Z) * n.Z)
			report.maximumSourcePlanarityError = math.max(report.maximumSourcePlanarityError, error)
			normals[v] = (normals[v] or Vector3.zero) + n * area
			visit()
		end
	end
	assert(
		join ~= "miter" or report.maximumSourcePlanarityError <= planarityTolerance,
		"Miter shell requires planar source faces within tolerance; triangulate nonplanar faces first"
	)
	for _, id in U.keys(mesh.vertices) do
		visit()
		local p = mesh.vertices[id]
		assert(not strict or normals[id], "Shell requires incident faces at every vertex")
		local n
		if join == "miter" then
			local rank
			n, rank = require(script.Parent.ShellMiter)(
				mesh,
				id,
				topology.vertexFaces[id],
				faceNormals,
				options,
				visit
			)
			report.ranks[rank] += 1
		else
			assert(not normals[id] or normals[id].Magnitude > 0, "Shell vertex has ambiguous averaged normal")
			n = U.unit(normals[id] or Vector3.yAxis, Vector3.yAxis)
		end
		report.maximumMiter = math.max(report.maximumMiter, n.Magnitude)
		if n.Magnitude > miterLimit then
			report.miterLimitExceeded += 1
		end
		local function point(distance)
			return Vector3.new(p.X + n.X * distance, p.Y + n.Y * distance, p.Z + n.Z * distance)
		end
		top[id] = out:addVertex(point(thickness * (offset + 1) / 2))
		bottom[id] = out:addVertex(point(thickness * (offset - 1) / 2))
		for _, fid in topology.vertexFaces[id] do
			visit()
			local normal = faceNormals[fid]
			for _, entry in
				{ { top[id], thickness * (offset + 1) / 2 }, { bottom[id], thickness * (offset - 1) / 2 } }
			do
				local q = out.vertices[entry[1]]
				local actual = (q.X - p.X) * normal.X + (q.Y - p.Y) * normal.Y + (q.Z - p.Z) * normal.Z
				report.maximumOffsetError = math.max(report.maximumOffsetError, math.abs(actual - entry[2]))
			end
		end
		maps.vertex[top[id]], maps.vertex[bottom[id]] = { { id, 1 } }, { { id, 1 } }
	end
	local function face(ids, corners, source, indices, reverse)
		visit()
		local copied = {}
		for i, c in corners do
			copied[i] = U.copy(c)
			if reverse and copied[i].tangentSign then
				copied[i].tangentSign *= -1
			end
		end
		local fid = out:addFace(ids, copied, mesh.faces[source].material)
		maps.face[fid] = { { source, 1 } }
		for i, oldIndex in indices do
			maps.corner[fid .. ":" .. i] = { { source .. ":" .. oldIndex, 1 } }
		end
		return fid
	end
	for _, fid in U.keys(mesh.faces) do
		local source = mesh.faces[fid]
		local a, b, bc, ai, bi = {}, {}, {}, {}, {}
		for i, id in source.vertices do
			a[i], ai[i] = top[id], i
			table.insert(b, 1, bottom[id])
			table.insert(bc, 1, source.corners[i])
			table.insert(bi, 1, i)
		end
		local upper = face(a, source.corners, fid, ai, false)
		local lower = face(b, bc, fid, bi, true)
		if
			out:faceNormal(upper):Dot(faceNormals[fid]) <= 0
			or out:faceNormal(lower):Dot(faceNormals[fid]) >= 0
		then
			report.orientationFailures += 1
		end
	end
	for _, key in U.keys(topology.edges) do
		visit()
		local edge = topology.edges[key]
		maps.edge[U.edge(top[edge.a], top[edge.b])], maps.edge[U.edge(bottom[edge.a], bottom[edge.b])] =
			{ { key, 1 } }, { { key, 1 } }
		if #edge.faces == 1 then
			local a, b = edge.a, edge.b
			if edge.directions[1] < 0 then
				a, b = b, a
			end
			local fid = edge.faces[1]
			local source = mesh.faces[fid]
			local ia, ib = table.find(source.vertices, a), table.find(source.vertices, b)
			face(
				{ top[b], top[a], bottom[a], bottom[b] },
				{ source.corners[ib], source.corners[ia], source.corners[ia], source.corners[ib] },
				fid,
				{ ib, ia, ia, ib },
				false
			)
		end
	end
	for name in mesh.groups do
		out.groups[name] = {}
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	out:recalculateNormals(options.normalAngle or (join == "miter" and math.rad(60) or nil))
	A.validate(out)
	report.validation = out:validate()
	if strict then
		local components = require(script.Parent.Connectivity).analyze(mesh).components
		for _, component in components do
			if component.boundaryLoops == 0 then
				report.closedComponents += 1
				local origin = mesh.vertices[U.keys(component.vertices)[1]]
				local volumes = { 0, 0, 0 }
				local function determinant(a, b, c)
					local ax, ay, az = a.X - origin.X, a.Y - origin.Y, a.Z - origin.Z
					local bx, by, bz = b.X - origin.X, b.Y - origin.Y, b.Z - origin.Z
					local cx, cy, cz = c.X - origin.X, c.Y - origin.Y, c.Z - origin.Z
					return (ax * (by * cz - bz * cy) + ay * (bz * cx - bx * cz) + az * (bx * cy - by * cx))
						/ 6
				end
				for fid in component.faces do
					local ids = mesh.faces[fid].vertices
					for i = 2, #ids - 1 do
						visit()
						for k, map in { false, top, bottom } do
							local positions = map and out.vertices or mesh.vertices
							local a, b, c = ids[1], ids[i], ids[i + 1]
							volumes[k] += determinant(
								positions[map and map[a] or a],
								positions[map and map[b] or b],
								positions[map and map[c] or c]
							)
						end
					end
				end
				table.insert(
					report.componentVolumes,
					{ source = volumes[1], top = volumes[2], bottom = -volumes[3] }
				)
				if volumes[1] * volumes[2] <= 0 or volumes[1] * volumes[3] <= 0 then
					report.orientationFailures += 1
				end
			end
		end
	end
	if checked and report.validation.valid then
		report.outputIntersections = audit(out, "outputIntersections")
	end
	report.top, report.bottom = top, bottom
	report.inputMaps = maps
	report.work = work
	report.maxOffsetError = maxOffsetError
	report.complete = report.validation.valid
		and (
			not strict
			or (
				report.validation.closed
				and report.orientationFailures == 0
				and report.miterLimitExceeded == 0
				and (join == "normal" or report.maximumOffsetError <= maxOffsetError)
				and (
					not checked
					or report.outputIntersections
						and report.outputIntersections.complete
						and report.outputIntersections.intersectionFree
				)
			)
		)
	if not report.complete then
		report.reason = not report.validation.valid and "Shell collapsed source geometry at native precision"
			or report.orientationFailures > 0 and "Shell reversed or consumed source geometry"
			or report.miterLimitExceeded > 0 and "Shell miter limit exceeded"
			or join == "miter" and report.maximumOffsetError > maxOffsetError and "Shell face-offset error exceeds tolerance"
			or "Shell intersection audit failed or was incomplete"
	end
	assert(report.complete or detailed and options.requireComplete == false, report.reason)
	assert(not options.cancelled or not options.cancelled(), "Solidify cancelled")
	return out, report
end
