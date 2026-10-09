--!strict
-- Custom corner normals without topology or material changes.
local U = require(script.Parent.Util)
local Core = require(script.Parent.NormalCore)
local A = require(script.Parent.AttributeCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Shared normal-editing options (selection masks, weighting, budgets); validated by NormalCore.
type Options = { [string]: any }
local N = {}
function N.recalculate(mesh: Mesh, options: Options?)
	return Core.reduce(mesh, Core.setup(mesh, options), options, false)
end
function N.average(mesh: Mesh, options: Options?)
	return Core.reduce(mesh, Core.setup(mesh, options), options, true)
end
function N.set(mesh: Mesh, values: { [any]: Vector3 }, options: Options?)
	assert(type(values) == "table", "Corner normal dictionary required")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(values) do
		assert(state.index.corners[key], "Unknown normal corner")
		state.write(key, Core.unit(values[key]))
	end
	return state.finish()
end
function N.direction(mesh: Mesh, direction: Vector3, options: Options?)
	local n = Core.unit(direction)
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, n)
	end
	return state.finish()
end
function N.point(mesh: Mesh, target: Vector3, options: Options?)
	local options: Options = options or {}
	assert(U.vector(target), "Finite normal target required")
	local direction = options.direction or "toward"
	assert(direction == "toward" or direction == "away", "Normal point direction must be toward or away")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		if state.weight(key) == 0 then
			continue
		end
		local p = mesh.vertices[state.index.corners[key].vertex]
		local d = direction == "toward" and target - p or p - target
		if d == Vector3.zero then
			assert(
				options.coincident == "keep",
				"Normal target coincides with a vertex; use coincident='keep' explicitly"
			)
			state.report.coincidentCorners = (state.report.coincidentCorners or 0) + 1
		else
			state.write(key, d)
		end
	end
	return state.finish()
end
function N.rotate(mesh: Mesh, rotation: CFrame, options: Options?)
	assert(typeof(rotation) == "CFrame", "Normal rotation requires a CFrame")
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, rotation:VectorToWorldSpace(state.source(key)))
	end
	return state.finish()
end
function N.flip(mesh: Mesh, options: Options?)
	local state = Core.setup(mesh, options)
	for _, key in U.keys(state.index.corners) do
		state.write(key, -state.source(key))
	end
	return state.finish()
end
function N.markSharp(mesh: Mesh, edges: { [string]: boolean }, options: Options?)
	assert(type(edges) == "table", "Sharp edge dictionary required")
	local state = Core.setup(mesh, options)
	for key, value in edges do
		assert(state.index.edges[key] and type(value) == "boolean", "Invalid sharp edge")
	end
	local channel = state.out.attributes.sharp_edge
	if channel then
		assert(
			channel.domain == "edge" and channel.dataType == "boolean",
			"sharp_edge must be an edge boolean channel"
		)
	else
		channel =
			{ domain = "edge", dataType = "boolean", default = false, interpolation = "nearest", values = {} }
		state.out.attributes.sharp_edge = channel
	end
	for key, value in edges do
		if value == channel.default then
			channel.values[key] = nil
		else
			channel.values[key] = value
		end
	end
	A.validate(state.out)
	if options and options.recalculate == false then
		return state.finish()
	end
	local config: Options = table.clone(options or {})
	config.sharpEdges = nil
	return N.recalculate(state.out, config)
end
-- Recalculates normals over several meshes as one welded surface and returns a copy of each mesh
-- with the shared normals, keeping its own faces, UVs and materials. Use it when one surface was
-- split into parts (for example a Roblox.partition or a published multi-part model), so shading
-- does not break at part boundaries. tolerance (default 1e-4) welds coincident positions; angle
-- (radians, default pi) keeps sharper creases split.
export type UnifyOptions = { tolerance: number?, angle: number? }
function N.unify(meshes: { Mesh }, options: UnifyOptions?): { Mesh }
	local Topology = require(script.Parent.Topology) :: any
	local tolerance = options and options.tolerance or 1e-4
	local angle = options and options.angle or math.pi
	assert(tolerance > 0 and angle >= 0 and angle <= math.pi, "Invalid unify options")
	-- Topology.join appends each mesh's faces in key order with consecutive new ids
	local owner: { number } = {}
	for k, m in meshes do
		for _ in m.faces do
			table.insert(owner, k)
		end
	end
	local joined: Mesh = Topology.join(meshes)
	local first = math.huge
	for fid in joined.faces do
		first = math.min(first, fid)
	end
	joined = Topology.weld(joined, tolerance)
	joined:recalculateNormals(angle)
	local sets: { { [number]: boolean } } = {}
	for k in meshes do
		sets[k] = {}
	end
	for fid in joined.faces do
		sets[owner[fid - first + 1]][fid] = true
	end
	local out: { Mesh } = {}
	for k in meshes do
		out[k] = Topology.extract(joined, sets[k])
	end
	return out
