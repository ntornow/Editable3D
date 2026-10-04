-- Private one-sided tensor patches. Infinite creases separate face sectors.
local U = require(script.Parent.Util)
local X = require(script.Parent.ExpansionArithmetic)
local F = {}
function F.originalCollinear(p, a, b, work)
	-- Original native controls are exact binary32 inputs. Their differences
	-- and products are safely normal in binary64 expansion arithmetic. Refined
	-- controls have uncertainty and cannot use this exact-identity shortcut.
	if p[4] ~= 0 or a[4] ~= 0 or b[4] ~= 0 then
		return false
	end
	local u, v = {}, {}
	for axis = 1, 3 do
		u[axis] = X.difference(a[axis], p[axis])
		v[axis] = X.difference(b[axis], p[axis])
	end
	for _, pair in { { 1, 2 }, { 2, 3 }, { 3, 1 } } do
		work(32)
		if
			X.sign(X.subtract(X.multiply(u[pair[1]], v[pair[2]]), X.multiply(u[pair[2]], v[pair[1]]))) ~= 0
		then
			return false
		end
	end
	return true
end
function F.originalOpposed(p, a, b, work)
	if p[4] ~= 0 or a[4] ~= 0 or b[4] ~= 0 then
		return false
	end
	local dot = {}
	for axis = 1, 3 do
		work(32)
		dot = X.add(dot, X.multiply(X.difference(a[axis], p[axis]), X.difference(b[axis], p[axis])))
	end
	return X.sign(dot) < 0
end
function F.originalMidpoint(p, a, b, work)
	-- Exact identity only: rounding a+b before halving can erase a nonzero residual.
	-- Refined controls carry uncertainty and cannot use this source-data proof.
	if p[4] ~= 0 or a[4] ~= 0 or b[4] ~= 0 then
		return false
	end
	for axis = 1, 3 do
		work(8)
		if X.sign(X.add(X.difference(a[axis], p[axis]), X.difference(b[axis], p[axis]))) ~= 0 then
			return false
		end
	end
	return true
end
function F.originalThreeTransverseZero(p, edges, diagonals, work)
	local points = { p, edges[1], edges[2], edges[3], edges[4], diagonals[1], diagonals[2], diagonals[3] }
	for _, point in points do
		if point[4] ~= 0 then
			return false
		end
	end
	-- lambda is irrational. Both rational coefficient vectors must vanish.
	for _, weights in { { -16, 18, 12, 12, 18, -11, -22, -11 }, { -64, -80, 48, 48, -80, 32, 64, 32 } } do
		for axis = 1, 3 do
			local sum = {}
			for i, point in points do
				work(16)
				sum = X.add(sum, X.multiply({ point[axis] }, { weights[i] }))
			end
			if X.sign(sum) ~= 0 then
				return false
			end
		end
	end
	return true
end
local function hard(m, top, a, b)
	local key = U.edge(a, b)
	return #top.edges[key].faces == 1 or m.edges[key] == 10
