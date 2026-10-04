-- Seam cutting, disk-chart harmonic parameterization and deterministic chart packing.
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local Conformal = require(script.Parent.Conformal)
local A = require(script.Parent.AttributeCore)
local W = {}
function W.autoSeams(mesh, options)
	return require(script.Parent.AutomaticSeams)(mesh, options)
end
function W.angleBased(mesh, options)
	return require(script.Parent.AngleBased)(mesh, options)
end
function W.harmonic(mesh, options)
	options = options or {}
	local topology = mesh:topology()
	local nextVertex = {}
	local boundaryCount = 0
	for _, edge in topology.edges do
		assert(#edge.faces <= 2, "Unwrap requires manifold input")
		if #edge.faces == 1 then
			local a, b = edge.a, edge.b
			if edge.directions[1] < 0 then
				a, b = b, a
			end
			assert(not nextVertex[a], "Nonmanifold chart boundary")
			nextVertex[a] = b
			boundaryCount += 1
		end
	end
	assert(boundaryCount >= 3, "Chart is closed; provide seams first")
	local start = U.keys(nextVertex)[1]
	local loop, seen = {}, {}
	local v = start
	repeat
		assert(v and not seen[v], "Broken chart boundary")
		seen[v] = true
		table.insert(loop, v)
		v = nextVertex[v]
	until v == start
	assert(#loop == boundaryCount, "Chart must have one boundary loop")
	local uv = {}
	local length = 0
	local lengths = {}
	for i, id in loop do
		lengths[i] = length
		length += (mesh.vertices[loop[i % #loop + 1]] - mesh.vertices[id]).Magnitude
	end
	assert(length > 0)
	for i, id in loop do
		local angle = 2 * math.pi * lengths[i] / length
		uv[id] = Vector2.new(0.5 + 0.5 * math.cos(angle), 0.5 + 0.5 * math.sin(angle))
	end
	local interior = {}
	for _, id in U.keys(mesh.vertices) do
		if not seen[id] then
			uv[id] = Vector2.new(0.5, 0.5)
			table.insert(interior, id)
		end
	end
	local iterations, residual = 0, 0
	for iteration = 1, options.iterations or 2000 do
		iterations = iteration
		residual = 0
		for _, id in interior do
			local sum = Vector2.zero
			local n = 0
			for other in topology.neighbors[id] do
				sum += uv[other]
				n += 1
			end
			assert(n > 0)
			local value = sum / n
			residual = math.max(residual, (value - uv[id]).Magnitude)
			uv[id] = value
		end
		if residual < (options.tolerance or 1e-6) then
			break
		end
	end
	local out = mesh:clone()
	for _, f in out.faces do
		for i, id in f.vertices do
			f.corners[i].uv = uv[id]
		end
	end
	return out,
		{
			iterations = iterations,
			residual = residual,
			converged = residual < (options.tolerance or 1e-6),
			boundaryVertices = #loop,
		}
end
function W.unwrap(mesh, seams, options)
	if options and options.method == "angle" then
		return require(script.Parent.AngleUnwrap)(mesh, seams, options)
	end
	options = options or {}
	if seams == nil then
		seams = {}
		local channel = (mesh.attributes or {})[options.seamAttribute or "uv_seam"]
		if channel then
			assert(
				channel.domain == "edge" and channel.dataType == "boolean",
				"Seam attribute must be edge boolean"
			)
			A.validate(mesh)
			for key in A.keys(mesh, "edge") do
				if A.read(channel, key) then
					seams[key] = true
				end
			end
		end
	end
	local topology = mesh:topology()
	local faceAdj = {}
	local parents = {}
	local cornerNodes = {}
	local nodeData = {}
	local nextNode = 1
	local function find(x)
		while parents[x] ~= x do
			parents[x] = parents[parents[x]]
			x = parents[x]
		end
		return x
	end
	local function union(a, b)
		a, b = find(a), find(b)
		if a ~= b then
			parents[math.max(a, b)] = math.min(a, b)
		end
	end
	for _, fid in U.keys(mesh.faces) do
		faceAdj[fid] = {}
		cornerNodes[fid] = {}
		local f = mesh.faces[fid]
		for i, id in f.vertices do
			local node = nextNode
			nextNode += 1
			parents[node] = node
			cornerNodes[fid][id] = node
			nodeData[node] = { vertex = id, face = fid, corner = i }
		end
	end
	for key, e in topology.edges do
		assert(#e.faces <= 2, "Cannot unwrap nonmanifold edge")
		if #e.faces == 2 and not seams[key] then
			local a, b = e.faces[1], e.faces[2]
			table.insert(faceAdj[a], b)
			table.insert(faceAdj[b], a)
			union(cornerNodes[a][e.a], cornerNodes[b][e.a])
			union(cornerNodes[a][e.b], cornerNodes[b][e.b])
		end
	end
	local charts, visited = {}, {}
	for _, seed in U.keys(mesh.faces) do
		if not visited[seed] then
			local queue = { seed }
			visited[seed] = true
			local cursor = 1
			while cursor <= #queue do
				local fid = queue[cursor]
				cursor += 1
				for _, neighbor in faceAdj[fid] do
					if not visited[neighbor] then
						visited[neighbor] = true
						table.insert(queue, neighbor)
					end
				end
			end
			local chart = Mesh.new()
			local roots, faces = {}, {}
			for _, fid in queue do
				local f = mesh.faces[fid]
				local vs = {}
				for i, id in f.vertices do
					local root = find(cornerNodes[fid][id])
					if not roots[root] then
						roots[root] = chart:addVertex(mesh.vertices[id])
					end
					vs[i] = roots[root]
				end
				local newId = chart:addFace(vs, f.corners, f.material)
				faces[newId] = fid
			end
			local flat, report
			if options.method == "lscm" then
				flat, report = Conformal.lscm(chart, options)
				-- Fit isotropically into one packing cell, preserving chart angles.
				local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
				for _, f in flat.faces do
					for _, c in f.corners do
						lo = Vector2.new(math.min(lo.X, c.uv.X), math.min(lo.Y, c.uv.Y))
						hi = Vector2.new(math.max(hi.X, c.uv.X), math.max(hi.Y, c.uv.Y))
					end
				end
				local span = math.max(hi.X - lo.X, hi.Y - lo.Y)
				assert(span > 0, "Collapsed UV chart")
				for _, f in flat.faces do
					for _, c in f.corners do
						c.uv = (c.uv - lo) / span
					end
				end
			else
				assert(options.method == nil or options.method == "harmonic", "Unknown unwrap method")
				flat, report = W.harmonic(chart, options)
			end
			table.insert(charts, { mesh = flat, faces = faces, report = report })
		end
	end
	local out = mesh:clone()
	local columns = math.ceil(math.sqrt(#charts))
	local padding = options.padding or 0.04
	assert(padding >= 0 and padding < 0.5)
	for i, chart in charts do
		local offset = Vector2.new((i - 1) % columns, math.floor((i - 1) / columns))
		for newId, f in chart.mesh.faces do
			local target = out.faces[chart.faces[newId]]
			for j, c in f.corners do
				target.corners[j].uv = (offset + Vector2.one * padding + c.uv * (1 - 2 * padding)) / columns
			end
		end
	end
	local reports = {}
	for i, c in charts do
		reports[i] = c.report
	end
	return out, { charts = #charts, reports = reports }
end
function W.sharpSeams(mesh, angle)
	local seams = {}
	local threshold = math.cos(angle or math.rad(60))
	local normals = {}
	for fid in mesh.faces do
		normals[fid] = mesh:faceNormal(fid)
	end
	for key, e in mesh:topology().edges do
		if #e.faces ~= 2 or normals[e.faces[1]]:Dot(normals[e.faces[2]]) < threshold then
			seams[key] = true
		end
	end
	return seams
end
return W
