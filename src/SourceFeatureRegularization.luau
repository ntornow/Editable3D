-- Conforming source-feature snapping with exact rational reference geometry.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Edit = require(script.Parent.MeshEditCore)
return function(mesh, options, visit)
	local config = options.regularization
	assert(
		type(config) == "table" and config.method == "features",
		"Feature regularization settings required"
	)
	assert(
		config.edgePairs == nil or type(config.edgePairs) == "boolean",
		"Boolean edge-pair regularization option required"
	)
	local maxCoefficients = U.integer(options.maxExactCoefficients or 1000000, 1)
	local distance = config.distance
	assert(
		type(distance) == "number" and U.finite(distance) and distance >= 2 ^ -126 and distance <= 2 ^ 130,
		"Invalid feature regularization distance"
	)
	if options.checkpoint then
		options.checkpoint({ stage = "regularize", progress = 0 })
	end
	assert(not options.cancelled or not options.cancelled(), "Source regularization cancelled")
	local allocated = 0
	local function allocate(n)
		allocated += n
		assert(allocated <= maxCoefficients, "Feature regularization coefficient budget exceeded")
	end
	local phase = "regularize"
	local function tick(n)
		visit(phase, n or 1)
	end
	local R = require(script.Parent.ExactRational)(tick, options.maxExactBits or 8192)
	local G = require(script.Parent.ExactFeatureClosest)(R, tick)
	local enclose = require(script.Parent.ExactRationalBounds)(R, tick)
	local zero, one = R.number(0), R.number(1)
	local radius = R.number(distance)
	local radius2 = R.mul(radius, radius)
	local expanded2 = R.mul(radius2, R.number(4))
	local function rational(p)
		return { R.number(p.X), R.number(p.Y), R.number(p.Z) }
	end
	local function native(p)
		local v = {}
		for i, x in p do
			local b = enclose(x)
			v[i] = (b[1] + b[2]) / 2
		end
		local point = Vector3.new(table.unpack(v))
		assert(U.vector(point), "Feature construction is not native finite")
		return point
	end
	local nodes, used, incident = {}, {}, {}
	assert(
		U.count(mesh.vertices) <= (options.maxVertices or 100000),
		"Feature regularization vertex budget exceeded"
	)
	for id, p in mesh.vertices do
		tick()
		allocate(7)
		nodes[id] = {
			position = p,
			exact = rational(p),
			reference = rational(p),
			refs = { [id] = one },
			frozen = false,
		}
	end
	for fid, face in mesh.faces do
		assert(#face.vertices <= (options.maxFaceVertices or 2000), "Feature face vertex budget exceeded")
		for _, id in face.vertices do
			tick()
			allocate(1)
			used[id] = true
			incident[id] = incident[id] or {}
			incident[id][fid] = true
		end
	end
	local function adjacent(id, target)
		for original in nodes[target].refs do
			for fid in incident[id] do
				tick()
				if incident[original] and incident[original][fid] then
					return true
				end
			end
		end
		return false
	end
	local countVertices = U.count(nodes)
	assert(countVertices <= (options.maxVertices or 100000), "Feature regularization vertex budget exceeded")
	local nextVertex = mesh.nextVertex
	local triangles, roots, edges = {}, {}, {}
	local edgeOrigins, segmentOrigins = {}, {}
	local countTriangles = 0
	local function points(ids, key)
		local out = {}
		for i, id in ids do
			out[i] = nodes[id][key]
		end
		return out
	end
	local function addTriangle(root, ids, corners)
		tick()
		allocate(1)
		countTriangles += 1
		assert(countTriangles <= (options.maxFaces or 200000), "Feature regularization face budget exceeded")
		local tri = { index = #triangles + 1, root = root, ids = ids, corners = corners, active = true }
		triangles[#triangles + 1] = tri
		root.leaves[tri.index] = tri
		for i, id in ids do
			local key = U.edge(id, ids[i % 3 + 1])
			edges[key] = edges[key] or {}
			edges[key][tri.index] = true
		end
		return tri
	end
	local function removeTriangle(tri)
		assert(tri.active)
		tri.active = false
		countTriangles -= 1
		tri.root.leaves[tri.index] = nil
		for i, id in tri.ids do
			local key = U.edge(id, tri.ids[i % 3 + 1])
			edges[key][tri.index] = nil
		end
	end
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		for _, indices in
			mesh:faceTriangles(fid, {
				validateSimple = true,
				maxVertices = options.maxFaceVertices or 2000,
				maxWork = options.maxFaceWork or options.maxWork or 5000000,
			})
		do
			local ids, corners = {}, {}
			for i, k in indices do
				ids[i] = face.vertices[k]
				corners[i] = { [k] = one }
			end
			local lo, hi = nodes[ids[1]].position, nodes[ids[1]].position
			for _, id in ids do
				lo = lo:Min(nodes[id].position)
				hi = hi:Max(nodes[id].position)
			end
			local root = { index = #roots + 1, face = fid, leaves = {}, lo = lo, hi = hi }
			roots[#roots + 1] = root
			addTriangle(root, ids, corners)
			for i, a in ids do
				local b = ids[i % 3 + 1]
				local key = U.edge(a, b)
				if not edgeOrigins[key] then
					allocate(1)
					local origin = { key = key, a = math.min(a, b), b = math.max(a, b), segments = {} }
					edgeOrigins[key] = origin
					segmentOrigins[key] = origin
					origin.segments[key] = { a, b }
				end
			end
		end
	end
	local function blendMaps(maps, weights)
		local out = {}
		for i, refs in maps do
			if weights[i].sign == 0 then
				continue
			end
			for id, weight in refs do
				tick()
				allocate(1)
				out[id] = R.add(out[id] or zero, R.mul(weight, weights[i]))
			end
		end
		return out
	end
	local function splitEdge(a, b, t, targetId)
		local affected = U.keys(edges[U.edge(a, b)])
		for _, index in affected do
			local old = triangles[index]
			local ia, ib
			for i, vertex in old.ids do
				if vertex == a then
					ia = i
				elseif vertex == b then
					ib = i
				end
			end
			assert(ia and ib)
			local first, second = ia, ib
			if first % 3 + 1 ~= second then
				first, second = second, first
			end
			local third = second % 3 + 1
			local corner = blendMaps({ old.corners[ia], old.corners[ib] }, { R.sub(one, t), t })
			removeTriangle(old)
			addTriangle(
				old.root,
				{ old.ids[first], targetId, old.ids[third] },
				{ old.corners[first], corner, old.corners[third] }
			)
			addTriangle(
				old.root,
				{ targetId, old.ids[second], old.ids[third] },
				{ corner, old.corners[second], old.corners[third] }
			)
		end
		local oldKey = U.edge(a, b)
		local origin = segmentOrigins[oldKey]
		if origin then
			segmentOrigins[oldKey] = nil
			origin.segments[oldKey] = nil
			for _, pair in { { a, targetId }, { targetId, b } } do
				local key = U.edge(pair[1], pair[2])
				segmentOrigins[key] = origin
				origin.segments[key] = pair
			end
		end
	end
	local function bboxDistance(p, lo, hi)
		local q =
			Vector3.new(math.clamp(p.X, lo.X, hi.X), math.clamp(p.Y, lo.Y, hi.Y), math.clamp(p.Z, lo.Z, hi.Z))
		return G.squared(rational(p), rational(q))
	end
	local function bvh(list)
		if #list == 0 then
			return nil
		end
		local lo, hi = roots[list[1]].lo, roots[list[1]].hi
		for _, i in list do
			tick()
			lo = lo:Min(roots[i].lo)
			hi = hi:Max(roots[i].hi)
		end
		local node = { lo = lo, hi = hi }
		if #list <= 8 then
			node.roots = list
			return node
		end
		local axis = "X"
		for _, key in { "Y", "Z" } do
			if hi[key] - lo[key] > hi[axis] - lo[axis] then
				axis = key
			end
		end
		table.sort(list, function(a, b)
			tick()
			local x, y = roots[a].lo[axis] + roots[a].hi[axis], roots[b].lo[axis] + roots[b].hi[axis]
			return x < y or x == y and a < b
		end)
		local left, right = {}, {}
		for i, value in list do
			table.insert(i <= math.floor(#list / 2) and left or right, value)
		end
		node.left, node.right = bvh(left), bvh(right)
		return node
	end
	local ids = {}
	for i in roots do
		ids[#ids + 1] = i
	end
	local tree = bvh(ids)
	local function audit(tri)
		local valid = G.orientation(points(tri.ids, "reference"), points(tri.ids, "exact"))
		assert(valid, "Feature regularization collapses or reverses a source triangle during motion")
	end
	local snaps = {}
	for _, id in U.keys(used) do
		tick()
		local source = nodes[id]
		local selected
		local function offer(tri, result)
			if not result or R.compare(result.squared, radius2) > 0 then
				return
			end
			local targetIds = {}
			for _, i in result.indices do
				targetIds[#targetIds + 1] = tri.ids[i]
			end
			table.sort(targetIds)
			if result.dimension <= 1 then
				for _, target in targetIds do
					if adjacent(id, target) then
						return
					end
				end
				if result.dimension == 1 then
					for index in edges[U.edge(targetIds[1], targetIds[2])] do
						tick()
						if incident[id][triangles[index].root.face] then
							return
						end
					end
				end
			end
			local comparison = selected and R.compare(result.squared, selected.squared) or -1
			local earlier = false
			if selected and result.dimension == selected.dimension then
				local same = true
				for i, value in targetIds do
					if value ~= selected.targetIds[i] then
						earlier = value < selected.targetIds[i]
						same = false
						break
					end
				end
				if same then
					earlier = tri.index < selected.triangle.index
				end
			end
			if
				comparison < 0
				or comparison == 0
					and (result.dimension < selected.dimension or result.dimension == selected.dimension and earlier)
			then
				result.triangle = tri
				result.targetIds = targetIds
				selected = result
			end
		end
		local function query(node)
			if not node or R.compare(bboxDistance(source.position, node.lo, node.hi), expanded2) > 0 then
				return
			end
			tick()
			if node.roots then
				for _, rootIndex in node.roots do
					local root = roots[rootIndex]
					if incident[id][root.face] then
						continue
					end
					for _, triIndex in U.keys(root.leaves) do
						local tri = root.leaves[triIndex]
						local allowed = {}
						for i, vertex in tri.ids do
							allowed[i] = nodes[vertex].frozen and not adjacent(id, vertex)
						end
						offer(tri, G.triangle(source.exact, points(tri.ids, "exact"), allowed))
					end
				end
			else
				query(node.left)
				query(node.right)
			end
		end
		query(tree)
		if selected then
			local target = native(selected.position)
			local exact = rational(target)
			assert(
				R.compare(G.squared(exact, source.reference), radius2) <= 0,
				"Native feature snap exceeds original source radius"
			)
			local tri = selected.triangle
			local reused
			for _, i in selected.indices do
				if nodes[tri.ids[i]].position == target then
					reused = tri.ids[i]
					break
				end
			end
			local targetId = reused
			if not reused then
				local reference = G.blend(points(tri.ids, "reference"), selected.weights)
				assert(
					R.compare(G.squared(exact, reference), radius2) <= 0,
					"Feature refinement exceeds original source radius"
				)
				countVertices += 1
				assert(
					countVertices <= (options.maxVertices or 100000),
					"Feature regularization vertex budget exceeded"
				)
				targetId = nextVertex
				nextVertex += 1
				assert(not nodes[targetId], "Feature vertex identity collision")
				local maps = {}
				for i, vertex in tri.ids do
					maps[i] = nodes[vertex].refs
				end
				allocate(6)
				nodes[targetId] = {
					position = target,
					exact = exact,
					reference = reference,
					refs = blendMaps(maps, selected.weights),
					frozen = true,
				}
				if selected.dimension == 2 then
					local corner = blendMaps(tri.corners, selected.weights)
					removeTriangle(tri)
					for i = 1, 3 do
						local j = i % 3 + 1
						addTriangle(
							tri.root,
							{ tri.ids[i], tri.ids[j], targetId },
							{ tri.corners[i], tri.corners[j], corner }
						)
					end
				else
					assert(selected.dimension == 1)
					local a, b = tri.ids[selected.indices[1]], tri.ids[selected.indices[2]]
					local t = selected.weights[selected.indices[2]]
					splitEdge(a, b, t, targetId)
				end
			end
			source.position, source.exact = target, exact
			snaps[#snaps + 1] = {
				sourceVertex = id,
				targetVertex = targetId,
				dimension = reused and 0 or selected.dimension,
				sourceFace = tri.root.face,
			}
		end
		source.frozen = true
	end
	local edgeSnaps = {}
	if config.edgePairs then
		phase = "regularizeEdges"
		if options.checkpoint then
			options.checkpoint({ stage = phase, progress = 0 })
		end
		assert(not options.cancelled or not options.cancelled(), "Source edge-pair regularization cancelled")
		local edgeList = {}
		for _, origin in edgeOrigins do
			origin.lo = mesh.vertices[origin.a]:Min(mesh.vertices[origin.b])
			origin.hi = mesh.vertices[origin.a]:Max(mesh.vertices[origin.b])
			table.insert(edgeList, origin)
		end
		table.sort(edgeList, function(a, b)
			tick()
			return a.a < b.a or a.a == b.a and a.b < b.b
		end)
		for i, origin in edgeList do
			origin.index = i
		end
		local function edgeTree(list)
			if #list == 0 then
				return nil
			end
			local lo, hi = list[1].lo, list[1].hi
			for _, o in list do
				tick()
				lo = lo:Min(o.lo)
				hi = hi:Max(o.hi)
			end
			local node = { lo = lo, hi = hi }
			if #list <= 8 then
				node.items = list
				return node
			end
			local axis = "X"
			for _, key in { "Y", "Z" } do
				if hi[key] - lo[key] > hi[axis] - lo[axis] then
					axis = key
				end
			end
			table.sort(list, function(a, b)
				tick()
				local x, y = a.lo[axis] + a.hi[axis], b.lo[axis] + b.hi[axis]
				return x < y or x == y and a.index < b.index
			end)
			local left, right = {}, {}
			for i, o in list do
				table.insert(i <= math.floor(#list / 2) and left or right, o)
			end
			node.left, node.right = edgeTree(left), edgeTree(right)
			return node
		end
		local pairTree = edgeTree(table.clone(edgeList))
		local tripleRadius = R.mul(radius2, R.number(9))
		local function boxesWithin(a, b)
			local distance = zero
			for _, axis in { "X", "Y", "Z" } do
				local delta = zero
				if a.lo[axis] > b.hi[axis] then
					delta = R.sub(R.number(a.lo[axis]), R.number(b.hi[axis]))
				elseif b.lo[axis] > a.hi[axis] then
					delta = R.sub(R.number(b.lo[axis]), R.number(a.hi[axis]))
				end
				distance = R.add(distance, R.mul(delta, delta))
			end
			return R.compare(distance, tripleRadius) <= 0
		end
		local function insertEdgePoint(segment, t, point)
			local a, b = segment[1], segment[2]
			assert(
				nodes[a].position ~= point and nodes[b].position ~= point,
				"Native edge-pair refinement collapses to an endpoint"
			)
			local weights = { R.sub(one, t), t, zero }
			local reference = G.blend({ nodes[a].reference, nodes[b].reference, nodes[a].reference }, weights)
			local exact = rational(point)
			assert(
				R.compare(G.squared(exact, reference), radius2) <= 0,
				"Edge-pair refinement exceeds original source radius"
			)
			countVertices += 1
			assert(
				countVertices <= (options.maxVertices or 100000),
				"Feature regularization vertex budget exceeded"
			)
			local id = nextVertex
			nextVertex += 1
			assert(not nodes[id], "Feature vertex identity collision")
			allocate(6)
			nodes[id] = {
				position = point,
				exact = exact,
				reference = reference,
				refs = blendMaps({ nodes[a].refs, nodes[b].refs }, weights),
				frozen = true,
			}
			splitEdge(a, b, t, id)
			return id
		end
		for _, sourceEdge in edgeList do
			local candidates = {}
			local function queryPairs(node)
				tick()
				if not node or not boxesWithin(sourceEdge, node) then
					return
				end
				if node.items then
					for _, targetEdge in node.items do
						tick()
						if
							targetEdge.index >= sourceEdge.index or not boxesWithin(sourceEdge, targetEdge)
						then
							continue
						end
						local excluded = false
						for _, a in { sourceEdge.a, sourceEdge.b } do
							for _, b in { targetEdge.a, targetEdge.b } do
								if adjacent(a, b) then
									excluded = true
								end
							end
						end
						if not excluded then
							candidates[#candidates + 1] = targetEdge
						end
					end
				else
					queryPairs(node.left)
					queryPairs(node.right)
				end
			end
			queryPairs(pairTree)
			table.sort(candidates, function(a, b)
				tick()
				return a.index < b.index
			end)
			for _, targetEdge in candidates do
				local best
				for _, targetKey in U.keys(targetEdge.segments) do
					local ta = targetEdge.segments[targetKey]
					for _, sourceKey in U.keys(sourceEdge.segments) do
						tick()
						local sb = sourceEdge.segments[sourceKey]
						local result = G.edgePair(
							{ nodes[ta[1]].exact, nodes[ta[2]].exact },
							{ nodes[sb[1]].exact, nodes[sb[2]].exact }
						)
						if
							result
							and result.squared.sign > 0
							and R.compare(result.squared, radius2) <= 0
							and (not best or R.compare(result.squared, best.squared) < 0)
						then
							result.target, result.source = ta, sb
							best = result
						end
					end
				end
				if best then
					-- The earlier edge owns the common anchor. Each inserted node has its own reference.
					local point = native(best.first)
					local exact = rational(point)
					assert(
						R.compare(G.squared(exact, best.second), radius2) <= 0,
						"Native edge-pair snap exceeds current source radius"
					)
					local targetId = insertEdgePoint(best.target, best.a, point)
					local sourceId = insertEdgePoint(best.source, best.b, point)
					edgeSnaps[#edgeSnaps + 1] = {
						sourceEdge = sourceEdge.key,
						targetEdge = targetEdge.key,
						sourceVertex = sourceId,
						targetVertex = targetId,
					}
				end
			end
		end
	end
	phase = "regularize"
	local out = mesh:clone()
	out.faces = {}
	out.nextVertex = nextVertex
	for id, node in nodes do
		out.vertices[id] = node.position
	end
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = {
			vertex = true,
			edge = false,
			face = false,
			corner = false,
		},
	}
	local function refs(values, prefix)
		local result = {}
		for _, key in U.keys(values) do
			local value = values[key]
			if value.sign ~= 0 then
				local bounds = enclose(value)
				local weight = (bounds[1] + bounds[2]) / 2
				assert(weight > 0 and U.finite(weight), "Feature attribute weight loses native precision")
				result[#result + 1] = { prefix and prefix .. key or key, weight }
			end
		end
		return result
	end
	for id, node in nodes do
		if not mesh.vertices[id] then
			maps.vertex[id] = refs(node.refs)
		end
	end
	local kept = {}
	local checked, maximum = 0, zero
	for _, tri in triangles do
		if not tri.active then
			continue
		end
		audit(tri)
		checked += 1
		local original = tri.root.face
		local fid
		if not kept[original] then
			fid = original
			kept[original] = true
		else
			fid = out.nextFace
			out.nextFace += 1
		end
		local corners = {}
		for i, values in tri.corners do
			local cornerRefs = {}
			for _, entry in refs(values) do
				cornerRefs[#cornerRefs + 1] = { original, entry[1], entry[2] }
			end
			corners[i] = Edit.corner(mesh, cornerRefs)
			maps.corner[fid .. ":" .. i] = refs(values, original .. ":")
		end
		out.faces[fid] =
			{ vertices = table.clone(tri.ids), corners = corners, material = mesh.faces[original].material }
		maps.face[fid] = { { original, 1 } }
		local sourceFace = mesh.faces[original]
		for i, vertex in tri.ids do
			local j = i % 3 + 1
			for k, oldVertex in sourceFace.vertices do
				tick()
				local nextCorner = k % #sourceFace.vertices + 1
				local on = true
				for _, index in { i, j } do
					for ref, value in tri.corners[index] do
						if value.sign ~= 0 and ref ~= k and ref ~= nextCorner then
							on = false
						end
					end
				end
				if on then
					maps.edge[U.edge(vertex, tri.ids[j])] =
						{ { U.edge(oldVertex, sourceFace.vertices[nextCorner]), 1 } }
				end
			end
		end
	end
	for _, node in nodes do
		local square = G.squared(node.exact, node.reference)
		assert(R.compare(square, radius2) <= 0, "Feature source displacement bound failed")
		if R.compare(square, maximum) > 0 then
			maximum = square
		end
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	out:recalculateNormals()
	local validation = out:validate()
	assert(validation.valid, "Feature regularization produces invalid refined topology")
	local square = enclose(maximum)
	local bound = math.min(
		distance,
		require(script.Parent.DirectedInterval).sqrt({ math.max(0, square[1]), square[2] })[2]
	)
	return out,
		{
			method = "features",
			distance = distance,
			snaps = snaps,
			edgeSnaps = edgeSnaps,
			edgePairs = config.edgePairs == true,
			maps = maps,
			triangles = checked,
			exactRefinementEntries = allocated,
			usedVertices = U.count(used),
			addedVertices = countVertices - U.count(mesh.vertices),
			maxDisplacement = bound,
			sourceSurfaceHausdorffBound = bound,
			displacementCertified = true,
			sourceSurfaceBoundCertified = true,
			triangleHomotopyOrientationCertified = true,
			topologyChanged = countVertices > U.count(mesh.vertices) or countTriangles ~= U.count(mesh.faces),
			globalIsotopyCertified = false,
			originalSolidEqualityCertified = false,
		}
end