end
function F.sector(m, top, vertex, target, work)
	local sharp = m.sharp[vertex] or 0
	if sharp > 0 and sharp < 10 then
		return nil
	end
	local hardCount = 0
	for other in top.neighbors[vertex] do
		work(1)
		local s = m.edges[U.edge(vertex, other)] or 0
		if s > 0 and s < 10 then
			return nil
		end
		if hard(m, top, vertex, other) then
			hardCount += 1
		end
	end
	local seen, queue, cursor = { [target] = true }, { target }, 1
	local leading, byEdge = nil, {}
	while cursor <= #queue do
		local fid = queue[cursor]
		cursor += 1
		local face = m.faces[fid]
		if #face ~= 4 then
			return nil, "nonquad"
		end
		local i = assert(table.find(face, vertex))
		local a, b = face[i % 4 + 1], face[(i + 2) % 4 + 1]
		byEdge[a] = { diagonal = face[(i + 1) % 4 + 1], next = b, face = fid }
		if hard(m, top, vertex, a) then
			leading = a
		end
		for _, other in { a, b } do
			work(1)
			if not hard(m, top, vertex, other) then
				for _, neighbor in top.edges[U.edge(vertex, other)].faces do
					if not seen[neighbor] then
						seen[neighbor] = true
						table.insert(queue, neighbor)
					end
				end
			end
		end
	end
	local kind = (sharp == 10 or hardCount > 2) and "corner"
		or hardCount == 2 and "crease"
		or hardCount == 0 and "smooth"
		or "dart"
	local result =
		{ kind = kind, count = #queue, closed = leading == nil, edges = {}, diagonals = {}, faces = {} }
	if not leading then
		return result
	end
	local edge = leading
	table.insert(result.edges, edge)
	for _ = 1, #queue do
		local entry = assert(byEdge[edge], "Sharp sector lost oriented incidence")
		table.insert(result.faces, entry.face)
		table.insert(result.diagonals, entry.diagonal)
		edge = entry.next
		table.insert(result.edges, edge)
	end
	assert(hard(m, top, vertex, edge), "Sharp sector lost its trailing boundary")
	return result
end
function F.controls(m, top, fid, blend, work)
	local face = m.faces[fid]
	if #face ~= 4 then
		return nil
	end
	local boundaries, any = {}, false
	for i, a in face do
		boundaries[i] = hard(m, top, a, face[i % 4 + 1])
		any = any or boundaries[i]
	end
	if not any then
		return nil
	end
	for _, vertex in face do
		local sector = F.sector(m, top, vertex, fid, work)
		if not sector then
			return nil
		end
		local regular = sector.kind == "smooth" and sector.closed and sector.count == 4
			or sector.kind == "crease" and not sector.closed and sector.count == 2
			or sector.kind == "corner" and not sector.closed and sector.count == 1
		if not regular then
			return nil
		end
	end
	local minX, maxX = boundaries[4] and 1 or 0, boundaries[2] and 2 or 3
	local minY, maxY = boundaries[1] and 1 or 0, boundaries[3] and 2 or 3
	local function inside(p)
		return p[1] >= minX and p[1] <= maxX and p[2] >= minY and p[2] <= maxY
	end
	local positions =
		{ [face[1]] = { 1, 1 }, [face[2]] = { 2, 1 }, [face[3]] = { 2, 2 }, [face[4]] = { 1, 2 } }
	local grid, queue, seen, cursor = {}, { fid }, { [fid] = true }, 1
	while cursor <= #queue do
		local current = m.faces[queue[cursor]]
		cursor += 1
		for i, a in current do
			work(1)
			local b = current[i % 4 + 1]
			local pa, pb = positions[a], positions[b]
			if not pa or not pb then
				return nil
			end
			if inside(pa) then
				local key = pa[1] .. ":" .. pa[2]
				if grid[key] and grid[key] ~= a then
					return nil
				end
				grid[key] = a
			end
			local dx, dy = pb[1] - pa[1], pb[2] - pa[2]
			local pc, pd = { pa[1] + dy, pa[2] - dx }, { pb[1] + dy, pb[2] - dx }
			if not inside(pc) or not inside(pd) or hard(m, top, a, b) then
				continue
			end
			for _, neighbor in top.edges[U.edge(a, b)].faces do
				if seen[neighbor] then
					continue
				end
				local g = m.faces[neighbor]
				if #g ~= 4 then
					return nil
				end
				local j = assert(table.find(g, b))
				if g[j % 4 + 1] ~= a then
					return nil
				end
				for _, entry in { { g[(j + 1) % 4 + 1], pc }, { g[(j + 2) % 4 + 1], pd } } do
					local old = positions[entry[1]]
					if old and (old[1] ~= entry[2][1] or old[2] ~= entry[2][2]) then
						return nil
					end
					positions[entry[1]] = entry[2]
				end
				seen[neighbor] = true
				table.insert(queue, neighbor)
			end
		end
	end
	local controls = {}
	for i = minX, maxX do
		for j = minY, maxY do
			local key = i .. ":" .. j
			if not grid[key] then
				return nil
			end
			controls[key] = m.vertices[grid[key]]
		end
	end
	local function reflected(a, b)
		work(8)
		return blend({ a, b }, { 2, -1 })
	end
	-- Linear odd extension across each constrained row commutes with uniform
	-- cubic subdivision. It reproduces the crease and fixed-corner masks.
	for j = minY, maxY do
		if minX == 1 then
			controls["0:" .. j] = reflected(controls["1:" .. j], controls["2:" .. j])
		end
		if maxX == 2 then
			controls["3:" .. j] = reflected(controls["2:" .. j], controls["1:" .. j])
		end
	end
	for i = 0, 3 do
		if minY == 1 then
			controls[i .. ":0"] = reflected(controls[i .. ":1"], controls[i .. ":2"])
		end
		if maxY == 2 then
			controls[i .. ":3"] = reflected(controls[i .. ":2"], controls[i .. ":1"])
		end
	end
	return controls
end
return F
