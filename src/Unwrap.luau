--!strict
-- Seam cutting, disk-chart harmonic parameterization and deterministic chart packing.
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local Conformal = require(script.Parent.Conformal)
local A = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Edge key ("smallerId:largerId") to true for every seam edge.
export type Seams = { [string]: boolean }
export type HarmonicOptions = { iterations: number?, tolerance: number? }
export type HarmonicReport = {
	iterations: number,
	residual: number,
	converged: boolean,
	boundaryVertices: number,
}
-- Unwrap options also carry method-specific settings forwarded to Conformal, AngleUnwrap and
-- AutomaticSeams (method, padding, seamAttribute, iterations, tolerance, budgets, ...).
type Options = { [string]: any }
local W = {}
function W.autoSeams(mesh: Mesh, options: Options?)
	return require(script.Parent.AutomaticSeams)(mesh, options)
end
function W.angleBased(mesh: Mesh, options: Options?)
	return require(script.Parent.AngleBased)(mesh, options)
end
function W.harmonic(mesh: Mesh, options: HarmonicOptions?): (Mesh, HarmonicReport)
	local options: HarmonicOptions = options or {}
	local topology = mesh:topology()
	local nextVertex: { [number]: number } = {}
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
	local loop: { number }, seen: { [number]: boolean } = {}, {}
	local v: number? = start
	repeat
		assert(v and not seen[v], "Broken chart boundary")
		local current: number = v
		seen[current] = true
		table.insert(loop, current)
		v = nextVertex[current]
	until v == start
	assert(#loop == boundaryCount, "Chart must have one boundary loop")
	local uv: { [number]: Vector2 } = {}
	local length = 0
	local lengths: { number } = {}
	for i, id in loop do
		lengths[i] = length
		length += (mesh.vertices[loop[i % #loop + 1]] - mesh.vertices[id]).Magnitude
	end
	assert(length > 0)
	for i, id in loop do
		local angle = 2 * math.pi * lengths[i] / length
		uv[id] = Vector2.new(0.5 + 0.5 * math.cos(angle), 0.5 + 0.5 * math.sin(angle))
	end
	local interior: { number } = {}
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
function W.unwrap(mesh: Mesh, seams: Seams?, options: Options?)
	if options and options.method == "angle" then
		return require(script.Parent.AngleUnwrap)(mesh, seams, options)
	end
	local options: Options = options or {}
	local seams: Seams = seams :: any
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
	local faceAdj: { [number]: { number } } = {}
	local parents: { [number]: number } = {}
	local cornerNodes: { [number]: { [number]: number } } = {}
	local nodeData: { [number]: { vertex: number, face: number, corner: number } } = {}
	local nextNode = 1
	local function find(x: number): number
		while parents[x] ~= x do
			parents[x] = parents[parents[x]]
			x = parents[x]
		end
		return x
	end
	local function union(a: number, b: number)
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
	local charts: { { mesh: Mesh, faces: { [number]: number }, report: any } }, visited: { [number]: boolean } =
		{}, {}
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
			local roots: { [number]: number }, faces: { [number]: number } = {}, {}
			for _, fid in queue do
				local f = mesh.faces[fid]
				local vs: { number } = {}
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
			local flat: Mesh, report: any
			if options.method == "lscm" then
				flat, report = Conformal.lscm(chart, options)
				-- Fit isotropically into one packing cell, preserving chart angles.
				local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
				for _, f in flat.faces do
					for _, c in f.corners do
						local uv = c.uv :: Vector2
						lo = Vector2.new(math.min(lo.X, uv.X), math.min(lo.Y, uv.Y))
						hi = Vector2.new(math.max(hi.X, uv.X), math.max(hi.Y, uv.Y))
					end
				end
				local span = math.max(hi.X - lo.X, hi.Y - lo.Y)
				assert(span > 0, "Collapsed UV chart")
				for _, f in flat.faces do
					for _, c in f.corners do
						c.uv = ((c.uv :: Vector2) - lo) / span
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
				target.corners[j].uv = (
					offset
					+ Vector2.one * padding
					+ (c.uv :: Vector2) * (1 - 2 * padding)
				) / columns
			end
		end
	end
	local reports: { any } = {}
	for i, c in charts do
		reports[i] = c.report
	end
	return out, { charts = #charts, reports = reports }
end
function W.sharpSeams(mesh: Mesh, angle: number?): Seams
	local seams: Seams = {}
	local threshold = math.cos(angle or math.rad(60))
	local normals: { [number]: Vector3 } = {}
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
