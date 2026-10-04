-- Private polygon-preserving clip for the already-validated convex bevel path.
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Edit = require(script.Parent.MeshEditCore)
return function(mesh, point, normal)
	assert(U.vector(point) and U.vector(normal) and normal.Magnitude > 0, "Finite convex cut plane required")
	normal = normal.Unit
	local tolerance = 1e-8
	local distances, inside, outside = {}, false, false
	for id, p in mesh.vertices do
		local d = (p - point):Dot(normal)
		distances[id] = d
		inside = inside or d < -tolerance
		outside = outside or d > tolerance
	end
	if not outside then
		return mesh:clone()
	end
	local out = Mesh.new()
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = { vertex = false, edge = false, face = false, corner = false },
	}
	if not inside then
		A.transfer(mesh, out, maps)
		return out
	end
	local originals, cuts, capIds = {}, {}, {}
	local function old(id)
		if not originals[id] then
			originals[id] = out:addVertex(mesh.vertices[id])
			maps.vertex[originals[id]] = { { id, 1 } }
		end
		if math.abs(distances[id]) < tolerance then
			capIds[originals[id]] = true
		end
		return originals[id]
	end
	local function crossing(a, b, fa, ia, ib)
		local t = distances[a] / (distances[a] - distances[b])
		local key = U.edge(a, b)
		local id = cuts[key]
		if t < 1e-8 then
			id = old(a)
		elseif t > 1 - 1e-8 then
			id = old(b)
		elseif not id then
			id = out:addVertex(mesh.vertices[a]:Lerp(mesh.vertices[b], t))
			cuts[key] = id
			maps.vertex[id] = { { a, 1 - t }, { b, t } }
		end
		capIds[id] = true
		return { id = id, refs = { { fa, ia, 1 - t }, { fa, ib, t } }, edges = { [key] = true } }
	end
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		local polygon = {}
		local function append(r)
			if not polygon[#polygon] or polygon[#polygon].id ~= r.id then
				table.insert(polygon, r)
			end
		end
		for i, a in f.vertices do
			local j = i % #f.vertices + 1
			local b = f.vertices[j]
			local da, db = distances[a], distances[b]
			if da <= tolerance then
				append({
					id = old(a),
					refs = { { fid, i, 1 } },
					edges = {
						[U.edge(a, b)] = true,
						[U.edge(a, f.vertices[(i - 2) % #f.vertices + 1])] = true,
					},
				})
			end
			if da < -tolerance and db > tolerance or da > tolerance and db < -tolerance then
				append(crossing(a, b, fid, i, j))
			end
		end
		if #polygon > 1 and polygon[1].id == polygon[#polygon].id then
			table.remove(polygon)
		end
		if #polygon >= 3 then
			local vs, cs = {}, {}
			for i, r in polygon do
				vs[i], cs[i] = r.id, Edit.corner(mesh, r.refs)
			end
			local nf = out:addFace(vs, cs, f.material)
			maps.face[nf] = { { fid, 1 } }
			for i, r in polygon do
				local cr = {}
				for _, ref in r.refs do
					table.insert(cr, { ref[1] .. ":" .. ref[2], ref[3] })
				end
				maps.corner[nf .. ":" .. i] = cr
				local nextRecord = polygon[i % #polygon + 1]
				for edge in r.edges do
					if nextRecord.edges[edge] then
						maps.edge[U.edge(r.id, nextRecord.id)] = { { edge, 1 } }
					end
				end
			end
		end
	end
	local ids = U.keys(capIds)
	if #ids >= 3 then
		local center = Vector3.zero
		for _, id in ids do
			center += out.vertices[id] / #ids
		end
		local x, y = U.frame(normal)
		table.sort(ids, function(a, b)
			local p, q = out.vertices[a] - center, out.vertices[b] - center
			return math.atan2(p:Dot(y), p:Dot(x)) < math.atan2(q:Dot(y), q:Dot(x))
		end)
		out:addFace(ids)
	end
	out:removeUnused()
	for id in maps.vertex do
		if not out.vertices[id] then
			maps.vertex[id] = nil
		end
	end
	A.transfer(mesh, out, maps)
	for name in mesh.groups do
		out.groups[name] = {}
	end
	A.vertexData(mesh, out, maps.vertex)
	return out:recalculateNormals()
end