end
-- Mean curvature per vertex of one surface given as one or more meshes: parts cut from it, or published parts read
-- back, whose triangles share no vertices. The meshes are welded (tolerance, default 1e-4) and the cotangent
-- Laplacian gives the mean-curvature normal at each vertex, K = (1 / 2A) sum (cot a + cot b) (p - q) with A a third
-- of the area of the triangles round it (exact enough on stretched grids such as lofts, where a uniform umbrella
-- under-reads badly); H = K . n / 2 with n the area-weighted vertex normal: 1/R on a sphere of radius R, 1/(2R) on a
-- cylinder, positive on ridges and bulges, negative in valleys and creases (faces wound counter-clockwise seen from
-- outside). Values at open boundaries are one-sided. smooth (default 0) averages each value with its neighbours
-- that many times. Returns the welded vertices' positions, normals and curvatures as parallel arrays for
-- Bake.pointSampler: cavity and edge masks in bake shaders, crisp creases baked into a sculpt's colour map.
export type CurvatureOptions = { tolerance: number?, smooth: number? }
function N.curvature(meshes: { Mesh }, options: CurvatureOptions?): ({ Vector3 }, { Vector3 }, { number })
	local Topology = require(script.Parent.Topology) :: any
	local o: CurvatureOptions = options or {}
	local tolerance = o.tolerance or 1e-4
	local smooth = o.smooth or 0
	assert(#meshes > 0, "curvature needs meshes")
	assert(tolerance > 0 and smooth >= 0, "Invalid curvature options")
	local welded: Mesh = Topology.weld(Topology.join(meshes), tolerance)
	local V = welded.vertices
	local weight: { [number]: { [number]: number } } = {}
	local area: { [number]: number } = {}
	local normal: { [number]: Vector3 } = {}
	local function addWeight(i: number, j: number, w: number)
		weight[i] = weight[i] or {}
		weight[j] = weight[j] or {}
		weight[i][j] = (weight[i][j] or 0) + w
		weight[j][i] = (weight[j][i] or 0) + w
	end
	local function triangle(i: number, j: number, k: number)
		local a, b, c = V[i], V[j], V[k]
		local cross = (b - a):Cross(c - a)
		local twice = cross.Magnitude
		if twice < 1e-14 then
			return
		end
		-- the cotangent of each corner weights the opposite edge
		addWeight(j, k, (b - a):Dot(c - a) / twice)
		addWeight(k, i, (c - b):Dot(a - b) / twice)
		addWeight(i, j, (a - c):Dot(b - c) / twice)
		for _, v in { i, j, k } do
			area[v] = (area[v] or 0) + twice / 6
			normal[v] = (normal[v] or Vector3.zero) + cross
		end
	end
	for _, f in welded.faces do
		local vs = f.vertices
		for t = 2, #vs - 1 do
			triangle(vs[1], vs[t], vs[t + 1])
		end
	end
	local ids: { number }, index: { [number]: number } = {}, {}
	for id in V do
		if weight[id] then
			table.insert(ids, id)
			index[id] = #ids
		end
	end
	local points: { Vector3 } = table.create(#ids)
	local normals: { Vector3 } = table.create(#ids)
	local values: { number } = table.create(#ids)
	for k, id in ids do
		local p = V[id]
		local sum = Vector3.zero
		for j, w in weight[id] do
			sum += (p - V[j]) * w
		end
		local n = normal[id]
		n = if n.Magnitude > 1e-12 then n.Unit else Vector3.yAxis
		local A = area[id]
		points[k], normals[k] = p, n
		values[k] = if A > 1e-14 then (sum / (2 * A)):Dot(n) / 2 else 0
	end
	for _ = 1, smooth do
		local nextValues: { number } = table.create(#ids)
		for k, id in ids do
			local total, count = values[k], 1
			for j in weight[id] do
				total += values[index[j]]
				count += 1
			end
			nextValues[k] = total / count
		end
		values = nextValues
	end
	return points, normals, values
end
function N.tangents(mesh: Mesh, options: Options?)
	return require(script.Parent.NormalTangents)(mesh, options)
end
return N
