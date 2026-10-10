-- Authoring helpers for building and texturing complex objects: loft/sweep options, box UVs and
-- bakes that tolerate degenerate faces. Expected values are derived analytically.
local harness = require(script.Parent.TestHarness)
return function(E)
	local report, test, rejects = harness()
	local function near(a, b, tolerance)
		assert(math.abs(a - b) <= (tolerance or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function count(t)
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	local function rows(n, m, closedRing)
		local out = {}
		for i = 1, n do
			local row = {}
			for j = 1, m do
				if closedRing then
					local a = (j - 1) / m * 2 * math.pi
					row[j] = Vector3.new(math.cos(a), i, math.sin(a))
				else
					row[j] = Vector3.new(j, -i, 0)
				end
			end
			out[i] = row
		end
		return out
	end
	test("loft defaults are unchanged: closed quads with wrap-around UVs", function()
		local m = E.Curves.loft(rows(3, 6, true), false)
		assert(count(m.faces) == 2 * 6)
		local maxU = 0
		for _, f in m.faces do
			assert(#f.vertices == 4)
			for _, c in f.corners do
				maxU = math.max(maxU, c.uv.X)
			end
		end
		near(maxU, 1)
	end)
	test("open lofts make a sheet whose UVs span [0, 1] without a wrap face", function()
		local m = E.Curves.loft(rows(4, 5, false), true, { closed = false })
		assert(count(m.faces) == 3 * 4, "caps are ignored for open lofts")
		local lo, hi = Vector2.new(1, 1), Vector2.zero
		for _, f in m.faces do
			for i, c in f.corners do
				lo, hi = lo:Min(c.uv), hi:Max(c.uv)
				local p = m.vertices[f.vertices[i]]
				near(c.uv.X, (p.X - 1) / 4)
				near(c.uv.Y, (-p.Y - 1) / 3)
			end
		end
		near(lo.X, 0)
		near(hi.X, 1)
		near(hi.Y, 1)
	end)
	test("triangle lofts drop zero-area triangles from pinched rings", function()
		local r = rows(3, 6, true)
		for j = 1, 6 do
			r[3][j] = Vector3.new(0, 3, 0) -- the last ring collapses to a point
		end
		local m = E.Curves.loft(r, false, { triangles = true })
		-- 6 quads in the first band (12 triangles); the pinched band keeps one triangle per quad
		assert(count(m.faces) == 12 + 6, "faces " .. count(m.faces))
		for fid, f in m.faces do
			assert(#f.vertices == 3)
			local _, area = m:faceNormal(fid)
			assert(area > 0)
		end
	end)
	test("smoothBoundary straightens a staircase edge without shrinking the sheet", function()
		-- a 12 x 12 grid with every cell above the diagonal x + y > 12 removed: a staircase edge
		local m = E.Mesh.new()
		local id = {}
		for i = 0, 12 do
			id[i] = {}
			for j = 0, 12 do
				id[i][j] = m:addVertex(Vector3.new(i, j, 0))
			end
		end
		for i = 0, 11 do
			for j = 0, 11 do
				if i + j < 12 then
					m:addFace({ id[i][j], id[i + 1][j], id[i + 1][j + 1], id[i][j + 1] })
				end
			end
		end
		local function stair(mesh)
			-- mean distance of the diagonal boundary vertices from the line x + y = 12.5
			local total, n = 0, 0
			for i = 1, 10 do
				local p = mesh.vertices[id[i][12 - i]]
				total += math.abs(p.X + p.Y - 12.5)
				p = mesh.vertices[id[i][13 - i]]
				total += math.abs(p.X + p.Y - 12.5)
				n += 2
			end
			return total / n
		end
		local before = stair(m)
		local untouched = E.Sculpt.smooth(m, nil, 10)
		near(stair(untouched), before, 1e-9) -- smooth pins the boundary
		local out, moved = E.Sculpt.smoothBoundary(m, nil, 10)
		assert(moved > 20, "moved " .. moved)
		assert(stair(out) < 0.25 * before, string.format("staircase %.3f -> %.3f", before, stair(out)))
		-- straight boundary runs stay on their line; the sheet stays planar
		assert(math.abs(out.vertices[id[0][5]].X) < 0.02, "straight edge drifted") -- drift spreads from the stair end
		for _, p in out.vertices do
			near(p.Z, 0)
		end
		-- the masked-out half keeps its staircase
		local mask = {}
		for i = 0, 12 do
			for j = 0, 12 do
				mask[id[i][j]] = i < 6 and 1 or 0
			end
		end
		local half = E.Sculpt.smoothBoundary(m, mask, 10)
		near((half.vertices[id[9][3]] - m.vertices[id[9][3]]).Magnitude, 0)
		assert((half.vertices[id[3][9]] - m.vertices[id[3][9]]).Magnitude > 0.05)
		-- rings relax the interior next to the edge, but leave the far interior alone
		local relaxed = E.Sculpt.smoothBoundary(m, nil, 10, { rings = 1 })
		assert((relaxed.vertices[id[5][6]] - out.vertices[id[5][6]]).Magnitude > 1e-4)
		near((relaxed.vertices[id[2][2]] - out.vertices[id[2][2]]).Magnitude, 0)
	end)
	test("vertexOcclusion darkens the inside of a fold and pointSampler keeps sheets apart", function()
		-- a floor with a wall standing on it: floor vertices next to the wall are half enclosed
		local floor = E.Primitives.grid(10, 10, Vector2.new(10, 10))
		local wall = E.Deform.map(E.Primitives.grid(10, 4, Vector2.new(10, 4)), function(p)
			return Vector3.new(0.05, p.Z + 2, p.X)
		end)
		local open = E.Bake.vertexOcclusion(floor, { samples = 32, distance = 20 })
		local closed = E.Bake.vertexOcclusion(
			floor,
			{ occluder = E.Topology.join({ floor, wall }), samples = 32, distance = 20 }
		)
		local near0, far0 = nil, nil
		for id, p in floor.vertices do
			near(open[id], 1)
			if math.abs(p.X - 1) < 1e-6 and math.abs(p.Z) < 1e-6 then
				near0 = closed[id]
			elseif math.abs(p.X - 5) < 1e-6 and math.abs(p.Z) < 1e-6 then
				far0 = closed[id]
			end
		end
		assert(
			near0 and far0 and near0 < far0 and near0 < 0.85,
			string.format("near %s far %s", tostring(near0), tostring(far0))
		)
		-- sampler: a smooth blend in space, nil far away, and the normal keeps opposite sheets apart
		local sample = E.Bake.pointSampler(
			{ Vector3.new(0, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0.2, 0) },
			{ 0, 1, 5 },
			1,
			{ Vector3.yAxis, Vector3.yAxis, -Vector3.yAxis }
		)
		local mid = sample(Vector3.new(0.5, 0, 0), Vector3.yAxis)
		assert(mid and math.abs(mid - 0.5) < 1e-6, tostring(mid))
		local below = sample(Vector3.new(0, 0.2, 0), -Vector3.yAxis)
		assert(below and math.abs(below - 5) < 1e-6, tostring(below))
		assert(sample(Vector3.new(10, 0, 0)) == nil)
	end)
	test("occlusionSampler joins meshes, counts occluders and smooths per-vertex openness", function()
		-- the floor split into two halves (as chunked parts), a wall standing on it as an occluder
		local left = E.Deform.map(E.Primitives.grid(10, 10, Vector2.new(5, 10)), function(p)
			return p + Vector3.new(-2.5, 0, 0)
		end)
		local right = E.Deform.map(E.Primitives.grid(10, 10, Vector2.new(5, 10)), function(p)
			return p + Vector3.new(2.5, 0, 0)
		end)
		local wall = E.Deform.map(E.Primitives.grid(10, 4, Vector2.new(10, 4)), function(p)
			return Vector3.new(0.05, p.Z + 2, p.X)
		end)
		local sampler, mean = E.Bake.occlusionSampler(
			{ left, right },
			{ occluders = { wall }, samples = 32, distance = 20, radius = 1.2 }
		)
		local nearWall = sampler(Vector3.new(1, 0, 0), Vector3.yAxis)
		local farAway = sampler(Vector3.new(4.5, 0, 0), Vector3.yAxis)
		assert(
			nearWall and farAway and nearWall < farAway,
			string.format("%s %s", tostring(nearWall), tostring(farAway))
		)
		assert(mean > 0 and mean < 1, "mean " .. mean)
		-- without the occluder the floor is open everywhere
		local openSampler, openMean = E.Bake.occlusionSampler(
			{ left, right },
			{ samples = 16, distance = 20 }
		)
		near(openMean, 1)
		near(openSampler(Vector3.new(1, 0, 0), Vector3.yAxis) :: number, 1)
		rejects(function()
			E.Bake.occlusionSampler({})
		end, "occlusionSampler needs meshes")
	end)
	test(
		"heightOcclusion: flat is open, pits are occluded, wraps, and discounts a cylinder's curvature",
		function()
			local function field(rows: number, cols: number, f: (number, number) -> number): { { number } }
				local h = {}
				for r = 1, rows do
					h[r] = {}
					for c = 1, cols do
						h[r][c] = f(r, c)
					end
				end
				return h
			end
			local flat = E.Bake.heightOcclusion(
				field(9, 9, function()
					return 2
				end),
				{ cellX = 0.25, cellY = 0.25 }
			)
			for r = 1, 9 do
				for c = 1, 9 do
					near(flat[r][c], 0, 1e-12)
				end
			end
			-- a pit 1 stud deep and 1 stud wide: its centre is well occluded, a cell 2 studs away is open
			local pit = field(21, 21, function(r, c)
				return if math.abs(r - 11) <= 2 and math.abs(c - 11) <= 2 then 0 else 1
			end)
			local occ = E.Bake.heightOcclusion(pit, { cellX = 0.25, cellY = 0.25 })
			assert(occ[11][11] > 0.5, "pit centre " .. occ[11][11])
			near(occ[11][20], 0, 1e-12)
			near(occ[2][2], 0, 1e-12)
			-- periodic columns: a dip at column 1 occludes the cells across the wrap like its other neighbours
			local ring = field(5, 16, function(_, c)
				return if c == 1 then -1 else 0
			end)
			local wrapped = E.Bake.heightOcclusion(ring, { periodicX = true, distances = { 1 } })
			near(wrapped[3][2], wrapped[3][16], 1e-12)
			assert(wrapped[3][1] > 0.3, "the dip itself is occluded by both sides")
			local open = E.Bake.heightOcclusion(ring, { distances = { 1 } })
			assert(open[3][1] < wrapped[3][1], "without wrapping the dip sees past the edge")
			-- a slightly raised column: occludes its neighbours on a flat field, much less on a tight cylinder
			local ridge = field(5, 11, function(_, c)
				return if c == 6 then 0.2 else 0
			end)
			local plain = E.Bake.heightOcclusion(ridge, { distances = { 1 } })
			local curved = E.Bake.heightOcclusion(ridge, { distances = { 1 }, curvatureRadius = 2 })
			assert(plain[3][5] > 0, "the ridge occludes its neighbour")
			assert(curved[3][5] < plain[3][5], "curvature lowers the ridge as seen from the neighbour")
			-- missing cells are skipped
			local holes = field(5, 5, function(r, c)
				return if r == 3 and c == 3 then 0 / 0 else 0
			end)
			local h = E.Bake.heightOcclusion(holes)
			near(h[3][3], 0, 1e-12)
			near(h[2][2], 0, 1e-12)
			rejects(function()
				E.Bake.heightOcclusion({ { 1, 2 }, { 1 } })
			end, "heightOcclusion rows must have matching lengths")
		end
	)
	test("foldDirections: along parallel folds, coherent; isotropic or missing slopes are not", function()
		local function grid(rows: number, cols: number, f: (number, number) -> Vector2?): { { Vector2? } }
			local g = {}
			for r = 1, rows do
				g[r] = {}
				for c = 1, cols do
					g[r][c] = f(r, c)
				end
			end
			return g
		end
		-- ridges running along y (z = sin(2 pi x / 2)): slopes point along x, so folds run along y
		local cell = 0.1
		local dirs, coh = E.Bake.foldDirections(
			grid(20, 40, function(_, c)
				local x = c * cell
				return Vector2.new(math.pi * math.cos(math.pi * x), 0)
			end),
			{ cellX = cell, cellY = cell, rho = 0.4 }
		)
		near(math.abs(dirs[10][20].Y), 1, 1e-5)
		assert(coh[10][20] > 0.99, "parallel folds are coherent " .. coh[10][20])
		-- ridges at 45 degrees: slopes along (1, 1), folds along (1, -1)
		local dirs45 = E.Bake.foldDirections(
			grid(20, 20, function(r, c)
				local s = math.cos((r + c) * cell)
				return Vector2.new(s, s)
			end),
			{ cellX = cell, cellY = cell, rho = 0.3 }
		)
		local d = dirs45[10][10]
		near(math.abs(d.X + d.Y), 0, 1e-5)
		near(d.Magnitude, 1, 1e-5)
		-- a round bump has slopes pointing every way: low coherence at its centre
		local _, cohBump = E.Bake.foldDirections(
			grid(21, 21, function(r, c)
				local x, y = (c - 11) * cell, (r - 11) * cell
				return Vector2.new(-2 * x, -2 * y)
			end),
			{ cellX = cell, cellY = cell, rho = 0.5 }
		)
		assert(cohBump[11][11] < 0.2, "a bump is not a fold " .. cohBump[11][11])
		-- no slopes (nil holes need the column count; false marks a missing cell too): coherence 0
		local _, cohNone = E.Bake.foldDirections(
			grid(4, 4, function()
				return nil
			end),
			{ columns = 4 }
		)
		near(cohNone[2][2], 0, 1e-12)
		local _, cohFalse = E.Bake.foldDirections({ { false, false, false }, { false, false, false } })
		near(cohFalse[2][3], 0, 1e-12)
		rejects(function()
			E.Bake.foldDirections({ {}, {} })
		end, "foldDirections needs at least one column")
	end)
	test(
		"flowSmooth: averages along the directions, keeps detail across them, wraps and respects gaps",
		function()
			local rows, cols = 24, 32
			local field, along = {}, {}
			for r = 1, rows do
				field[r], along[r] = {}, {}
				for c = 1, cols do
					-- folds across x (period 8 columns) plus a fine ripple along y
					field[r][c] = math.sin(2 * math.pi * c / 8) + 0.5 * (if r % 2 == 0 then 1 else -1)
					along[r][c] = Vector2.new(0, 1)
				end
			end
			local out = E.Bake.flowSmooth(field, along, { length = 4, step = 0.5 })
			for r = 6, rows - 5 do
				for c = 1, cols do
					near(out[r][c], math.sin(2 * math.pi * c / 8), 0.08)
				end
			end
			-- smoothing across the folds instead flattens them
			local across = {}
			for r = 1, rows do
				across[r] = {}
				for c = 1, cols do
					across[r][c] = Vector2.new(1, 0)
				end
			end
			local flat = E.Bake.flowSmooth(field, across, { length = 8, step = 0.5, periodicX = true })
			assert(math.abs(flat[12][3] - field[12][3]) > 0.5, "folds are averaged away along x")
			-- coherence 0 keeps the field; NaN cells stay NaN and stop the walk
			local zero = {}
			for r = 1, rows do
				zero[r] = table.create(cols, 0)
			end
			local kept = E.Bake.flowSmooth(field, along, { length = 4, coherence = zero })
			near(kept[7][5], field[7][5], 1e-12)
			field[12][5] = 0 / 0
			local gap = E.Bake.flowSmooth(field, along, { length = 4, step = 0.5 })
			assert(gap[12][5] ~= gap[12][5], "missing cells stay missing")
			near(gap[14][9], out[14][9], 1e-9)
			rejects(function()
				E.Bake.flowSmooth({ { 1 } }, { { Vector2.zero } }, { length = 0 })
			end, "flowSmooth length must be positive")
		end
	)
	test("slopeFit: relief follows target normals, large scales and untargeted cells stay", function()
		local rows, cols = 24, 32
		local cell = 0.25
		-- a flat field; targets are the normals of ripples along x (period 2 studs, amplitude 0.2)
		local function rip(c: number): number
			return 0.2 * math.sin(2 * math.pi * (c - 1) * cell / 2)
		end
		local function ripSlope(c: number): number
			return 0.2 * (2 * math.pi / 2) * math.cos(2 * math.pi * (c - 1) * cell / 2)
		end
		local heights, normals = {}, {}
		for r = 1, rows do
			heights[r], normals[r] = {}, {}
			for c = 1, cols do
				heights[r][c] = 5
				normals[r][c] = Vector3.new(-ripSlope(c), 0, 1).Unit
			end
		end
		local out, report =
			E.Bake.slopeFit(heights, normals, { cellX = cell, cellY = cell, periodicX = true, keep = 3 })
		assert(report.cells == rows * cols, "every cell targeted")
		assert(report.slopeErrorAfter < 0.25 * report.slopeErrorBefore, "slopes follow the targets")
		-- the ripple's shape (up to its mean) appears, the mean height stays
		local mean, err = 0, 0
		for c = 1, cols do
			mean += out[12][c]
		end
		mean /= cols
		near(mean, 5, 0.02)
		for c = 1, cols do
			err = math.max(err, math.abs((out[12][c] - mean) - rip(c)))
		end
		assert(err < 0.06, "ripple recovered within " .. err)
		-- gain scales the relief
		local out2 = E.Bake.slopeFit(
			heights,
			normals,
			{ cellX = cell, cellY = cell, periodicX = true, keep = 3, gain = 2 }
		)
		local a1, a2 = 0, 0
		for c = 1, cols do
			a1 = math.max(a1, math.abs(out[12][c] - mean))
			a2 = math.max(a2, math.abs(out2[12][c] - 5))
		end
		assert(a2 > 1.7 * a1, "gain 2 doubles the relief")
		-- no targets: unchanged; a missing cell stays missing; clip bounds the change
		local none = {}
		for r = 1, rows do
			none[r] = {}
		end
		local same = E.Bake.slopeFit(heights, none, { cellX = cell, cellY = cell })
		near(same[5][5], 5, 1e-9)
		heights[3][3] = 0 / 0
		local holes = E.Bake.slopeFit(heights, normals, { cellX = cell, cellY = cell, clip = 0.05 })
		assert(holes[3][3] ~= holes[3][3], "missing stays missing")
		for c = 1, cols do
			assert(math.abs(holes[12][c] - 5) <= 0.05 + 1e-9, "clipped")
		end
		-- a large tilt in the targets is a large scale: removed, the field's own slope kept
		local tilt = {}
		for r = 1, rows do
			tilt[r] = {}
			for c = 1, cols do
				tilt[r][c] = Vector3.new(-0.5, 0, 1).Unit
			end
		end
		heights[3][3] = 5
		local kept = E.Bake.slopeFit(heights, tilt, { cellX = cell, cellY = cell, keep = 1 })
		local mid = kept[12][16] - kept[12][15]
		assert(math.abs(mid) < 0.5 * 0.5 * cell, "interior keeps the flat field's slope")
		rejects(function()
			E.Bake.slopeFit({ { 1, 2 }, { 1 } }, { {}, {} })
		end, "slopeFit rows must have matching lengths")
		rejects(function()
			E.Bake.slopeFit(heights, tilt, { trend = "median" :: any })
		end, "slopeFit trend must be mean or linear")
	end)
	test(
		"slopeFit trend linear: no offset where a large-scale correction ramps to the domain's edge",
		function()
			-- targets tilted along y (a pure large scale) over a strip whose top rows are missing: the integrated
			-- correction is a ramp; the local mean leaves about 0.8 x slope x keep at the edges, the local plane ~0
			local rows, cols, cell = 28, 36, 0.25
			local heights, tilt = {}, {}
			for r = 1, rows do
				heights[r], tilt[r] = {}, {}
				for c = 1, cols do
					heights[r][c] = if r > 22 then 0 / 0 else 2
					tilt[r][c] = Vector3.new(0, -0.4, 1).Unit
				end
			end
			local function worst(out): number
				local m = 0
				for r = 1, 22 do
					for c = 1, cols do
						m = math.max(m, math.abs(out[r][c] - 2))
					end
				end
				return m
			end
			local opts = { cellX = cell, cellY = cell, periodicX = true, keep = 1.5 }
			local meanOut = E.Bake.slopeFit(heights, tilt, opts)
			opts.trend = "linear"
			local linOut = E.Bake.slopeFit(heights, tilt, opts)
			local wm, wl = worst(meanOut), worst(linOut)
			assert(wm > 0.2, "the mean leaves an edge offset " .. wm)
			assert(wl < 0.25 * wm and wl < 0.06, "the plane leaves " .. wl .. " (mean " .. wm .. ")")
			-- small-scale relief survives the linear trend as it does the mean
			local rip = {}
			for r = 1, rows do
				rip[r] = {}
				for c = 1, cols do
					rip[r][c] = Vector3.new(-0.2 * math.pi * math.cos(math.pi * (c - 1) * cell), 0, 1).Unit
				end
			end
			local a =
				E.Bake.slopeFit(heights, rip, { cellX = cell, cellY = cell, periodicX = true, keep = 3 })
			local b = E.Bake.slopeFit(
				heights,
				rip,
				{ cellX = cell, cellY = cell, periodicX = true, keep = 3, trend = "linear" }
			)
			local amp = 0
			for c = 1, cols do
				amp = math.max(amp, math.abs(b[10][c] - 2))
				near(a[10][c], b[10][c], 0.03)
			end
			assert(amp > 0.12, "ripple kept " .. amp)
		end
	)
	test("Bake.modulateBytes multiplies covered texels and copies the rest exactly", function()
		local px = buffer.create(3 * 1 * 4)
		for i = 0, 2 do
			buffer.writeu8(px, i * 4, 100)
			buffer.writeu8(px, i * 4 + 1, 150)
			buffer.writeu8(px, i * 4 + 2, 200)
			buffer.writeu8(px, i * 4 + 3, 77)
		end
		local f = E.Texture.new(3, 1)
		f:set(0, 0, Color3.new(1.5, 1.5, 1.5), 1) -- covered: multiplied, the blue clamps at 255
		f:set(1, 0, Color3.new(1.002, 1, 1), 1) -- covered but within tolerance: unchanged
		-- pixel 2 is uncovered (alpha 0): unchanged
		local out, changed = E.Bake.modulateBytes(px, 3, 1, f)
		assert(changed == 1, "changed " .. changed)
		assert(buffer.readu8(out, 0) == 150 and buffer.readu8(out, 1) == 225 and buffer.readu8(out, 2) == 255)
		assert(buffer.readu8(out, 3) == 77, "alpha kept")
		for k = 4, 11 do
			assert(buffer.readu8(out, k) == buffer.readu8(px, k), "untouched byte " .. k)
		end
		local tinted = E.Bake.modulateBytes(
			px,
			3,
			1,
			(function()
				local g = E.Texture.new(3, 1)
				g:set(2, 0, Color3.new(0.5, 1, 2), 1)
				return g
			end)()
		)
		assert(
			buffer.readu8(tinted, 8) == 50
				and buffer.readu8(tinted, 9) == 150
				and buffer.readu8(tinted, 10) == 255
		)
		rejects(function()
			E.Bake.modulateBytes(px, 2, 1, f)
		end, "RGBA8 pixels")
	end)
	test("capFan closes lofts whose end rings cannot be one polygon", function()
		local function volume(m)
			local v = 0
			for _, f in m.faces do
				local a = m.vertices[f.vertices[1]]
				for k = 2, #f.vertices - 1 do
					v += a:Dot(m.vertices[f.vertices[k]]:Cross(m.vertices[f.vertices[k + 1]]))
				end
			end
			return v / 6
		end
		local rings = rows(5, 16, true)
		-- the first ring collapses to a line (collinear), the last repeats one point for half its samples
		for j = 1, 16 do
			rings[1][j] = Vector3.new(math.cos((j - 1) / 16 * 2 * math.pi), 1, 0)
			if j > 8 then
				rings[5][j] = rings[5][8]
			end
		end
		local m = E.Curves.loft(rings, true, { triangles = true, capFan = true, outward = true })
		for fid in m.faces do
			local tris = m:faceTriangles(fid)
			assert(#tris >= 1)
		end
		assert(volume(m) > 0, "outward")
		-- every fan corner has a UV on the end ring's v
		local ok = 0
		for _, f in m.faces do
			for _, c in f.corners do
				assert(c.uv ~= nil, "uv")
				ok += 1
			end
		end
		assert(ok > 0)
		-- polygon caps on the same rings fail to triangulate, which is why the option exists
		local poly = E.Curves.loft(rings, true, { triangles = true })
		local failed = false
		for fid in poly.faces do
			if not pcall(function()
				poly:faceTriangles(fid)
			end) then
				failed = true
			end
		end
		assert(failed, "polygon cap of a collinear ring should be degenerate")
	end)
	test("outward lofts face out whichever way the rings are stacked", function()
		local function volume(m)
			local v = 0
			for _, f in m.faces do
				local a = m.vertices[f.vertices[1]]
				for k = 2, #f.vertices - 1 do
					v += a:Dot(m.vertices[f.vertices[k]]:Cross(m.vertices[f.vertices[k + 1]]))
				end
			end
			return v / 6
		end
		local up = rows(3, 12, true)
		local down = { up[3], up[2], up[1] }
		local plain = E.Curves.loft(down, true)
		local fixed = E.Curves.loft(down, true, { outward = true })
		local same = E.Curves.loft(up, true, { outward = true })
		assert(volume(plain) * volume(E.Curves.loft(up, true)) < 0, "ring order flips the winding")
		assert(volume(fixed) > 0 and volume(same) > 0)
		near(volume(fixed), volume(same))
		local tri = E.Curves.loft(down, true, { triangles = true, outward = true })
		assert(volume(tri) > 0)
	end)
	test("sweep accepts a per-ring profile function in a transported frame", function()
		local path = {}
		for i = 0, 10 do
			path[i + 1] = Vector3.new(0, 0, i)
		end
		local frames = {}
		local m = E.Curves.sweep(function(fraction, frame)
			table.insert(frames, frame)
			local r = 1 + fraction -- a cone from radius 1 to 2
			local ring = {}
			for j = 0, 7 do
				local a = j / 8 * 2 * math.pi
				ring[j + 1] = Vector2.new(math.cos(a), math.sin(a)) * r
			end
			return ring
		end, path, { caps = false })
		assert(#frames == 11)
		for _, frame in frames do
			near(frame.tangent.Z, 1)
			near(frame.x:Dot(frame.tangent), 0)
			near(frame.y:Dot(frame.tangent), 0)
		end
		for _, v in m.vertices do
			near(Vector2.new(v.X, v.Y).Magnitude, 1 + v.Z / 10, 1e-4)
		end
		rejects(function()
			E.Curves.sweep(function()
				return { Vector2.zero }
			end, path)
		end, "at least 3 points")
	end)
	test("box UVs give one chart per axis direction at a shared, uniform scale", function()
		local box = E.Primitives.box(Vector3.new(4, 2, 1))
		local m, info = E.UV.box(box, nil, { margin = 0.02 })
		assert(info.charts == 6)
		local uvs = E.UV.analyze(m)
		assert(uvs.overlapFree, "charts overlap")
		-- every face keeps its studs-to-UV ratio: area in UV = area in 3D * scale^2
		for fid, f in m.faces do
			local _, area = m:faceNormal(fid)
			local a, b, c = f.corners[1].uv, f.corners[2].uv, f.corners[3].uv
			local uvArea = math.abs((b - a).X * (c - a).Y - (b - a).Y * (c - a).X) / 2
			local _, triArea = m:faceNormal(fid)
			local p = {}
			for i, v in f.vertices do
				p[i] = m.vertices[v]
			end
			local area3 = (p[2] - p[1]):Cross(p[3] - p[1]).Magnitude / 2
			near(uvArea, area3 * info.scale ^ 2, 1e-6)
			assert(area > 0 and triArea > 0)
		end
		for _, f in m.faces do
			for _, c in f.corners do
				assert(
					c.uv.X >= 0.02 - 1e-6
						and c.uv.X <= 0.98 + 1e-6
						and c.uv.Y >= 0.02 - 1e-6
						and c.uv.Y <= 0.98 + 1e-6
				)
			end
		end
	end)
	test("box UVs work on unwelded triangle soups and rotated frames", function()
		local soup = E.Mesh.new()
		local box = E.Topology.triangulate(E.Primitives.box(Vector3.new(3, 3, 3)))
		for _, f in box.faces do
			local ids = {}
			for i, v in f.vertices do
				ids[i] = soup:addVertex(box.vertices[v])
			end
			soup:addFace(ids)
		end
		local frame = CFrame.Angles(0.3, 0.2, 0.1)
		local rotated = E.Deform.transform(soup, frame)
		local m, info = E.UV.box(rotated, frame)
		assert(info.charts == 6)
		assert(E.UV.analyze(m).overlapFree)
	end)
	test("bakes skip faces that cannot be triangulated and report them", function()
		local m = E.Mesh.new()
		local a, b, c = m:addVertex(Vector3.zero), m:addVertex(Vector3.xAxis), m:addVertex(Vector3.yAxis)
		local d = m:addVertex(Vector3.new(2, 0, 0)) -- collinear with a and b
		local corners =
			{ { uv = Vector2.new(0.1, 0.1) }, { uv = Vector2.new(0.9, 0.1) }, { uv = Vector2.new(0.1, 0.9) } }
		m:addFace({ a, b, c }, corners)
		m:addFace(
			{ a, b, d },
			{ { uv = Vector2.new(0.5, 0.5) }, { uv = Vector2.new(0.6, 0.5) }, { uv = Vector2.new(0.7, 0.5) } }
		)
		local texture, info = E.Bake.rasterize(m, 16, 16, function()
			return Color3.new(1, 0, 0), 1
		end)
		assert(info.skippedFaces == 1, "skipped " .. tostring(info.skippedFaces))
		assert(info.coveredPixels > 0)
		local color = texture:sample(Vector2.new(0.2, 0.2))
		near(color.R, 1)
	end)
	-- view from z = -10 looking along +Z: view x is world -X, depth is z + 10
	local view = CFrame.lookAt(Vector3.new(0, 0, -10), Vector3.zero)
	test("envelope reports the frontmost depth and fills isolated holes", function()
		local box = E.Primitives.box(Vector3.new(4, 4, 2)) -- front face at z = -1
		local env = E.Deform.envelope(box, view, 0.5)
		local d = env:sample(Vector2.new(0, 0))
		assert(d ~= nil, "no envelope at the center")
		near(d :: number, 9, 1e-6)
		assert(env:sample(Vector2.new(50, 0)) == nil)
		-- the blurred envelope keeps a flat face flat and stays inside the silhouette
		local soft = env:blurred(1)
		near(soft:sample(Vector2.new(0, 0)) :: number, 9, 1e-6)
		assert(soft:sample(Vector2.new(50, 0)) == nil)
	end)
	local function bumpySheet()
		-- welded grid in the xy plane with bumps z = 0.3 sin(2x), facing -Z (toward the view)
		local m = E.Mesh.new()
		local ids = {}
		for i = 0, 40 do
			ids[i] = {}
			for j = 0, 20 do
				local x, y = -4 + i * 0.2, -2 + j * 0.2
				ids[i][j] = m:addVertex(Vector3.new(x, y, 0.3 * math.sin(2 * x)))
			end
		end
		for i = 0, 39 do
			for j = 0, 19 do
				m:addFace({ ids[i][j], ids[i][j + 1], ids[i + 1][j + 1], ids[i + 1][j] })
			end
		end
		m:recalculateNormals()
		-- make sure the sheet faces the view
		local fid = next(m.faces)
		if m:faceNormal(fid).Z > 0 then
			m = E.Topology.reverse(m):recalculateNormals()
		end
		return m
	end
	test("relief imposes the target and compresses existing folds by alpha", function()
		local m = bumpySheet()
		local env = E.Deform.envelope(m, view, 0.2)
		local out = E.Deform.relief(m, view, function(_, front)
			return front + 0.05 -- a flat target just behind the front envelope
		end, { alpha = 0.25, envelope = env, minFacing = -1, depth = 5 })
		local maxDev = 0
		for id, v in out.vertices do
			local p = m.vertices[id]
			local front = env:sample(Vector2.new(-p.X, p.Y))
			if front and math.abs(p.X) < 3.5 and math.abs(p.Y) < 1.5 then
				local below = (p.Z + 10) - front
				local expected = front + 0.05 + 0.25 * math.max(0, below)
				maxDev = math.max(maxDev, math.abs((v.Z + 10) - expected))
				near(v.X, p.X)
				near(v.Y, p.Y)
			end
		end
		assert(maxDev < 1e-4, "deviation " .. maxDev)
		-- with a low-passed envelope as the target the bumps (wavelength ~3.1) are removed
		local smooth = env:blurred(1.5)
		local flat = E.Deform.relief(m, view, function(q)
			return smooth:sample(q)
		end, { alpha = 0, envelope = env, minFacing = -1, depth = 5 })
		local function amplitude(mesh)
			local lo, hi = math.huge, -math.huge
			for _, v in mesh.vertices do
				if math.abs(v.X) < 2.5 and math.abs(v.Y) < 1 then
					lo, hi = math.min(lo, v.Z), math.max(hi, v.Z)
				end
			end
			return hi - lo
		end
		assert(
			amplitude(flat) < amplitude(m) * 0.3,
			"folds not removed: " .. amplitude(flat) .. " vs " .. amplitude(m)
		)
	end)
	test("relief leaves back faces and deep geometry in place", function()
		-- a slab: the bumpy front sheet plus a flat back sheet 4 studs behind, facing away
		local front = bumpySheet()
		local back = E.Topology.reverse(E.Deform.transform(bumpySheet(), CFrame.new(0, 0, 4)))
		local slab = E.Topology.join({ front, back })
		local out = E.Deform.relief(slab, view, function(_, d)
			return d - 0.5 -- pull the front forward
		end, { alpha = 0, depth = 1 })
		local movedFront, movedBack = 0, 0
		for id, v in out.vertices do
			local p = slab.vertices[id]
			if (v - p).Magnitude > 1e-6 then
				if p.Z < 2 then
					movedFront += 1
				else
					movedBack += 1
				end
			end
		end
		assert(movedBack == 0, "back vertices moved")
		assert(movedFront > 100, "front did not move: " .. movedFront)
		rejects(function()
			E.Deform.relief(slab, view, function()
				return 0
			end, { fade = 0 })
		end, "Invalid relief options")
	end)
	test("envelope of several meshes keeps the frontmost surface of all of them", function()
		local back = E.Primitives.box(Vector3.new(4, 4, 2)) -- front face at z = -1, depth 9
		local front = E.Deform.transform(E.Primitives.box(Vector3.new(2, 2, 2)), CFrame.new(0, 0, -3)) -- depth 6
		local env = E.Deform.envelope({ back, front }, view, 0.25)
		near(env:sample(Vector2.new(0, 0)) :: number, 6, 1e-6)
		-- view x is world -X: x = -1.5 is covered by the back box alone
		near(env:sample(Vector2.new(1.5, 0)) :: number, 9, 1e-6)
		near(E.Deform.envelope(back, view, 0.25):sample(Vector2.new(0, 0)) :: number, 9, 1e-6)
	end)
	-- a camera 10 studs in front of the origin looking along +Z (pixel x grows toward world -X)
	local camera = E.Camera.new(CFrame.lookAt(Vector3.new(0, 0, -10), Vector3.zero), 40, 200, 200)
	local focal = 100 / math.tan(math.rad(20))
	local function tiltedSheet(n: number)
		-- the plane z = 0.5 x over |x|, |y| <= 3, facing the camera
		local m = E.Mesh.new()
		local ids = {}
		for i = 0, n do
			ids[i] = {}
			for j = 0, n do
				local x, y = -3 + 6 * i / n, -3 + 6 * j / n
				ids[i][j] = m:addVertex(Vector3.new(x, y, 0.5 * x))
			end
		end
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				m:addFace({ ids[i][j], ids[i][j + 1], ids[i + 1][j + 1], ids[i + 1][j] })
			end
		end
		m:recalculateNormals()
		if m:faceNormal((next(m.faces))).Z > 0 then
			m = E.Topology.reverse(m):recalculateNormals()
		end
		return m
	end
	test("camera envelope interpolates depth perspective-correctly across large faces", function()
		local env = E.Deform.envelope(tiltedSheet(1), camera, 2)
		for _, du in { -60, -25, 0, 30, 60 } do
			-- along the pixel row through the principal point: x = -du * d / f on z = 0.5 x
			local expected = 10 / (1 + 0.5 * du / focal)
			near(env:sample(Vector2.new(100 + du, 100)) :: number, expected, 1e-4)
		end
		assert(env:sample(Vector2.new(5, 100)) == nil, "outside the sheet")
	end)
	test("camera relief moves points along their rays", function()
		local sheet = tiltedSheet(30)
		local out = E.Deform.relief(sheet, camera, function(_, front)
			return front - 0.5 -- pull the visible surface 0.5 toward the camera
		end, { alpha = 0, step = 2 })
		local moved = 0
		local origin = camera.frame.Position
		for id, v in out.vertices do
			local p = sheet.vertices[id]
			if (v - p).Magnitude > 1e-6 then
				moved += 1
				local a, b = p - origin, v - origin
				assert(a.Unit:Cross(b.Unit).Magnitude < 1e-6, "left its ray")
				local before = camera.frame:PointToObjectSpace(p)
				local after = camera.frame:PointToObjectSpace(v)
				near(-after.Z, -before.Z - 0.5, 1e-3)
			end
		end
		assert(moved > 500, "moved " .. moved)
	end)
	test("sectionScale scales each side of a per-height centre separately", function()
		local box = E.Primitives.box(Vector3.new(2, 10, 4)) -- z in [-2, 2], y in [-5, 5]
		local out = E.Deform.sectionScale(box, CFrame.identity, function(h)
			if h < 0 then
				return nil
			end
			return 0.5, 2, 0.5
		end)
		for id, v in out.vertices do
			local p = box.vertices[id]
			if p.Y < 0 then
				near((v - p).Magnitude, 0)
			else
				near(v.X, p.X)
				near(v.Z, if p.Z < 0.5 then 0.5 + (p.Z - 0.5) * 2 else 0.5 + (p.Z - 0.5) * 0.5)
			end
		end
		-- blended: points beyond centre +- blend take the full scale on their side
		local blended = E.Deform.sectionScale(box, CFrame.identity, function()
			return 0, 2, 0.5
		end, { blend = 1 })
		for id, v in blended.vertices do
			local p = box.vertices[id]
			near(v.Z, p.Z * (if p.Z < 0 then 2 else 0.5))
		end
		-- a rotated frame scales world X (local Z = world -X); the mask holds a vertex
		local wide = E.Primitives.box(Vector3.new(4, 10, 2))
		local held = next(wide.vertices)
		local mask = {}
		for id in wide.vertices do
			mask[id] = if id == held then 0 else 1 -- with a mask, unlisted vertices stay put
		end
		local sideways = E.Deform.sectionScale(
			wide,
			CFrame.fromMatrix(Vector3.zero, Vector3.zAxis, Vector3.yAxis, -Vector3.xAxis),
			function()
				return 0, 3, 1
			end,
			{ mask = mask }
		)
		for id, v in sideways.vertices do
			local p = wide.vertices[id]
			near(v.X, if id == held or p.X < 0 then p.X else p.X * 3)
			near(v.Z, p.Z)
		end
		rejects(function()
			E.Deform.sectionScale(box, CFrame.identity, function()
				return 0, 1, 1
			end, { blend = -1 })
		end, "Section blend must be nonnegative")
	end)
	test("sectionScaleMap is sectionScale's point map: a height band widened about an axis", function()
		local box = E.Primitives.box(Vector3.new(2, 10, 4))
		local rule = function(h: number): (number?, number?, number?)
			if h < 0 then
				return nil
			end
			return 0.5, 2, 0.5
		end
		local viaMesh = E.Deform.sectionScale(box, CFrame.identity, rule, { blend = 0.3 })
		local map = E.Deform.sectionScaleMap(CFrame.identity, rule, 0.3)
		for id, v in viaMesh.vertices do
			near((map(box.vertices[id]) - v).Magnitude, 0, 1e-5)
		end
		-- a neck-like band: world x scaled by 1 + 0.1 inside y in [1, 2], unchanged outside
		local band = E.Deform.sectionScaleMap(
			CFrame.fromMatrix(Vector3.zero, Vector3.zAxis, Vector3.yAxis),
			function(y: number): (number?, number?, number?)
				if y < 1 or y > 2 then
					return nil
				end
				return 0, 1.1, 1.1
			end
		)
		local p = band(Vector3.new(2, 1.5, -3))
		near(p.X, 2.2, 1e-5)
		near(p.Y, 1.5, 1e-5)
		near(p.Z, -3, 1e-5)
		near((band(Vector3.new(2, 3, -3)) - Vector3.new(2, 3, -3)).Magnitude, 0, 1e-5)
		rejects(function()
			E.Deform.sectionScaleMap(CFrame.identity, rule, -1)
		end, "Section blend must be nonnegative")
	end)
	test("edgeField is the position map behind Deform.edge", function()
		local m = E.Mesh.new()
		local ids = {}
		for i = 0, 30 do
			ids[i] = {}
			for j = 0, 20 do
				ids[i][j] = m:addVertex(Vector3.new(-3 + i * 0.2, -2 + j * 0.2, 0))
			end
		end
		for i = 0, 29 do
			for j = 0, 19 do
				m:addFace({ ids[i][j], ids[i][j + 1], ids[i + 1][j + 1], ids[i + 1][j] })
			end
		end
		m:recalculateNormals()
		local line = { Vector2.new(-2, -1), Vector2.new(2, 1) }
		local env = E.Deform.envelope(m, view, 0.2, 3)
		local options = { envelope = env, height = 0.4, width = 0.6, drop = 0.25 }
		local edged = E.Deform.edge(m, view, line, options)
		local field = E.Deform.edgeField(view, line, options)
		local moved = 0
		for id, p in m.vertices do
			local q = field(p)
			near((q - edged.vertices[id]).Magnitude, 0, 1e-9)
			if (q - p).Magnitude > 1e-6 then
				moved += 1
			end
		end
		assert(moved > 50, "edge moved " .. moved)
		rejects(function()
			E.Deform.edgeField(view, line, {})
		end, "edgeField needs options.envelope")
	end)
	test("edgeField profile roll raises a rounded roll above the line", function()
		local m = E.Mesh.new()
		local ids = {}
		for i = 0, 30 do
			ids[i] = {}
			for j = 0, 40 do
				ids[i][j] = m:addVertex(Vector3.new(-3 + i * 0.2, -2 + j * 0.2, 0))
			end
		end
		for i = 0, 29 do
			for j = 0, 39 do
				m:addFace({ ids[i][j], ids[i][j + 1], ids[i + 1][j + 1], ids[i + 1][j] })
			end
		end
		local env = E.Deform.envelope(m, view, 0.2, 3)
		-- a horizontal line in the view (view Y is world y here); its left side, +y, is the upper layer
		local line = { Vector2.new(-2.5, 0), Vector2.new(2.5, 0) }
		local H, R = 0.6, 1.0
		local field = E.Deform.edgeField(
			view,
			line,
			{ envelope = env, height = H, radius = R, profile = "roll", drop = 0.2 }
		)
		local function lift(y: number): number
			-- movement toward the viewer at (0, 0, -10): -z
			return -field(Vector3.new(0, y, 0)).Z
		end
		near(lift(R), H, 1e-6) -- the top of the roll
		near(lift(0.5 * R), H * math.sqrt(0.75), 1e-6) -- on the quarter circle
		near(lift(3 * R), H * math.exp(-(2 / 1.2) ^ 2), 1e-6) -- easing back into the surface
		assert(lift(1.6) < H and lift(1.6) > 0, "the roll eases back")
		assert(lift(-0.4) < 0, "the lower side drops")
		-- the lip profile is unchanged by default, and unknown profiles are rejected
		local lip = E.Deform.edgeField(view, line, { envelope = env, height = H, width = 0.5 })
		near(-lip(Vector3.new(0, 0.5, 0)).Z, H * math.exp(-1), 1e-6)
		rejects(function()
			E.Deform.edgeField(view, line, { envelope = env, profile = "wave" })
		end, "edge profile must be")
		-- softroll: zero slope at the line, the same top at R
		local soft = E.Deform.edgeField(
			view,
			line,
			{ envelope = env, height = H, radius = R, profile = "softroll", drop = 0 }
		)
		local function softLift(y: number): number
			return -soft(Vector3.new(0, y, 0)).Z
		end
		near(softLift(R), H, 1e-6)
		near(softLift(0.5 * R), H * 0.5, 1e-6)
		assert(softLift(0.05) < 0.01 * H, "a soft roll starts flat at its edge")
		assert(lift(0.05) > 0.25 * H, "the quarter-circle roll starts steep")
		-- groove: a symmetric valley on both sides of the line
		local groove =
			E.Deform.edgeField(view, line, { envelope = env, height = 0.3, width = 0.4, profile = "groove" })
		near(groove(Vector3.new(0, 0, 0)).Z, 0.3, 1e-6)
		near(groove(Vector3.new(0, 0.4, 0)).Z, 0.3 * math.exp(-1), 1e-6)
		near(groove(Vector3.new(0, -0.4, 0)).Z, 0.3 * math.exp(-1), 1e-6)
	end)
	test("smoothDisplacement keeps linear fields, softens steps and agrees across meshes", function()
		local function sheet(x0: number, x1: number)
			local m = E.Mesh.new()
			local ids = {}
			for i = 0, math.round((x1 - x0) / 0.25) do
				ids[i] = {}
				for j = 0, 24 do
					ids[i][j] = m:addVertex(Vector3.new(x0 + i * 0.25, -3 + j * 0.25, 0))
				end
			end
			for i = 0, math.round((x1 - x0) / 0.25) - 1 do
				for j = 0, 23 do
					m:addFace({ ids[i][j], ids[i][j + 1], ids[i + 1][j + 1], ids[i + 1][j] })
				end
			end
			return m
		end
		-- two sheets sharing the column x = 0
		local left, right = sheet(-4, 0), sheet(0, 4)
		local linear = E.Deform.smoothDisplacement({ left, right }, function(p)
			return Vector3.new(0, 0, 0.1 * p.X + 0.3)
		end, { sigma = 0.4 })
		-- interior points: the Gaussian mean of a linear field is the field itself
		near(linear(Vector3.new(1, 0, 0)).Z, 0.4, 1e-6)
		near(linear(Vector3.new(-2, 0.5, 0)).Z, 0.1, 1e-6)
		local step = E.Deform.smoothDisplacement({ left, right }, function(p)
			return if p.X > 0.01 then Vector3.new(0, 0, 1) else Vector3.zero
		end, { sigma = 0.5 })
		local at0 = step(Vector3.new(0, 0, 0)).Z
		assert(at0 > 0.3 and at0 < 0.6, "step not softened at the edge: " .. at0)
		near(step(Vector3.new(3, 0, 0)).Z, 1, 1e-6)
		near(step(Vector3.new(-3, 0, 0)).Z, 0, 1e-9)
		local previous = -1
		for x = -1.5, 1.5, 0.25 do
			local z = step(Vector3.new(x, 0, 0)).Z
			assert(z >= previous - 1e-9, "not monotone")
			previous = z
		end
		-- the shared column gets one value whichever sheet asks
		local moved = E.Deform.map(left, function(p)
			return p + step(p)
		end)
		local movedRight = E.Deform.map(right, function(p)
			return p + step(p)
		end)
		for id, v in left.vertices do
			if math.abs(v.X) < 1e-9 then
				local zl = moved.vertices[id].Z
				for rid, w in right.vertices do
					if (w - v).Magnitude < 1e-9 then
						near(movedRight.vertices[rid].Z, zl, 1e-12)
					end
				end
			end
		end
		rejects(function()
			E.Deform.smoothDisplacement(left, function()
				return Vector3.zero
			end, { sigma = 0 })
		end, "Invalid smoothing options")
	end)
	test("box UVs with tile are world-aligned studs / tile and unpacked", function()
		local box = E.Deform.transform(E.Primitives.box(Vector3.new(8, 4, 2)), CFrame.new(10, 3, -5))
		local m, info = E.UV.box(box, nil, { tile = 4 })
		near(info.scale, 0.25)
		for fid, f in m.faces do
			local n = m:faceNormal(fid)
			for i, v in f.vertices do
				local p = m.vertices[v]
				local uv = f.corners[i].uv
				if math.abs(n.Z) > 0.9 then
					near(math.abs(uv.X), math.abs(p.X) / 4)
					near(uv.Y, -p.Y / 4)
				elseif math.abs(n.Y) > 0.9 then
					near(uv.X, p.X / 4)
				end
			end
		end
		rejects(function()
			E.UV.box(box, nil, { tile = 0 })
		end, "tile must be positive")
	end)
	test("Roblox.destroy refuses published bundles unless forced; release frees editables only", function()
		local R = E.Roblox
		local log = {}
		local function stub(name)
			return {
				Destroy = function()
					table.insert(log, name)
				end,
			}
		end
		local bundle: any = {
			model = stub("model"),
			handles = { { editable = stub("editable") } },
			images = { stub("image") },
			published = true,
		}
		local ok, err = pcall(R.destroy, bundle)
		assert(not ok and string.find(tostring(err), "Bundle is published", 1, true))
		assert(#log == 0, "nothing may be destroyed")
		R.release(bundle)
		assert(table.concat(log, ",") == "editable,image" and bundle.handles[1].editable == nil)
		R.release(bundle) -- idempotent
		R.destroy(bundle, { force = true })
		assert(table.concat(log, ",") == "editable,image,model")
		local preview: any = { model = stub("m2"), handles = { { editable = stub("e2") } }, images = {} }
		R.destroy(preview)
		assert(table.concat(log, ",") == "editable,image,model,m2,e2")
	end)
	test("Bake.skyVisibility darkens points under an overhang and stays open elsewhere", function()
		-- a 10 x 10 floor at y 0 and a 2 x 2 x 2 box floating at y 1..3 over its centre
		local floor = E.Mesh.new()
		local a = floor:addVertex(Vector3.new(-5, 0, -5))
		local b = floor:addVertex(Vector3.new(5, 0, -5))
		local c = floor:addVertex(Vector3.new(5, 0, 5))
		local d = floor:addVertex(Vector3.new(-5, 0, 5))
		floor:addFace({ a, d, c, b })
		local box = E.Primitives.box(Vector3.new(2, 2, 2))
		box = E.Deform.map(box, function(p)
			return p + Vector3.new(0, 2, 0)
		end)
		local sample, info = E.Bake.skyVisibility({ floor, box }, { directions = 32, pixel = 0.1 })
		assert(info.directions == 32 and info.triangles >= 14, "directions and triangles: " .. info.triangles)
		local under = sample(Vector3.new(0, 0.001, 0), Vector3.yAxis)
		local corner = sample(Vector3.new(4.5, 0.001, 4.5), Vector3.yAxis)
		local top = sample(Vector3.new(0, 3.001, 0), Vector3.yAxis)
		assert(under < 0.6, "under the box: " .. under)
		assert(corner > 0.9, "far corner open: " .. corner)
		assert(top > 0.98, "box top open: " .. top)
		-- a point facing away from every sampled direction counts as open
		assert(sample(Vector3.new(0, -1, 0), -Vector3.yAxis) >= 0, "downward normal handled")
		rejects(function()
			E.Bake.skyVisibility({})
		end, "needs occluders")
	end)
	test("Roblox.sweep keeps the editables listed in keep, directly or inside tables", function()
		local R = E.Roblox
		local log = {}
		local function editable(name)
			return {
				editable = true,
				Destroy = function()
					table.insert(log, name)
				end,
			}
		end
		local function isEditable(v)
			return type(v) == "table" and v.editable == true
		end
		local rough, metal, template, stale =
			editable("rough"), editable("metal"), editable("template"), editable("stale")
		local session: any = {
			images = { roughness = rough, metalness = metal },
			templates = { template },
			builds = { { images = { stale, rough } } },
		}
		local report =
			R.sweep(session, { live = {}, keep = { session.images, template }, isEditable = isEditable })
		assert(
			report.destroyed == 1 and report.kept == 3,
			"destroyed " .. report.destroyed .. ", kept " .. report.kept
		)
		assert(table.concat(log, ",") == "stale", table.concat(log, ","))
	end)
	test(
		"Roblox.sweep counts editables an earlier sweep destroyed as stale, without destroying them again",
		function()
			local R = E.Roblox
			local calls = 0
			local function editable()
				return {
					editable = true,
					Destroy = function()
						calls += 1
					end,
				}
			end
			local function isEditable(v)
				return type(v) == "table" and v.editable == true
			end
			local session: any = { a = editable(), b = { editable(), editable() } }
			local first = R.sweep(session, { live = {}, isEditable = isEditable })
			assert(first.destroyed == 3 and first.stale == 0 and calls == 3, "first sweep destroys three")
			local second = R.sweep(session, { live = {}, isEditable = isEditable })
			assert(
				second.destroyed == 0 and second.stale == 3 and calls == 3,
				"second sweep finds them stale"
			)
			local dry = R.sweep({ fresh = editable() }, { live = {}, isEditable = isEditable, dryRun = true })
			assert(
				dry.destroyed == 1 and dry.stale == 0 and calls == 3,
				"a dry run destroys nothing and marks nothing"
			)
		end
	)
	test("Roblox.sweep destroys unreferenced editables in nested tables and keeps live ones", function()
		local R = E.Roblox
		local log = {}
		local function editable(name)
			return {
				editable = true,
				Destroy = function()
					table.insert(log, name)
				end,
			}
		end
		local function isEditable(v)
			return type(v) == "table" and v.editable == true
		end
		local shown, stale, keyed, deep =
			editable("shown"), editable("stale"), editable("keyed"), editable("deep")
		local session: any = {
			build = { bundle = { handles = { { editable = shown } }, images = { stale } } },
			byImage = { [keyed] = "a key" },
			again = { stale },
			far = { { { { deep } } } },
			other = { 1, Vector3.one, "text" },
		}
		session.cycle = session
		local live = { [shown] = true }
		local dry = R.sweep(session, { live = live, isEditable = isEditable, dryRun = true })
		assert(dry.destroyed == 3 and dry.kept == 1 and #log == 0, "a dry run only counts")
		local shallow = R.sweep(session, { live = live, isEditable = isEditable, depth = 3 })
		assert(shallow.destroyed == 2 and shallow.kept == 0, "depth limits the tables searched")
		table.sort(log)
		assert(table.concat(log, ",") == "keyed,stale", table.concat(log, ","))
		local full = R.sweep(session, { live = live, isEditable = isEditable })
		-- the shallow sweep already destroyed "keyed" and "stale": they count as stale, destroyed once
		assert(full.destroyed == 1 and full.stale == 2 and full.kept == 1, "each object counted once")
		assert(#log == 3 and table.find(log, "deep") and not table.find(log, "shown"), "live editable kept")
		local calls = 0
		local big = table.create(120000, 0)
		R.sweep(big, {
			live = {},
			isEditable = isEditable,
			checkpoint = function()
				calls += 1
			end,
		})
		assert(calls == 4, "checkpoint every 50,000 keys and values: " .. calls)
	end)
	test("Spatial.coincident measures co-facing and back-to-back overlap by area", function()
		local function sheet(z, flip, shift)
			local out = {}
			for i = 1, 4 do
				local row = {}
				for j = 1, 5 do
					row[j] = Vector3.new(j + (shift or 0), -i, z)
				end
				out[if flip then 5 - i else i] = row
			end
			return E.Curves.loft(out, true, { closed = false })
		end
		local base = sheet(0, false)
		local c = E.Spatial.coincident(base, sheet(0.01, false))
		near(c.area, 12, 1e-6)
		near(c.sameFraction, 1, 1e-6)
		near(c.oppositeFraction, 0, 1e-6)
		local back = E.Spatial.coincident(base, sheet(0.01, true))
		near(back.sameFraction, 0, 1e-6)
		near(back.oppositeFraction, 1, 1e-6)
		near(E.Spatial.coincident(base, sheet(0.5, false)).sameFraction, 0, 1e-6)
		-- half the sheet overlaps a copy shifted by 2 of its 4 columns
		local half = E.Spatial.coincident(base, E.Spatial.new(sheet(0, false, 2)), { tolerance = 0.01 })
		near(half.same, 6, 1e-6)
		local pairs_ = E.Spatial.coincidentPairs({ base, sheet(0.02, false), sheet(3, false) })
		assert(#pairs_ == 2, "only the first two sheets coincide")
		for _, pr in pairs_ do
			assert(pr.a ~= 3 and pr.b ~= 3)
			near(pr.sameFraction, 1, 1e-6)
		end
	end)
	test("Spatial.trimCoincident removes only the co-facing overlap", function()
		local function sheet(z, flip, shift)
			local out = {}
			for i = 1, 4 do
				local row = {}
				for j = 1, 5 do
					row[j] = Vector3.new(j + (shift or 0), -i, z)
				end
				out[if flip then 5 - i else i] = row
			end
			return E.Curves.loft(out, true, { closed = false })
		end
		local lower = sheet(0, false)
		local trimmed, removed = E.Spatial.trimCoincident(lower, { sheet(0.01, false, 2) })
		assert(removed == 6, "two of four columns, 3 rows of quads: " .. removed)
		near(E.Spatial.coincident(trimmed, sheet(0, false)).area, 6, 1e-6)
		local _, none = E.Spatial.trimCoincident(lower, { sheet(0.01, true), sheet(1, false) })
		assert(none == 0, "back-to-back and distant layers stay")
	end)
	test("Roblox.partition makes spatially compact chunks from interleaved face order", function()
		-- every quad's first triangle, then every quad's second: the order triangulation can leave
		local m = E.Mesh.new()
		local ids = {}
		for i = 0, 20 do
			ids[i] = {}
			for j = 0, 20 do
				ids[i][j] = m:addVertex(Vector3.new(j, -i, 0))
			end
		end
		for half = 1, 2 do
			for i = 0, 19 do
				for j = 0, 19 do
					local a, b, c, d = ids[i][j], ids[i][j + 1], ids[i + 1][j + 1], ids[i + 1][j]
					if half == 1 then
						m:addFace({ a, b, c })
					else
						m:addFace({ a, c, d })
					end
				end
			end
		end
		local chunks = E.Roblox.partition(m, 100)
		assert(#chunks == 8, "8 full chunks")
		local area = 0
		for _, c in chunks do
			assert(#c.mesh:triangles() == 100)
			local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
			for _, v in c.mesh.vertices do
				lo, hi = lo:Min(v), hi:Max(v)
			end
			area += (hi.X - lo.X) * (hi.Y - lo.Y)
		end
		-- compact chunks tile the 20 x 20 sheet; interleaved ones would each span all of it
		assert(area <= 400 * 1.6, "chunk bounds overlap: " .. area)
	end)
	test("coincidence needs the point to project inside a triangle, not beside a gap", function()
		-- fine checkerboard: the keeper holds one triangle of each 0.1-stud quad, the other mesh
		-- the complementary halves 0.01 in front. Nothing overlaps, although every centroid of the
		-- second mesh is within 0.03 of a keeper edge.
		local function halves(which, z)
			local m = E.Mesh.new()
			local ids = {}
			for i = 0, 10 do
				ids[i] = {}
				for j = 0, 10 do
					ids[i][j] = m:addVertex(Vector3.new(j * 0.1, -i * 0.1, z))
				end
			end
			for i = 0, 9 do
				for j = 0, 9 do
					local a, b, c, d = ids[i][j], ids[i][j + 1], ids[i + 1][j + 1], ids[i + 1][j]
					m:addFace(if which == 1 then { a, b, c } else { a, c, d })
				end
			end
			return m
		end
		local keeper, other = halves(1, 0), halves(2, 0.01)
		near(E.Spatial.coincident(other, keeper).same, 0, 1e-9)
		local _, removed = E.Spatial.trimCoincident(other, { keeper })
		assert(removed == 0, "complementary halves are not coincident: " .. removed)
		near(E.Spatial.coincident(other, halves(2, 0.02)).sameFraction, 1, 1e-6)
	end)
	test("Topology.snap closes cracks across meshes and keeps their topology", function()
		local a, b = E.Mesh.new(), E.Mesh.new()
		local p1, p2 = a:addVertex(Vector3.new(0, 0, 0)), a:addVertex(Vector3.new(1, 0, 0))
		a:addFace({ p1, p2, a:addVertex(Vector3.new(0, 1, 0)) })
		-- the neighbour's copy of the shared edge drifted by 0.02
		local q1, q2 = b:addVertex(Vector3.new(0.02, 0, 0)), b:addVertex(Vector3.new(1, 0.02, 0))
		b:addFace({ q2, q1, b:addVertex(Vector3.new(0.5, -1, 0)) })
		local out, moved, removed = E.Topology.snap({ a, b }, 0.05)
		assert(moved == 4 and removed == 0, "four corners move: " .. moved)
		assert(out[1].vertices[p1] == out[2].vertices[q1] and out[1].vertices[p2] == out[2].vertices[q2])
		near(out[1].vertices[p1].X, 0.01, 1e-9)
		assert(#out[1]:triangles() == 1 and #out[2]:triangles() == 1)
		assert(a.vertices[p1] == Vector3.new(0, 0, 0), "inputs are not mutated")
		-- a sliver narrower than the tolerance collapses and is removed; seeds bound the moves
		local c = E.Mesh.new()
		c:addFace({
			c:addVertex(Vector3.new(0, 0, 0)),
			c:addVertex(Vector3.new(0.03, 0, 0)),
			c:addVertex(Vector3.new(0, 0.03, 0)),
		})
		local chain = E.Mesh.new()
		local apex = chain:addVertex(Vector3.new(0.2, 7, 0))
		local row = {}
		for k = 0, 9 do
			row[k] = chain:addVertex(Vector3.new(k * 0.04, 5, 0))
		end
		for k = 0, 8 do
			chain:addFace({ row[k], row[k + 1], apex })
		end
		local sealed, _, gone = E.Topology.snap({ c, chain }, 0.05)
		assert(gone >= 1 and #sealed[1]:triangles() == 0, "collapsed sliver removed")
		local count = 0
		for id, v in sealed[2].vertices do
			assert((v - chain.vertices[id]).Magnitude <= 0.05 + 1e-9, "no chained drift")
			count += 1
		end
		assert(count >= 5, "the chain keeps distinct vertices: " .. count)
	end)
	test("Deform.relief moves coincident soup corners together", function()
		-- two triangles meeting at a crease, as an unwelded soup: the shared edge has one vertex
		-- id per triangle and the faces turn different amounts toward the view
		local m = E.Mesh.new()
		local a1, b1 = m:addVertex(Vector3.new(0, 0, 0)), m:addVertex(Vector3.new(0, 1, 0))
		m:addFace({ b1, a1, m:addVertex(Vector3.new(-1, 0.5, 0)) })
		local a2, b2 = m:addVertex(Vector3.new(0, 0, 0)), m:addVertex(Vector3.new(0, 1, 0))
		m:addFace({ a2, b2, m:addVertex(Vector3.new(0.7, 0.5, 0.7)) })
		-- a backdrop far behind keeps the envelope defined around the edge's end points
		m:addFace({
			m:addVertex(Vector3.new(-3, -3, 5)),
			m:addVertex(Vector3.new(0, 4, 5)),
			m:addVertex(Vector3.new(3, -3, 5)),
		})
		local view = CFrame.lookAt(Vector3.new(0, 0.5, -10), Vector3.new(0, 0.5, 0))
		local out = E.Deform.relief(m, view, function()
			return 9
		end, { normals = false, minFacing = 0.5, depth = 3, step = 0.05 })
		assert(out.vertices[a1] == out.vertices[a2] and out.vertices[b1] == out.vertices[b2], "crack opened")
		assert(out.vertices[a1] ~= m.vertices[a1], "the shared edge moved")
	end)
	test("Primitives.prism faces outward for concave polygons in either winding", function()
		local function volume(m)
			local v = 0
			for _, t in m:triangles() do
				local a, b, c = m.vertices[t[1]], m.vertices[t[2]], m.vertices[t[3]]
				v += a:Dot(b:Cross(c)) / 6
			end
			return v
		end
		assert(volume(E.Primitives.box(Vector3.new(1, 2, 3))) > 0, "sign convention follows box")
		-- an L shape: area 3 (unit squares), concave corner at (1, 1)
		local l = {
			Vector2.new(0, 0),
			Vector2.new(2, 0),
			Vector2.new(2, 1),
			Vector2.new(1, 1),
			Vector2.new(1, 2),
			Vector2.new(0, 2),
		}
		local reversed = {}
		for i = #l, 1, -1 do
			table.insert(reversed, l[i])
		end
		for _, poly in { l, reversed } do
			local m = E.Primitives.prism(poly, 1, 3)
			near(volume(m), 6, 1e-9)
			-- each side face's normal points away from the interior
			for fid, f in m.faces do
				local n = m:faceNormal(fid)
				if math.abs(n.Y) < 0.5 then
					local c = Vector3.zero
					for _, v in f.vertices do
						c += m.vertices[v]
					end
					c /= #f.vertices
					local probe = c + n * 0.01
					local inside = probe.Y > 1
						and probe.Y < 3
						and probe.X > 0
						and probe.Z > 0
						and (probe.X < 1 and probe.Z < 2 or probe.Z < 1 and probe.X < 2)
					assert(not inside, "side face points inward")
				end
			end
		end
		-- a battered base: frustum of a 2 x 2 square, bottom scaled 1.5
		local sq = { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(1, 1), Vector2.new(-1, 1) }
		near(volume(E.Primitives.prism(sq, 0, 3, { bottomScale = 1.5 })), (4 + 9 + 6) * 3 / 3, 1e-9)
		-- stairs: solid volume = sum of step blocks
		local st = E.Primitives.stairs(2, 4, 2, 4)
		near(volume(st), 2 * (1 * 0.5 * 4 + 1 * 0.5 * 3 + 1 * 0.5 * 2 + 1 * 0.5 * 1) / 1, 1e-9)
	end)
	test("Primitives.tree is deterministic, stands on the ground and splits bark from foliage", function()
		local a = E.Primitives.tree({ height = 20, seed = 3 })
		local b = E.Primitives.tree({ height = 20, seed = 3 })
		local c = E.Primitives.tree({ height = 20, seed = 4 })
		local function bounds(m)
			local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
			for _, v in m.vertices do
				lo, hi = lo:Min(v), hi:Max(v)
			end
			return lo, hi
		end
		local la, ha = bounds(a)
		local lb, hb = bounds(b)
		assert(la == lb and ha == hb, "same seed, same tree")
		local lc, hc = bounds(c)
		assert(lc ~= la or hc ~= ha, "different seed, different tree")
		near(la.Y, 0, 1e-6)
		assert(ha.Y > 20 * 0.85 and ha.Y < 20 * 1.2, "height " .. ha.Y)
		local materials = {}
		for _, f in a.faces do
			materials[f.material] = (materials[f.material] or 0) + 1
		end
		assert(materials[1] and materials[2] and materials[2] > materials[1], "bark and foliage")
		assert(#E.Roblox.partition(a, 18000) == 2, "one chunk per material")
	end)
	test("Registration.translation and icp recover offsets; principalAxes; outline helpers", function()
		-- translation: an exact shifted copy with a third of its faces removed
		local src = E.Primitives.sphere(2, 12, 8)
		local shift = Vector3.new(3.25, -1.5, 0.75)
		local moved = E.Deform.transform(src, CFrame.new(shift), nil, { normals = "transform" })
		local keep = {}
		local i = 0
		for fid in moved.faces do
			i += 1
			if i % 3 ~= 0 then
				keep[fid] = true
			end
		end
		local t, votes = E.Registration.translation(src, E.Topology.extract(moved, keep))
		assert(t and votes > 10, "translation found")
		near((t - shift).Magnitude, 0, 1e-4)
		-- icp, translation only, from a nearby start
		local frame, rep = E.Registration.icp(
			src,
			moved,
			{ initial = CFrame.new(shift + Vector3.new(0.3, -0.2, 0.25)), iterations = 30 }
		)
		near((frame.Position - shift).Magnitude, 0, 2e-2)
		assert(rep.rms < 0.05)
		-- rigid icp recovers a small rotation of an asymmetric shape
		local boxy = E.Primitives.box(Vector3.new(4, 2, 1))
		local turn = CFrame.new(0.2, 0, 0) * CFrame.Angles(0, math.rad(6), 0)
		local turned = E.Deform.transform(boxy, turn, nil, { normals = "transform" })
		local rframe = E.Registration.icp(boxy, turned, { rigid = true, iterations = 40 })
		near((rframe.Position - turn.Position).Magnitude, 0, 5e-2)
		-- principal axes of a 6 x 2 x 1 box: X longest, Z shortest
		local pa = E.Geometry.principalAxes(E.Primitives.box(Vector3.new(6, 2, 1)))
		near(pa.center.Magnitude, 0, 1e-9)
		assert(math.abs(pa.axes[1].X) > 0.999 and math.abs(pa.axes[3].Z) > 0.999, "axes order")
		assert(pa.variances[1] > pa.variances[2] and pa.variances[2] > pa.variances[3])
		-- outlines in both windings
		local sq = { Vector2.new(0, 0), Vector2.new(4, 0), Vector2.new(4, 4), Vector2.new(0, 4) }
		local rsq = { sq[4], sq[3], sq[2], sq[1] }
		for _, poly in { sq, rsq } do
			assert(
				E.Planar.outlineContains(poly, Vector2.new(1, 1))
					and not E.Planar.outlineContains(poly, Vector2.new(5, 1))
			)
			near(E.Planar.outlineDistance(poly, Vector2.new(1, 2)), 1, 1e-9)
			local grown = E.Planar.offsetOutline(poly, 1)
			for _, q in grown do
				assert(not E.Planar.outlineContains(poly, q), "offset grows the outline")
				near(E.Planar.outlineDistance(poly, q), math.sqrt(2), 1e-6)
			end
		end
	end)
	test("MeshRepair.audit finds cracks, folds, isolated faces, duplicates and inside-out solids", function()
		local box = E.Primitives.box(Vector3.new(2, 2, 2))
		local good = E.MeshRepair.audit(box)
		assert(good.closed and not good.insideOut and good.boundaryEdges == 0 and good.foldedEdges == 0)
		near(good.signedVolume, 8, 1e-9)
		local bad = E.MeshRepair.audit(E.Topology.reverse(box))
		assert(bad.insideOut, "reversed box is inside-out")
		-- a sheet whose shared edge drifted 0.02 apart: cracks, and isolated faces in a soup
		local m = E.Mesh.new()
		m:addFace({
			m:addVertex(Vector3.new(0, 0, 0)),
			m:addVertex(Vector3.new(1, 0, 0)),
			m:addVertex(Vector3.new(0, 1, 0)),
		})
		m:addFace({
			m:addVertex(Vector3.new(1.02, 0, 0)),
			m:addVertex(Vector3.new(1, 1, 0)),
			m:addVertex(Vector3.new(0.02, 1, 0)),
		})
		local cracked = E.MeshRepair.audit(m)
		assert(cracked.crackEdges >= 2 and cracked.isolatedFaces == 2, "crack edges " .. cracked.crackEdges)
		-- a folded quad: the second triangle flipped back over the first
		local f = E.Mesh.new()
		local a, b, c =
			f:addVertex(Vector3.new(0, 0, 0)),
			f:addVertex(Vector3.new(1, 0, 0)),
			f:addVertex(Vector3.new(0, 1, 0))
		local d = f:addVertex(Vector3.new(0.3, 0.3, 0.001))
		f:addFace({ a, b, c })
		f:addFace({ b, d, c })
		local folded = E.MeshRepair.audit(f)
		assert(folded.foldedEdges == 1, "fold found")
		-- duplicates
		local dup = E.Mesh.new()
		local p, q, r =
			dup:addVertex(Vector3.new(0, 0, 0)),
			dup:addVertex(Vector3.new(1, 0, 0)),
			dup:addVertex(Vector3.new(0, 1, 0))
		dup:addFace({ p, q, r })
		dup:addFace({ q, r, p })
		assert(E.MeshRepair.audit(dup).duplicateFaces == 1)
	end)
	test("MeshRepair.despike pulls a pit back onto the surface and keeps real relief", function()
		-- a 2 x 2 stud sheet at 0.1 spacing with one vertex pushed 0.6 behind it, and a broad bump
		local rowsA = {}
		for r = 1, 21 do
			local row = {}
			for c = 1, 21 do
				local x, y = (c - 11) * 0.1, (r - 11) * 0.1
				row[c] = Vector3.new(x, y, 0.3 * math.exp(-(x * x + y * y) / 0.5))
			end
			rowsA[r] = row
		end
		local sheet = E.Topology.gridSheet(rowsA)
		local pit
		for id, v in sheet.vertices do
			if math.abs(v.X - 0.3) < 1e-6 and math.abs(v.Y + 0.4) < 1e-6 then
				pit = id
			end
		end
		local expected = sheet.vertices[pit]
		sheet:setPosition(pit, expected - Vector3.new(0, 0, 0.6))
		local fixed, rep = E.MeshRepair.despike(sheet, { distance = 0.2 })
		assert(rep.spikes == 1, "spikes " .. rep.spikes)
		near((fixed.vertices[pit] - expected).Magnitude, 0, 0.05)
		-- the bump (0.3 high over 1 stud) is real relief: nothing else moved
		for id, v in sheet.vertices do
			if id ~= pit then
				near((fixed.vertices[id] - v).Magnitude, 0, 1e-9)
			end
		end
		-- split copies of a vertex (a soup) move together
		local soup = E.Mesh.new()
		for _, f in sheet.faces do
			local vs = {}
			for i, v in f.vertices do
				vs[i] = soup:addVertex(sheet.vertices[v])
			end
			soup:addFace(vs)
		end
		local displaced = expected - Vector3.new(0, 0, 0.6)
		local copiesBefore = 0
		for _, v in soup.vertices do
			if (v - displaced).Magnitude < 1e-9 then
				copiesBefore += 1
			end
		end
		assert(copiesBefore >= 4, "the soup splits the pit vertex " .. copiesBefore)
		local fixedSoup = E.MeshRepair.despike(soup, { distance = 0.2 })
		local copies = 0
		for _, v in fixedSoup.vertices do
			if (v - expected).Magnitude < 0.05 then
				copies += 1
			end
			assert((v - displaced).Magnitude > 1e-6, "a copy stayed behind")
		end
		assert(copies == copiesBefore, "copies moved " .. copies .. " of " .. copiesBefore)
	end)
	test("Topology.gridSheet builds a masked sheet with grid UVs, winding toward +Z", function()
		local rowsB = {}
		for r = 1, 4 do
			local row = {}
			for c = 1, 5 do
				row[c] = if r == 2 and c == 3 then false else Vector3.new(c - 1, r - 1, 0)
			end
			rowsB[r] = row
		end
		local m = E.Topology.gridSheet(rowsB)
		-- 3 x 4 cells, the hole removes the 4 cells around (2, 3): 8 cells, 16 triangles; vertex (1, 3)
		-- belonged only to removed cells, so 20 - 2 vertices remain
		assert(count(m.faces) == 16, "faces " .. count(m.faces))
		assert(count(m.vertices) == 18, "vertices " .. count(m.vertices))
		for fid, f in m.faces do
			local n = m:faceNormal(fid)
			near(n.Z, 1)
			for i, v in f.vertices do
				local p = m.vertices[v]
				near(f.corners[i].uv.X, p.X / 4)
				near(f.corners[i].uv.Y, p.Y / 3)
			end
		end
		local flipped = E.Topology.gridSheet(rowsB, { flip = true })
		for fid in flipped.faces do
			near(flipped:faceNormal(fid).Z, -1)
		end
		rejects(function()
			E.Topology.gridSheet({ { Vector3.zero, Vector3.xAxis } })
		end, "gridSheet needs at least two rows")
	end)
	test("Normals.curvature gives 1/R on a sphere, 1/(2R) on a tube, and welds split parts", function()
		local sphere = E.Primitives.sphere(2, 48, 24)
		local _, normals, values = E.Normals.curvature({ sphere })
		local inside = 0
		for k, h in values do
			-- skip the poles' fans, where the umbrella operator is lopsided
			if math.abs(normals[k].Y) < 0.8 then
				assert(math.abs(h - 0.5) < 0.08, "sphere curvature " .. h)
				inside += 1
			end
		end
		assert(inside > 100, "sphere vertices checked")
		-- a tube of radius 1 with rings every 0.5 studs: |H| = 1/2 away from its open ends
		local profile = {}
		for i = 0, 8 do
			table.insert(profile, Vector2.new(1, -2 + 0.5 * i))
		end
		local tube = E.Curves.lathe(profile, 64)
		local points, _, tv = E.Normals.curvature({ tube })
		local checked = 0
		for k, p in points do
			if math.abs(p.Y) < 1.2 then
				assert(math.abs(math.abs(tv[k]) - 0.5) < 0.06, "tube curvature " .. tv[k])
				checked += 1
			end
		end
		assert(checked > 100, "tube vertices checked")
		-- two halves of the sphere weld into one surface: the seam's vertices match the whole sphere's
		local top, bottom = {}, {}
		for fid, f in sphere.faces do
			local c = Vector3.zero
			for _, v in f.vertices do
				c += sphere.vertices[v]
			end
			if c.Y >= 0 then
				top[fid] = true
			else
				bottom[fid] = true
			end
		end
		local parts = { E.Topology.extract(sphere, top), E.Topology.extract(sphere, bottom) }
		local p2, n2, v2 = E.Normals.curvature(parts)
		local seam = 0
		for k, h in v2 do
			if math.abs(p2[k].Y) < 0.2 and math.abs(n2[k].Y) < 0.8 then
				assert(math.abs(h - 0.5) < 0.08, "seam curvature " .. h)
				seam += 1
			end
		end
		assert(seam > 10, "seam vertices checked")
		local _, _, smoothed = E.Normals.curvature({ sphere }, { smooth = 3 })
		assert(#smoothed == #values, "smoothing keeps one value per vertex")
		rejects(function()
			E.Normals.curvature({})
		end, "curvature needs meshes")
	end)
	test(
		"Curves.ellipseStack inscribes rings in each level's x and z ranges and caps the ends round",
		function()
			local levels = {
				{ y = 0, x0 = -2, x1 = 2, z0 = -1, z1 = 1 },
				{ y = 2, x0 = -3, x1 = 1, z0 = -2, z1 = 2 },
				{ y = 4, x0 = -1, x1 = 1, z0 = -1, z1 = 1 },
			}
			local rows = E.Curves.ellipseStack(levels, { columns = 16 })
			assert(#rows == 3 and #rows[1] == 17, "rows and columns")
			near((rows[1][1] - rows[1][17]).Magnitude, 0)
			-- the middle level touches its rectangle at the axis directions: +x at column 1, +z a quarter round
			near(rows[2][1].X, 1)
			near(rows[2][1].Z, 0)
			near(rows[2][5].Z, 2)
			near(rows[2][9].X, -3)
			for _, row in rows do
				for _, p in row do
					assert(p.Y == row[1].Y, "rings lie at their level")
				end
			end
			-- resampled every 0.5 studs with interpolated ranges; caps shrink the ends toward the centre
			local fine = E.Curves.ellipseStack(
				levels,
				{ columns = 8, step = 0.5, capBottom = 1, capTop = 1, exponent = 3 }
			)
			assert(#fine == 9, "levels every 0.5 studs: " .. #fine)
			near(fine[3][1].Y, 1)
			near(fine[3][1].X, 1.5) -- x1 halfway between 2 and 1 at y 1, no cap there
			assert((fine[1][1] - Vector3.new(0, 0, 0)).Magnitude < 0.01, "bottom closed to its centre")
			rejects(function()
				E.Curves.ellipseStack({ levels[2], levels[1] })
			end, "ellipseStack levels must ascend in y")
		end
	)
	test("Roblox.studioLimits gives long-job limits and keeps overrides", function()
		local l = E.Roblox.studioLimits({ maxSeconds = 60, padding = 4 })
		assert(l.maxSeconds == 60 and l.padding == 4, "overrides kept")
		assert(l.maxWork == 1e11 and l.maxBytes == 2 ^ 31 and l.maxTriangles == 4e6, "defaults")
		assert(type(l.checkpoint) == "function", "yielding checkpoint")
		assert(E.Roblox.studioLimits().maxSeconds == 1800, "default time")
	end)
	test(
		"Topology.gridSectors cuts columns into sheets whose inset UVs map back to grid positions",
		function()
			local rows = {}
			for r = 1, 4 do
				local row = {}
				for c = 1, 9 do
					local a = (c - 1) / 8 * math.pi
					row[c] = Vector3.new(math.cos(a), r - 1, math.sin(a))
				end
				rows[r] = row
			end
			local seen = {}
			local pieces = E.Topology.gridSectors(rows, {
				sectors = { 1, 5, 9 },
				inset = 0.1,
				normal = function(r, c)
					seen[c] = true
					return Vector3.new(1, 0, 0)
				end,
			})
			assert(#pieces == 2, "two sectors")
			assert(
				pieces[1].first == 1 and pieces[1].last == 5 and pieces[2].first == 5 and pieces[2].last == 9,
				"bounds"
			)
			assert(seen[9] and seen[5] and seen[1], "normals asked with whole-grid columns")
			for _, piece in pieces do
				-- 3 x 4 cells
				assert(count(piece.mesh.faces) == 24, "faces " .. count(piece.mesh.faces))
				for _, f in piece.mesh.faces do
					for i, v in f.vertices do
						local p = piece.mesh.vertices[v]
						local uv = f.corners[i].uv
						assert(
							uv.X >= 0.1 - 1e-9
								and uv.X <= 0.9 + 1e-9
								and uv.Y >= 0.1 - 1e-9
								and uv.Y <= 0.9 + 1e-9,
							"inset"
						)
						local row, column = piece.toGrid(uv)
						near(row, p.Y + 1)
						local want = math.acos(math.clamp(p.X, -1, 1)) / math.pi * 8 + 1
						near(column, want)
					end
				end
			end
			rejects(function()
				E.Topology.gridSectors(rows, { sectors = { 1, 5 } })
			end, "gridSectors bounds must run from 1 to the column count")
		end
	)
	test("Bake.gridSample interpolates numbers and vectors bilinearly, clamped to the grid", function()
		local values = { { 0, 10 }, { 20, 30 } }
		near(E.Bake.gridSample(values, 1.5, 1.5), 15)
		near(E.Bake.gridSample(values, 1, 2), 10)
		near(E.Bake.gridSample(values, 9, -3), 20)
		local vecs = { { Vector3.zero, Vector3.xAxis }, { Vector3.yAxis, Vector3.one } }
		local v = E.Bake.gridSample(vecs, 1.5, 1.5)
		near(v.X, 0.5)
		near(v.Y, 0.5)
		near(v.Z, 0.25)
		near(E.Bake.gridSample({ { 7 } }, 3, 3), 7)
	end)
	test("Topology.gridSheet writes explicit unit normals to every corner, unchanged by flip", function()
		local rows = {}
		for r = 1, 3 do
			local row = {}
			for c = 1, 4 do
				row[c] = Vector3.new(c - 1, r - 1, 0.2 * (c - 1) * (c - 1))
			end
			rows[r] = row
		end
		-- the normal of the cylinder z = 0.2 x^2, unscaled: the sheet makes it unit
		local function normal(_, c, p)
			assert(p.X == c - 1, "normal gets the grid position")
			return Vector3.new(-0.4 * p.X, 0, 1) * 3
		end
		for _, flip in { false, true } do
			local m = E.Topology.gridSheet(rows, { normal = normal, flip = flip })
			assert(count(m.faces) == 12, "faces " .. count(m.faces))
			for _, f in m.faces do
				for i, v in f.vertices do
					local p = m.vertices[v]
					local want = Vector3.new(-0.4 * p.X, 0, 1).Unit
					near((f.corners[i].normal :: Vector3 - want).Magnitude, 0)
				end
			end
		end
		-- without the option corners carry no normal (recalculateNormals or toModel supply them)
		for _, f in E.Topology.gridSheet(rows).faces do
			assert(f.corners[1].normal == nil, "unexpected normal")
		end
	end)
	test("Deform.moveTable moves every copy of a listed position and passes others through", function()
		local field, stats = E.Deform.moveTable({
			{ 1, 2, 3, 0.5, 0, 0 },
			{ -4, 0.004, 9.99, 0, -1, 0 },
		})
		near((field(Vector3.new(1, 2, 3)) - Vector3.new(1.5, 2, 3)).Magnitude, 0)
		near((field(Vector3.new(1.002, 1.999, 3.001)) - Vector3.new(1.502, 1.999, 3.001)).Magnitude, 0)
		near((field(Vector3.new(-4, 0.006, 9.99)) - Vector3.new(-4, -0.994, 9.99)).Magnitude, 0)
		local p = Vector3.new(1.01, 2, 3)
		assert(field(p) == p, "outside the tolerance passes through")
		assert(stats.hits == 3 and stats.size == 2, "hits " .. stats.hits)
		rejects(function()
			E.Deform.moveTable({ { 1, 2, 3 } })
		end, "moveTable entries are { x, y, z, dx, dy, dz }")
	end)
	test("Deform.cylindricalMap squeezes a sector toward the axis and leaves the rest", function()
		local frame = CFrame.new(10, 0, -5)
		-- halve the radius beyond 1 over phi -45..45 (toward the frame's +X), keep everything else
		local map = E.Deform.cylindricalMap(frame, function(r, phi)
			if math.abs(phi) <= 45 and r > 1 then
				return 1 + (r - 1) * 0.5
			end
			return nil
		end)
		local function at(r, phiDeg, h)
			local a = math.rad(phiDeg)
			return frame:PointToWorldSpace(Vector3.new(r * math.cos(a), h, -r * math.sin(a)))
		end
		near((map(at(3, 0, 2)) - at(2, 0, 2)).Magnitude, 0, 1e-6)
		near((map(at(3, 30, -1)) - at(2, 30, -1)).Magnitude, 0, 1e-6)
		near((map(at(3, 90, 0)) - at(3, 90, 0)).Magnitude, 0, 1e-6)
		near((map(at(0.5, 0, 0)) - at(0.5, 0, 0)).Magnitude, 0, 1e-6)
		-- phi = 90 is the frame's -Z, the axis point stays, and a twist turns points round the axis
		near((at(1, 90, 0) - frame:PointToWorldSpace(Vector3.new(0, 0, -1))).Magnitude, 0, 1e-6)
		local twist = E.Deform.cylindricalMap(frame, function(r, phi, h)
			return r, phi + 90, h
		end)
		near((twist(at(2, 0, 4)) - at(2, 90, 4)).Magnitude, 0, 1e-6)
		near((twist(frame.Position) - frame.Position).Magnitude, 0, 1e-6)
	end)
	test("Deform.moveTable takes a flat list and matches across cell boundaries", function()
		-- entries sit just below cell boundaries on every axis; queries land just above them
		local field, stats = E.Deform.moveTable({ 0.0099, 0.0199, -0.0001, 1, 0, 0, 5, 5, 5, 0, 0, 2 })
		near((field(Vector3.new(0.0101, 0.0201, 0.0001)) - Vector3.new(1.0101, 0.0201, 0.0001)).Magnitude, 0)
		near((field(Vector3.new(5.002, 4.998, 5)) - Vector3.new(5.002, 4.998, 7)).Magnitude, 0)
		local far = Vector3.new(0.0099, 0.0199, 0.004)
		assert(field(far) == far, "beyond the tolerance on one axis passes through")
		assert(stats.size == 2 and stats.hits == 2, "size " .. stats.size .. " hits " .. stats.hits)
		rejects(function()
			E.Deform.moveTable({ 1, 2, 3, 4, 5 })
		end, "a flat moveTable has six numbers per move")
	end)
	test("MeshRepair.unfold untangles a crumpled vertex in a grid", function()
		local g = E.Topology.triangulate(E.Primitives.grid(6, 6, Vector2.new(6, 6)))
		-- push one interior vertex far across its neighbours, flipping its triangles
		local target
		for id, v in g.vertices do
			if math.abs(v.X) < 1e-6 and math.abs(v.Z) < 1e-6 then
				target = id
			end
		end
		g.vertices[target] = Vector3.new(2.5, 0.05, 0.4)
		local before = E.MeshRepair.audit(g)
		assert(before.foldedEdges > 0, "crumpled")
		local fixed, rep = E.MeshRepair.unfold(g)
		assert(rep.before > 0 and rep.after == 0, "no folds left " .. rep.after)
		assert(E.MeshRepair.audit(fixed).foldedEdges == 0)
	end)
	test("Deform.envelope fills interior holes when the step is finer than the mesh", function()
		-- a coarse 4 x 4 grid quad sheet facing the view, sampled at a step much finer than its edges
		local g = E.Topology.triangulate(E.Primitives.grid(2, 2, Vector2.new(4, 4)))
		g = E.Deform.transform(g, CFrame.Angles(-math.pi / 2, 0, 0)) -- into the XY plane
		local view = CFrame.lookAt(Vector3.new(0, 0, -10), Vector3.zero)
		local plain = E.Deform.envelope(g, view, 0.05)
		local filled = E.Deform.envelope(g, view, 0.05, 3)
		local holes, filledHoles = 0, 0
		for k, d in plain.depth do
			if d == false and filled.depth[k] ~= false then
				filledHoles += 1
			end
			if d == false then
				holes += 1
			end
		end
		assert(filledHoles >= 0 and holes >= filledHoles)
		-- every sample inside the sheet is defined after filling
		for x = -1.9, 1.9, 0.13 do
			for y = -1.9, 1.9, 0.17 do
				assert(filled:sample(Vector2.new(x, y)) ~= nil, "hole at " .. x .. "," .. y)
			end
		end
		-- the silhouette does not grow
		assert(filled:sample(Vector2.new(2.3, 0)) == nil)
	end)
	test("Deform.edge raises a lip on the left of the polyline and steps down on the right", function()
		local g = E.Topology.triangulate(E.Primitives.grid(40, 40, Vector2.new(8, 8)))
		g = E.Deform.transform(g, CFrame.Angles(-math.pi / 2, 0, 0)) -- sheet in the XY plane at z = 0
		local view = CFrame.lookAt(Vector3.new(0, 0, -10), Vector3.zero)
		-- view coordinates: q.X = -x (right vector is -X), q.Y = y; a horizontal line from q.X -3 to 3
		local out = E.Deform.edge(
			g,
			view,
			{ Vector2.new(-3, 0), Vector2.new(3, 0) },
			{ height = 0.3, width = 0.5, drop = 0.2, dropWidth = 0.4 }
		)
		local function zAt(x, y)
			local best, z = math.huge, 0
			for id, v in g.vertices do
				local d = (Vector2.new(v.X, v.Y) - Vector2.new(x, y)).Magnitude
				if d < best then
					best, z = d, out.vertices[id].Z
				end
			end
			return z
		end
		-- left of the direction (+q.X) is +q.Y = +y: raised toward the viewer (negative z)
		assert(zAt(0, 0.1) < -0.2, "lip " .. zAt(0, 0.1))
		assert(zAt(0, -0.1) > 0.05, "step down " .. zAt(0, -0.1))
		near(zAt(0, 2.5), 0, 1e-3)
		near(zAt(3.8, 0.1), 0, 1e-9) -- beyond the polyline's end (q.X = -3.8)
	end)
	test("Deform.taperComponents scales each spike about its own axis, base to tip", function()
		local function spike(dir)
			local c = E.Primitives.cylinder(0.5, 4, 8)
			local frame = CFrame.lookAt(dir * 3, dir * 5) * CFrame.Angles(-math.pi / 2, 0, 0)
			return E.Deform.transform(c, frame, nil, { normals = "transform" })
		end
		local m = E.Topology.join({ spike(Vector3.xAxis), spike(-Vector3.xAxis), spike(Vector3.zAxis) })
		local out = E.Deform.taperComponents(m, Vector3.zero, 2, 1)
		local function radiusAt(mesh, dir, along)
			local best = 0
			for _, v in mesh.vertices do
				local t = v:Dot(dir)
				if math.abs(t - along) < 0.05 then
					best = math.max(best, (v - dir * t).Magnitude)
				end
			end
			return best
		end
		for _, dir in { Vector3.xAxis, -Vector3.xAxis, Vector3.zAxis } do
			near(radiusAt(out, dir, 1), 1.0, 1e-3)
			near(radiusAt(out, dir, 5), 0.5, 1e-3)
		end
	end)
	test(
		"Deform.taperComponents keeps spikes with overlapping bases apart (each vertex by its own piece)",
		function()
			local function spike(dir)
				local c = E.Primitives.cylinder(0.5, 4, 12)
				local frame = CFrame.lookAt(dir * 2.2, dir * 4.2) * CFrame.Angles(-math.pi / 2, 0, 0)
				return E.Deform.transform(c, frame, nil, { normals = "transform" })
			end
			-- two spikes 20 degrees apart from near the origin: their bases overlap
			local a = spike(Vector3.xAxis)
			local b = spike(Vector3.new(math.cos(math.rad(20)), math.sin(math.rad(20)), 0))
			local joined = E.Deform.taperComponents(E.Topology.join({ a, b }), Vector3.zero, 2, 1)
			local ref = {}
			for _, piece in
				{
					E.Deform.taperComponents(a, Vector3.zero, 2, 1),
					E.Deform.taperComponents(b, Vector3.zero, 2, 1),
				}
			do
				for _, v in piece.vertices do
					table.insert(ref, v)
				end
			end
			local worst = 0
			for _, v in joined.vertices do
				local best = math.huge
				for _, r in ref do
					best = math.min(best, (v - r).Magnitude)
				end
				worst = math.max(worst, best)
			end
			assert(worst < 1e-4, "every vertex scaled about its own spike: worst " .. worst)
		end
	)
	test("Deform.segmentMap re-aims a segment, scales its length and turns and scales the offsets", function()
		-- +y of length 2 onto +z of length 4: the least rotation is a quarter turn about +x
		local map =
			E.Deform.segmentMap(Vector3.zero, Vector3.new(0, 2, 0), Vector3.xAxis, Vector3.new(1, 0, 4), 0.5)
		near((map(Vector3.new(0, 1, 0)) - Vector3.new(1, 0, 2)).Magnitude, 0, 1e-6)
		near((map(Vector3.new(0.3, 1, 0)) - Vector3.new(1.15, 0, 2)).Magnitude, 0, 1e-6)
		near((map(Vector3.new(0, 1, 0.2)) - Vector3.new(1, -0.1, 2)).Magnitude, 0, 1e-6)
		near((map(Vector3.new(0, 2, 0)) - Vector3.new(1, 0, 4)).Magnitude, 0, 1e-6)
		-- across as a function of u (0 at a0, 1 at b0), clamped beyond the ends
		local tapered = E.Deform.segmentMap(
			Vector3.zero,
			Vector3.yAxis,
			Vector3.zero,
			Vector3.yAxis,
			function(u)
				return 2 - u
			end
		)
		near(tapered(Vector3.new(0.1, 0, 0)).X, 0.2, 1e-6)
		near(tapered(Vector3.new(0.1, 0.5, 0)).X, 0.15, 1e-6)
		near(tapered(Vector3.new(0.1, 3, 0)).X, 0.1, 1e-6)
		near(tapered(Vector3.new(0.1, 3, 0)).Y, 3, 1e-6)
		-- opposite directions: a half turn
		local flip = E.Deform.segmentMap(Vector3.zero, Vector3.xAxis, Vector3.zero, -Vector3.xAxis)
		near((flip(Vector3.new(0.5, 0, 0)) - Vector3.new(-0.5, 0, 0)).Magnitude, 0, 1e-6)
		near(flip(Vector3.new(0, 0.3, 0)).Magnitude, 0.3, 1e-6)
	end)
	test("Deform.mapComponents gives each welded piece its own map and its axis, ends and length", function()
		local function rod(at)
			local c = E.Primitives.cylinder(0.25, 4, 8)
			return E.Deform.transform(c, CFrame.new(at), nil, { normals = "transform" })
		end
		local seen = {}
		local out = E.Deform.mapComponents(
			E.Topology.join({ rod(Vector3.new(-3, 0, 0)), rod(Vector3.new(3, 0, 0)) }),
			function(piece)
				table.insert(seen, piece)
				near(math.abs(piece.axis.Y), 1, 1e-6)
				near(piece.length, 4, 1e-6)
				near(math.min(piece.lo.Y, piece.hi.Y), -2, 1e-6)
				near(math.max(piece.lo.Y, piece.hi.Y), 2, 1e-6)
				if piece.center.X > 0 then
					return function(v)
						return v + Vector3.new(0, 0, 5)
					end
				end
				return nil
			end
		)
		assert(#seen == 2, "two pieces, got " .. #seen)
		for _, v in out.vertices do
			if v.X > 0 then
				near(v.Z, 5, 1.0)
			else
				near(v.Z, 0, 0.5)
			end
		end
	end)
	test("Deform.segmentMap rejects zero-length segments and invalid scales", function()
		rejects(function()
			E.Deform.segmentMap(Vector3.zero, Vector3.zero, Vector3.zero, Vector3.xAxis)
		end, "nonzero length")
		rejects(function()
			E.Deform.segmentMap(Vector3.zero, Vector3.xAxis, Vector3.zero, Vector3.zero)
		end, "nonzero length")
		local bad = E.Deform.segmentMap(Vector3.zero, Vector3.xAxis, Vector3.zero, Vector3.xAxis, function()
			return 0 / 0
		end)
		rejects(function()
			bad(Vector3.new(0.5, 1, 0))
		end, "invalid scale")
	end)
	test(
		"Deform.mapComponents reports each piece's bounds and count, keeps topology and skips pieces without area",
		function()
			local rod = E.Deform.transform(
				E.Primitives.cylinder(0.25, 4, 8),
				CFrame.new(3, 0, 0),
				nil,
				{ normals = "transform" }
			)
			local flat = E.Mesh.new()
			local a = flat:addVertex(Vector3.new(-3, 0, 0))
			local b = flat:addVertex(Vector3.new(-2, 0, 0))
			local c = flat:addVertex(Vector3.new(-1, 0, 0)) -- collinear: no area
			flat:addFace({ a, b, c })
			local joined = E.Topology.join({ rod, flat })
			local nv, nf = 0, 0
			for _ in joined.vertices do
				nv += 1
			end
			for _ in joined.faces do
				nf += 1
			end
			local pieces, indices = {}, {}
			local out = E.Deform.mapComponents(joined, function(piece)
				table.insert(pieces, piece)
				indices[piece.index] = true
				return function(v)
					return v + Vector3.new(0, 1, 0)
				end
			end)
			assert(#pieces == 1, "the piece without area is skipped, got " .. #pieces)
			local piece = pieces[1]
			local rodCount = 0
			for _ in rod.vertices do
				rodCount += 1
			end
			assert(piece.count == rodCount, "count " .. tostring(piece.count) .. " vs " .. rodCount)
			near(piece.min.X, 2.75, 1e-3)
			near(piece.max.X, 3.25, 1e-3)
			near(piece.min.Y, -2, 1e-3)
			near(piece.max.Y, 2, 1e-3)
			local ov, of = 0, 0
			for id, v in out.vertices do
				ov += 1
				local before = joined.vertices[id]
				if before.X > 2 then
					near((v - before).Magnitude, 1, 1e-9)
				else
					near((v - before).Magnitude, 0, 1e-12)
				end
			end
			for fid, f in out.faces do
				of += 1
				assert(
					table.concat(f.vertices, ",") == table.concat(joined.faces[fid].vertices, ","),
					"face order kept"
				)
			end
			assert(ov == nv and of == nf, "same vertices and faces")
		end
	)
	test("Deform.taperComponents keeps each face's corner data (UVs)", function()
		-- an elongated box (the box primitive carries per-corner UVs) standing on the anchor's side
		local spike =
			E.Deform.transform(E.Primitives.box(Vector3.new(0.6, 4, 0.6)), CFrame.new(0, 3, 0), nil, {
				normals = "transform",
			})
		local out = E.Deform.taperComponents(spike, Vector3.zero, 2, 1)
		local checked = 0
		for fid, f in spike.faces do
			local g = out.faces[fid]
			for i, corner in f.corners do
				if corner.uv then
					checked += 1
					near((g.corners[i].uv - corner.uv).Magnitude, 0, 1e-12)
				end
			end
		end
		assert(checked > 0, "the primitive carries UVs")
	end)
	test("Topology.componentLabels welds a triangle soup into its solid pieces", function()
		local m = E.Mesh.new()
		-- two tetrahedra as triangle soup: every face has its own three vertices
		local function tetra(offset)
			local a, b, c, d =
				Vector3.new(0, 0, 0) + offset,
				Vector3.new(1, 0, 0) + offset,
				Vector3.new(0, 1, 0) + offset,
				Vector3.new(0, 0, 1) + offset
			for _, tri in { { a, c, b }, { a, b, d }, { a, d, c }, { b, c, d } } do
				m:addFace({ m:addVertex(tri[1]), m:addVertex(tri[2]), m:addVertex(tri[3]) })
			end
		end
		tetra(Vector3.zero)
		tetra(Vector3.new(5, 0, 0))
		local labels, infos = E.Topology.componentLabels(m)
		assert(#infos == 2, "two pieces, got " .. #infos)
		assert(infos[1].count == 12 and infos[2].count == 12, "every soup vertex labelled")
		assert(math.abs(infos[1].centroid.X - 0.25) < 1e-6 and math.abs(infos[2].centroid.X - 5.25) < 1e-6)
		for id, label in labels do
			assert((m.vertices[id].X < 2) == (label == 1), "label follows the piece")
		end
		local _, apart = E.Topology.componentLabels(m, { tolerance = 0 })
		assert(#apart == 8, "without welding each soup face stands alone, got " .. #apart)
	end)
	return report
end
