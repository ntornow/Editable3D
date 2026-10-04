-- Bounded local triangle refinement and split/collapse/flip isotropic remeshing.
local U = require(script.Parent.Util)
local Topology = require(script.Parent.Topology)
local Spatial = require(script.Parent.Spatial)
local Attributes = require(script.Parent.AttributeCore)
local Patch = require(script.Parent.AttributePatch)
local Seams = require(script.Parent.AttributeSeams)
local CollapseTransfer = require(script.Parent.CollapseTransfer)
local A = {}
local function mixMap(a, b, t)
	local out = {}
	for k, v in a or {} do
		out[k] = v * (1 - t)
	end
	for k, v in b or {} do
		out[k] = (out[k] or 0) + v * t
	end
	return out
end
local function corner(a, b)
	local c = U.copy(a)
	for k, v in b do
		local av = a[k]
		if av ~= nil and typeof(av) == typeof(v) then
			local kind = typeof(v)
			if kind == "number" or kind == "Vector2" or kind == "Vector3" or kind == "Color3" then
				c[k] = U.mix(av, v, 0.5)
			end
		end
	end
	if c.normal then
		c.normal = U.unit(c.normal)
	end
	return c
end
local function selected(options, p)
	if not options.region then
		return true
	end
	local value = options.region(p)
	return value == true or (type(value) == "number" and value > 0)
end
local function targetAt(target, p)
	local value = type(target) == "function" and target(p) or target
	assert(
		type(value) == "number" and U.finite(value) and value > 0,
		"Target length must be positive and finite"
	)
	return value
end
local function split(mesh, e)
	local maps = { vertex = {}, edge = {}, face = {}, corner = {} }
	local removed = { edge = { [U.edge(e.a, e.b)] = true }, face = {}, corner = {} }
	local id = mesh:addVertex((mesh.vertices[e.a] + mesh.vertices[e.b]) / 2)
	maps.vertex[id] = { { e.a, 0.5 }, { e.b, 0.5 } }
	maps.edge[U.edge(e.a, id)], maps.edge[U.edge(id, e.b)] =
		{ { U.edge(e.a, e.b), 1 } }, { { U.edge(e.a, e.b), 1 } }
	mesh.weights[id] = mixMap(mesh.weights[e.a], mesh.weights[e.b], 0.5)
	for _, g in mesh.groups do
		g[id] = ((g[e.a] or 0) + (g[e.b] or 0)) / 2
	end
	for _, fid in e.faces do
		local f = mesh.faces[fid]
		for i = 1, 3 do
			local j, k = i % 3 + 1, (i + 1) % 3 + 1
			local a, b, c = f.vertices[i], f.vertices[j], f.vertices[k]
			if U.edge(a, b) == U.edge(e.a, e.b) then
				local middle = corner(f.corners[i], f.corners[j])
				mesh.faces[fid] = nil
				local left = mesh:addFace({ a, id, c }, { f.corners[i], middle, f.corners[k] }, f.material)
				local right = mesh:addFace({ id, b, c }, { middle, f.corners[j], f.corners[k] }, f.material)
				maps.face[left], maps.face[right] = { { fid, 1 } }, { { fid, 1 } }
				local va, vb, vc =
					{ { fid .. ":" .. i, 1 } }, { { fid .. ":" .. j, 1 } }, { { fid .. ":" .. k, 1 } }
				local vm = { { fid .. ":" .. i, 0.5 }, { fid .. ":" .. j, 0.5 } }
				maps.corner[left .. ":1"], maps.corner[left .. ":2"], maps.corner[left .. ":3"] = va, vm, vc
				maps.corner[right .. ":1"], maps.corner[right .. ":2"], maps.corner[right .. ":3"] =
					vm, vb, vc
				removed.face[fid] = true
				for slot = 1, 3 do
					removed.corner[fid .. ":" .. slot] = true
				end
				break
			end
		end
	end
	Patch(mesh, maps, removed)(mesh)
	return id
end
local function protection(mesh, topology, options)
	local locked, boundary = Seams.locked(mesh, topology, options), {}
	for _, e in topology.edges do
		if #e.faces ~= 2 then
			boundary[e.a], boundary[e.b] = true, true
			if options.preserveBoundary ~= false then
				locked[e.a], locked[e.b] = true, true
			end
		elseif options.sharpAngle ~= false then
			local n1, n2 = mesh:faceNormal(e.faces[1]), mesh:faceNormal(e.faces[2])
			if n1:Dot(n2) < math.cos(options.sharpAngle or math.rad(50)) then
				locked[e.a], locked[e.b] = true, true
			end
		end
	end
	for id, p in mesh.vertices do
		if not selected(options, p) then
			locked[id] = true
		end
	end
	return locked, boundary
