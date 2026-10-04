-- Explicit UV trim domains. Polygon boundaries are exact; curve boundaries are sampled with reports.
local U = require(script.Parent.Util)
local N = require(script.Parent.NURBS)
local D = require(script.Parent.Planar)
local Q = require(script.Parent.SplineQuery)
local Mesh = require(script.Parent.Mesh)
local Domain = require(script.Parent.TrimDomain)
local T = {}

local function domain(outer, holes, options)
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
function T.surface(surface, outer, holes, options)
	local validated = domain(outer, holes, options)
	local loops = {}
	for i, ring in validated.boundaryLoops do
		loops[i] = {}
		for _, id in ring do
			table.insert(loops[i], validated.points[id])
		end
	end
	local copied = N.clampSurface(N.clampSurface(surface, "U"), "V")
	local inner = {}
	for i = 2, #loops do
		table.insert(inner, loops[i])
	end
	return { kind = "trimmedSurface", surface = copied, outer = loops[1], holes = inner }
end

function T.regions(surface, regions, options)
	local config = table.clone(options or {})
	Domain.controls(surface, config)
	local copied = N.clampSurface(N.clampSurface(U.copy(surface), "U"), "V")
	config.maxInputVertices = config.maxTrimVertices or 2000
	config.maxVertices = config.maxParameterVertices or 20000
	config.maxTriangles = config.maxParameterTriangles or 40000
	local parts, report = require(script.Parent.TrimRegionDecompose)(regions, config)
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
function T.classify(trimmed, uv)
	assert(
		trimmed.kind == "trimmedSurface" or trimmed.kind == "trimmedSurfaceSet",
		"Trimmed surface required"
	)
	assert(
		typeof(uv) == "Vector2" and U.finite(uv.X) and U.finite(uv.Y),
		"Finite native trim parameter required"
	)
	return Domain.classify(
		trimmed.kind == "trimmedSurfaceSet" and trimmed.regions
			or { { outer = trimmed.outer, holes = trimmed.holes } },
		uv
	)
end
function T.evaluate(trimmed, u, v)
	assert(U.finite(u) and U.finite(v) and u >= 0 and u <= 1 and v >= 0 and v <= 1)
	local uv = Vector2.new(u, v)
	assert(T.classify(trimmed, uv) ~= "outside", "Parameter lies outside the trimmed domain")
	return N.evaluateSurface(trimmed.surface, uv.X, uv.Y)
end

function T.fromCurves(surface, outerCurve, holeCurves, options)
	options = options or {}
	local curves = { outerCurve }
	for _, curve in holeCurves or {} do
		table.insert(curves, curve)
	end
	local loops, reports = {}, {}
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
	local holes = {}
	for i = 2, #loops do
		table.insert(holes, loops[i])
	end
	return T.surface(surface, loops[1], holes, options), { curves = reports, parameterTolerance = tolerance }
end

function T.tessellate(trimmed, options)
	options = table.clone(options or {})
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
	local data = Domain.prepare(trimmed.regions, options, visit)
	local levels = options.levels or 3
	U.integer(levels, 0)
	assert(levels <= 12, "Trim subdivision depth budget exceeded")
	local maxTriangles = options.maxTriangles or 200000
	assert(#data.triangles * 4 ^ levels <= maxTriangles, "Trim triangle budget exceeded")
	local points, triangles = table.clone(data.points), U.copy(data.triangles)
	local maxVertices = options.maxVertices or 100000
	assert(#points <= maxVertices, "Trim vertex budget exceeded")
	local boundary = {}
	for _, ring in data.boundaryLoops do
		for i, id in ring do
			boundary[U.edge(id, ring[i % #ring + 1])] = true
		end
	end
	for level = 1, levels do
		local edgePoints, nextBoundary, nextTriangles = {}, {}, {}
		local function midpoint(a, b)
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
	local mesh, normals = Mesh.new(), {}
	local evaluator = N.compileSurface(trimmed.surface)
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
		local corners = {}
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
			regions = #trimmed.regions,
			work = work,
			periodicWelding = false,
			method = "Uniform conforming triangle subdivision",
		}
end
function T.adaptive(trimmed, options)
	return require(script.Parent.SurfaceTrimAdaptive)(trimmed, options)
end
return T
