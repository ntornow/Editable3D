-- Private geometric limit evaluator. No scene objects or attribute interpolation.
local U = require(script.Parent.Util)
local Feature = require(script.Parent.SubdivisionFeaturePatch)
local L = {}
local EPS = 2.220446049250313e-16
local function decay(x)
	return x == 10 and 10 or math.max(0, x - 1)
end
local function topology(m)
	local t = { edges = {}, neighbors = {}, vertexFaces = {} }
	for id in m.vertices do
		t.neighbors[id], t.vertexFaces[id] = {}, {}
	end
	for fid, face in m.faces do
		for i, a in face do
			local b = face[i % #face + 1]
			local key = U.edge(a, b)
			local e = t.edges[key]
			if not e then
				e = { a = a, b = b, faces = {} }
				t.edges[key] = e
			end
			table.insert(e.faces, fid)
			t.neighbors[a][b], t.neighbors[b][a] = true, true
			table.insert(t.vertexFaces[a], fid)
		end
	end
	return t
end
local function blend(points, weights)
	local p = { 0, 0, 0, 0 }
	local magnitude = 0
	for i, q in points do
		local w = weights and weights[i] or 1 / #points
		for k = 1, 3 do
			p[k] += q[k] * w
			magnitude += math.abs(q[k] * w)
		end
		p[4] += math.abs(w) * q[4]
	end
	-- Bounds all scalar products/sums, plus rounded coefficients, in this stencil.
	p[4] += (8 * #points + 16) * EPS * magnitude
	return p
end
local function native(p, optional)
	local value = Vector3.new(p[1], p[2], p[3])
	if optional and not U.vector(value) then
		return nil, math.huge
	end
	assert(
		U.finite(value.X) and U.finite(value.Y) and U.finite(value.Z),
		"Limit position exceeds native range"
	)
	local error = math.sqrt((value.X - p[1]) ^ 2 + (value.Y - p[2]) ^ 2 + (value.Z - p[3]) ^ 2)
	return value, p[4] + error
end
local function crop(m, target, top, work)
	local faces, frontier = { [target] = true }, { target }
	-- Four vertex-adjacency rings leave a full mask halo after each 2:1 refinement.
	for _ = 1, 4 do
		local nextFrontier = {}
		for _, fid in frontier do
			for _, v in m.faces[fid] do
				for _, other in top.vertexFaces[v] do
					work(1)
					if not faces[other] then
						faces[other] = true
						table.insert(nextFrontier, other)
					end
				end
			end
		end
		frontier = nextFrontier
	end
	local out = { vertices = {}, faces = {}, edges = {}, sharp = {} }
	for fid in faces do
		out.faces[fid] = m.faces[fid]
		for i, v in m.faces[fid] do
			out.vertices[v], out.sharp[v] = m.vertices[v], m.sharp[v]
			local key = U.edge(v, m.faces[fid][i % #m.faces[fid] + 1])
			out.edges[key] = m.edges[key]
		end
	end
	if m.normalHistory then
		out.normalHistory = { previous = m.normalHistory, faces = out.faces }
	end
	return out
end
local function refine(m, cfg, work)
	local top = topology(m)
	local count = 0
	for _, f in m.faces do
		count += #f
	end
	assert(
		count <= cfg.maxFaces
			and U.count(m.vertices) + U.count(top.edges) + U.count(m.faces) <= cfg.maxVertices,
		"Limit local allocation budget exceeded"
	)
	local fp, ep, vp, childEdges, childSharp = {}, {}, {}, {}, {}
	for fid, f in m.faces do
		local points = {}
		for _, v in f do
			table.insert(points, m.vertices[v])
		end
		fp[fid] = blend(points)
		work(#f)
	end
	local sharpEdges = {}
	for key, e in top.edges do
		local sharp = #e.faces == 1 and 10 or (m.edges[key] or 0)
		sharpEdges[key] = sharp
		local mid = blend({ m.vertices[e.a], m.vertices[e.b] })
		local smooth = #e.faces == 2
				and blend({ m.vertices[e.a], m.vertices[e.b], fp[e.faces[1]], fp[e.faces[2]] })
			or mid
		local a = math.min(sharp, 1)
		ep[key] = blend({ smooth, mid }, { 1 - a, a })
		work(8)
	end
	for v, p in m.vertices do
		local ns, fs, boundary, finiteSum, finiteCount =
			U.keys(top.neighbors[v]), top.vertexFaces[v], {}, 0, 0
		for _, other in ns do
			local key = U.edge(v, other)
			if #top.edges[key].faces == 1 then
				table.insert(boundary, other)
			end
			local s = sharpEdges[key]
			if s > 0 and s < 10 then
				finiteSum += s
				finiteCount += 1
			end
		end
		local sharp = m.sharp[v] or 0
		if #boundary > 0 and (cfg.boundary == "fixed" or (cfg.boundary == "edgeAndCorner" and #fs == 1)) then
			sharp = 10
		end
		childSharp[v] = decay(sharp)
		local children, parentNeighbors, childNeighbors, sum, n = {}, {}, {}, 0, 0
		childEdges[v] = children
		if sharp > 0 and childSharp[v] == 0 then
			sum += sharp
			n += 1
		end
		for _, other in ns do
			local s = sharpEdges[U.edge(v, other)]
			local c = decay(s)
			if cfg.creasing == "chaikin" and s > 0 and s < 10 and finiteCount > 1 then
				c = math.max(0, (3 * s + (finiteSum - s) / (finiteCount - 1)) / 4 - 1)
			end
			children[other] = c
			if s > 0 then
				table.insert(parentNeighbors, other)
			end
			if c > 0 then
				table.insert(childNeighbors, other)
			end
			if s > 0 and c == 0 then
				sum += s
				n += 1
			end
		end
		local smooth = p
		if #boundary == 2 then
			smooth = blend({ p, m.vertices[boundary[1]], m.vertices[boundary[2]] }, { 0.75, 0.125, 0.125 })
		elseif #boundary == 0 and #ns >= 2 then
			local points, weights = { p }, { (#ns - 2) / #ns }
			for _, other in ns do
				table.insert(points, m.vertices[other])
				table.insert(weights, 1 / (#ns * #ns))
			end
			for _, fid in fs do
				table.insert(points, fp[fid])
				table.insert(weights, 1 / (#ns * #fs))
			end
			smooth = blend(points, weights)
		end
		local function mask(s, neighbors)
			if s > 0 or #neighbors > 2 then
				return p
			end
			if #neighbors == 2 then
				return blend(
					{ p, m.vertices[neighbors[1]], m.vertices[neighbors[2]] },
					{ 0.75, 0.125, 0.125 }
				)
			end
			return smooth
		end
		local alpha = n == 0 and 0 or math.min(1, sum / n)
		vp[v] = blend(
			{ mask(childSharp[v], childNeighbors), mask(sharp, parentNeighbors) },
			{ 1 - alpha, alpha }
		)
		work(8 * (#ns + #fs + 1))
	end
	local out = { vertices = {}, faces = {}, edges = {}, sharp = {} }
	local vids, eids, fids, children = {}, {}, {}, {}
	local function add(p)
		local id = #out.vertices + 1
		out.vertices[id] = p
		return id
	end
	for _, id in U.keys(vp) do
		vids[id] = add(vp[id])
		out.sharp[vids[id]] = childSharp[id]
	end
	for _, key in U.keys(ep) do
		eids[key] = add(ep[key])
	end
	for _, fid in U.keys(fp) do
		fids[fid] = add(fp[fid])
	end
	for key, e in top.edges do
		out.edges[U.edge(vids[e.a], eids[key])] = childEdges[e.a][e.b]
		out.edges[U.edge(vids[e.b], eids[key])] = childEdges[e.b][e.a]
	end
	for _, fid in U.keys(m.faces) do
		local f = m.faces[fid]
		children[fid] = {}
		for i, v in f do
			local id = #out.faces + 1
			out.faces[id] =
				{ vids[v], eids[U.edge(v, f[i % #f + 1])], fids[fid], eids[U.edge(f[(i - 2) % #f + 1], v)] }
			children[fid][i] = id
		end
	end
	if m.normalHistory then
		out.normalHistory = { previous = m.normalHistory }
	end
	return out, children
end
local function regular(m, top, fid)
	local face = m.faces[fid]
	if #face ~= 4 then
		return nil
	end
	for _, v in face do
		if (m.sharp[v] or 0) > 0 or U.count(top.neighbors[v]) ~= 4 or #top.vertexFaces[v] ~= 4 then
			return nil
		end
		for other in top.neighbors[v] do
			local key = U.edge(v, other)
			if #top.edges[key].faces ~= 2 or (m.edges[key] or 0) > 0 then
				return nil
			end
		end
		for _, f in top.vertexFaces[v] do
			if #m.faces[f] ~= 4 then
				return nil
			end
		end
	end
	local positions =
		{ [face[1]] = { 1, 1 }, [face[2]] = { 2, 1 }, [face[3]] = { 2, 2 }, [face[4]] = { 1, 2 } }
	local grid, seen, queue = {}, { [fid] = true }, { fid }
	local cursor = 1
	while cursor <= #queue do
		local f = m.faces[queue[cursor]]
		cursor += 1
		for i, a in f do
			local b = f[i % 4 + 1]
			local pa, pb = positions[a], positions[b]
			if not pa or not pb then
				return nil
			end
			if pa[1] >= 0 and pa[1] <= 3 and pa[2] >= 0 and pa[2] <= 3 then
				local key = pa[1] .. ":" .. pa[2]
				if grid[key] and grid[key] ~= a then
					return nil
				end
				grid[key] = a
			end
			local dx, dy = pb[1] - pa[1], pb[2] - pa[2]
			local pc, pd = { pa[1] + dy, pa[2] - dx }, { pb[1] + dy, pb[2] - dx }
			if
				pc[1] >= 0
				and pc[1] <= 3
				and pc[2] >= 0
				and pc[2] <= 3
				and pd[1] >= 0
				and pd[1] <= 3
				and pd[2] >= 0
				and pd[2] <= 3
			then
				for _, other in top.edges[U.edge(a, b)].faces do
					if not seen[other] then
						local g = m.faces[other]
						if #g ~= 4 then
							return nil
						end
						local j = table.find(g, b)
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
						seen[other] = true
						table.insert(queue, other)
					end
				end
			end
		end
	end
	if U.count(grid) ~= 16 then
		return nil
	end
	return grid
end
local function basis(t)
	return {
		(1 - t) ^ 3 / 6,
		(3 * t ^ 3 - 6 * t ^ 2 + 4) / 6,
		(-3 * t ^ 3 + 3 * t ^ 2 + 3 * t + 1) / 6,
		t ^ 3 / 6,
	}, {
		-(1 - t) ^ 2 / 2,
		(9 * t ^ 2 - 12 * t) / 6,
		(-9 * t ^ 2 + 6 * t + 3) / 6,
		t ^ 2 / 2,
	}
end
local function normalFromTangents(a, ea, b, eb)
	if not a or not b then
		return nil
	end
	-- Scale before the cross product: native Vector3 crosses overflow at ordinary
	-- large model scales, even when both derivatives and the unit normal fit.
	local scale =
		math.max(math.abs(a.X), math.abs(a.Y), math.abs(a.Z), math.abs(b.X), math.abs(b.Y), math.abs(b.Z))
	local normal, normalError
	if scale > 0 then
		local ax, ay, az, bx, by, bz =
			a.X / scale, a.Y / scale, a.Z / scale, b.X / scale, b.Y / scale, b.Z / scale
		local x, y, z = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
		local length = math.sqrt(x * x + y * y + z * z)
		local uncertainty = (ea / scale) * math.sqrt(bx * bx + by * by + bz * bz)
			+ (eb / scale) * math.sqrt(ax * ax + ay * ay + az * az)
			+ (ea / scale) * (eb / scale)
			+ 32 * EPS
		if length > uncertainty then
			normal = Vector3.new(x / length, y / length, z / length)
			normalError = math.min(2, 2 * uncertainty / length + 2e-7)
		end
	end
	return normal, normalError
end
local function patch(m, grid, u, v, jacobian, controls)
	local bu, du = basis(u)
	local bv, dv = basis(v)
	local points, ws, wu, wv = {}, {}, {}, {}
	for i = 0, 3 do
		for j = 0, 3 do
			table.insert(points, controls and controls[i .. ":" .. j] or m.vertices[grid[i .. ":" .. j]])
			table.insert(ws, bu[i + 1] * bv[j + 1])
			table.insert(wu, du[i + 1] * bv[j + 1] * jacobian[1] + bu[i + 1] * dv[j + 1] * jacobian[3])
			table.insert(wv, du[i + 1] * bv[j + 1] * jacobian[2] + bu[i + 1] * dv[j + 1] * jacobian[4])
		end
	end
	local position, error = native(blend(points, ws))
	local a, ea = native(blend(points, wu), true)
	local b, eb = native(blend(points, wv), true)
	if not a or not b then
		return {
			position = position,
			errorBound = error,
			method = "bicubic",
			derivativesAvailable = false,
			derivativeReason = "Derivatives exceed native range",
		}
	end
	local normal, normalError = normalFromTangents(a, ea, b, eb)
	return {
		position = position,
		errorBound = error,
		derivativeU = a,
		derivativeV = b,
		derivativeErrorU = ea,
		derivativeErrorV = eb,
		normal = normal,
		normalErrorBound = normalError,
		method = "bicubic",
		derivativesAvailable = true,
	}
end
local function chartJet(outgoing, preceding, index, jacobian)
	local result = { derivativesAvailable = false }
	local du, dv
	if index == 1 then
		du, dv = outgoing, preceding
	elseif index == 2 then
		du, dv = blend({ preceding }, { -1 }), outgoing
	elseif index == 3 then
		du, dv = blend({ outgoing }, { -1 }), blend({ preceding }, { -1 })
	else
		du, dv = preceding, blend({ outgoing }, { -1 })
	end
	local derivativeU, errorU = native(blend({ du, dv }, { jacobian[1], jacobian[3] }), true)
	local derivativeV, errorV = native(blend({ du, dv }, { jacobian[2], jacobian[4] }), true)
	if derivativeU and derivativeV then
		result.derivativeU, result.derivativeV = derivativeU, derivativeV
		result.derivativeErrorU, result.derivativeErrorV = errorU, errorV
		result.derivativesAvailable = true
	else
		result.derivativeReason = "Derivatives exceed native range"
	end
	return result
end
local function regularVertexJet(m, top, vertex, target, index, jacobian, work)
	if (m.sharp[vertex] or 0) > 0 or #top.vertexFaces[vertex] ~= 4 or U.count(top.neighbors[vertex]) ~= 4 then
		return nil
	end
	for other in top.neighbors[vertex] do
		local key = U.edge(vertex, other)
		if #top.edges[key].faces ~= 2 or (m.edges[key] or 0) > 0 then
			return nil
		end
	end
	local byEdge = {}
	for _, fid in top.vertexFaces[vertex] do
		local face = m.faces[fid]
		if #face ~= 4 then
			return nil
		end
		local i = assert(table.find(face, vertex))
		byEdge[face[i % 4 + 1]] = { face[(i + 1) % 4 + 1], face[(i + 2) % 4 + 1] }
	end
	local first = m.faces[target][index % 4 + 1]
	local current, seen, edges, diagonals = first, {}, {}, {}
	for i = 1, 4 do
		local pair = byEdge[current]
		if not pair or seen[current] then
			return nil
		end
		seen[current] = true
		edges[i], diagonals[i] = m.vertices[current], m.vertices[pair[1]]
		current = pair[2]
	end
	if current ~= first then
		return nil
	end
	-- Closed valence-four core: the two half-eigenvalue modes reproduce the
	-- affine chart. All remaining modes, including the patch halo, are smaller.
	local du = blend(
		{ edges[1], edges[3], diagonals[1], diagonals[2], diagonals[3], diagonals[4] },
		{ 4 / 12, -4 / 12, 1 / 12, -1 / 12, -1 / 12, 1 / 12 }
	)
	local dv = blend(
		{ edges[2], edges[4], diagonals[1], diagonals[2], diagonals[3], diagonals[4] },
		{ 4 / 12, -4 / 12, 1 / 12, 1 / 12, -1 / 12, -1 / 12 }
	)
	work(128)
	local result = chartJet(du, dv, index, jacobian)
	result.normal, result.normalErrorBound = normalFromTangents(
		result.derivativeU,
		result.derivativeErrorU,
		result.derivativeV,
		result.derivativeErrorV
	)
	result.normalMethod = "regularVertexJet"
	return result
end
local function characteristicNormal(m, top, v)
	local n = #top.vertexFaces[v]
	if n < 3 then
		return nil
	end
	local theta = 2 * math.pi / n
	local c = math.cos(theta)
	local lambda = (5 + c + math.sqrt((c + 9) * (c + 1))) / 16
	local beta = math.cos(theta / 2) / (8 * (lambda - 0.25))
	local byEdge = {}
	for _, fid in top.vertexFaces[v] do
		local f = m.faces[fid]
		local i = table.find(f, v)
		byEdge[f[i % 4 + 1]] = { f[(i + 1) % 4 + 1], f[(i + 2) % 4 + 1] }
	end
	local current = U.keys(byEdge)[1]
	local points, cosine, sine = {}, {}, {}
	for i = 0, n - 1 do
		local pair = byEdge[current]
		table.insert(points, m.vertices[current])
		table.insert(cosine, math.cos(i * theta))
		table.insert(sine, math.sin(i * theta))
		table.insert(points, m.vertices[pair[1]])
		table.insert(cosine, beta * math.cos((i + 0.5) * theta))
		table.insert(sine, beta * math.sin((i + 0.5) * theta))
		current = pair[2]
	end
	local a, ea = native(blend(points, cosine), true)
	local b, eb = native(blend(points, sine), true)
	return normalFromTangents(a, ea, b, eb)
end
local function vertexLimit(m, top, v)
	local ns, hard = {}, {}
	if (m.sharp[v] or 0) > 0 and m.sharp[v] ~= 10 then
		return nil
	end
	for other in top.neighbors[v] do
		local key = U.edge(v, other)
		local s = #top.edges[key].faces == 1 and 10 or (m.edges[key] or 0)
		if s > 0 and s ~= 10 then
			return nil
		end
		table.insert(ns, other)
		if s == 10 then
			table.insert(hard, other)
		end
	end
	if m.sharp[v] == 10 or #hard > 2 then
		return m.vertices[v]
	end
	if #hard == 2 then
		return blend({ m.vertices[v], m.vertices[hard[1]], m.vertices[hard[2]] }, { 4 / 6, 1 / 6, 1 / 6 })
	end
	if #hard > 0 or #ns < 2 or #ns ~= #top.vertexFaces[v] then
		return nil
	end
	local n = #ns
	local points, weights = { m.vertices[v] }, { n / (n + 5) }
	for _, other in ns do
		table.insert(points, m.vertices[other])
		table.insert(weights, 4 / (n * (n + 5)))
	end
	for _, fid in top.vertexFaces[v] do
		local f = m.faces[fid]
		if #f ~= 4 then
			return nil
		end
		local i = table.find(f, v)
		table.insert(points, m.vertices[f[(i + 1) % 4 + 1]])
		table.insert(weights, 1 / (n * (n + 5)))
	end
	local normal, normalError = characteristicNormal(m, top, v)
	return blend(points, weights), normal, normalError
end
local function featureVertex(m, top, vertex, target, index, jacobian, work, options, config)
	local sector, pending = Feature.sector(m, top, vertex, target, work)
	if not sector or sector.closed then
		return nil, pending
	end
	local p, edges, diagonals = m.vertices[vertex], {}, {}
	for _, v in sector.edges do
		table.insert(edges, m.vertices[v])
	end
	for _, v in sector.diagonals do
		table.insert(diagonals, m.vertices[v])
	end
	-- If E0+E2=2P exactly, the fixed and crease vertex masks both retain P.
	-- Sharp boundary edge children (P+Ei)/2 preserve that identity at every
	-- refinement, so this two-face sector has the ordinary crease's finite jet.
	local exactFixedCrease = sector.kind == "corner"
		and sector.count == 2
		and Feature.originalMidpoint(p, edges[1], edges[#edges], work)
	local outgoing, preceding, firstTangent, secondTangent
	local method
	if sector.kind == "corner" and sector.count == 1 then
		outgoing = blend({ edges[1], p }, { 1, -1 })
		preceding = blend({ edges[2], p }, { 1, -1 })
		firstTangent, secondTangent, method = outgoing, preceding, "fixedCornerSector"
	elseif sector.kind == "corner" and sector.count == 2 and not exactFixedCrease then
		-- The fixed two-face operator has one size-two Jordan block at 1/2.
		-- Its generalized mode is along S=A+B-2P, and its eigenfunction is
		-- the regular transverse coordinate Y. The other surviving direction
		-- is the regular boundary coordinate X. The full 15-control annular
		-- operator gives (du cross dv)/k -> ((A-P) cross (B-P))/6 uniformly;
		-- all other modes have modulus at most 1/4. A nonzero bounded cross
		-- product therefore certifies the oriented normal, without finite jets.
		firstTangent = blend({ edges[1], p }, { 1, -1 })
		secondTangent = blend({ edges[#edges], p }, { 1, -1 })
		method = "fixedCornerJordan"
		if
			Feature.originalCollinear(p, edges[1], edges[#edges], work)
			and Feature.originalOpposed(p, edges[1], edges[#edges], work)
		then
			-- Here s=c*t with |c|<2. The generalized scalar annular mode
			-- satisfies |dw/dx|<=1/2, from its exact control differences and
			-- positive one-sided cubic weights. The limiting cross product is
			-- (t cross a)*(1+c*dw/dx), with a strictly positive scalar factor.
			firstTangent = blend({ edges[1], edges[#edges] }, { 0.5, -0.5 })
			secondTangent = blend({ p, edges[2], diagonals[1], diagonals[2] }, { -1, 2 / 3, 1 / 6, 1 / 6 })
			method = "fixedCollinearJordan"
		end
	elseif
		sector.count == 3
		and (
			sector.kind == "crease"
			or sector.kind == "corner" and Feature.originalMidpoint(p, edges[1], edges[4], work)
		)
	then
		-- The complete21-control annular operator has leading nonconstant
		-- eigenvalues lambda=(11+sqrt57)/32 and1/2. All324 Bernstein
		-- coefficients of the9 annular characteristic Jacobians are positive.
		-- Hence the oriented normal converges uniformly to T cross V.
		firstTangent = blend({ edges[1], edges[4] }, { 0.5, -0.5 })
		local points = { p, edges[1], edges[2], edges[3], edges[4], diagonals[1], diagonals[2], diagonals[3] }
		local base = blend(
			points,
			{ -16 / 114, 18 / 114, 12 / 114, 12 / 114, 18 / 114, -11 / 114, -22 / 114, -11 / 114 }
		)
		local coefficient = blend(
			points,
			{ -64 / 114, -80 / 114, 48 / 114, 48 / 114, -80 / 114, 32 / 114, 64 / 114, 32 / 114 }
		)
		local I = require(script.Parent.DirectedInterval)
		local interval = I.div(I.add({ 11, 11 }, I.sqrt({ 57, 57 })), { 32, 32 })
		local lambda = (interval[1] + interval[2]) / 2
		local radius = math.max(lambda - interval[1], interval[2] - lambda)
		secondTangent = blend({ base, coefficient }, { 1, lambda })
		secondTangent[4] += radius * (math.abs(coefficient[1]) + math.abs(coefficient[2]) + math.abs(
			coefficient[3]
		) + coefficient[4])
		method = sector.kind == "corner" and "fixedMidpointThreeSector" or "creaseThreeSector"
		if Feature.originalThreeTransverseZero(p, edges, diagonals, work) then
			-- With the growing transverse mode exactly absent, X is affine
			-- in each original face and all remaining modes decay faster than1/2.
			local face = assert(table.find(sector.faces, target))
			local slopes = { { 1, 1 }, { 1, -1 }, { -1, -1 } }
			outgoing = blend({ firstTangent }, { slopes[face][1] })
			preceding = blend({ firstTangent }, { slopes[face][2] })
			secondTangent = { 0, 0, 0, 0 }
		end
	elseif (sector.kind == "crease" and sector.count <= 2) or exactFixedCrease then
		local t = blend({ edges[1], edges[#edges] }, { 0.5, -0.5 })
		firstTangent = t
		method = exactFixedCrease and "fixedMidpointCrease" or "creaseCharacteristic"
		if sector.count == 1 then
			-- The two chart partials coincide up to sign. The next, repeated
			-- eigenvalue is 1/4; its Jordan mode supplies the limiting plane.
			outgoing, preceding = t, blend({ t }, { -1 })
			secondTangent = blend({ edges[1], edges[2], p }, { 1, 1, -2 })
		else
			local cross = blend(
				{ p, edges[1], edges[2], edges[3], diagonals[1], diagonals[2] },
				{ -4 / 6, -1 / 6, 4 / 6, -1 / 6, 1 / 6, 1 / 6 }
			)
			secondTangent = cross
			if sector.faces[1] == target then
				outgoing, preceding = t, cross
			else
				outgoing, preceding = cross, blend({ t }, { -1 })
			end
		end
	end
	local certificate
	if options.exactConstrainedJets and not outgoing then
		local jets
		jets, certificate =
			require(script.Parent.ConstrainedJetCertificate)(p, edges, diagonals, sector.kind, options, work)
		if jets then
			local face = assert(table.find(sector.faces, target))
			outgoing, preceding = jets[face], jets[face + 1]
			firstTangent, secondTangent = outgoing, preceding
			method = "exactConstrainedJets"
		end
	end
	local normal, normalError
	if firstTangent then
		work(16 * (#edges + #diagonals + 1))
		local a, ea = native(firstTangent, true)
		local b, eb = native(secondTangent, true)
		normal, normalError = normalFromTangents(a, ea, b, eb)
		if
			not normal
			and sector.kind == "crease"
			and sector.count == 1
			and Feature.originalCollinear(p, edges[1], edges[2], work)
		then
			local nextMode, nextError = native(blend({ diagonals[1], p }, { 1, -1 }), true)
			normal, normalError = normalFromTangents(a, ea, nextMode, nextError)
		end
	end
	local normalCertificate
	if options.exactConstrainedNormals and not normal then
		normal, normalCertificate = require(script.Parent.ConstrainedNormalCertificate)(
			m,
			top,
			sector,
			vertex,
			target,
			config,
			options,
			work
		)
		if normal then
			normalError, method = normalCertificate.normalErrorBound, "exactConstrainedNormals"
		end
	end
	local result: { [string]: any } = {
		oneSided = true,
		normal = normal,
		normalErrorBound = normalError,
		normalMethod = method,
		constrainedJetCertificate = certificate,
		constrainedNormalCertificate = normalCertificate,
		normalReason = not normal and normalCertificate and normalCertificate.reason or nil,
		normalSectorFaces = sector.count,
		derivativesAvailable = false,
	}
	if outgoing then
		for name, value in chartJet(outgoing, preceding, index, jacobian) do
			result[name] = value
		end
	end
	return result
end
local function enclosure(m, top, fid, u, v)
	local f = m.faces[fid]
	local p = blend(
		{ m.vertices[f[1]], m.vertices[f[2]], m.vertices[f[3]], m.vertices[f[4]] },
		{ (1 - u) * (1 - v), u * (1 - v), u * v, (1 - u) * v }
	)
	local position, rounding = native(p)
	local radius, err = 0, 0
	for _, vtx in f do
		for _, other in top.vertexFaces[vtx] do
			for _, id in m.faces[other] do
				local q = m.vertices[id]
				radius =
					math.max(radius, math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2 + (q[3] - p[3]) ^ 2))
				err = math.max(err, q[4])
			end
		end
	end
	return {
		position = position,
		errorBound = radius + rounding + err + 32 * EPS * radius,
		method = "convexHull",
		derivativesAvailable = false,
	}
end
function L.prepare(mesh, options, config, state)
	local tolerance = options.tolerance or 1e-5
	assert(U.finite(tolerance) and tolerance > 0, "Limit tolerance must be finite and positive")
	local maxDepth = U.integer(options.maxDepth or 24, 0)
	assert(maxDepth <= 48, "Limit depth budget must not exceed 48")
	local maxWork = U.integer(options.maxWork or 20000000, 1)
	local maxQueries = U.integer(options.maxQueries or 10000, 1)
	assert(
		U.count(mesh.vertices) <= config.maxVertices and U.count(mesh.faces) <= config.maxFaces,
		"Limit input allocation budget exceeded"
	)
	local original =
		{ vertices = {}, faces = {}, edges = U.copy(state.edges), sharp = U.copy(state.vertices) }
	for id, p in mesh.vertices do
		original.vertices[id] = { p.X, p.Y, p.Z, 0 }
	end
	for fid, f in mesh.faces do
		original.faces[fid] = table.clone(f.vertices)
	end
	local initialTop = topology(original)
	for _, e in initialTop.edges do
		assert(#e.faces <= 2, "Limit evaluation requires manifold edges")
	end
	local totalWork, queries = 0, 0
	local nextNormalCheckpoint = 262144
	local function work(n)
		totalWork += n
		assert(totalWork <= maxWork, "Limit work budget exceeded")
		assert(not options.cancelled or not options.cancelled(), "Limit evaluation cancelled")
		if
			(options.exactConstrainedNormals or options.exactPolynomialNormals)
			and options.checkpoint
			and totalWork >= nextNormalCheckpoint
		then
			nextNormalCheckpoint = totalWork + 262144
			options.checkpoint({ stage = "exactNormalWork", work = totalWork })
		end
	end
	local evaluator = {}
	function evaluator:evaluate(fid, u, v, corner)
		U.integer(fid, 1)
		local face = assert(original.faces[fid], "Unknown limit face")
		assert(
			U.finite(u) and U.finite(v) and u >= 0 and u <= 1 and v >= 0 and v <= 1,
			"Limit parameters must be in [0,1]"
		)
		if corner ~= nil then
			U.integer(corner, 1)
			assert(corner <= #face, "Unknown limit corner patch")
		else
			assert(#face == 4, "Nonquad limit faces require a corner patch")
		end
		queries += 1
		assert(queries <= maxQueries, "Limit query budget exceeded")
		local before = totalWork
		work(1)
		local m = crop(original, fid, initialTop, work)
		if options.exactConstrainedNormals or options.exactPolynomialNormals then
			m.normalHistory = {
				initial = {
					vertices = m.vertices,
					faces = m.faces,
					edges = m.edges,
					sharp = m.sharp,
				},
			}
		end
		local target, jacobian, depth = fid, { 1, 0, 0, 1 }, 0
		if corner then
			local children
			m, children = refine(m, config, work)
			target = children[target][corner]
		end
		local result
		while true do
			local top = topology(m)
			work(U.count(m.vertices) + U.count(m.faces))
			local grid = regular(m, top, target)
			local controls = not grid and Feature.controls(m, top, target, blend, work) or nil
			if grid or controls then
				result = patch(m, grid, u, v, jacobian, controls)
				if controls then
					result.method, result.oneSided = "bicubicOneSided", true
				end
				if options.exactPolynomialNormals and not result.normal then
					local certificate
					result.normal, certificate = require(script.Parent.PolynomialNormalCertificate)(
						m,
						top,
						target,
						grid,
						u,
						v,
						jacobian,
						config,
						options,
						work
					)
					result.polynomialNormalCertificate = certificate
					result.normalErrorBound = certificate.normalErrorBound
					result.normalReason = certificate.reason
					result.normalMethod = "exactPolynomialNormals"
					if u == 0 or u == 1 or v == 0 or v == 1 then
						result.oneSided = true
					end
				end
				break
			end
			local index = (u == 0 and v == 0) and 1
				or (u == 1 and v == 0) and 2
				or (u == 1 and v == 1) and 3
				or (u == 0 and v == 1) and 4
				or nil
			local point, normal, normalError
			if index then
				point, normal, normalError = vertexLimit(m, top, m.faces[target][index])
			end
			local refineFeature = false
			if point then
				local p, e = native(point)
				result = {
					position = p,
					errorBound = e,
					method = "vertexMask",
					derivativesAvailable = false,
					normal = normal,
					normalErrorBound = normalError,
				}
				local jet = regularVertexJet(m, top, m.faces[target][index], target, index, jacobian, work)
				if jet then
					for name, value in jet do
						result[name] = value
					end
					result.normal, result.normalErrorBound = jet.normal, jet.normalErrorBound
				elseif not normal then
					local feature, pending = featureVertex(
						m,
						top,
						m.faces[target][index],
						target,
						index,
						jacobian,
						work,
						options,
						config
					)
					refineFeature = pending == "nonquad" and depth < maxDepth
					if feature then
						for name, value in feature do
							result[name] = value
						end
					end
				end
				if not refineFeature then
					break
				end
			end
			if not refineFeature then
				result = enclosure(m, top, target, u, v)
				if result.errorBound <= tolerance or depth == maxDepth then
					break
				end
			end
			if options.checkpoint then
				options.checkpoint({
					stage = "limit",
					depth = depth,
					work = totalWork,
					face = fid,
					errorBound = result.errorBound,
				})
			end
			local quadrant, a, b, c, d
			if u <= 0.5 and v <= 0.5 then
				quadrant = 1
				u, v = 2 * u, 2 * v
				a, b, c, d = 2, 0, 0, 2
			elseif u > 0.5 and v <= 0.5 then
				quadrant = 2
				u, v = 2 * v, 2 * (1 - u)
				a, b, c, d = 0, 2, -2, 0
			elseif u > 0.5 then
				quadrant = 3
				u, v = 2 * (1 - u), 2 * (1 - v)
				a, b, c, d = -2, 0, 0, -2
			else
				quadrant = 4
				u, v = 2 * (1 - v), 2 * u
				a, b, c, d = 0, -2, 2, 0
			end
			jacobian = {
				a * jacobian[1] + b * jacobian[3],
				a * jacobian[2] + b * jacobian[4],
				c * jacobian[1] + d * jacobian[3],
				c * jacobian[2] + d * jacobian[4],
			}
			local children
			m, children = refine(m, config, work)
			target = children[target][quadrant]
			m = crop(m, target, topology(m), work)
			depth += 1
		end
		result.complete = result.errorBound <= tolerance
		result.success = result.complete
		result.reason = result.complete and "tolerance"
			or (result.method == "convexHull" and "maxDepth" or "precision")
		result.face, result.corner, result.depth, result.work = fid, corner, depth, totalWork - before
		result.tolerance = tolerance
		if not result.derivativesAvailable and not result.derivativeReason then
			result.derivativeReason = "No applicable finite derivative stencil at this query"
		end
		result.normalAvailable = result.normal ~= nil
		if not result.normal and not result.normalReason then
			result.normalReason = "Degenerate, numerically unresolved or unsupported limit tangent plane"
		end
		assert(
			not options.requireComplete or result.complete,
			"Limit query did not meet tolerance: " .. result.reason
		)
		return result
	end
	function evaluator:statistics()
		return { work = totalWork, queries = queries }
	end
	return evaluator
end
return L
