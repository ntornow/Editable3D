--!strict
-- Parameter-conforming adaptive rational patches with Bernstein control error bounds.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local Mesh = require(script.Parent.Mesh)
local Types = require(script.Parent.Types)
local A = {}

-- Surface descriptors come from NURBS (typed separately); treated as opaque here.
type Surface = any
export type PatchBound = { errorBound: number, rationalDeviation: number, twist: number }
export type MeshCheckpoint = (info: { [string]: any }) -> ()
export type AdaptiveOptions = {
	tolerance: number?,
	maxLeaves: number?,
	maxDepth: number?,
	seamTolerance: number?,
	closedU: boolean?,
	closedV: boolean?,
	collapsePoles: boolean?,
	maxVertices: number?,
	maxTriangles: number?,
	material: number?,
	checkpoint: MeshCheckpoint?,
}
export type AdaptiveReport = {
	converged: boolean,
	errorBound: number,
	leaves: number,
	refinements: number,
	triangles: number,
	poles: { [string]: boolean },
	reason: string?,
}
type PatchLeaf = { surface: Surface, u0: number, u1: number, v0: number, v1: number }
-- Line tables map a fixed parameter to a set of values, later replaced by sorted value lists.
type Lines = { [number]: { [number]: any } }

local patchBound = require(script.Parent.SurfacePatchBound)

