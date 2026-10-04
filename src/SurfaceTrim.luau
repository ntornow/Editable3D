--!strict
-- Explicit UV trim domains. Polygon boundaries are exact; curve boundaries are sampled with reports.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local D = require(script.Parent.Planar)
local Q = require(script.Parent.SplineQuery)
local Mesh = require(script.Parent.Mesh)
local Domain = require(script.Parent.TrimDomain)
local Types = require(script.Parent.Types)
local T = {}

-- Curve and surface descriptors come from NURBS (typed separately); treated as opaque here.
type Curve = any
type Surface = any
export type Loop = { Vector2 }
export type TrimmedSurface = {
	kind: "trimmedSurface",
	surface: Surface,
	outer: Loop,
	holes: { Loop },
}
export type TrimmedSurfaceSet = {
	kind: "trimmedSurfaceSet",
	surface: Surface,
	-- Region records are produced by TrimRegionDecompose, which defines their shape.
	regions: any,
	closedU: boolean,
	closedV: boolean,
	parameterConstruction: { clippingError: number, arrangementError: number },
}
export type Trimmed = TrimmedSurface | TrimmedSurfaceSet
export type InfoCheckpoint = (info: { [string]: any }) -> ()
export type FromCurvesOptions = {
	curveTolerance: number?,
	closingTolerance: number?,
	tolerance: number?,
	maxNodes: number?,
	maxDepth: number?,
	maxAngle: number?,
	maxWork: number?,
	maxVertices: number?,
	maxIntersections: number?,
	checkpoint: ((fraction: number) -> ())?,
	_visit: (() -> ())?,
}
export type RegionOptions = {
	maxControls: number?,
	maxRegions: number?,
	maxWork: number?,
	maxTrimVertices: number?,
	maxParameterVertices: number?,
	maxParameterTriangles: number?,
	maxInputVertices: number?,
	maxVertices: number?,
	maxTriangles: number?,
	maxClippingError: number?,
	maxConstructionError: number?,
	maxCoordinate: number?,
	maxCopies: number?,
	maxSegments: number?,
	closedU: boolean?,
	closedV: boolean?,
	cancelled: (() -> boolean)?,
	checkpoint: InfoCheckpoint?,
}
export type TessellateOptions = {
	maxControls: number?,
	maxRegions: number?,
	maxTrimVertices: number?,
	maxVertices: number?,
	maxTriangles: number?,
	maxWork: number?,
	levels: number?,
	material: number?,
	closedU: boolean?,
	closedV: boolean?,
	cancelled: (() -> boolean)?,
	checkpoint: ((fraction: number) -> ())?,
}
export type AdaptiveTrimOptions = {
	tolerance: number?,
	seamTolerance: number?,
	maxControls: number?,
	maxRegions: number?,
	maxTrimVertices: number?,
	maxVertices: number?,
	maxTriangles: number?,
	maxParameterVertices: number?,
	maxParameterTriangles: number?,
	maxSegments: number?,
	maxConstructionError: number?,
	maxWork: number?,
	maxLeaves: number?,
	maxDepth: number?,
	material: number?,
	collapsePoles: boolean?,
	closedU: boolean?,
	closedV: boolean?,
	cancelled: (() -> boolean)?,
	checkpoint: InfoCheckpoint?,
}
export type FromCurvesReport = { curves: { Q.SampleReport }, parameterTolerance: number }
export type TessellationReport = {
	levels: number,
	triangles: number,
	vertices: number,
	boundaryEdges: number,
	parameterArea: number,
	geometricErrorBound: boolean,
	regions: number,
	work: number,
	periodicWelding: boolean,
	method: string,
}

local function domain(outer: Loop, holes: { Loop }?, options: D.Options?): D.Domain
	for _, loop in { outer, table.unpack(holes or {}) } do
		for _, uv in loop do
			assert(
				typeof(uv) == "Vector2"
					and U.finite(uv.X)
					and U.finite(uv.Y)
					and uv.X >= 0
					and uv.X <= 1
					and uv.Y >= 0
					and uv.Y <= 1,
				"Trim coordinates must lie in the normalized unit domain"
			)
		end
	end
	return D.triangulate(outer, holes, options)
