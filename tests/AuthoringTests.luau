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
	return report
end
