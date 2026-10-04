-- Private bounded graph queries over a detached Connectivity index.
local U = require(script.Parent.Util)
local Connectivity = require(script.Parent.Connectivity)
local function active(value)
	return value == true or (type(value) == "number" and value > 0)
end
local function prepare(mesh, options)
	options = options or {}
	assert(
		options.faceStepping == nil or type(options.faceStepping) == "boolean",
		"Face stepping must be boolean"
	)
	assert(options.cost == nil or type(options.cost) == "function", "Path cost must be a function")
	local index = Connectivity.index(mesh, options)
	local domain = options.domain or "vertex"
	assert(domain == "vertex" or domain == "edge" or domain == "face", "Unknown traversal domain")
	local nodes = domain == "vertex" and index.vertices or (domain == "edge" and index.edges or index.faces)
	local blocked, barriers = options.blocked or {}, options.blockedEdges or {}
	for key, value in blocked do
		assert(
			nodes[key] and (type(value) == "boolean" or type(value) == "number"),
			"Invalid blocked element"
		)
	end
	for key, value in barriers do
		assert(
			index.edges[key] and (type(value) == "boolean" or type(value) == "number"),
			"Invalid blocked edge"
		)
	end
	local positions = {}
	for key, node in nodes do
		if domain == "vertex" then
			local p = node.position
			positions[key] = { p.X, p.Y, p.Z }
		else
			local vs = domain == "edge" and { node.a, node.b } or node.vertices
			local x, y, z = 0, 0, 0
			for _, v in vs do
				local p = index.vertices[v].position
				x += p.X / #vs
				y += p.Y / #vs
				z += p.Z / #vs
			end
			positions[key] = { x, y, z }
		end
	end
	local function permitted(key)
		return not active(blocked[key]) and not (domain == "edge" and active(barriers[key]))
	end
	local function neighbors(key, visit)
		local result = {}
		local function add(other)
			visit()
			if other ~= key and permitted(other) then
				result[other] = true
			end
		end
		if domain == "vertex" then
			if options.faceStepping then
				for _, ck in nodes[key].corners do
					for _, v in index.faces[index.corners[ck].face].vertices do
						add(v)
					end
				end
			end
			for _, ek in nodes[key].edges do
				visit()
				if not active(barriers[ek]) then
					local e = index.edges[ek]
					add(e.a == key and e.b or e.a)
				end
			end
			-- Explicit barriers still prevent their direct endpoint transition.
			for _, ek in nodes[key].edges do
				if active(barriers[ek]) then
					local e = index.edges[ek]
					result[e.a == key and e.b or e.a] = nil
				end
			end
		elseif domain == "edge" then
			local e = nodes[key]
			if options.faceStepping then
				for _, fid in e.faces do
					local f = index.faces[fid]
					if #f.corners == 4 then
						for i, ck in f.corners do
							if index.corners[ck].edge == key then
								add(index.corners[f.corners[(i + 1) % 4 + 1]].edge)
							end
						end
					end
				end
			else
				for _, v in { e.a, e.b } do
					for _, ek in index.vertices[v].edges do
						add(ek)
					end
				end
			end
		else
			local f = nodes[key]
			for _, ck in f.corners do
				local h = index.corners[ck]
				if options.faceStepping then
					-- Diagonal face hops stay inside the vertex fan cut by barriers.
					local queue, seen, cursor = { key }, { [key] = true }, 1
					while cursor <= #queue do
						local current = index.faces[queue[cursor]]
						cursor += 1
						local ci = table.find(current.vertices, h.vertex)
						local c = index.corners[current.corners[ci]]
						for _, ek in { c.edge, index.corners[c.previous].edge } do
							visit()
							if not active(barriers[ek]) then
								for _, fid in index.edges[ek].faces do
									visit()
									if not seen[fid] and permitted(fid) then
										seen[fid] = true
										table.insert(queue, fid)
										add(fid)
									end
								end
							end
						end
					end
				elseif not active(barriers[h.edge]) then
					for _, fid in index.edges[h.edge].faces do
						add(fid)
					end
				end
			end
		end
		return U.keys(result)
	end
	local metric = options.metric or "length"
	assert(metric == "length" or metric == "hops", "Unknown path metric")
	local function cost(a, b)
		local length = 1
		if metric == "length" then
			local p, q = positions[a], positions[b]
			local x, y, z = p[1] - q[1], p[2] - q[2], p[3] - q[3]
			length = math.sqrt(x * x + y * y + z * z)
		end
		if options.cost then
			length = options.cost(a, b, length)
		end
		assert(
			type(length) == "number" and U.finite(length) and length >= 0,
			"Path costs must be finite and nonnegative"
		)
		return length
	end
	return {
		index = index,
		nodes = nodes,
		domain = domain,
		neighbors = neighbors,
		cost = cost,
		permitted = permitted,
	}