end
function T.surface(surface: Surface, outer: Loop, holes: { Loop }?, options: D.Options?): TrimmedSurface
	local validated = domain(outer, holes, options)
	local loops: { Loop } = {}
	for i, ring in validated.boundaryLoops do
		loops[i] = {}
		for _, id in ring do
			table.insert(loops[i], validated.points[id])
		end
	end
	local copied = N.clampSurface(N.clampSurface(surface, "U"), "V")
	local inner: { Loop } = {}
	for i = 2, #loops do
		table.insert(inner, loops[i])
	end
	return { kind = "trimmedSurface", surface = copied, outer = loops[1], holes = inner }
end

-- Region inputs are validated by TrimRegionDecompose, which defines their shape.
function T.regions(surface: Surface, regions: any, options: RegionOptions?): (TrimmedSurfaceSet, any)
	local config: RegionOptions = table.clone(options or {})
	Domain.controls(surface, config)
	local copied = N.clampSurface(N.clampSurface(U.copy(surface), "U"), "V")
	config.maxInputVertices = config.maxTrimVertices or 2000
	config.maxVertices = config.maxParameterVertices or 20000
	config.maxTriangles = config.maxParameterTriangles or 40000
	local parts: any, report: any = require(script.Parent.TrimRegionDecompose)(regions, config)
	return {
		kind = "trimmedSurfaceSet",
		surface = copied,
		regions = parts,
		closedU = config.closedU == true,
		closedV = config.closedV == true,
		parameterConstruction = {
			clippingError = report.clippingError,
			arrangementError = report.constructionError,
		},
	},
		report
end
function T.classify(trimmed: Trimmed, uv: Vector2): string
	assert(
		trimmed.kind == "trimmedSurface" or trimmed.kind == "trimmedSurfaceSet",
		"Trimmed surface required"
	)
	assert(
		typeof(uv) == "Vector2" and U.finite(uv.X) and U.finite(uv.Y),
		"Finite native trim parameter required"
	)
	return Domain.classify(
		trimmed.kind == "trimmedSurfaceSet" and (trimmed :: any).regions
			or { { outer = (trimmed :: any).outer, holes = (trimmed :: any).holes } },
		uv
	)
end
function T.evaluate(trimmed: Trimmed, u: number, v: number): Vector3
	assert(U.finite(u) and U.finite(v) and u >= 0 and u <= 1 and v >= 0 and v <= 1)
	local uv = Vector2.new(u, v)
	assert(T.classify(trimmed, uv) ~= "outside", "Parameter lies outside the trimmed domain")
	return N.evaluateSurface(trimmed.surface, uv.X, uv.Y)
end

