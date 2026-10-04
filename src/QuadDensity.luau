-- Conforming longest-edge refinement in immutable integer source-triangle charts.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Corner = require(script.Parent.MeshEditCore).corner
local E = require(script.Parent.ExpansionArithmetic)
local I = require(script.Parent.DirectedInterval)
local Q = require(script.Parent.QuadGeometry)
local G = require(script.Parent.PlanarReduceGeometry)
local R = {}
function R.pointError(source, fid, uv, den, p)
	local vertices = source.faces[fid].vertices
	local w = { den - uv[1] - uv[2], uv[1], uv[2] }
	local sum = { 0, 0 }
	for axis, value in { p.X, p.Y, p.Z } do
		local total = { 0 }
		for i, id in vertices do
			local q = source.vertices[id]
			local x = axis == 1 and q.X or axis == 2 and q.Y or q.Z
			total = E.add(total, E.multiply({ x }, { w[i] }))
		end
		local delta = E.subtract(total, E.multiply({ value }, { den }))
		if E.sign(delta) ~= 0 then
			local interval = { 0, 0 }
			for _, x in delta do
				interval = I.add(interval, { x, x })
			end
			sum = I.add(sum, I.square(I.div(interval, { den, den })))
		end
	end
	return sum[2] == 0 and 0 or I.sqrt(sum)[2]
