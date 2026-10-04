local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local T = {}
local function ref(key, weight)
	return { key, weight or 1 }
end
local function cornerKey(fid, i)
	return fid .. ":" .. i
end
local function mixCorners(face, references)
	local result, fields = {}, {}
	for _, pair in references do
		for field in face.corners[pair[1]] do
			fields[field] = true
		end
	end
	for field in fields do
		local channel, refs = nil, {}
		for _, pair in references do
			local value = face.corners[pair[1]][field]
			if value ~= nil then
				local kind = typeof(value)
				channel = channel
					or {
						dataType = kind,
						values = {},
						interpolation = (kind == "boolean" or kind == "string") and "nearest" or "linear",
					}
				channel.values[pair[1]] = value
				table.insert(refs, pair)
			end
		end
		result[field] = A.blend(channel, refs)
	end
	return result
end
function T.triangulate(mesh)
	local out = mesh:clone()
	out.faces = {}
	out.nextFace = 1
	local maps = { face = {}, corner = {}, identity = { face = false, corner = false } }
	for _, t in mesh:triangles() do
		local f = mesh.faces[t.face]
		local fid = out:addFace(
			{ t[1], t[2], t[3] },
			{ f.corners[t.corners[1]], f.corners[t.corners[2]], f.corners[t.corners[3]] },
			f.material
		)
		maps.face[fid] = { ref(t.face) }
		for i, c in t.corners do
			maps.corner[cornerKey(fid, i)] = { ref(cornerKey(t.face, c)) }
		end
	end
	return A.transfer(mesh, out, maps)
