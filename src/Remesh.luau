--!strict
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local Fields = require(script.Parent.Fields)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
export type RemeshOptions = {
	maxCells: number?,
	maxSourceTriangleSamples: number?,
	maxVertices: number?,
	maxFaces: number?,
	yieldEvery: number?,
	cancelled: (() -> boolean)?,
	-- fromField reports { stage, layer, layers, vertices, faces }; projection forwards its own payload.
	checkpoint: ((progress: any) -> ())?,
	-- false skips attribute projection; a table supplies Attributes.project options.
	transfer: (boolean | { [string]: any })?,
	materialOffsetB: number?,
	[string]: any,
}
-- Reports carry validation, transfer/projection results and source correspondence.
export type RemeshReport = { [string]: any }
export type ScalarField = (Vector3) -> number
local R = {}
function R.quads(mesh: Mesh, targetLength: number, options: { [string]: any }?): (Mesh, any)
	return require(script.Parent.QuadRetopology)(mesh, targetLength, options)
end
local function dimensions(
	lo: Vector3,
	hi: Vector3,
	cellSize: number,
	options: RemeshOptions
): (number, number, number)
	assert(
		type(cellSize) == "number"
			and U.finite(cellSize)
			and cellSize > 0
			and U.vector(lo)
			and U.vector(hi)
			and hi.X > lo.X
			and hi.Y > lo.Y
			and hi.Z > lo.Z,
		"Remesh requires finite bounds and positive cell size"
	)
	local nx, ny, nz =
		math.ceil((hi.X - lo.X) / cellSize),
		math.ceil((hi.Y - lo.Y) / cellSize),
		math.ceil((hi.Z - lo.Z) / cellSize)
	assert(
		nx * ny * nz <= U.integer(options.maxCells or 250000, 1),
		"Remesh cell budget exceeded; increase cellSize or maxCells"
	)
	return nx, ny, nz
end
local function samplingBudget(
	meshes: { Mesh },
	lo: Vector3,
	hi: Vector3,
	cellSize: number,
	options: RemeshOptions
): number
	local nx, ny, nz = dimensions(lo, hi, cellSize, options)
	local triangles = 0
	for _, mesh in meshes do
		for _, face in mesh.faces do
			triangles += #face.vertices - 2
		end
	end
	local work = (nx + 1) * (ny + 1) * (nz + 1) * triangles
	assert(
		work <= U.integer(options.maxSourceTriangleSamples or 10000000, 1),
		"Remesh signed-distance source work budget exceeded"
	)
	assert(not options.cancelled or not options.cancelled(), "Remesh cancelled")
	return work
end
local function transfer(source: Mesh?, mesh: Mesh, options: RemeshOptions, work: number): (Mesh, RemeshReport)
	local validation = mesh:validate()
	if options.transfer == false then
		return mesh,
			{
				complete = validation.valid,
				validation = validation,
				transferred = false,
				sourceTriangleSamples = work,
			}
	end
	assert(
		options.transfer == nil or options.transfer == true or type(options.transfer) == "table",
		"Remesh transfer must be a table or boolean"
	)
	local config: { [string]: any } = type(options.transfer) == "table"
			and table.clone(options.transfer :: { [string]: any })
		or {}
	config.cancelled = config.cancelled or options.cancelled
	config.checkpoint = config.checkpoint or options.checkpoint
	local out, projection = require(script.Parent.Attributes).project(source :: Mesh, mesh, config)
	return out,
		{
			complete = validation.valid and projection.complete,
			validation = validation,
			transferred = true,
			projection = projection,
			sourceTriangleSamples = work,
		}
