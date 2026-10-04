-- Exact contact/overlap cells for single affine surface parameterizations.
local I = require(script.Parent.DirectedInterval)
local makeR = require(script.Parent.ExactRational)
local solve = require(script.Parent.AffineBoxRelation)
local orderedBoundary = require(script.Parent.AffineCellBoundary)
return function(a, b, initial, options, limits, ctx, report)
	ctx.check("affineIdentity")
	ctx.allocate(4096)
	local R = makeR(ctx.visit, ctx.maxExactBits)
	local zero = R.number(0)
	local enclose = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local function affine(s)
		assert(
			s.degreeU == 1 and s.degreeV == 1 and #s.control == 2 and #s.control[1] == 2,
			"Exact affine intersections require single degree-one 2x2 surface patches"
		)
		local weight = s.weights[1][1]
		for _, row in s.weights do
			for _, value in row do
				assert(value == weight, "Exact affine intersections require constant weights")
			end
		end
		local p, q, r, t = s.control[1][1], s.control[2][1], s.control[1][2], s.control[2][2]
		local origin, u, v = {}, {}, {}
		for axis, name in { "X", "Y", "Z" } do
			local first, nextU, nextV, last =
				R.number(p[name]), R.number(q[name]), R.number(r[name]), R.number(t[name])
			assert(
				R.equal(R.add(first, last), R.add(nextU, nextV)),
				"Surface controls do not form an exact affine parallelogram"
			)
			origin[axis], u[axis], v[axis] = first, R.sub(nextU, first), R.sub(nextV, first)
		end
		return { origin = origin, u = u, v = v }
	end
	local first, second = affine(a), affine(b)
	local rows, bounds = {}, {}
	for axis = 1, 3 do
		rows[axis] = {
			first.u[axis],
			first.v[axis],
			R.neg(second.u[axis]),
			R.neg(second.v[axis]),
			R.sub(second.origin[axis], first.origin[axis]),
		}
	end
	for axis, range in initial do
		bounds[axis] = { R.number(range[1]), R.number(range[2]) }
	end
	ctx.check("affineSolve")
	local relation = solve(rows, bounds, R, ctx.visit)
	report.method = "Exact rational affine equalities and exhaustive active-bound enumeration"
	report.algorithm = "exactAffine"
	report.cells, report.components, report.connections, report.unresolvedConnections = {}, {}, {}, {}
	report.rootCoverageComplete, report.parameterComponentsCertified, report.cellTopologyCertified =
		true, true, true
	report.componentCount = #relation.vertices > 0 and 1 or 0
	report.componentSpace = "Closed four-dimensional parameter domain; no spatial or periodic identification"
	report.affineCandidates = relation.candidates or 0
	report.equalityRank, report.affineEquations = relation.equalityRank, rows
	report.parameterBox, report.segmentCount = initial, 0
	report.visited, report.covered, report.excluded = 1, report.componentCount, 1 - report.componentCount
	report.ordering, report.periodicQuotient = { requested = false }, { requested = false }
	report.parameterTopologyCertified, report.componentTopologyCertified, report.orderedComplete =
		false, false, false
	report.quotientTopologyCertified, report.quotientComplete = false, false
	report.connectivity = {
		complete = true,
		reason = "convexAffineCell",
		pairs = 0,
		visited = 0,
		excludedPairs = 0,
		witnessTests = 0,
		connections = 0,
		unresolvedPairs = 0,
	}
	report.boundaryOwnership =
		"Closed parameter box; all affine boundary, corner and degenerate contacts retained"
	report.complete = true
	if #relation.vertices > 0 then
		local function rank(vectors, columns)
			local matrix = {}
			for i, vector in vectors do
				matrix[i] = table.clone(vector)
				matrix[i][columns + 1] = zero
			end
			local _, pivots = relation.rref(matrix, columns)
			return #pivots
		end
		local spatial, differences = {}, {}
		for i, parameters in relation.vertices do
			local point = {}
			for axis = 1, 3 do
				point[axis] = R.add(
					first.origin[axis],
					R.add(R.mul(first.u[axis], parameters[1]), R.mul(first.v[axis], parameters[2]))
				)
				local other = R.add(
					second.origin[axis],
					R.add(R.mul(second.u[axis], parameters[3]), R.mul(second.v[axis], parameters[4]))
				)
				assert(R.equal(point[axis], other), "Affine vertex violates the equality system")
			end
			spatial[i] = point
			if i > 1 then
				local delta = {}
				for axis = 1, 3 do
					delta[axis] = R.sub(point[axis], spatial[1][axis])
				end
				table.insert(differences, delta)
			end
		end
		local dimension = rank(differences, 3)
		local parameterBoundary, parameterAxes =
			orderedBoundary(relation.vertices, relation.dimension, R, ctx.visit)
		local spatialBoundary, spatialAxes = orderedBoundary(spatial, dimension, R, ctx.visit)
		local cell = {
			certified = true,
			topologyCertified = true,
			convex = true,
			connected = true,
			parameterDimension = relation.dimension,
			spatialDimension = dimension,
			kind = dimension == 0 and "point" or dimension == 1 and "segment" or "polygon",
			surfaceRanks = { rank({ first.u, first.v }, 3), rank({ second.u, second.v }, 3) },
			spatialMapInjective = relation.dimension == dimension,
			parameterBoundary = parameterBoundary,
			parameterProjectionAxes = parameterAxes,
			spatialBoundary = spatialBoundary,
			spatialProjectionAxes = spatialAxes,
			vertices = {},
			triangles = {},
			errorBound = 0,
			parameterBox = {},
			positionBox = {},
			proof = "Convex hull of every feasible vertex of the bounded exact affine equality relation",
		}
		if dimension == 2 then
			for j = 2, #cell.spatialBoundary - 1 do
				table.insert(
					cell.triangles,
					{ cell.spatialBoundary[1], cell.spatialBoundary[j], cell.spatialBoundary[j + 1] }
				)
			end
		end
		ctx.check("affineBounds")
		for i, parameters in relation.vertices do
			local vertex = {
				parametersExact = parameters,
				positionExact = spatial[i],
				parameterBox = {},
				parameters = {},
				positionBox = {},
				parameterErrorBound = 0,
				activeBounds = relation.active[i],
				certified = true,
			}
			for axis, x in parameters do
				local range = enclose(x)
				-- Intersect two proved enclosures, retaining the requested domain.
				range = assert(I.intersect(range, initial[axis]))
				vertex.parameterBox[axis], vertex.parameters[axis] = range, I.mid(range)
				local delta = I.sub(range, { vertex.parameters[axis], vertex.parameters[axis] })
				vertex.parameterErrorBound =
					math.max(vertex.parameterErrorBound, math.abs(delta[1]), math.abs(delta[2]))
				cell.parameterBox[axis] = cell.parameterBox[axis] and I.hull(cell.parameterBox[axis], range)
					or range
			end
			local values = {}
			for axis, x in spatial[i] do
				local range = enclose(x)
				vertex.positionBox[axis], values[axis] = range, I.mid(range)
				cell.positionBox[axis] = cell.positionBox[axis] and I.hull(cell.positionBox[axis], range)
					or range
			end
			vertex.position = Vector3.new(values[1], values[2], values[3])
			local square = { 0, 0 }
			for axis, name in { "X", "Y", "Z" } do
				square = I.add(
					square,
					I.square(
						I.sub(vertex.positionBox[axis], { vertex.position[name], vertex.position[name] })
					)
				)
			end
			vertex.errorBound = I.sqrt(square)[2]
			vertex.accurate = vertex.errorBound <= limits.tolerance
			cell.errorBound = math.max(cell.errorBound, vertex.errorBound)
			table.insert(cell.vertices, vertex)
		end
		cell.accurate = cell.errorBound <= limits.tolerance
		-- Equal convex coefficients give a surjective correspondence in both
		-- directions; the maximum vertex error bounds the complete convex hulls.
		cell.approximation =
			"Native convex hull; maximum vertex displacement bounds two-sided whole-cell distance"
		cell.nativeTopologyCertified = cell.errorBound == 0
		report.cells[1] = cell
		report.components[1] = {
			cellIndices = { 1 },
			curveIndices = {},
			connectionIndices = {},
			parameterBox = cell.parameterBox,
			dimension = cell.parameterDimension,
			connected = true,
			isolated = true,
			certified = true,
		}
		report.complete = cell.accurate
	end
	report.success, report.converged = report.complete, report.complete
	report.reason = report.complete and "complete" or "approximation"
	ctx.check("finish")
	assert(not options.cancelled or not options.cancelled(), "Surface intersection query cancelled")
	assert(
		report.complete or not options.requireComplete,
		"Affine intersection native approximation exceeds tolerance"
	)
	return report
end