function T.fromCurves(
	surface: Surface,
	outerCurve: Curve,
	holeCurves: { Curve }?,
	options: FromCurvesOptions?
): (TrimmedSurface, FromCurvesReport)
	local options: FromCurvesOptions = options or {}
	local curves: { Curve } = { outerCurve }
	for _, curve in (holeCurves or {}) :: { Curve } do
		table.insert(curves, curve)
	end
	local loops: { Loop }, reports: { Q.SampleReport } = {}, {}
	local tolerance = options.curveTolerance or 0.0001
	local closing = options.closingTolerance or 1e-6
	assert(U.finite(closing) and closing >= 0)
	for i, curve in curves do
		for _, p in curve.points do
			assert(math.abs(p.Z) <= closing, "Trim curve controls must lie in the XY parameter plane")
		end
		local sampling = table.clone(options)
		sampling.tolerance = tolerance
		local points, r = Q.sample(curve, sampling)
		assert(r.converged, "Trim curve sampling did not meet its tolerance")
		assert((points[1] - points[#points]).Magnitude <= closing, "Trim curves must be closed")
		loops[i] = {}
		for j = 1, #points - 1 do
			table.insert(loops[i], Vector2.new(points[j].X, points[j].Y))
		end
		reports[i] = r
	end
	local holes: { Loop } = {}
	for i = 2, #loops do
		table.insert(holes, loops[i])
	end
	return T.surface(surface, loops[1], holes, options), { curves = reports, parameterTolerance = tolerance }
end

function T.tessellate(trimmed: Trimmed, options: TessellateOptions?): (Types.Mesh, TessellationReport)
	local options: TessellateOptions = table.clone(options or {})
	options.maxTrimVertices = options.maxTrimVertices or options.maxVertices or 2000
	trimmed, options = Domain.snapshot(trimmed, options)
	local work = 0
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local function visit()
		work += 1
		assert(work <= maxWork, "Trim tessellation work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Trim tessellation cancelled")
		if work % 256 == 0 and options.checkpoint then
			options.checkpoint(work / maxWork)
		end
	end
	if options.checkpoint then
		options.checkpoint(0)
	end
	visit()
	local data: any = Domain.prepare((trimmed :: any).regions, options, visit)
	local levels = options.levels or 3
	U.integer(levels, 0)
	assert(levels <= 12, "Trim subdivision depth budget exceeded")
	local maxTriangles = options.maxTriangles or 200000
	assert(#data.triangles * 4 ^ levels <= maxTriangles, "Trim triangle budget exceeded")
	local points: { Vector2 }, triangles: { { number } } = table.clone(data.points), U.copy(data.triangles)
	local maxVertices = options.maxVertices or 100000
	assert(#points <= maxVertices, "Trim vertex budget exceeded")
	local boundary: { [string]: boolean } = {}
	for _, ring in data.boundaryLoops do
		for i, id in ring do
			boundary[U.edge(id, ring[i % #ring + 1])] = true
		end
	end
	for level = 1, levels do
		local edgePoints: { [string]: number }, nextBoundary: { [string]: boolean }, nextTriangles: { { number } } =
			{}, {}, {}
		local function midpoint(a: number, b: number): number
			local key = U.edge(a, b)
			if edgePoints[key] then
				return edgePoints[key]
			end
			local pa, pb = points[a], points[b]
			local uv = Vector2.new((pa.X + pb.X) * 0.5, (pa.Y + pb.Y) * 0.5)
			assert(uv ~= pa and uv ~= pb, "Trim edge is below native parameter resolution")
			assert(#points < maxVertices, "Trim vertex budget exceeded")
			table.insert(points, uv)
			local id = #points
			edgePoints[key] = id
			if boundary[key] then
				nextBoundary[U.edge(a, id)] = true
				nextBoundary[U.edge(id, b)] = true
			end
			return id
		end
		for _, triangle in triangles do
			visit()
			local a, b, c = triangle[1], triangle[2], triangle[3]
			local ab, bc, ca = midpoint(a, b), midpoint(b, c), midpoint(c, a)
			for _, child in { { a, ab, ca }, { ab, b, bc }, { ca, bc, c }, { ab, bc, ca } } do
				table.insert(nextTriangles, child)
			end
		end
		triangles, boundary = nextTriangles, nextBoundary
		if options.checkpoint then
			options.checkpoint(level / (levels + 1))
		end
	end
	local mesh, normals: { [number]: Vector3 } = Mesh.new(), {}
	local evaluator: any = N.compileSurface(trimmed.surface)
	for i, uv in points do
		visit()
		local d = evaluator.derivatives(uv.X, uv.Y)
		assert(d.regular, "Trim mesh has a singular sample; move the trim or repair the surface")
		mesh:addVertex(d.position)
		normals[i] = d.normal
		if i % 256 == 0 and options.checkpoint then
			options.checkpoint((levels + i / #points) / (levels + 1))
		end
	end
	for _, triangle in triangles do
		local corners: { Types.Corner } = {}
		for i, id in triangle do
			corners[i] = { uv = points[id], normal = normals[id] }
		end
		mesh:addFace(triangle, corners, options.material)
	end
	if options.checkpoint then
		options.checkpoint(1)
	end
	assert(not options.cancelled or not options.cancelled(), "Trim tessellation cancelled")
	local validation = mesh:validate()
	assert(validation.valid, "Trimmed surface produced degenerate or invalid topology")
	return mesh,
		{
			levels = levels,
			triangles = #triangles,
			vertices = #points,
			boundaryEdges = U.count(boundary),
			parameterArea = data.area,
			geometricErrorBound = false,
			regions = #(trimmed :: any).regions,
			work = work,
			periodicWelding = false,
			method = "Uniform conforming triangle subdivision",
		}
end
function T.adaptive(trimmed: Trimmed, options: AdaptiveTrimOptions?): (Types.Mesh, any)
	return require(script.Parent.SurfaceTrimAdaptive)(trimmed, options)
end
return T