end
function T.join(meshes)
	local out = Mesh.new()
	for _, m in meshes do
		local map = {}
		local maps = {
			vertex = {},
			edge = {},
			face = {},
			corner = {},
			identity = { vertex = false, edge = false, face = false, corner = false },
		}
		for _, id in U.keys(m.vertices) do
			map[id] = out:addVertex(m.vertices[id])
			maps.vertex[map[id]] = { ref(id) }
			out.weights[map[id]] = U.copy(m.weights[id])
		end
		for _, id in U.keys(m.faces) do
			local f = m.faces[id]
			local v = {}
			for _, a in f.vertices do
				table.insert(v, map[a])
			end
			local fid = out:addFace(v, f.corners, f.material)
			maps.face[fid] = { ref(id) }
			for i, a in f.vertices do
				maps.corner[cornerKey(fid, i)] = { ref(cornerKey(id, i)) }
				local b = f.vertices[i % #f.vertices + 1]
				maps.edge[U.edge(map[a], map[b])] = { ref(U.edge(a, b)) }
			end
		end
		A.transfer(m, out, maps, true)
		for name, g in m.groups do
			out.groups[name] = out.groups[name] or {}
			for id, w in g do
				out.groups[name][map[id]] = w
			end
		end
	end
	return out
end
function T.extract(mesh, faces)
	local out = mesh:clone()
	for id in out.faces do
		if not faces[id] then
			out.faces[id] = nil
		end
	end
	return out:removeUnused()
end
function T.components(mesh)
	local top = mesh:topology()
	local seen = {}
	local result = {}
	for _, root in U.keys(mesh.faces) do
		if not seen[root] then
			local set = { [root] = true }
			local queue = { root }
			seen[root] = true
			local i = 1
			while i <= #queue do
				local f = mesh.faces[queue[i]]
				i += 1
				for _, v in f.vertices do
					for _, nextId in top.vertexFaces[v] do
						if not seen[nextId] then
							seen[nextId] = true
							set[nextId] = true
							table.insert(queue, nextId)
						end
					end
				end
			end
			table.insert(result, T.extract(mesh, set))
		end
	end
	return result
end
function T.reverse(mesh)
	local out = mesh:clone()
	local maps = { corner = {}, identity = { corner = false } }
	for fid, f in out.faces do
		local v, c = {}, {}
		for i = #f.vertices, 1, -1 do
			table.insert(v, f.vertices[i])
			local corner = U.copy(f.corners[i])
			if corner.normal then
				corner.normal = -corner.normal
			end
			if corner.tangentSign then
				corner.tangentSign = -corner.tangentSign
			end
			table.insert(c, corner)
			maps.corner[cornerKey(fid, #c)] = { ref(cornerKey(fid, i)) }
		end
		f.vertices = v
		f.corners = c
	end
	out.revision += 1
	return A.transfer(mesh, out, maps)
end
function T.weld(mesh, tolerance)
	assert(tolerance > 0, "Positive tolerance required")
	local out = mesh:clone()
	local buckets, map = {}, {}
	local maps = { vertex = {}, edge = {}, corner = {}, identity = { edge = false, corner = false } }
	local function bucketKey(x, y, z)
		return x .. "," .. y .. "," .. z
	end
	for _, id in U.keys(out.vertices) do
		local p = out.vertices[id]
		local x, y, z = math.floor(p.X / tolerance), math.floor(p.Y / tolerance), math.floor(p.Z / tolerance)
		local found
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					for _, other in buckets[bucketKey(x + dx, y + dy, z + dz)] or {} do
						if
							(p - out.vertices[other]).Magnitude <= tolerance and (not found or other < found)
						then
							found = other
						end
					end
				end
			end
		end
		map[id] = found or id
		maps.vertex[map[id]] = maps.vertex[map[id]] or {}
		table.insert(maps.vertex[map[id]], ref(id))
		if not found then
			local k = bucketKey(x, y, z)
			buckets[k] = buckets[k] or {}
			table.insert(buckets[k], id)
		end
	end
	for fid, f in out.faces do
		local v, c, seen = {}, {}, {}
		for i, id in f.vertices do
			local a = map[id]
			if not seen[a] then
				seen[a] = true
				table.insert(v, a)
				table.insert(c, f.corners[i])
				maps.corner[cornerKey(fid, #v)] = { ref(cornerKey(fid, i)) }
			end
		end
		if #v < 3 then
			out.faces[fid] = nil
			for i = 1, #v do
				maps.corner[cornerKey(fid, i)] = nil
			end
		else
			f.vertices = v
			f.corners = c
		end
	end
	local surviving = A.keys(out, "edge")
	local sourceEdges = mesh:topology().edges
	for _, key in U.keys(sourceEdges) do
		local e = sourceEdges[key]
		local nextKey = U.edge(map[e.a], map[e.b])
		if surviving[nextKey] then
			maps.edge[nextKey] = maps.edge[nextKey] or {}
			table.insert(maps.edge[nextKey], ref(key))
		end
	end
	A.transfer(mesh, out, maps)
	for _, g in out.groups do
		for id, w in table.clone(g) do
			g[map[id]] = math.max(g[map[id]] or 0, w)
		end
	end
	return out:removeUnused():recalculateNormals(), map
end
function T.extrude(mesh, selected, offset)
	assert(U.vector(offset))
	local out = mesh:clone()
	local map, boundary = {}, {}
	local maps = { vertex = {}, edge = {}, face = {}, corner = {} }
	for _, fid in U.keys(selected) do
		if selected[fid] then
			local f = assert(mesh.faces[fid], "Unknown selected face")
			for i, a in f.vertices do
				if not map[a] then
					map[a] = out:addVertex(mesh.vertices[a] + offset)
					out.weights[map[a]] = U.copy(mesh.weights[a])
					maps.vertex[map[a]] = { ref(a) }
				end
				local b = f.vertices[i % #f.vertices + 1]
				local k = U.edge(a, b)
				if boundary[k] then
					boundary[k] = false
				else
					boundary[k] = { a, b, fid, i }
				end
			end
		end
	end
	for fid in selected do
		if selected[fid] then
			local f = mesh.faces[fid]
			for i, a in f.vertices do
				local b = f.vertices[i % #f.vertices + 1]
				maps.edge[U.edge(map[a], map[b])] = { ref(U.edge(a, b)) }
			end
		end
	end
	for fid in selected do
		if selected[fid] then
			local f = out.faces[fid]
			for i, v in f.vertices do
				f.vertices[i] = map[v]
			end
		end
	end
	for _, edge in boundary do
		if edge then
			local a, b = edge[1], edge[2]
			local sourceId, i = edge[3], edge[4]
			local face = mesh.faces[sourceId]
			local j = i % #face.vertices + 1
			local fid = out:addFace(
				{ a, b, map[b], map[a] },
				{ face.corners[i], face.corners[j], face.corners[j], face.corners[i] },
				face.material
			)
			maps.face[fid] = { ref(sourceId) }
			for k, c in { i, j, j, i } do
				maps.corner[cornerKey(fid, k)] = { ref(cornerKey(sourceId, c)) }
			end
		end
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	return out:removeUnused():recalculateNormals(), map
end
function T.insetFaces(mesh, selected, fraction)
	assert(fraction > 0 and fraction < 1, "Inset fraction must be between zero and one")
	local out = mesh:clone()
	local maps = { vertex = {}, edge = {}, face = {}, corner = {} }
	for _, fid in U.keys(selected) do
		if selected[fid] then
			local f = mesh.faces[fid]
			local center = Vector3.zero
			for _, v in f.vertices do
				center += mesh.vertices[v]
			end
			center /= #f.vertices
			local inner, innerCorners, innerRefs = {}, {}, {}
			for i, v in f.vertices do
				inner[i] = out:addVertex(mesh.vertices[v]:Lerp(center, fraction))
				local vertexRefs, cornerRefs, localRefs = {}, {}, {}
				for j, other in f.vertices do
					local weight = fraction / #f.vertices + (i == j and 1 - fraction or 0)
					table.insert(vertexRefs, ref(other, weight))
					table.insert(cornerRefs, ref(cornerKey(fid, j), weight))
					table.insert(localRefs, ref(j, weight))
				end
				maps.vertex[inner[i]] = vertexRefs
				innerRefs[i] = cornerRefs
				innerCorners[i] = mixCorners(f, localRefs)
				maps.corner[cornerKey(fid, i)] = cornerRefs
			end
			out.faces[fid].vertices = inner
			out.faces[fid].corners = innerCorners
			for i, a in f.vertices do
				local j = i % #f.vertices + 1
				local ringId = out:addFace(
					{ a, f.vertices[j], inner[j], inner[i] },
					{ f.corners[i], f.corners[j], innerCorners[j], innerCorners[i] },
					f.material
				)
				maps.face[ringId] = { ref(fid) }
				maps.corner[cornerKey(ringId, 1)] = { ref(cornerKey(fid, i)) }
				maps.corner[cornerKey(ringId, 2)] = { ref(cornerKey(fid, j)) }
				maps.corner[cornerKey(ringId, 3)] = innerRefs[j]
				maps.corner[cornerKey(ringId, 4)] = innerRefs[i]
				maps.edge[U.edge(inner[i], inner[j])] = { ref(U.edge(a, f.vertices[j])) }
			end
		end
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	return out:recalculateNormals()
end
function T.bridge(mesh, loopA, loopB)
	assert(#loopA == #loopB and #loopA >= 3, "Bridge requires equally sampled loops")
	local out = mesh:clone()
	for i, a in loopA do
		local j = i % #loopA + 1
		out:addFace({ a, loopA[j], loopB[j], loopB[i] })
	end
	return out:recalculateNormals()
end
function T.fill(mesh, loop)
	local out = mesh:clone()
	out:addFace(loop)
	return out:recalculateNormals()
end
function T.splitEdge(mesh, a, b, t)
	t = t or 0.5
	assert(t > 0 and t < 1)
	assert(mesh:topology().edges[U.edge(a, b)], "Edge not found")
	local out = mesh:clone()
	local id = out:addVertex(mesh.vertices[a]:Lerp(mesh.vertices[b], t))
	local maps = {
		vertex = { [id] = { ref(a, 1 - t), ref(b, t) } },
		edge = { [U.edge(a, id)] = { ref(U.edge(a, b)) }, [U.edge(id, b)] = { ref(U.edge(a, b)) } },
		corner = {},
		identity = { corner = false },
	}
	for fid, f in out.faces do
		local inserted = nil

		for i, v in f.vertices do
			local j = i % #f.vertices + 1
			local w = f.vertices[j]
			if (v == a and w == b) or (v == b and w == a) then
				local fct = v == a and t or 1 - t
				inserted = { i, j, fct }
				local corner = {}
				for k, x in f.corners[i] do
					local y = f.corners[j][k]
					if
						y
						and (
							typeof(x) == "Vector2"
							or typeof(x) == "Vector3"
							or typeof(x) == "Color3"
							or type(x) == "number"
						)
					then
						corner[k] = U.mix(x, y, fct)
					end
				end
				table.insert(f.vertices, i + 1, id)
				table.insert(f.corners, i + 1, corner)
				break
			end
		end
		for k = 1, #f.vertices do
			if inserted and k == inserted[1] + 1 then
				maps.corner[cornerKey(fid, k)] = {
					ref(cornerKey(fid, inserted[1]), 1 - inserted[3]),
					ref(cornerKey(fid, inserted[2]), inserted[3]),
				}
			else
				local old = inserted and k > inserted[1] + 1 and k - 1 or k
				maps.corner[cornerKey(fid, k)] = { ref(cornerKey(fid, old)) }
			end
		end
	end
	A.transfer(mesh, out, maps)
	A.vertexData(mesh, out, maps.vertex)
	return out:recalculateNormals(), id
end
function T.dissolveEdge(mesh, a, b)
	local edge = mesh:topology().edges[U.edge(a, b)]
	assert(edge and #edge.faces == 2, "Dissolve requires two incident faces")
	local fa, fb = mesh.faces[edge.faces[1]], mesh.faces[edge.faces[2]]
	assert(fa.material == fb.material, "Material boundary cannot be dissolved")
	local na = mesh:faceNormal(edge.faces[1])
	local nb = mesh:faceNormal(edge.faces[2])
	assert(na:Dot(nb) > 1 - 1e-6, "Dissolve requires coplanar faces")
	local successors, corners, cornerRefs = {}, {}, {}
	for k, f in { fa, fb } do
		for i, v in f.vertices do
			local nextId = f.vertices[i % #f.vertices + 1]
			if U.edge(v, nextId) ~= U.edge(a, b) then
				assert(not successors[v], "Faces share more than one edge")
				successors[v] = nextId
				corners[v] = f.corners[i]
				cornerRefs[v] = cornerKey(edge.faces[k], i)
			end
		end
	end
	local start = U.keys(successors)[1]
	local loop, attrs, seen = {}, {}, {}
	local current = start
	repeat
		assert(current and not seen[current], "Boundary does not form a single loop")
		seen[current] = true
		table.insert(loop, current)
		table.insert(attrs, corners[current])
		current = successors[current]
	until current == start
	assert(#loop == U.count(successors), "Dissolve would produce holes")
	local out = mesh:clone()
	out.faces[edge.faces[1]] = nil
	out.faces[edge.faces[2]] = nil
	local fid = out:addFace(loop, attrs, fa.material)
	local maps = { face = { [fid] = { ref(edge.faces[1]), ref(edge.faces[2]) } }, corner = {} }
	for i, v in loop do
		maps.corner[cornerKey(fid, i)] = { ref(cornerRefs[v]) }
	end
	A.transfer(mesh, out, maps)
	return out:removeUnused():recalculateNormals()
end
return T