function A.bound(surface: Surface): PatchBound
	local patches: { any } = N.bezierPatches(surface)
	assert(#patches == 1, "Bound requires one Bezier patch; use NURBS.bezierPatches first")
	local error, rational, twist = patchBound(patches[1].surface)
	return { errorBound = error, rationalDeviation = rational, twist = twist }
end

local function addLine(lines: Lines, fixed: number, value: number)
	lines[fixed] = lines[fixed] or {}
	lines[fixed][value] = true
end
local function range(values: { number }, lo: number, hi: number, reverse: boolean): { number }
	local first, last = 1, #values + 1
	while first < last do
		local middle = math.floor((first + last) / 2)
		if values[middle] < lo then
			first = middle + 1
		else
			last = middle
		end
	end
	local result: { number } = {}
	local i = first
	while i <= #values and values[i] <= hi do
		table.insert(result, values[i])
		i += 1
	end
	if reverse then
		local flipped: { number } = {}
		for j = #result, 1, -1 do
			table.insert(flipped, result[j])
		end
		return flipped
	end
	return result
end

function A.tessellate(surface: Surface, options: AdaptiveOptions?): (Types.Mesh, AdaptiveReport)
	local options: AdaptiveOptions = options or {}
	local seamTolerance = options.seamTolerance or 1e-6
	assert(U.finite(seamTolerance) and seamTolerance >= 0)
	local prepared: any = N.compileSurface(surface)
	local leaves: { PatchLeaf }, refinement: any = require(script.Parent.SurfacePartition)(surface, options)
	local maximum, converged, visited = refinement.errorBound, refinement.converged, refinement.refinements
	local vertical: Lines, horizontal: Lines = {}, {}
	for _, node in leaves do
		for _, u in { node.u0, node.u1 } do
			for _, v in { node.v0, node.v1 } do
				addLine(vertical, u, v)
				addLine(horizontal, v, u)
			end
		end
	end
	local function synchronize(lines: Lines, a: number, b: number)
		local both: { [number]: boolean } = {}
		for value in lines[a] do
			both[value] = true
		end
		for value in lines[b] do
			both[value] = true
		end
		lines[a], lines[b] = both, both
	end
	if options.closedU then
		synchronize(vertical, 0, 1)
	end
	if options.closedV then
		synchronize(horizontal, 0, 1)
	end
	for key, values in vertical do
		vertical[key] = U.keys(values)
	end
	for key, values in horizontal do
		horizontal[key] = U.keys(values)
	end
	local poles: { [string]: boolean } = {}
	if options.collapsePoles then
		-- Each edge is a mixed (name, axis, value) tuple.
		for _, edge in
			{ { "U0", "V", 0 }, { "U1", "V", 1 }, { "V0", "U", 0 }, { "V1", "U", 1 } } :: { { any } }
		do
			local curve: any = N.isoCurve(surface, edge[2], edge[3])
			local collapse = true
			for _, p in curve.points do
				if (p - curve.points[1]).Magnitude > seamTolerance then
					collapse = false
					break
				end
			end
			poles[edge[1]] = collapse
		end
	end
	local mesh, vertices: { [string]: number } = Mesh.new(), {}
	local triangleCount = 0
	local function corner(u: number, v: number, evaluator: any, node: PatchLeaf): (number, Types.Corner)
		local d: any =
			evaluator.derivatives((u - node.u0) / (node.u1 - node.u0), (v - node.v0) / (node.v1 - node.v0))
		if options.closedU and (u == 0 or u == 1) then
			assert(
				(d.position - prepared.evaluate(1 - u, v)).Magnitude <= seamTolerance,
				"Closed U boundary does not coincide"
			)
		end
		if options.closedV and (v == 0 or v == 1) then
			assert(
				(d.position - prepared.evaluate(u, 1 - v)).Magnitude <= seamTolerance,
				"Closed V boundary does not coincide"
			)
		end
		local normal = d.normal
		if not d.regular then
			local pu, pv = u, v
			if u == 0 and poles.U0 then
				pu = 1e-5
			elseif u == 1 and poles.U1 then
				pu = 1 - 1e-5
			end
			if v == 0 and poles.V0 then
				pv = 1e-5
			elseif v == 1 and poles.V1 then
				pv = 1 - 1e-5
			end
			assert(pu ~= u or pv ~= v, "Singular interior surface sample")
			local limit = prepared.derivatives(pu, pv)
			assert(limit.regular, "Pole has no regular normal limit")
			normal = limit.normal
		end
		local cu, cv = u, v
		if options.closedU and cu == 1 then
			cu = 0
		end
		if options.closedV and cv == 1 then
			cv = 0
		end
		local key: string
		if u == 0 and poles.U0 then
			key = "poleU0"
		elseif u == 1 and poles.U1 then
			key = "poleU1"
		elseif v == 0 and poles.V0 then
			key = "poleV0"
		elseif v == 1 and poles.V1 then
			key = "poleV1"
		else
			key = string.format("%.17g:%.17g", cu, cv)
		end
		local id = vertices[key]
		if id then
			assert(
				(mesh.vertices[id] - d.position).Magnitude <= seamTolerance,
				"Shared adaptive boundary does not coincide within seam tolerance"
			)
		else
			assert(mesh.nextVertex <= (options.maxVertices or 100000), "Adaptive vertex budget exceeded")
			id = mesh:addVertex(d.position)
			vertices[key] = id
		end
		return id, { uv = Vector2.new(u, v), normal = normal }
	end
	for index, node in leaves do
		local boundary: { { number } } = {}
		for _, u in range(horizontal[node.v0], node.u0, node.u1, false) do
			table.insert(boundary, { u, node.v0 })
		end
		for _, v in range(vertical[node.u1], node.v0, node.v1, false) do
			if v > node.v0 then
				table.insert(boundary, { node.u1, v })
			end
		end
		for _, u in range(horizontal[node.v1], node.u0, node.u1, true) do
			if u < node.u1 then
				table.insert(boundary, { u, node.v1 })
			end
		end
		for _, v in range(vertical[node.u0], node.v0, node.v1, true) do
			if v > node.v0 and v < node.v1 then
				table.insert(boundary, { node.u0, v })
			end
		end
		local evaluator: any = N.compileSurface(node.surface)
		local center, centerCorner =
			corner((node.u0 + node.u1) * 0.5, (node.v0 + node.v1) * 0.5, evaluator, node)
		local ids: { number }, corners: { Types.Corner } = {}, {}
		for i, uv in boundary do
			ids[i], corners[i] = corner(uv[1], uv[2], evaluator, node)
		end
		for i = 1, #ids do
			local j = i % #ids + 1
			if ids[i] ~= ids[j] and ids[i] ~= center and ids[j] ~= center then
				triangleCount += 1
				assert(triangleCount <= (options.maxTriangles or 200000), "Adaptive triangle budget exceeded")
				mesh:addFace(
					{ center, ids[i], ids[j] },
					{ centerCorner, corners[i], corners[j] },
					options.material
				)
			end
		end
		if options.checkpoint then
			options.checkpoint({ stage = "mesh", progress = index / #leaves })
		end
	end
	local validation = mesh:validate()
	assert(
		validation.valid,
		"Adaptive surface produced degenerate or invalid topology; change controls or tolerance"
	)
	return mesh,
		{
			converged = converged,
			errorBound = maximum,
			leaves = #leaves,
			refinements = visited,
			triangles = triangleCount,
			poles = poles,
			reason = not converged and "Subdivision depth or leaf budget reached" or nil,
		}
end
return A