end
function R.fromField(
	field: ScalarField,
	lo: Vector3,
	hi: Vector3,
	cellSize: number,
	options: RemeshOptions?
): Mesh
	local options: RemeshOptions = options or {}
	assert(type(field) == "function", "Remesh requires a scalar field function")
	if options.yieldEvery ~= nil then
		U.integer(options.yieldEvery, 1)
	end
	local nx, ny, nz = dimensions(lo, hi, cellSize, options)
	local maxVertices, maxFaces =
		U.integer(options.maxVertices or 500000, 1), U.integer(options.maxFaces or 500000, 1)
	local vertices, faces = 0, 0
	local function checkpoint(stage, z)
		assert(not options.cancelled or not options.cancelled(), "Remesh cancelled")
		if options.checkpoint then
			options.checkpoint({ stage = stage, layer = z, layers = nz, vertices = vertices, faces = faces })
		end
	end
	checkpoint("begin", 0)
	local step = (hi - lo) / Vector3.new(nx, ny, nz)
	local m = Mesh.new()
	local samples, positions, edgeIds = {}, {}, {}
	local function id(x: number, y: number, z: number): number
		return 1 + x + (nx + 1) * (y + (ny + 1) * z)
	end
	for z = 0, nz do
		checkpoint("sample", z)
		for y = 0, ny do
			for x = 0, nx do
				local k = id(x, y, z)
				local p = lo + Vector3.new(x, y, z) * step
				local v = field(p)
				assert(U.finite(v), "Nonfinite field sample")
				positions[k] = p
				samples[k] = math.abs(v) < 1e-10 and 1e-10 or v
			end
		end
		if options.yieldEvery and z % options.yieldEvery == 0 then
			task.wait()
		end
	end
	local tetEdges = { { 1, 2 }, { 1, 3 }, { 1, 4 }, { 2, 3 }, { 2, 4 }, { 3, 4 } }
	local tets =
		{ { 1, 2, 3, 7 }, { 1, 3, 4, 7 }, { 1, 4, 8, 7 }, { 1, 8, 5, 7 }, { 1, 5, 6, 7 }, { 1, 6, 2, 7 } }
	local function intersect(a, b)
		local key = U.edge(a, b)
		if edgeIds[key] then
			return edgeIds[key]
		end
		local t = samples[a] / (samples[a] - samples[b])
		vertices += 1
		assert(vertices <= maxVertices, "Remesh vertex budget exceeded")
		local v = m:addVertex(positions[a]:Lerp(positions[b], t))
		edgeIds[key] = v
		return v
	end
	for z = 0, nz - 1 do
		checkpoint("build", z)
		for y = 0, ny - 1 do
			for x = 0, nx - 1 do
				local cube = {
					id(x, y, z),
					id(x + 1, y, z),
					id(x + 1, y + 1, z),
					id(x, y + 1, z),
					id(x, y, z + 1),
					id(x + 1, y, z + 1),
					id(x + 1, y + 1, z + 1),
					id(x, y + 1, z + 1),
				}
				for _, tet in tets do
					local points = {}
					local inside, outside = Vector3.zero, Vector3.zero
					local ni, no = 0, 0
					for _, k in tet do
						local a = cube[k]
						if samples[a] < 0 then
							inside += positions[a]
							ni += 1
						else
							outside += positions[a]
							no += 1
						end
					end
					if ni > 0 and no > 0 then
						for _, e in tetEdges do
							local a, b = cube[tet[e[1]]], cube[tet[e[2]]]
							if (samples[a] < 0) ~= (samples[b] < 0) then
								table.insert(points, intersect(a, b))
							end
						end
						local center = Vector3.zero
						for _, v in points do
							center += m.vertices[v]
						end
						center /= #points
						local normal = U.unit(outside / no - inside / ni)
						local tx, ty = U.frame(normal)
						table.sort(points, function(a, b)
							local p, q = m.vertices[a] - center, m.vertices[b] - center
							return math.atan2(p:Dot(ty), p:Dot(tx)) < math.atan2(q:Dot(ty), q:Dot(tx))
						end)
						for i = 2, #points - 1 do
							local a, b, c = points[1], points[i], points[i + 1]
							if
								(m.vertices[b] - m.vertices[a]):Cross(m.vertices[c] - m.vertices[a]).Magnitude
								> 1e-12
							then
								faces += 1
								assert(faces <= maxFaces, "Remesh face budget exceeded")
								m:addFace({ a, b, c })
							end
						end
					end
				end
			end
		end
		if options.yieldEvery and z % options.yieldEvery == 0 then
			task.wait()
		end
	end
	checkpoint("finish", nz)
	return m:removeUnused():recalculateNormals()
end
function R.voxel(mesh: Mesh, cellSize: number, options: RemeshOptions?): (Mesh, RemeshReport)
	local options: RemeshOptions = options or {}
	assert(
		type(cellSize) == "number" and U.finite(cellSize) and cellSize > 0,
		"Positive finite remesh cell size required"
	)
	require(script.Parent.AttributeCore).validate(mesh)
	local lo, hi = mesh:bounds()
	local pad = Vector3.one * cellSize * 2
	local work = samplingBudget({ mesh }, lo - pad, hi + pad, cellSize, options)
	local result = R.fromField(Fields.fromMesh(mesh), lo - pad, hi + pad, cellSize, options)
	return transfer(mesh, result, options, work)
end
function R.boolean(
	a: Mesh,
	b: Mesh,
	operation: string,
	cellSize: number,
	options: RemeshOptions?
): (Mesh, RemeshReport)
	local options: RemeshOptions = options or {}
	assert(
		type(cellSize) == "number" and U.finite(cellSize) and cellSize > 0,
		"Positive finite remesh cell size required"
	)
	assert(
		operation == "union" or operation == "subtract" or operation == "intersect",
		"Unknown Boolean operation"
	)
	local al, ah = a:bounds()
	local bl, bh = b:bounds()
	local pad = Vector3.one * cellSize * 2
	local work = samplingBudget({ a, b }, al:Min(bl) - pad, ah:Max(bh) + pad, cellSize, options)
	local source, forward, inverse
	if options.transfer ~= false then
		local right = operation == "subtract" and require(script.Parent.Topology).reverse(b) or b
		source, forward, inverse = require(script.Parent.BooleanSources)(a, right, options.materialOffsetB)
		if operation == "subtract" then
			local corners = {}
			for fid, f in b.faces do
				for i in f.vertices do
					local old = fid .. ":" .. i
					local id = forward.b.corner[fid .. ":" .. (#f.vertices - i + 1)]
					corners[old] = id
					inverse.corner[id] = { operand = "b", id = old }
				end
			end
			forward.b.corner = corners
		end
	end
	local mesh = R.fromField(
		Fields[operation](Fields.fromMesh(a), Fields.fromMesh(b)),
		al:Min(bl) - pad,
		ah:Max(bh) + pad,
		cellSize,
		options
	)
	local out, report = transfer(source, mesh, options, work)
	report.inputMaps, report.sourceRefs = forward, inverse
	return out, report
end
return R