end
local function collapse(mesh, e, topology, position, options)
	local common = 0
	for id in topology.neighbors[e.a] do
		if topology.neighbors[e.b][id] then
			common += 1
		end
	end
	if common ~= #e.faces then
		return false
	end
	local remove = {}
	for _, fid in e.faces do
		remove[fid] = true
	end
	local affected = {}
	for _, id in { e.a, e.b } do
		for _, fid in topology.vertexFaces[id] do
			affected[fid] = true
		end
	end
	local canonical = {}
	for fid, f in mesh.faces do
		if not remove[fid] then
			local vs = table.clone(f.vertices)
			for i, v in vs do
				if v == e.b then
					vs[i] = e.a
				end
			end
			local sorted = table.clone(vs)
			table.sort(sorted)
			local key = table.concat(sorted, ":")
			if canonical[key] then
				return false
			end
			canonical[key] = true
			if affected[fid] then
				local ps = {}
				for i, id in vs do
					ps[i] = id == e.a and position or mesh.vertices[id]
				end
				local n = (ps[2] - ps[1]):Cross(ps[3] - ps[1])
				local old = mesh:faceNormal(fid)
				if n.Magnitude < 1e-12 or n.Unit:Dot(old) < (options.minimumNormalDot or 0.2) then
					return false
				end
			end
		end
	end
	local transfer = CollapseTransfer(mesh, e.a, e.b, 0.5, topology, options)
	for fid in affected do
		if remove[fid] then
			mesh.faces[fid] = nil
		else
			local f = mesh.faces[fid]
			for i, id in f.vertices do
				if id == e.a or id == e.b then
					f.vertices[i] = e.a
				end
			end
		end
	end
	mesh.vertices[e.a] = position
	mesh.vertices[e.b] = nil
	transfer(mesh)
	mesh.revision += 1
	return true
end
local function flip(mesh, e, topology, boundary, locked, options)
	if #e.faces ~= 2 then
		return false
	end
	local f, g = mesh.faces[e.faces[1]], mesh.faces[e.faces[2]]
	if f.material ~= g.material then
		return false
	end
	local a, b, c, d, ca, cb, cc, cd
	local ia, ib, ic, idCorner
	for i, id in f.vertices do
		local j, k = i % 3 + 1, (i + 1) % 3 + 1
		if U.edge(id, f.vertices[j]) == U.edge(e.a, e.b) then
			a, b, c = id, f.vertices[j], f.vertices[k]
			ca, cb, cc = f.corners[i], f.corners[j], f.corners[k]
			ia, ib, ic = i, j, k
			break
		end
	end
	for i, vertex in g.vertices do
		if vertex ~= a and vertex ~= b then
			d, cd, idCorner = vertex, g.corners[i], i
		end
	end
	if not d or locked[c] or locked[d] or topology.edges[U.edge(c, d)] then
		return false
	end
	local valence, target = {}, {}
	for _, id in { a, b, c, d } do
		valence[id] = U.count(topology.neighbors[id])
		target[id] = boundary[id] and 4 or 6
	end
	local before, after = 0, 0
	for _, id in { a, b, c, d } do
		before += (valence[id] - target[id]) ^ 2
		local change = (id == a or id == b) and -1 or 1
		after += (valence[id] + change - target[id]) ^ 2
	end
	if after >= before then
		return false
	end
	local pa, pb, pc, pd = mesh.vertices[a], mesh.vertices[b], mesh.vertices[c], mesh.vertices[d]
	local n1, n2 = (pd - pc):Cross(pb - pc), (pc - pd):Cross(pa - pd)
	local old1, old2 = mesh:faceNormal(e.faces[1]), mesh:faceNormal(e.faces[2])
	if n1.Magnitude < 1e-12 or n2.Magnitude < 1e-12 then
		return false
	end
	if
		math.min(n1.Unit:Dot(old1), n1.Unit:Dot(old2), n2.Unit:Dot(old1), n2.Unit:Dot(old2))
		< (options.minimumNormalDot or 0.2)
	then
		return false
	end
	mesh.faces[e.faces[1]] = nil
	mesh.faces[e.faces[2]] = nil
	local left = mesh:addFace({ c, d, b }, { cc, cd, cb }, f.material)
	local right = mesh:addFace({ d, c, a }, { cd, cc, ca }, f.material)
	local maps = { face = {}, corner = {} }
	local faceRefs = { { e.faces[1], 0.5 }, { e.faces[2], 0.5 } }
	maps.face[left], maps.face[right] = faceRefs, faceRefs
	local ra, rb, rc, rd =
		{ { e.faces[1] .. ":" .. ia, 1 } },
		{ { e.faces[1] .. ":" .. ib, 1 } },
		{ { e.faces[1] .. ":" .. ic, 1 } },
		{ { e.faces[2] .. ":" .. idCorner, 1 } }
	maps.corner[left .. ":1"], maps.corner[left .. ":2"], maps.corner[left .. ":3"] = rc, rd, rb
	maps.corner[right .. ":1"], maps.corner[right .. ":2"], maps.corner[right .. ":3"] = rd, rc, ra
	local removed = { edge = { [U.edge(a, b)] = true }, face = {}, corner = {} }
	for _, fid in e.faces do
		removed.face[fid] = true
		for i = 1, 3 do
			removed.corner[fid .. ":" .. i] = true
		end
	end
	Patch(mesh, maps, removed)(mesh)
	return true