end
local function search(graph, seeds, target, options)
	options = options or {}
	local maxVisited = U.integer(options.maxVisited or 250000, 1)
	local maxWork = U.integer(options.maxWork or 5000000, 1)
	local radius = options.radius or math.huge
	assert(type(radius) == "number" and radius >= 0 and radius == radius, "Invalid traversal radius")
	local heap, distance, parent, settled = {}, {}, {}, {}
	local function less(a, b)
		return a.distance < b.distance or (a.distance == b.distance and a.key < b.key)
	end
	local function push(key, value)
		local item = { key = key, distance = value }
		table.insert(heap, item)
		local i = #heap
		while i > 1 do
			local p = math.floor(i / 2)
			if not less(item, heap[p]) then
				break
			end
			heap[i] = heap[p]
			i = p
		end
		heap[i] = item
	end
	local function pop()
		local first = heap[1]
		local tail = table.remove(heap)
		if #heap > 0 then
			local i = 1
			while i * 2 <= #heap do
				local child = i * 2
				if child < #heap and less(heap[child + 1], heap[child]) then
					child += 1
				end
				if not less(heap[child], tail) then
					break
				end
				heap[i] = heap[child]
				i = child
			end
			heap[i] = tail
		end
		return first
	end
	local report = {
		complete = true,
		found = false,
		visited = 0,
		work = 0,
		distances = {},
		predecessors = parent,
		selection = {},
		path = {},
	}
	local exhausted = {}
	local function visit()
		report.work += 1
		if report.work > maxWork then
			error(exhausted)
		end
		if options.checkpoint and report.work % 256 == 0 then
			options.checkpoint(math.min(1, report.visited / maxVisited))
		end
	end
	if options.checkpoint then
		options.checkpoint(0)
	end
	for _, key in U.keys(seeds) do
		if active(seeds[key]) then
			assert(graph.nodes[key], "Unknown traversal seed")
			if graph.permitted(key) then
				distance[key] = 0
				push(key, 0)
			end
		end
	end
	if target ~= nil then
		assert(graph.nodes[target], "Unknown traversal target")
	end
	local ok, err = pcall(function()
		while #heap > 0 do
			visit()
			local entry = pop()
			local key = entry.key
			if not settled[key] and entry.distance == distance[key] then
				if report.visited >= maxVisited then
					report.complete = false
					report.reason = "visit_budget"
					break
				end
				settled[key] = true
				report.visited += 1
				report.distances[key] = entry.distance
				report.selection[key] = true
				if key == target then
					report.found = true
					report.distance = entry.distance
					break
				end
				for _, other in graph.neighbors(key, visit) do
					local d = entry.distance + graph.cost(key, other)
					assert(U.finite(d), "Path distance overflow")
					if not settled[other] and d <= radius and d < (distance[other] or math.huge) then
						distance[other] = d
						parent[other] = key
						push(other, d)
					end
				end
			end
		end
	end)
	if not ok then
		if err == exhausted then
			report.complete = false
			report.reason = "work_budget"
		else
			error(err, 0)
		end
	end
	if report.found then
		local key = target
		while key ~= nil do
			table.insert(report.path, key)
			key = parent[key]
		end
		local path = {}
		for i = #report.path, 1, -1 do
			table.insert(path, report.path[i])
		end
		report.path = path
		report.selection = {}
		for _, id in path do
			report.selection[id] = true
		end
	elseif target ~= nil then
		report.selection = {}
		if report.complete then
			report.reason = "unreachable"
		end
	end
	return report
end
return { prepare = prepare, search = search, active = active }
