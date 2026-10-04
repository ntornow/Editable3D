-- Transactional multi-chart angle unwrap with shared work and final layout audits.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Connectivity = require(script.Parent.Connectivity)
local Charts = require(script.Parent.UnwrapChartTopology)
local AngleBased = require(script.Parent.AngleBased)
local Packing = require(script.Parent.UVPacking)
local NativeAudit = require(script.Parent.AngleNativeAudit)
return function(source, sourceSeams, settings)
	local options = U.copy(settings or {})
	local seams = sourceSeams ~= nil and U.copy(sourceSeams) or nil
	assert(
		options.pins == nil,
		"Multi-chart angle unwrap chooses chart gauges; use Unwrap.angleBased for explicit boundary pins"
	)
	local maxVertices = U.integer(options.maxVertices or 20000, 1)
	local maxFaces = U.integer(options.maxFaces or 40000, 1)
	local maxCorners = U.integer(options.maxCorners or 200000, 1)
	local maxTriangles = U.integer(options.maxTriangles or 40000, 1)
	local maxFaceVertices = U.integer(options.maxFaceVertices or 2000, 3)
	local maxWork = U.integer(options.maxWork or 50000000, 1)
	local maxChartFaces = U.integer(options.maxChartFaces or maxFaces, 1)
	local maxCharts = U.integer(options.maxCharts or maxFaces, 1)
	assert(
		U.count(source.vertices) <= maxVertices and U.count(source.faces) <= maxFaces,
		"Angle atlas input allocation budget exceeded"
	)
	local corners, triangleCount = 0, 0
	for _, face in source.faces do
		corners += #face.vertices
		triangleCount += #face.vertices - 2
		assert(
			corners <= maxCorners and #face.vertices <= maxFaceVertices,
			"Angle atlas corner budget exceeded"
		)
		assert(triangleCount <= maxTriangles, "Angle atlas triangle allocation budget exceeded")
	end
	for _, name in { "cancelled", "checkpoint" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Angle atlas callback must be a function"
		)
	end
	assert(
		options.requireComplete == nil or type(options.requireComplete) == "boolean",
		"Angle atlas requireComplete must be boolean"
	)
	assert(
		options.packing == nil or type(options.packing) == "table",
		"Angle atlas packing options must be a table"
	)
	local mesh = source:clone()
	A.validate(mesh)
	local work = 0
	local function visit(n)
		work += n or 1
		assert(work <= maxWork, "Angle atlas work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Angle atlas cancelled")
	end
	local function checkpoint(stage)
		visit(0)
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = work })
		end
	end
	checkpoint("begin")
	visit(U.count(mesh.vertices) + U.count(mesh.faces) + corners)
	assert(
		Connectivity.analyze(mesh, { maxElements = maxVertices + maxFaces + maxCorners }).valid,
		"Angle atlas requires oriented manifold geometry"
	)
	local topology = mesh:topology()
	if seams == nil then
		seams = {}
		local channel = mesh.attributes[options.seamAttribute or "uv_seam"]
		if channel then
			assert(
				channel.domain == "edge" and channel.dataType == "boolean",
				"Angle atlas seam attribute must be edge boolean"
			)
			for key in topology.edges do
				visit(1)
				if A.read(channel, key) then
					seams[key] = true
				end
			end
		end
	end
	assert(type(seams) == "table", "Angle atlas seams must be an edge boolean set")
	for key, value in seams do
		assert(topology.edges[key] and type(value) == "boolean", "Invalid angle atlas seam")
	end
	local adjacency, kept = {}, {}
	for fid in mesh.faces do
		adjacency[fid] = {}
	end
	for key, edge in topology.edges do
		visit(1)
		if #edge.faces == 2 and not seams[key] then
			kept[key] = true
			table.insert(adjacency[edge.faces[1]], edge.faces[2])
			table.insert(adjacency[edge.faces[2]], edge.faces[1])
		end
	end
	local components, seen = {}, {}
	for _, seed in U.keys(mesh.faces) do
		if not seen[seed] then
			assert(#components < maxCharts, "Angle atlas chart allocation budget exceeded")
			local faces = { seed }
			seen[seed] = true
			local cursor = 1
			while cursor <= #faces do
				local fid = faces[cursor]
				cursor += 1
				for _, neighbor in adjacency[fid] do
					visit(1)
					if not seen[neighbor] then
						assert(#faces < maxChartFaces, "Angle atlas chart face budget exceeded")
						seen[neighbor] = true
						table.insert(faces, neighbor)
					end
				end
			end
			table.sort(faces)
			table.insert(components, faces)
		end
	end
	local report = {
		complete = false,
		applied = false,
		charts = #components,
		reports = {},
		chartMaps = {},
		seams = U.copy(seams),
	}
	local function finish(out, reason)
		report.work = work
		if not report.complete then
			report.reason = reason
		end
		assert(not options.requireComplete or report.complete, "Angle atlas incomplete: " .. tostring(reason))
		return out, report
	end
	if #components == 0 then
		report.complete = true
		return finish(mesh)
	end
	local out = mesh:clone()
	local records, angles = {}, {}
	local function childSettings(config, stage)
		local child = U.copy(config)
		local used = 0
		local callback = child.checkpoint
		child.requireComplete = false
		child.maxWork = math.min(child.maxWork or maxWork, maxWork - work)
		local additionalCancellation = child.cancelled
		child.cancelled = function()
			return options.cancelled and options.cancelled()
				or additionalCancellation ~= options.cancelled
					and additionalCancellation
					and additionalCancellation()
		end
		child.checkpoint = function(status)
			visit(math.max(0, status.work - used))
			used = status.work
			if callback and callback ~= options.checkpoint then
				callback(status)
			end
			checkpoint(stage .. ":" .. status.stage)
		end
		return child, function(result)
			visit(math.max(0, result.work - used))
		end
	end
	for index, faces in components do
		local chart = Charts.build(mesh, topology, faces, kept, visit)
		assert(
			chart.disk and #chart.collapsedSeams == 0,
			"Angle atlas cuts must form representable disk charts"
		)
		local config, account = childSettings(options, "chart" .. index)
		local flat, result = AngleBased(chart.mesh, config)
		account(result)
		report.reports[index] = result
		table.insert(report.chartMaps, {
			id = faces[1],
			faces = faces,
			faceMap = chart.faceMap,
			vertexMap = chart.vertexMap,
			cornerMap = chart.cornerMap,
		})
		if not result.complete then
			report.failedChart = faces[1]
			return finish(mesh, "chartUnwrap")
		end
		for localId, face in flat.faces do
			local target = out.faces[chart.faceMap[localId]]
			for i, corner in face.corners do
				visit(1)
				if target.corners[i].uv ~= corner.uv then
					target.corners[i].uv, target.corners[i].tangent, target.corners[i].tangentSign =
						corner.uv, nil, nil
				end
			end
		end
		for i, triangle in result.triangles do
			visit(1)
			table.insert(
				records,
				{ face = chart.faceMap[triangle.face], corners = triangle.corners, island = faces[1] }
			)
			for k = 1, 3 do
				table.insert(angles, result.optimizedAngles[3 * i - 3 + k])
			end
		end
	end
	local packing = U.copy(options.packing or {})
	packing.textureSize = options.textureSize or Vector2.one
	packing.seams = seams
	if packing.normalizeDensity == nil then
		packing.normalizeDensity = true
	end
	if packing.margin == nil and options.padding ~= nil then
		packing.margin = options.padding
	end
	local config, account = childSettings(packing, "packing")
	local atlas, packed = Packing.run(out, config)
	account(packed)
	report.packing = packed
	if not packed.complete then
		return finish(mesh, "packing")
	end
	local audit = NativeAudit.run(atlas, records, angles, packing.textureSize, options, visit)
	report.nativeAudit = audit
	report.complete = audit.nativeOrientation
		and audit.maximumAngleResidual <= (options.reconstructionAngleTolerance or 1e-5)
		and (not audit.overlapChecked or audit.overlapFree)
	checkpoint("atlasVerified")
	if not report.complete then
		return finish(mesh, "nativeAtlasAudit")
	end
	report.applied = true
	return finish(atlas)
end