end
function R.refine(source, target, context)
	local options, visit = context.options, context.visit
	local denominator = 2 ^ options.maxDepth
	local mesh = source:clone()
	local refs, edges, origins, heap = {}, {}, {}, {}
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = { vertex = true, edge = false, face = false, corner = false },
	}
	local vertices, faces = U.count(mesh.vertices), U.count(mesh.faces)
	local function higher(a, b)
		visit(1)
		return a.ratio == b.ratio and a.key < b.key or a.ratio > b.ratio
	end
	local function push(entry)
		table.insert(heap, entry)
		local i = #heap
		while i > 1 do
			local p = math.floor(i / 2)
			if not higher(heap[i], heap[p]) then
				break
			end
			heap[i], heap[p] = heap[p], heap[i]
			i = p
		end
	end
	local function pop()
		local first, last = heap[1], table.remove(heap)
		if #heap > 0 then
			heap[1] = last
			local i = 1
			while 2 * i <= #heap do
				local j = 2 * i
				if j < #heap and higher(heap[j + 1], heap[j]) then
					j += 1
				end
				if not higher(heap[j], heap[i]) then
					break
				end
				heap[j], heap[i] = heap[i], heap[j]
				i = j
			end
		end
		return first
	end
	local function attach(fid)
		local f = mesh.faces[fid]
		for i, a in f.vertices do
			visit(1)
			local b = f.vertices[i % 3 + 1]
			local key = U.edge(a, b)
			local edge = edges[key]
			if not edge then
				local point = Q.mean(mesh, { a, b })
				local length = target and target(point) or math.huge
				edge = {
					key = key,
					a = a,
					b = b,
					point = point,
					faces = {},
					ratio = Q.length(mesh.vertices[a], mesh.vertices[b]) / length,
				}
				edges[key] = edge
				push(edge)
			end
			edge.faces[fid] = true
		end
	end
	local function detach(fid)
		for i, a in mesh.faces[fid].vertices do
			visit(1)
			local key = U.edge(a, mesh.faces[fid].vertices[i % 3 + 1])
			local edge = edges[key]
			edge.faces[fid] = nil
			if not next(edge.faces) then
				edges[key] = nil
			end
		end
		mesh.faces[fid], refs[fid] = nil, nil
	end
	for _, fid in U.keys(source.faces) do
		local f = source.faces[fid]
		assert(#f.vertices == 3, "Density source must be triangulated")
		refs[fid] = { face = fid, uv = { { 0, 0 }, { denominator, 0 }, { 0, denominator } }, depth = 0 }
		for i, a in f.vertices do
			local key = U.edge(a, f.vertices[i % 3 + 1])
			origins[key] = key
		end
		attach(fid)
	end
	local function weights(fid, uv, domain)
		local w = { denominator - uv[1] - uv[2], uv[1], uv[2] }
		local result = {}
		for i, id in source.faces[fid].vertices do
			if w[i] > 0 then
				table.insert(result, { domain == "vertex" and id or fid .. ":" .. i, w[i] })
			end
		end
		return result
	end
	local operations, rejections = 0, {}
	while #heap > 0 and operations < options.maxSplits do
		visit(1)
		local best = pop()
		if edges[best.key] ~= best or best.blocked then
			continue
		end
		if best.ratio <= options.splitThreshold then
			break
		end
		local ids = U.keys(best.faces)
		local reason
		for _, fid in ids do
			if refs[fid].depth >= options.maxDepth then
				reason = "depth"
			end
		end
		if best.point == mesh.vertices[best.a] or best.point == mesh.vertices[best.b] then
			reason = "nativePrecision"
		end
		if reason then
			best.blocked = reason
			rejections[reason] = (rejections[reason] or 0) + 1
			continue
		end
		context.allocation(vertices + 1, faces + #ids, 3 * (faces + #ids), faces + #ids)
		local middle = mesh:addVertex(best.point)
		vertices += 1
		faces += #ids
		origins[U.edge(best.a, middle)], origins[U.edge(middle, best.b)] =
			origins[best.key], origins[best.key]
		local children = {}
		for _, fid in ids do
			local face, ref = mesh.faces[fid], refs[fid]
			for i, a in face.vertices do
				local j, k = i % 3 + 1, (i + 1) % 3 + 1
				local b, c = face.vertices[j], face.vertices[k]
				if U.edge(a, b) ~= best.key then
					continue
				end
				local ua, ub, uc = ref.uv[i], ref.uv[j], ref.uv[k]
				local um = { (ua[1] + ub[1]) / 2, (ua[2] + ub[2]) / 2 }
				assert(um[1] % 1 == 0 and um[2] % 1 == 0, "Nonintegral density chart")
				maps.vertex[middle] = maps.vertex[middle] or weights(ref.face, um, "vertex")
				for _, child in
					{
						{ ids = { a, middle, c }, uv = { ua, um, uc } },
						{ ids = { middle, b, c }, uv = {
							um,
							ub,
							uc,
						} },
					}
				do
					local id = mesh:addFace(child.ids)
					refs[id] = { face = ref.face, uv = child.uv, depth = ref.depth + 1 }
					table.insert(children, id)
				end
				break
			end
			detach(fid)
		end
		for _, fid in children do
			attach(fid)
		end
		operations += 1
		context.checkpoint("density", { splits = operations, faces = faces })
	end
	local maximum, areas, normalAngle = 0, {}, 0
	for _, fid in U.keys(mesh.faces) do
		visit(1)
		local face, ref = mesh.faces[fid], refs[fid]
		local a, b, c = ref.uv[1], ref.uv[2], ref.uv[3]
		local area = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
		assert(area > 0, "Reversed density chart")
		areas[ref.face] = (areas[ref.face] or 0) + area
		maps.face[fid] = { { ref.face, 1 } }
		face.material = source.faces[ref.face].material
		for i, id in face.vertices do
			visit(1)
			maximum =
				math.max(maximum, R.pointError(source, ref.face, ref.uv[i], denominator, mesh.vertices[id]))
			local cr = weights(ref.face, ref.uv[i], "corner")
			maps.corner[fid .. ":" .. i] = cr
			local intrinsic = {}
			for _, r in cr do
				local slot = tonumber(string.match(r[1], ":(%d+)$"))
				table.insert(intrinsic, { ref.face, slot, r[2] })
			end
			face.corners[i] = Corner(source, intrinsic)
			face.corners[i].normal, face.corners[i].tangent = nil, nil
		end
		local sn = G.plane(source, source.faces[ref.face].vertices, visit)
		local tn = G.plane(mesh, face.vertices, visit)
		if not sn or not tn then
			return nil, { reason = "degenerateDensityTriangle" }
		end
		normalAngle = math.max(normalAngle, Q.angle(sn, tn))
	end
	for fid in source.faces do
		assert(areas[fid] == denominator ^ 2, "Incomplete density chart")
	end
	local unmet, maxRatio = 0, 0
	for key, edge in edges do
		visit(1)
		if origins[key] then
			maps.edge[key] = { { origins[key], 1 } }
		end
		maxRatio = math.max(maxRatio, edge.ratio)
		if edge.ratio > options.splitThreshold then
			unmet += 1
		end
	end
	context.transfer(source, mesh, maps)
	A.vertexData(source, mesh, maps.vertex)
	return mesh,
		{
			complete = unmet == 0,
			operations = operations,
			errorBound = maximum,
			maximumNormalAngle = normalAngle,
			unmetEdges = unmet,
			maxRatio = maxRatio,
			rejections = rejections,
			refs = refs,
			denominator = denominator,
			maps = maps,
		}
end
return R
