-- Private four-sided transfinite quad fill, with explicit boundary correspondence.
local U = require(script.Parent.Util)
local C = require(script.Parent.Connectivity)
local Core = require(script.Parent.MeshEditCore)
return function(mesh, boundary, span, options)
	options = options or {}
	assert(
		type(boundary) == "table" and #boundary >= 4 and #boundary % 2 == 0,
		"Grid boundary needs an even number of distinct vertices"
	)
	U.integer(span, 1)
	local height = #boundary / 2 - span
	assert(height >= 1, "Grid span must leave a positive second dimension")
	local offset = options.offset or 0
	assert(type(offset) == "number" and offset % 1 == 0, "Grid offset must be an integer")
	local edit, index = Core.begin(mesh, options), C.index(mesh, options)
	local loop, seen = {}, {}
	for i = 1, #boundary do
		local v = boundary[(i - 1 + offset) % #boundary + 1]
		assert(mesh.vertices[v] and not seen[v], "Grid boundary vertices must exist and be distinct")
		loop[i], seen[v] = v, true
	end
	local orientation
	for i, a in loop do
		local e = index.edges[U.edge(a, loop[i % #loop + 1])]
		if e then
			assert(#e.corners == 1, "Grid fill can only attach to boundary edges")
			local direction = index.corners[e.corners[1]].vertex == a
			assert(orientation == nil or orientation == direction, "Inconsistent grid boundary orientation")
			orientation = direction
		end
	end
	if orientation then
		local reversed = {}
		for i = 1, #loop do
			reversed[i] = loop[(span - i + 1) % #loop + 1]
		end
		loop = reversed
	end
	local grid, references, boundaryRefs = {}, {}, {}
	for _, id in loop do
		local corner = index.vertices[id].corners[1]
		if corner then
			local c = index.corners[corner]
			boundaryRefs[id] = { { c.face, c.index, 1 } }
		else
			boundaryRefs[id] = {}
		end
	end
	for j = 0, height do
		grid[j + 1] = {}
	end
	for i = 0, span do
		grid[1][i + 1] = loop[i + 1]
	end
	for j = 1, height do
		grid[j + 1][span + 1] = loop[span + j + 1]
	end
	for i = 1, span do
		grid[height + 1][span - i + 1] = loop[span + height + i + 1]
	end
	for j = 1, height - 1 do
		grid[height - j + 1][1] = loop[2 * span + height + j + 1]
	end
	local corners = { grid[1][1], grid[1][span + 1], grid[height + 1][span + 1], grid[height + 1][1] }
	for j = 1, height - 1 do
		for i = 1, span - 1 do
			local u, v = i / span, j / height
			local rails = { grid[1][i + 1], grid[height + 1][i + 1], grid[j + 1][1], grid[j + 1][span + 1] }
			local factors = { 1 - v, v, 1 - u, u }
			local cornerWeights = { (1 - u) * (1 - v), u * (1 - v), u * v, (1 - u) * v }
			local origin, delta = mesh.vertices[corners[1]], Vector3.zero
			local vr, cr = {}, {}
			for k, id in rails do
				delta += (mesh.vertices[id] - origin) * factors[k]
				table.insert(vr, { id, factors[k] / 2 })
				for _, r in boundaryRefs[id] do
					table.insert(cr, { r[1], r[2], factors[k] / 2 })
				end
			end
			for k, id in corners do
				delta -= (mesh.vertices[id] - origin) * cornerWeights[k]
			end
			local id = edit.vertex(origin + delta, vr)
			grid[j + 1][i + 1], references[id] = id, cr
		end
	end
	for id, refs in boundaryRefs do
		references[id] = refs
	end
	local material = options.material or 1
	U.integer(material, 1)
	for j = 1, height do
		for i = 1, span do
			local vs = { grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i] }
			local refs, faceRefs, sourceFaces = {}, {}, {}
			for k, id in vs do
				refs[k] = references[id]
				-- Select a boundary face incident on this cell, keeping separate corner seams.
				for _, neighbor in { vs[k % 4 + 1], vs[(k - 2) % 4 + 1] } do
					local edge = index.edges[U.edge(id, neighbor)]
					if edge and #edge.corners == 1 then
						local c = index.corners[edge.corners[1]]
						local ci = table.find(mesh.faces[c.face].vertices, id)
						refs[k] = { { c.face, ci, 1 } }
						break
					end
				end
				for _, r in refs[k] do
					sourceFaces[r[1]] = true
				end
			end
			for _, fid in U.keys(sourceFaces) do
				table.insert(faceRefs, { fid, 1 })
			end
			local fid = edit.face(
				vs,
				refs,
				options.material or (faceRefs[1] and mesh.faces[faceRefs[1][1]].material) or material,
				faceRefs
			)
			if options.uv == "grid" or #faceRefs == 0 then
				local uv = {
					Vector2.new((i - 1) / span, (j - 1) / height),
					Vector2.new(i / span, (j - 1) / height),
					Vector2.new(i / span, j / height),
					Vector2.new((i - 1) / span, j / height),
				}
				for k, value in uv do
					edit.out.faces[fid].corners[k].uv = value
				end
			end
		end
	end
	assert(options.uv == nil or options.uv == "grid" or options.uv == "preserve", "Unknown grid UV mode")
	edit.report.grid, edit.report.boundary, edit.report.span, edit.report.height = grid, loop, span, height
	return edit.finish()
end
