-- Geometry-guided dual forests with audited disk-preserving cycle recovery.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Connectivity = require(script.Parent.Connectivity)
local G = require(script.Parent.PlanarReduceGeometry)
local Charts = require(script.Parent.UnwrapChartTopology)
return function(source, settings)
	local options = U.copy(settings or {})
	local maxVertices = U.integer(options.maxVertices or 250000, 1)
	local maxFaces = U.integer(options.maxFaces or 250000, 1)
	local maxCorners = U.integer(options.maxCorners or 1000000, 1)
	local maxFaceVertices = U.integer(options.maxFaceVertices or 2000, 3)
	local maxChartFaces = U.integer(options.maxChartFaces or 256, 1)
	local maxCharts = U.integer(options.maxCharts or maxFaces, 1)
	local maxWork = U.integer(options.maxWork or 20000000, 1)
	local maxClosureTests = U.integer(options.maxClosureTests or 1000000, 0)
	assert(
		U.count(source.vertices) <= maxVertices and U.count(source.faces) <= maxFaces,
		"Automatic seam allocation budget exceeded"
	)
	local corners = 0
	for _, face in source.faces do
		corners += #face.vertices
		assert(
			corners <= maxCorners and #face.vertices <= maxFaceVertices,
			"Automatic seam corner budget exceeded"
		)
	end
	for _, name in { "splitMaterials", "preserveUVSeams", "recoverCycles" } do
		assert(
			options[name] == nil or type(options[name]) == "boolean",
			"Automatic seam flags must be boolean"
		)
	end
	for _, name in { "cancelled", "checkpoint" } do
		assert(
			options[name] == nil or type(options[name]) == "function",
			"Automatic seam callback must be a function"
		)
	end
	local angleLimit, normalCone = options.angleLimit or math.pi / 3, options.normalCone or math.pi / 2
	for _, value in { angleLimit, normalCone } do
		assert(
			type(value) == "number" and U.finite(value) and value >= 0 and value <= math.pi,
			"Automatic seam angles must lie in [0,pi]"
		)
	end
	local mesh = source:clone()
	A.validate(mesh)
	local work = 0
	local function visit(n)
		work += n or 1
		assert(work <= maxWork, "Automatic seam work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Automatic seam construction cancelled")
	end
	local function checkpoint(stage)
		visit(0)
		if options.checkpoint then
			options.checkpoint({ stage = stage, work = work })
		end
	end
	checkpoint("begin")
	visit(U.count(mesh.vertices) + U.count(mesh.faces) + corners)
	local validation = Connectivity.analyze(mesh, { maxElements = maxVertices + maxFaces + maxCorners })
	assert(validation.valid, "Automatic seams require oriented manifold geometry")
	local topology = mesh:topology()
	local normals, lookup, adjacency = {}, {}, {}
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		normals[fid] = assert(G.plane(mesh, face.vertices, visit), "Degenerate automatic seam source face")
		mesh:faceTriangles(
			fid,
			{ validateSimple = true, maxVertices = maxFaceVertices, maxWork = maxWork, _visit = visit }
		)
		lookup[fid], adjacency[fid] = {}, {}
		for i, vertex in face.vertices do
			lookup[fid][vertex] = i
		end
	end
	local protected = {}
	for key, value in options.seams or {} do
		assert(topology.edges[key] and type(value) == "boolean", "Invalid explicit automatic seam edge")
		if value then
			protected[key] = "explicit"
		end
	end
	local attributes = { uv_seam = true, sharp_edge = true, subdivision_edge_sharpness = true }
	for _, name in options.seamAttributes or {} do
		assert(mesh.attributes[name], "Missing automatic seam attribute")
		attributes[name] = true
	end
	for name in attributes do
		local channel = mesh.attributes[name]
		if channel then
			assert(
				channel.domain == "edge" and (channel.dataType == "boolean" or channel.dataType == "number"),
				"Automatic seam fields must be boolean or numeric edges"
			)
			for key in topology.edges do
				visit(1)
				local value = A.read(channel, key)
				if value == true or type(value) == "number" and value > 0 then
					protected[key] = protected[key] or "attribute"
				end
			end
		end
	end
	local function dot(a, b)
		return math.clamp(a.x * b.x + a.y * b.y + a.z * b.z, -1, 1)
	end
	local candidates = {}
	for key, edge in topology.edges do
		visit(1)
		if #edge.faces == 1 then
			protected[key] = "boundary"
		else
			local a, b = edge.faces[1], edge.faces[2]
			local cosine = dot(normals[a], normals[b])
			if cosine + 2 ^ -45 < math.cos(angleLimit) then
				protected[key] = protected[key] or "angle"
			end
			if options.splitMaterials ~= false and mesh.faces[a].material ~= mesh.faces[b].material then
				protected[key] = protected[key] or "material"
			end
			if options.preserveUVSeams then
				for _, vertex in { edge.a, edge.b } do
					if
						mesh.faces[a].corners[lookup[a][vertex]].uv
						~= mesh.faces[b].corners[lookup[b][vertex]].uv
					then
						protected[key] = protected[key] or "uv"
					end
				end
			end
			if not protected[key] then
				local p, q = mesh.vertices[edge.a], mesh.vertices[edge.b]
				local length = math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 + (p.Z - q.Z) ^ 2)
				table.insert(
					candidates,
					{ key = key, a = a, b = b, va = edge.a, vb = edge.b, score = length * (1 + cosine) / 2 }
				)
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.va == b.va and a.vb < b.vb or a.va < b.va
	end)
	for i, edge in candidates do
		edge.rank = i
		table.insert(adjacency[edge.a], edge)
		table.insert(adjacency[edge.b], edge)
	end
	local kept, owner, charts = {}, {}, {}
	for _, seed in U.keys(mesh.faces) do
		if not owner[seed] then
			assert(#charts < maxCharts, "Automatic seam chart budget exceeded")
			local faces, heap, queued = { seed }, {}, {}
			owner[seed] = seed
			local function push(edge)
				if queued[edge.key] then
					return
				end
				queued[edge.key] = true
				local i = #heap + 1
				while i > 1 do
					visit(1)
					local parent = math.floor(i / 2)
					if heap[parent].rank < edge.rank then
						break
					end
					heap[i] = heap[parent]
					i = parent
				end
				heap[i] = edge
			end
			local function pop()
				local result = heap[1]
				local last = table.remove(heap)
				if #heap > 0 then
					local i = 1
					while i * 2 <= #heap do
						visit(1)
						local child = i * 2
						if child < #heap and heap[child + 1].rank < heap[child].rank then
							child += 1
						end
						if last.rank < heap[child].rank then
							break
						end
						heap[i] = heap[child]
						i = child
					end
					heap[i] = last
				end
				return result
			end
			for _, edge in adjacency[seed] do
				push(edge)
			end
			while #heap > 0 and #faces < maxChartFaces do
				visit(1)
				local edge = pop()
				local nextFace = owner[edge.a] == seed and edge.b or edge.a
				if
					not owner[nextFace]
					and dot(normals[seed], normals[nextFace]) + 2 ^ -45 >= math.cos(normalCone)
				then
					owner[nextFace] = seed
					kept[edge.key] = true
					table.insert(faces, nextFace)
					for _, nextEdge in adjacency[nextFace] do
						push(nextEdge)
					end
				end
			end
			table.sort(faces)
			local chart = Charts.build(mesh, topology, faces, kept, visit)
			assert(chart.disk and #chart.collapsedSeams == 0, "Automatic seam forest failed the disk audit")
			chart.id = seed
			table.insert(charts, chart)
			checkpoint("chartForest")
		end
	end
	local byId = {}
	for _, chart in charts do
		byId[chart.id] = chart
	end
	local closureTests, recovered = 0, 0
	local closureLimited = false
	if options.recoverCycles ~= false then
		for _, edge in candidates do
			if not kept[edge.key] and owner[edge.a] == owner[edge.b] then
				if closureTests >= maxClosureTests then
					closureLimited = true
					break
				end
				closureTests += 1
				kept[edge.key] = true
				local id = owner[edge.a]
				local trial = Charts.build(mesh, topology, byId[id].faces, kept, visit)
				local allowed = trial.disk
				for _, key in trial.collapsedSeams do
					if protected[key] then
						allowed = false
					end
				end
				if allowed then
					recovered += 1 + #trial.collapsedSeams
					for _, key in trial.collapsedSeams do
						kept[key] = true
					end
					trial.collapsedSeams = {}
					trial.id = id
					byId[id] = trial
				else
					kept[edge.key] = nil
				end
			end
		end
	end
	local seams, reasons, chartReports = {}, {}, {}
	for key, edge in topology.edges do
		visit(1)
		if not kept[key] then
			seams[key] = true
			reasons[key] = protected[key]
				or (
					#edge.faces == 2 and owner[edge.faces[1]] ~= owner[edge.faces[2]] and "chartBoundary"
					or "cutGraph"
				)
		end
	end
	for _, old in charts do
		local chart = Charts.build(mesh, topology, old.faces, kept, visit)
		assert(chart.disk and #chart.collapsedSeams == 0, "Final automatic seam chart audit failed")
		local maximum = 0
		for _, fid in chart.faces do
			maximum = math.max(maximum, math.acos(dot(normals[old.id], normals[fid])))
		end
		table.insert(chartReports, {
			id = old.id,
			faces = chart.faces,
			vertices = chart.topology.vertices,
			edges = chart.topology.edges,
			boundaryEdges = chart.topology.boundaryEdges,
			boundaryLoops = 1,
			eulerCharacteristic = 1,
			maximumNormalAngle = maximum,
		})
	end
	checkpoint("seamsVerified")
	return seams,
		{
			complete = true,
			charts = chartReports,
			faceToChart = owner,
			reasons = reasons,
			closureTests = closureTests,
			recoveredEdges = recovered,
			closureLimited = closureLimited,
			work = work,
		}
end
