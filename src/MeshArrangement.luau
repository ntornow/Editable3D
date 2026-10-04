-- Private source-triangle intersection arrangements with explicit geometric welding.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local D = require(script.Parent.Planar)
local A = require(script.Parent.AttributeCore)
local C = require(script.Parent.Connectivity)
local I = require(script.Parent.Intersections)
local Triangle = require(script.Parent.TriangleIntersectionCore)
return function(mesh, options)
	options = options or {}
	A.validate(mesh)
	local validation = mesh:validate()
	assert(validation.valid, "Intersection arrangement requires valid oriented source topology")
	local topologyOptions = table.clone(options)
	if options.checkpoint then
		topologyOptions.checkpoint = function(progress)
			options.checkpoint({ stage = "topology", progress = progress })
		end
	end
	local index = C.index(mesh, topologyOptions)
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local maxVertices = U.integer(options.maxVertices or 100000, 3)
	local maxFaces = U.integer(options.maxFaces or 200000, 1)
	local work, maxDisplacement, featureDisplacement = 0, 0, 0
	local function visit(stage, n)
		local before = work
		work += n or 1
		assert(work <= maxWork, "Intersection arrangement work budget exceeded")
		if math.floor(before / 256) ~= math.floor(work / 256) then
			assert(not options.cancelled or not options.cancelled(), "Intersection arrangement cancelled")
			if options.checkpoint then
				options.checkpoint({ stage = stage or "arrange", work = work, maxWork = maxWork })
			end
		end
	end
	assert(not options.cancelled or not options.cancelled(), "Intersection arrangement cancelled")
	if options.checkpoint then
		options.checkpoint({ stage = "begin", work = 0 })
	end
	local regularization
	local originalSource = mesh
	if options.regularization ~= nil then
		assert(type(options.regularization) == "table", "Source regularization must be a table")
		if options.regularization.method == "features" then
			mesh, regularization = require(script.Parent.SourceFeatureRegularization)(mesh, options, visit)
			index = C.index(mesh, topologyOptions)
			validation = mesh:validate()
		else
			mesh, regularization = require(script.Parent.SourceVertexRegularization)(mesh, options, visit)
		end
	end
	local lo, hi, usedVertices = nil, nil, {}
	for _, face in mesh.faces do
		for _, id in face.vertices do
			usedVertices[id] = true
		end
	end
	for id in usedVertices do
		local p = mesh.vertices[id]
		lo, hi = lo and lo:Min(p) or p, hi and hi:Max(p) or p
	end
	lo, hi = lo or Vector3.zero, hi or Vector3.zero
	local extent = math.max(hi.X - lo.X, hi.Y - lo.Y, hi.Z - lo.Z)
	local tolerance = options.tolerance
	if tolerance == nil then
		tolerance = math.max(extent * 1e-6, 1e-7)
	end
	assert(
		type(tolerance) == "number" and U.finite(tolerance) and tolerance >= 0,
		"Nonnegative finite arrangement tolerance required"
	)
	local nodes, exact, buckets, vertexNodes = {}, {}, {}, {}
	local function bucket(x, y, z)
		return string.format("%.17g:%.17g:%.17g", x, y, z)
	end
	local function register(p)
		visit()
		assert(U.vector(p), "Finite intersection construction required")
		if exact[p] then
			return exact[p]
		end
		local x, y, z
		if tolerance > 0 then
			x, y, z =
				math.floor((p.X - lo.X) / tolerance),
				math.floor((p.Y - lo.Y) / tolerance),
				math.floor((p.Z - lo.Z) / tolerance)
			local nearest, best = nil, tolerance
			for dx = -1, 1 do
				for dy = -1, 1 do
					for dz = -1, 1 do
						for _, id in buckets[bucket(x + dx, y + dy, z + dz)] or {} do
							local q = nodes[id].position
							local ax, ay, az = p.X - q.X, p.Y - q.Y, p.Z - q.Z
							local distance = math.sqrt(ax * ax + ay * ay + az * az)
							if distance <= best and (distance < best or not nearest or id < nearest) then
								nearest, best = id, distance
							end
						end
					end
				end
			end
			if nearest then
				maxDisplacement = math.max(maxDisplacement, best)
				exact[p] = nearest
				return nearest
			end
		end
		assert(#nodes < maxVertices, "Intersection arrangement vertex budget exceeded")
		local id = #nodes + 1
		nodes[id], exact[p] = { position = p, originals = {} }, id
		if tolerance > 0 then
			local key = bucket(x, y, z)
			buckets[key] = buckets[key] or {}
			table.insert(buckets[key], id)
		end
		return id
	end
	for _, id in U.keys(usedVertices) do
		local node = register(mesh.vertices[id])
		vertexNodes[id] = node
		table.insert(nodes[node].originals, id)
	end
	local triangles, edgeCuts = {}, {}
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		for _, corners in
			mesh:faceTriangles(fid, {
				validateSimple = true,
				maxVertices = options.maxFaceVertices or 2000,
				maxWork = options.maxFaceWork or maxWork,
			})
		do
			local points, ids = {}, {}
			for i, k in corners do
				points[i], ids[i] = mesh.vertices[face.vertices[k]], face.vertices[k]
			end
			local pr = Triangle.prepare(points)
			local axes = { "X", "Y", "Z" }
			local context = {
				face = fid,
				corners = corners,
				points = points,
				vertices = ids,
				projection = pr,
				index = #triangles + 1,
				paths = {},
				records = {},
				coplanar = {},
			}
			context.project = function(p)
				return Vector2.new(p[axes[pr.a]], p[axes[pr.b]])
			end
			context.normal = (points[2] - points[1]):Cross(points[3] - points[1]).Unit
			table.insert(triangles, context)
		end
	end
	local collectingCuts = true
	local function record(context, node, weights)
		local w, total = {}, 0
		for i = 1, 3 do
			assert(U.finite(weights[i]) and weights[i] >= -1e-10, "Invalid source intersection barycentrics")
			w[i] = math.max(0, weights[i])
			total += w[i]
		end
		assert(total > 0)
		for i = 1, 3 do
			w[i] /= total
		end
		local sourceX, sourceY, sourceZ = 0, 0, 0
		for i, p in context.points do
			sourceX += p.X * w[i]
			sourceY += p.Y * w[i]
			sourceZ += p.Z * w[i]
		end
		local originalCorner
		for i, id in context.vertices do
			if vertexNodes[id] == node then
				assert(not originalCorner, "Arrangement tolerance merges distinct source corners")
				originalCorner = i
			end
		end
		if originalCorner then
			local p = context.points[originalCorner]
			local dx, dy, dz = sourceX - p.X, sourceY - p.Y, sourceZ - p.Z
			featureDisplacement = math.max(featureDisplacement, math.sqrt(dx * dx + dy * dy + dz * dz))
			w = { 0, 0, 0 }
			w[originalCorner] = 1
		elseif tolerance > 0 then
			local chosen, nearest, edgeParameter = nil, tolerance, nil
			for i = 1, 3 do
				if w[i] == 0 then
					chosen, nearest = nil, 0
					break
				end
				local j, k = i % 3 + 1, (i + 1) % 3 + 1
				local b, c = context.points[j], context.points[k]
				local ex, ey, ez = c.X - b.X, c.Y - b.Y, c.Z - b.Z
				local t = ((sourceX - b.X) * ex + (sourceY - b.Y) * ey + (sourceZ - b.Z) * ez)
					/ (ex * ex + ey * ey + ez * ez)
				local dx, dy, dz =
					sourceX - (b.X + t * ex), sourceY - (b.Y + t * ey), sourceZ - (b.Z + t * ez)
				local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
				if t > 0 and t < 1 and distance < nearest then
					chosen, nearest, edgeParameter = i, distance, t
				end
			end
			if chosen then
				featureDisplacement = math.max(featureDisplacement, nearest)
				w[chosen] = 0
				w[chosen % 3 + 1], w[(chosen + 1) % 3 + 1] = 1 - edgeParameter, edgeParameter
			end
		end
		local edge, original, parameter
		local sourceEdges = {}
		for i = 1, 3 do
			if w[i] == 1 then
				original = context.vertices[i]
			end
			if w[i] == 0 then
				local a, b = i % 3 + 1, (i + 1) % 3 + 1
				local x, y = context.vertices[a], context.vertices[b]
				edge = U.edge(x, y)
				sourceEdges[edge] = true
				parameter = (x < y and w[b] or w[a]) / (w[a] + w[b])
			end
		end
		local binding = original and "v:" .. original
			or edge and "e:" .. edge .. ":" .. node
			or "t:" .. context.index .. ":" .. node
		local old = context.records[node]
		if old then
			if old.binding == binding or old.edge and not edge then
				return old
			end
			assert(edge and not old.edge, "Arrangement tolerance merges distinct source edges")
		end
		local x, y, z = 0, 0, 0
		for i, p in context.points do
			x += p.X * w[i]
			y += p.Y * w[i]
			z += p.Z * w[i]
		end
		local localPosition = Vector3.new(x, y, z)
		local r = {
			node = node,
			weights = w,
			binding = binding,
			original = original,
			edge = edge,
			sourceEdges = sourceEdges,
			uv = context.project(localPosition),
		}
		context.records[node] = r
		if edge and not original and collectingCuts then
			edgeCuts[edge] = edgeCuts[edge] or {}
			local previous = edgeCuts[edge][node]
			local edgeVertices = string.split(edge, ":")
			local edgeLength = (mesh.vertices[tonumber(edgeVertices[1])] - mesh.vertices[tonumber(
				edgeVertices[2]
			)]).Magnitude
			assert(
				not previous
					or math.abs(previous.t - parameter) * edgeLength <= tolerance * 2 + edgeLength * 1e-12,
				"Arrangement tolerance merges distinct parameters on a source edge"
			)
			edgeCuts[edge][node] = previous or { node = node, t = parameter }
		end
		return r
	end
	for _, context in triangles do
		for i, id in context.vertices do
			local w = { 0, 0, 0 }
			w[i] = 1
			record(context, vertexNodes[id], w)
		end
	end
	local scan = table.clone(options.intersectionOptions or {})
	scan.maxWork = scan.maxWork or maxWork
	scan.maxTriangles = scan.maxTriangles or options.maxTriangles or 500000
	scan.maxIntersections = scan.maxIntersections or 10000
	scan.includeAdjacent, scan.includeContacts = false, true
	if not scan.checkpoint then
		scan.checkpoint = options.checkpoint
	end
	local hits, audit = I.mesh(mesh, scan)
	local collapsedIntersections = 0
	assert(
		audit.complete,
		"Intersection arrangement requires a complete diagnostic scan: " .. tostring(audit.reason)
	)
	for _, hit in hits do
		visit()
		if not hit.constructionComplete then
			assert(
				tolerance > 0 and hit.maxRoundingError <= tolerance,
				"Intersection geometry collapses beyond repair tolerance; rescale source"
			)
			collapsedIntersections += 1
		end
		local ids = {}
		for i, p in hit.points do
			ids[i] = register(p)
		end
		local left, right = triangles[hit.triangleA], triangles[hit.triangleB]
		if hit.coplanar then
			left.coplanar[right.index], right.coplanar[left.index] = true, true
		end
		for _, entry in { { left, "barycentricA" }, { right, "barycentricB" } } do
			local context, field = entry[1], entry[2]
			for i, id in ids do
				record(context, id, hit.pointData[i][field])
			end
			local path, seenNodes = {}, {}
			for _, id in ids do
				if not seenNodes[id] then
					table.insert(path, id)
					seenNodes[id] = true
				end
			end
			if hit.kind == "polygon" and #path >= 3 then
				table.insert(path, path[1])
			end
			if #path == 1 then
				local r = context.records[path[1]]
				if not r.edge and not r.original then
					table.insert(path, vertexNodes[context.vertices[1]])
				end
			end
			if #path >= 2 then
				table.insert(context.paths, path)
			end
		end
	end
	collectingCuts = false
	for edge, cuts in edgeCuts do
		local sorted = {}
		for _, cut in cuts do
			table.insert(sorted, cut)
		end
		table.sort(sorted, function(a, b)
			return a.t < b.t or a.t == b.t and a.node < b.node
		end)
		for i = 2, #sorted do
			assert(sorted[i].t > sorted[i - 1].t, "Collapsed source edge cut ordering")
		end
		edgeCuts[edge] = sorted
	end
	local fragments, constructionError = {}, 0
	local sliverFlips, sliverDisplacement = 0, 0
	for _, context in triangles do
		visit()
		local boundary, known = {}, {}
		local function boundaryPoint(r)
			known[r.uv.X] = known[r.uv.X] or {}
			assert(not known[r.uv.X][r.uv.Y], "Arrangement boundary collapses in native projection")
			known[r.uv.X][r.uv.Y] = r
			table.insert(boundary, r.uv)
		end
		for i, a in context.vertices do
			local j = i % 3 + 1
			local b = context.vertices[j]
			boundaryPoint(context.records[vertexNodes[a]])
			local cuts = edgeCuts[U.edge(a, b)] or {}
			for k = 1, #cuts do
				local cut = cuts[a < b and k or #cuts - k + 1]
				local t = a < b and cut.t or 1 - cut.t
				local w = { 0, 0, 0 }
				w[i], w[j] = 1 - t, t
				local r = record(context, cut.node, w)
				local p, q =
					context.project(mesh.vertices[math.min(a, b)]),
					context.project(mesh.vertices[math.max(a, b)])
				r.uv = Vector2.new(p.X + (q.X - p.X) * cut.t, p.Y + (q.Y - p.Y) * cut.t)
				boundaryPoint(r)
			end
		end
		for _, r in context.records do
			known[r.uv.X] = known[r.uv.X] or {}
			local old = known[r.uv.X][r.uv.Y]
			assert(not old or old.node == r.node, "Distinct intersections collapse in native face projection")
			known[r.uv.X][r.uv.Y] = r
		end
		local paths = {}
		for _, path in context.paths do
			local points = {}
			for i, id in path do
				points[i] = context.records[id].uv
			end
			table.insert(paths, points)
		end
		local domain = D.constrain(boundary, {}, paths, {
			maxVertices = options.maxFacePoints or 10000,
			maxTriangles = options.maxFaceTriangles or 20000,
			maxSegments = options.maxSegments or 20000,
			maxWork = maxWork,
			_visit = visit,
		})
		constructionError = math.max(constructionError, domain.constructionError)
		local records = {}
		local a, b, c =
			context.projection.points[1], context.projection.points[2], context.projection.points[3]
		local _, denominator = P.orient2D(a, b, c)
		for i, p in domain.points do
			local r = known[p.X] and known[p.X][p.Y]
			if not r then
				local _, wa = P.orient2D(b, c, p)
				local _, wb = P.orient2D(c, a, p)
				local _, wc = P.orient2D(a, b, p)
				local w = { wa / denominator, wb / denominator, wc / denominator }
				local x, y, z = 0, 0, 0
				for k, q in context.points do
					x += q.X * w[k]
					y += q.Y * w[k]
					z += q.Z * w[k]
				end
				local node = register(Vector3.new(x, y, z))
				assert(not context.records[node], "Repair tolerance collapses distinct arranged face points")
				r = record(context, node, w)
				assert(
					not r.edge and not r.original,
					"Arrangement introduced an unregistered source-edge cut"
				)
			end
			records[i] = r
		end
		-- Rounded pieces of the same intersection line can enclose a sub-tolerance
		-- sliver. Flip its long diagonal to retain the bent, shared cut chain.
		local localTriangles = domain.triangles
		for _ = 1, #localTriangles * 2 do
			local edges, changed = {}, false
			for ti, tri in localTriangles do
				visit()
				for k, aIndex in tri do
					local bIndex = tri[k % 3 + 1]
					local key = U.edge(aIndex, bIndex)
					edges[key] = edges[key] or {}
					table.insert(edges[key], ti)
				end
			end
			for ti, tri in localTriangles do
				visit()
				local longest, edgeIndex = 0, nil
				for k, aIndex in tri do
					local bIndex = tri[k % 3 + 1]
					local length = (
						nodes[records[aIndex].node].position - nodes[records[bIndex].node].position
					).Magnitude
					if length > longest then
						longest, edgeIndex = length, k
					end
				end
				local ia, ib, ic = tri[edgeIndex], tri[edgeIndex % 3 + 1], tri[(edgeIndex + 1) % 3 + 1]
				local aPos, bPos, cPos =
					nodes[records[ia].node].position,
					nodes[records[ib].node].position,
					nodes[records[ic].node].position
				local altitude = (bPos - aPos):Cross(cPos - aPos).Magnitude / longest
				if altitude > tolerance then
					continue
				end
				local adjacent = edges[U.edge(ia, ib)]
				if #adjacent ~= 2 then
					continue
				end
				local tj = adjacent[1] == ti and adjacent[2] or adjacent[1]
				local id
				for _, indexValue in localTriangles[tj] do
					if indexValue ~= ia and indexValue ~= ib then
						id = indexValue
					end
				end
				if not id or edges[U.edge(ic, id)] then
					continue
				end
				local dPos = nodes[records[id].node].position
				local normal = context.normal * context.projection.sign
				local crossA, crossB = (dPos - aPos):Cross(cPos - aPos), (dPos - cPos):Cross(bPos - cPos)
				if crossA:Dot(normal) <= 0 or crossB:Dot(normal) <= 0 then
					continue
				end
				local newHeight = math.min(crossA.Magnitude, crossB.Magnitude)
					/ math.max(longest, (dPos - cPos).Magnitude)
				if newHeight <= altitude * 2 then
					continue
				end
				localTriangles[ti], localTriangles[tj] = { ia, id, ic }, { ic, id, ib }
				sliverFlips += 1
				sliverDisplacement = math.max(sliverDisplacement, altitude)
				changed = true
				break
			end
			if not changed then
				break
			end
		end
		for _, tri in localTriangles do
			assert(#fragments < maxFaces, "Intersection arrangement face budget exceeded")
			local ia, ib, ic = tri[1], tri[2], tri[3]
			if context.projection.sign < 0 then
				ib, ic = ic, ib
			end
			local rs = { records[ia], records[ib], records[ic] }
			local p, q, r = nodes[rs[1].node].position, nodes[rs[2].node].position, nodes[rs[3].node].position
			assert(
				(q - p):Cross(r - p):Dot(context.normal) > 0,
				"Repair tolerance collapses or reverses a fragment"
			)
			table.insert(fragments, { triangle = context.index, face = context.face, records = rs })
		end
	end
	return {
		source = mesh,
		originalSource = originalSource,
		triangles = triangles,
		nodes = nodes,
		fragments = fragments,
		register = register,
		visit = visit,
		getWork = function()
			return work
		end,
		sourceEdges = index.edges,
		validation = validation,
		report = {
			inputIntersections = audit,
			regularization = regularization,
			tolerance = tolerance,
			geometricNodes = #nodes,
			fragments = #fragments,
			maxWeldDisplacement = maxDisplacement,
			featureSnapDisplacement = featureDisplacement,
			collapsedIntersections = collapsedIntersections,
			planarConstructionError = constructionError,
			sliverEdgeFlips = sliverFlips,
			sliverDisplacement = sliverDisplacement,
			work = work,
		},
		extent = extent,
	}
end
