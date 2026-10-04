-- Exact Catmull-Clark refinement with deterministic local identifiers.
local U = require(script.Parent.Util)
return function(R, work)
	local one, zero, ten = R.number(1), R.number(0), R.number(10)
	local function min(a, b)
		return R.compare(a, b) <= 0 and a or b
	end
	local function max(a, b)
		return R.compare(a, b) >= 0 and a or b
	end
	local function decay(x)
		return R.equal(x, ten) and ten or max(zero, R.sub(x, one))
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
		local out = { zero, zero, zero }
		for i, p in points do
			local w = weights and weights[i] or R.div(one, R.number(#points))
			if type(w) == "number" then
				w = R.number(w)
			end
			for j = 1, 3 do
				out[j] = R.add(out[j], R.mul(w, p[j]))
			end
		end
		return out
	end
	local function refine(m, cfg, work)
		if cfg.normalAllocate then
			cfg.normalAllocate(20 * (U.count(m.vertices) + U.count(m.faces)))
		end
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
			local sharp = #e.faces == 1 and ten or (m.edges[key] or zero)
			sharpEdges[key] = sharp
			local mid = blend({ m.vertices[e.a], m.vertices[e.b] })
			local smooth = #e.faces == 2
					and blend({ m.vertices[e.a], m.vertices[e.b], fp[e.faces[1]], fp[e.faces[2]] })
				or mid
			local a = min(sharp, one)
			ep[key] = blend({ smooth, mid }, { R.sub(one, a), a })
			work(8)
		end
		for v, p in m.vertices do
			local ns, fs, boundary, finiteSum, finiteCount =
				U.keys(top.neighbors[v]), top.vertexFaces[v], {}, zero, 0
			for _, other in ns do
				local key = U.edge(v, other)
				if #top.edges[key].faces == 1 then
					table.insert(boundary, other)
				end
				local s = sharpEdges[key]
				if s.sign > 0 and R.compare(s, ten) < 0 then
					finiteSum = R.add(finiteSum, s)
					finiteCount += 1
				end
			end
			local sharp = m.sharp[v] or zero
			if
				#boundary > 0 and (cfg.boundary == "fixed" or (cfg.boundary == "edgeAndCorner" and #fs == 1))
			then
				sharp = ten
			end
			childSharp[v] = decay(sharp)
			local children, parentNeighbors, childNeighbors, sum, n = {}, {}, {}, zero, 0
			childEdges[v] = children
			if sharp.sign > 0 and childSharp[v].sign == 0 then
				sum = R.add(sum, sharp)
				n += 1
			end
			for _, other in ns do
				local s = sharpEdges[U.edge(v, other)]
				local c = decay(s)
				if cfg.creasing == "chaikin" and s.sign > 0 and R.compare(s, ten) < 0 and finiteCount > 1 then
					c = max(
						zero,
						R.sub(
							R.div(
								R.add(
									R.mul(R.number(3), s),
									R.div(R.sub(finiteSum, s), R.number(finiteCount - 1))
								),
								R.number(4)
							),
							one
						)
					)
				end
				children[other] = c
				if s.sign > 0 then
					table.insert(parentNeighbors, other)
				end
				if c.sign > 0 then
					table.insert(childNeighbors, other)
				end
				if s.sign > 0 and c.sign == 0 then
					sum = R.add(sum, s)
					n += 1
				end
			end
			local smooth = p
			if #boundary == 2 then
				smooth = blend(
					{ p, m.vertices[boundary[1]], m.vertices[boundary[2]] },
					{ 0.75, 0.125, 0.125 }
				)
			elseif #boundary == 0 and #ns >= 2 then
				local points, weights = { p }, { R.div(R.number(#ns - 2), R.number(#ns)) }
				for _, other in ns do
					table.insert(points, m.vertices[other])
					table.insert(weights, R.div(one, R.number(#ns * #ns)))
				end
				for _, fid in fs do
					table.insert(points, fp[fid])
					table.insert(weights, R.div(one, R.number(#ns * #fs)))
				end
				smooth = blend(points, weights)
			end
			local function mask(s, neighbors)
				if s.sign > 0 or #neighbors > 2 then
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
			local alpha = n == 0 and zero or min(one, R.div(sum, R.number(n)))
			vp[v] = blend(
				{ mask(childSharp[v], childNeighbors), mask(sharp, parentNeighbors) },
				{ R.sub(one, alpha), alpha }
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
				out.faces[id] = {
					vids[v],
					eids[U.edge(v, f[i % #f + 1])],
					fids[fid],
					eids[U.edge(f[(i - 2) % #f + 1], v)],
				}
				children[fid][i] = id
			end
		end
		return out, children
	end

	local function snapshot(source)
		local m = { vertices = {}, faces = {}, edges = U.copy(source.edges), sharp = U.copy(source.sharp) }
		for _, values in { m.edges, m.sharp } do
			for id, s in values do
				values[id] = R.number(s)
			end
		end
		for id, p in source.vertices do
			if p[4] ~= 0 then
				return nil, "uncertainControls"
			end
			m.vertices[id] = { R.number(p[1]), R.number(p[2]), R.number(p[3]) }
		end
		for id, f in source.faces do
			m.faces[id] = table.clone(f)
		end
		return m
	end
	return { refine = refine, snapshot = snapshot, topology = topology }
end