end
local function refineInPlace(mesh, target, options, report)
	local limit = U.integer(options.maxOperations or 5000, 1)
	local threshold = options.splitThreshold or 4 / 3
	assert(U.finite(threshold) and threshold > 0, "Positive split threshold required")
	local edges = mesh:topology().edges
	local heap = {}
	local function higher(a, b)
		return a.ratio == b.ratio and a.key < b.key or a.ratio > b.ratio
	end
	local function enqueue(key, e)
		local a, b = mesh.vertices[e.a], mesh.vertices[e.b]
		local p = (a + b) / 2
		if not selected(options, p) then
			return
		end
		local ratio = (b - a).Magnitude / targetAt(target, p)
		if ratio <= threshold then
			return
		end
		local item = { key = key, edge = e, ratio = ratio }
		local index = #heap + 1
		while index > 1 do
			local parent = math.floor(index / 2)
			if not higher(item, heap[parent]) then
				break
			end
			heap[index] = heap[parent]
			index = parent
		end
		heap[index] = item
	end
	local function pop()
		local first, last = heap[1], table.remove(heap)
		if #heap > 0 then
			local index = 1
			while index * 2 <= #heap do
				local child = index * 2
				if child < #heap and higher(heap[child + 1], heap[child]) then
					child += 1
				end
				if not higher(heap[child], last) then
					break
				end
				heap[index] = heap[child]
				index = child
			end
			heap[index] = last
		end
		return first
	end
	for key, e in edges do
		enqueue(key, e)
	end
	while report.operations < limit and #heap > 0 do
		local candidate = pop()
		local best = candidate.edge
		if edges[candidate.key] ~= best then
			continue
		end
		local oldFaces = {}
		for _, fid in best.faces do
			oldFaces[fid] = mesh.faces[fid]
		end
		local firstNewFace = mesh.nextFace
		split(mesh, best)
		for fid, face in oldFaces do
			for i, a in face.vertices do
				local key = U.edge(a, face.vertices[i % 3 + 1])
				local edge = edges[key]
				table.remove(edge.faces, assert(table.find(edge.faces, fid)))
				if #edge.faces == 0 then
					edges[key] = nil
				end
			end
		end
		local fresh = {}
		for fid = firstNewFace, mesh.nextFace - 1 do
			local face = mesh.faces[fid]
			for i, a in face.vertices do
				local b = face.vertices[i % 3 + 1]
				local key = U.edge(a, b)
				local edge = edges[key]
				if not edge then
					edge = { a = math.min(a, b), b = math.max(a, b), faces = {} }
					edges[key] = edge
					fresh[key] = edge
				end
				table.insert(edge.faces, fid)
			end
		end
		for key, e in fresh do
			enqueue(key, e)
		end
		report.splits += 1
		report.operations += 1
		if report.operations % 32 == 0 then
			assert(not options.cancelled or not options.cancelled(), "Adaptive remesh cancelled")
			if options.yieldEvery then
				task.wait()
			end
		end
	end
	report.budgetReached = report.operations >= limit
