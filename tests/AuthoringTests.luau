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
	return report
end
