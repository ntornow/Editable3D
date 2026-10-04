-- Exact initial halo lift for stationary sectors with exact local sharpness masks.
return function(R, work)
	local refinement = require(script.Parent.ExactSubdivisionRefinement)(R, work)
	return function(source, sector, vertex, cfg, masks, exactSource)
		local m, reason = exactSource, nil
		if not m then
			m, reason = refinement.snapshot(source)
		end
		if not m then
			return nil, reason
		end
		local child
		local starts = {}
		for i, fid in sector.faces do
			starts[i] = { fid, assert(table.find(m.faces[fid], vertex)) }
		end
		m, child = refinement.refine(m, cfg, work)
		local first = {}
		for i, pair in starts do
			first[i] = child[pair[1]][pair[2]]
		end
		m, child = refinement.refine(m, cfg, work)
		local points = {}
		local function insert(k, i, j, id)
			local index = masks.vertex(k, i, j)
			local previous = points[index]
			local point = m.vertices[id]
			if previous then
				for axis = 1, 3 do
					assert(R.equal(previous[axis], point[axis]), "Inconsistent exact annular lift")
				end
			else
				points[index] = point
			end
		end
		for k, fid in first do
			local f = {}
			for i = 1, 4 do
				f[i] = m.faces[child[fid][i]]
			end
			insert(k - 1, 0, 0, f[1][1])
			insert(k - 1, 1, 0, f[1][2])
			insert(k - 1, 1, 1, f[1][3])
			insert(k - 1, 0, 1, f[1][4])
			insert(k - 1, 2, 0, f[2][1])
			insert(k - 1, 2, 1, f[2][2])
			insert(k - 1, 2, 2, f[3][1])
			insert(k - 1, 1, 2, f[3][2])
			insert(k - 1, 0, 2, f[4][1])
		end
		assert(#points == masks.size)
		return points
	end
end