end
function A.refine(mesh, targetLength, options)
	options = options or {}
	Attributes.validate(mesh)
	assert(not options.cancelled or not options.cancelled(), "Adaptive remesh cancelled")
	local valid = mesh:validate()
	assert(valid.valid and valid.windingErrors == 0, "Adaptive refinement requires oriented manifold input")
	local out = Topology.triangulate(mesh)
	local report = { operations = 0, splits = 0, budgetReached = false }
	refineInPlace(out, targetLength, options, report)
	Attributes.validate(out)
	report.validation = out:validate()
	return out, report
end
function A.remesh(mesh, targetLength, options)
	options = options or {}
	Attributes.validate(mesh)
	assert(not options.cancelled or not options.cancelled(), "Adaptive remesh cancelled")
	local valid = mesh:validate()
	assert(valid.valid and valid.windingErrors == 0, "Adaptive remesh requires oriented manifold input")
	local out = Topology.triangulate(mesh)
	local reference = Spatial.new(options.reference or mesh)
	local report = { operations = 0, splits = 0, collapses = 0, flips = 0, budgetReached = false }
	local limit = U.integer(options.maxOperations or 5000, 1)
	for _ = 1, U.integer(options.iterations or 3, 1) do
		refineInPlace(out, targetLength, options, report)
		while report.operations < limit do
			local topology = out:topology()
			local locked = protection(out, topology, options)
			local candidates = {}
			for key, e in topology.edges do
				if not locked[e.a] and not locked[e.b] then
					local p = (out.vertices[e.a] + out.vertices[e.b]) / 2
					local ratio = (out.vertices[e.a] - out.vertices[e.b]).Magnitude
						/ targetAt(targetLength, p)
					if ratio < (options.collapseThreshold or 0.8) then
						table.insert(candidates, { edge = e, position = p, ratio = ratio, key = key })
					end
				end
			end
			table.sort(candidates, function(a, b)
				return a.ratio == b.ratio and a.key < b.key or a.ratio < b.ratio
			end)
			local accepted = false
			for _, c in candidates do
				local position = options.project == false and c.position
					or reference:closest(c.position).position
				if collapse(out, c.edge, topology, position, options) then
					report.collapses += 1
					report.operations += 1
					accepted = true
					break
				end
			end
			if not accepted then
				break
			end
			assert(not options.cancelled or not options.cancelled(), "Adaptive remesh cancelled")
			if options.yieldEvery and report.operations % 32 == 0 then
				task.wait()
			end
		end
		if options.flip ~= false then
			while report.operations < limit do
				local topology = out:topology()
				local locked, boundary = protection(out, topology, options)
				local changed = false
				for _, key in U.keys(topology.edges) do
					local e = topology.edges[key]
					if
						not locked[e.a]
						and not locked[e.b]
						and flip(out, e, topology, boundary, locked, options)
					then
						report.flips += 1
						report.operations += 1
						changed = true
						break
					end
				end
				if not changed then
					break
				end
			end
		end
		local topology = out:topology()
		local locked = protection(out, topology, options)
		for _, id in U.keys(out.vertices) do
			if not locked[id] and (options.relaxation or 0.3) > 0 then
				local p = out.vertices[id]
				local sum, n, count = Vector3.zero, Vector3.zero, 0
				for other in topology.neighbors[id] do
					sum += out.vertices[other]
					count += 1
				end
				for _, fid in topology.vertexFaces[id] do
					local normal, area = out:faceNormal(fid)
					n += normal * area
				end
				n = U.unit(n)
				local delta = sum / count - p
				delta -= n * delta:Dot(n)
				local proposal = p + delta * (options.relaxation or 0.3)
				if options.project ~= false then
					proposal = reference:closest(proposal).position
				end
				local oldNormals = {}
				for _, fid in topology.vertexFaces[id] do
					oldNormals[fid] = out:faceNormal(fid)
				end
				out.vertices[id] = proposal
				for fid, normal in oldNormals do
					local changed, area = out:faceNormal(fid)
					if area < 1e-12 or changed:Dot(normal) < (options.minimumNormalDot or 0.2) then
						out.vertices[id] = p
						break
					end
				end
			end
		end
		if report.operations >= limit then
			report.budgetReached = true
			break
		end
	end
	out:removeUnused():recalculateNormals()
	Attributes.validate(out)
	report.validation = out:validate()
	assert(
		report.validation.valid and report.validation.windingErrors == 0,
		"Adaptive remesh failed topology validation"
	)
	return out, report
end
return A
