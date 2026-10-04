-- Shared-edge corner quadrangulation with exact common-chart error certificates.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Corner = require(script.Parent.MeshEditCore).corner
local Bound = require(script.Parent.QuadPatchBound)
local Q = require(script.Parent.QuadGeometry)
return function(source, context)
	local visit = context.visit
	visit(U.count(source.vertices) + 4 * U.count(source.faces))
	local top = source:topology()
	local corners = 0
	for _, face in source.faces do
		corners += #face.vertices
	end
	context.allocation(
		U.count(source.vertices) + U.count(top.edges) + U.count(source.faces),
		corners,
		4 * corners,
		2 * corners
	)
	local out = source:clone()
	out.faces = {}
	local edges, centers, children = {}, {}, {}
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = { vertex = true, edge = false, face = false, corner = false },
	}
	for _, key in U.keys(top.edges) do
		visit(1)
		local edge = top.edges[key]
		local p = Q.mean(source, { edge.a, edge.b })
		if p == source.vertices[edge.a] or p == source.vertices[edge.b] then
			return nil, { reason = "nativeEdgePrecision" }
		end
		local id = out:addVertex(p)
		edges[key] = id
		maps.vertex[id] = { { edge.a, 1 }, { edge.b, 1 } }
		maps.edge[U.edge(edge.a, id)] = { { key, 1 } }
		maps.edge[U.edge(id, edge.b)] = { { key, 1 } }
	end
	local maximum, bounds, normalAngle = 0, {}, 0
	for _, fid in U.keys(source.faces) do
		local face = source.faces[fid]
		local n = #face.vertices
		assert(n == 3 or n == 4, "Triangle or quad patch required")
		local center = out:addVertex(Q.mean(source, face.vertices))
		centers[fid] = center
		maps.vertex[center] = {}
		local centerRefs = {}
		for i, id in face.vertices do
			table.insert(maps.vertex[center], { id, 1 })
			table.insert(centerRefs, { fid, i, 1 })
		end
		local uv = {}
		local chart = n == 3 and { { 0, 0 }, { 6, 0 }, { 0, 6 } }
			or { { 0, 0 }, { 6, 0 }, { 6, 6 }, {
				0,
				6,
			} }
		for i, id in face.vertices do
			uv[id] = chart[i]
		end
		uv[center] = n == 3 and { 2, 2 } or { 3, 3 }
		children[fid] = {}
		for i, a in face.vertices do
			visit(1)
			local j, k = i % n + 1, (i - 2) % n + 1
			local b, c = face.vertices[j], face.vertices[k]
			local nextMid, previousMid = edges[U.edge(a, b)], edges[U.edge(c, a)]
			uv[nextMid] = { (chart[i][1] + chart[j][1]) / 2, (chart[i][2] + chart[j][2]) / 2 }
			uv[previousMid] = { (chart[k][1] + chart[i][1]) / 2, (chart[k][2] + chart[i][2]) / 2 }
			local refs = {
				{ { fid, i, 1 } },
				{ { fid, i, 1 }, { fid, j, 1 } },
				centerRefs,
				{
					{ fid, k, 1 },
					{ fid, i, 1 },
				},
			}
			local cr = {}
			for slot, ref in refs do
				cr[slot] = Corner(source, ref)
				cr[slot].normal, cr[slot].tangent, cr[slot].tangentSign = nil, nil, nil
			end
			local ids = { a, nextMid, center, previousMid }
			if not Q.shape(out, ids, visit) then
				return nil, { reason = "nativeQuadShape" }
			end
			local child = out:addFace(ids, cr, face.material)
			table.insert(children[fid], child)
			maps.face[child] = { { fid, 1 } }
			for slot, ref in refs do
				local data = {}
				for _, r in ref do
					table.insert(data, { r[1] .. ":" .. r[2], r[3] })
				end
				maps.corner[child .. ":" .. slot] = data
			end
		end
		local a, b = Q.triangles(source, { fid }, uv, visit), Q.triangles(out, children[fid], uv, visit)
		local error, detail = Bound.check(a, b, out.vertices, n == 3, visit)
		if not error then
			return nil, { reason = detail }
		end
		local angle = Q.normalChange(a, b, detail.pairs, out.vertices, visit)
		if not angle then
			return nil, { reason = "degenerateQuadTriangle" }
		end
		normalAngle = math.max(normalAngle, angle)
		bounds[fid] = error
		maximum = math.max(maximum, error)
	end
	context.transfer(source, out, maps)
	A.vertexData(source, out, maps.vertex)
	return out,
		{
			errorBound = maximum,
			maximumNormalAngle = normalAngle,
			patchErrorBounds = bounds,
			children = children,
			edgeVertices = edges,
			faceVertices = centers,
			maps = maps,
		}
end
