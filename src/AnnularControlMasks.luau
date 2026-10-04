-- Complete stationary open-sector operator and annular Bezier extraction.
return function(R, n, kind, fixedBoundary, visit, allocate)
	local zero, one = R.number(0), R.number(1)
	local fixedStart = type(fixedBoundary) == "table" and fixedBoundary.start or fixedBoundary == true
	local fixedEnd = type(fixedBoundary) == "table" and fixedBoundary.finish or fixedBoundary == true
	local size = 6 * n + 3
	if allocate then
		allocate(size * size + 72 * n * size)
	end
	local function vertex(k, i, j)
		assert(k >= 0 and k < n and i >= 0 and i <= 2 and j >= 0 and j <= 2)
		if i == 0 and j == 0 then
			return 1
		end
		if j == 0 then
			return 2 + 2 * k + i - 1
		end
		if i == 0 then
			return 2 + 2 * (k + 1) + j - 1
		end
		return 2 + 2 * (n + 1) + 4 * k + (j - 1) * 2 + i - 1
	end
	local function blend(rows, weights)
		local out = {}
		for a, row in rows do
			local w = weights and weights[a] or R.div(one, R.number(#rows))
			for i, x in row do
				visit(1)
				out[i] = R.add(out[i] or zero, R.mul(w, x))
			end
		end
		for i, x in out do
			if x.sign == 0 then
				out[i] = nil
			end
		end
		return out
	end
	local function unit(i)
		return { [i] = one }
	end
	local function edge(a, b)
		return math.min(a, b) .. ":" .. math.max(a, b)
	end
	local faces, faceKeys, incident, neighbors, edges = {}, {}, {}, {}, {}
	for i = 1, size do
		incident[i] = {}
		neighbors[i] = {}
	end
	for k = 0, n - 1 do
		for j = 0, 1 do
			for i = 0, 1 do
				local f =
					{ vertex(k, i, j), vertex(k, i + 1, j), vertex(k, i + 1, j + 1), vertex(k, i, j + 1) }
				local id = #faces + 1
				faces[id] = f
				faceKeys[k .. ":" .. i .. ":" .. j] = id
				for a, v in f do
					local w = f[a % 4 + 1]
					table.insert(incident[v], id)
					neighbors[v][w] = true
					neighbors[w][v] = true
					local key = edge(v, w)
					edges[key] = edges[key] or { a = v, b = w, faces = {} }
					table.insert(edges[key].faces, id)
				end
			end
		end
	end
	local fp = {}
	for id, f in faces do
		local rows = {}
		for _, v in f do
			rows[#rows + 1] = unit(v)
		end
		fp[id] = blend(rows)
	end
	local ep = {}
	for key, e in edges do
		local rows = { unit(e.a), unit(e.b) }
		if #e.faces == 2 then
			rows[3] = fp[e.faces[1]]
			rows[4] = fp[e.faces[2]]
		end
		ep[key] = blend(rows)
	end
	local vp = {}
	-- Only old coordinates0..1 are queried; outer-grid boundary masks are unused.
	for v, fs in incident do
		local ns, hard = {}, {}
		for w in neighbors[v] do
			ns[#ns + 1] = w
			if #edges[edge(v, w)].faces == 1 then
				hard[#hard + 1] = w
			end
		end
		if
			v == 1 and kind == "corner"
			or fixedStart and v == vertex(0, 1, 0)
			or fixedEnd and v == vertex(n - 1, 0, 1)
		then
			vp[v] = unit(v)
		elseif #hard == 2 then
			vp[v] = blend(
				{ unit(v), unit(hard[1]), unit(hard[2]) },
				{ R.number(0.75), R.number(0.125), R.number(0.125) }
			)
		else
			local rows, weights = { unit(v) }, { R.div(R.number(#ns - 2), R.number(#ns)) }
			for _, w in ns do
				rows[#rows + 1] = unit(w)
				weights[#weights + 1] = R.div(one, R.number(#ns * #ns))
			end
			for _, f in fs do
				rows[#rows + 1] = fp[f]
				weights[#weights + 1] = R.div(one, R.number(#ns * #fs))
			end
			vp[v] = blend(rows, weights)
		end
	end
	local fine
	fine = function(k, i, j)
		if i < 0 then
			if k < n - 1 then
				return fine(k + 1, j, -i)
			end
			return blend({ fine(k, 0, j), fine(k, -i, j) }, { R.number(2), R.number(-1) })
		end
		if j < 0 then
			if k > 0 then
				return fine(k - 1, -j, i)
			end
			return blend({ fine(k, i, 0), fine(k, i, -j) }, { R.number(2), R.number(-1) })
		end
		local a = vertex(k, math.floor(i / 2), math.floor(j / 2))
		if i % 2 == 1 and j % 2 == 1 then
			return fp[faceKeys[k .. ":" .. math.floor(i / 2) .. ":" .. math.floor(j / 2)]]
		end
		if i % 2 == 1 then
			return ep[edge(a, vertex(k, math.floor(i / 2) + 1, math.floor(j / 2)))]
		end
		if j % 2 == 1 then
			return ep[edge(a, vertex(k, math.floor(i / 2), math.floor(j / 2) + 1))]
		end
		return vp[a]
	end
	local matrix = {}
	for k = 0, n - 1 do
		for j = 0, 2 do
			for i = 0, 2 do
				matrix[vertex(k, i, j)] = fine(k, i, j)
			end
		end
	end
	local C = { { 1, 4, 1, 0 }, { 0, 4, 2, 0 }, { 0, 2, 4, 0 }, { 0, 1, 4, 1 } }
	local patches = {}
	for k = 0, n - 1 do
		for _, cell in { { 1, 0 }, { 1, 1 }, { 0, 1 } } do
			local bezier = {}
			for u = 1, 4 do
				bezier[u] = {}
				for v = 1, 4 do
					local rows, weights = {}, {}
					for i = 1, 4 do
						for j = 1, 4 do
							local w = C[u][i] * C[v][j]
							if w ~= 0 then
								rows[#rows + 1] = fine(k, cell[1] + i - 2, cell[2] + j - 2)
								weights[#weights + 1] = R.div(R.number(w), R.number(36))
							end
						end
					end
					bezier[u][v] = blend(rows, weights)
				end
			end
			local du, dv = {}, {}
			for i = 1, 4 do
				dv[i] = {}
				for j = 1, 3 do
					dv[i][j] = blend({ bezier[i][j + 1], bezier[i][j] }, { R.number(3), R.number(-3) })
				end
			end
			for i = 1, 3 do
				du[i] = {}
				for j = 1, 4 do
					du[i][j] = blend({ bezier[i + 1][j], bezier[i][j] }, { R.number(3), R.number(-3) })
				end
			end
			patches[#patches + 1] = { sector = k + 1, cell = cell, du = du, dv = dv }
		end
	end
	return { size = size, matrix = matrix, patches = patches, vertex = vertex }
end
