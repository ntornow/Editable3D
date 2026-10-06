-- Procedural surface patterns and the bake-preparation helpers they rely on (cylindrical UV
-- options, normal-preserving transforms). Expected values are derived analytically.
local harness = require(script.Parent.TestHarness)
return function(E)
	local report, test, rejects = harness()
	local P = E.Pattern
	local function near(a, b, tolerance)
		assert(math.abs(a - b) <= (tolerance or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	test("band is a soft window with smoothstep shoulders on both bounds", function()
		near(P.band(5, 0, 10, 1), 1)
		near(P.band(-3, 0, 10, 1), 0)
		near(P.band(13, 0, 10, 1), 0)
		near(P.band(0, 0, 10, 1), 0.5)
		near(P.band(10, 0, 10, 1), 0.5)
		near(P.band(0.5, 0, 10, 1), P.smoothstep(-1, 1, 0.5))
		near(P.band(5, 0, 10), 1)
		near(P.band(-0.01, 0, 10), 0)
	end)
	test("hash is deterministic, uniform in [0, 1) and sensitive to every input", function()
		local seen, sum, n = {}, 0, 0
		for i = -20, 19 do
			for j = -5, 4 do
				local h = P.hash(i, j, 3, 11)
				assert(h >= 0 and h < 1)
				assert(h == P.hash(i, j, 3, 11))
				assert(h == P.hash(i + 0.7, j + 0.2, 3.9, 11), "non-integers floor")
				seen[h] = true
				sum += h
				n += 1
			end
		end
		local distinct = 0
		for _ in seen do
			distinct += 1
		end
		assert(distinct == n, "collisions in a 400-cell lattice")
		near(sum / n, 0.5, 0.05)
		assert(P.hash(1, 2, 3, 0) ~= P.hash(1, 2, 3, 1))
		assert(P.hash(1, 2, 3) ~= P.hash(2, 1, 3))
		assert(P.hash(1, 2, 3) ~= P.hash(1, 2, 4))
	end)
	test("smoothstep matches the cubic Hermite and handles reversed and equal edges", function()
		near(P.smoothstep(0, 1, 0.25), 0.25 * 0.25 * (3 - 0.5))
		near(P.smoothstep(0, 1, -1), 0)
		near(P.smoothstep(0, 1, 2), 1)
		near(P.smoothstep(1, 0, 0.25), 1 - P.smoothstep(0, 1, 0.25))
		near(P.smoothstep(2, 2, 1.9), 0)
		near(P.smoothstep(2, 2, 2), 1)
	end)
	test("fbm stays in [-1, 1], is seed-dependent and equals math.noise for one octave", function()
		local p = Vector3.new(0.37, 1.91, -2.45)
		near(P.fbm(p, { octaves = 1, frequency = 2 }), math.noise(p.X * 2, p.Y * 2, p.Z * 2))
		local differs = false
		for i = 1, 50 do
			local q = Vector3.new(i * 0.731, i * 0.177, -i * 0.413)
			local a = P.fbm(q, { octaves = 5 })
			assert(a >= -1 and a <= 1)
			if a ~= P.fbm(q, { octaves = 5, seed = 9 }) then
				differs = true
			end
		end
		assert(differs)
		rejects(function()
			P.fbm(p, { frequency = 0 })
		end, "Invalid fbm options")
	end)
	test("planar panels give cells, local coordinates and seam distance in studs", function()
		local o = { projection = "planar" :: "planar", width = 4, height = 2 }
		local s = P.panels(Vector3.new(5, 3.5, 0), o)
		assert(s.column == 1 and s.row == 1)
		near(s.u, 0.25)
		near(s.v, 0.75)
		near(s.seam, 0.5) -- 1 stud from the left edge, 0.5 from the top edge
		local t = P.panels(Vector3.new(-0.5, -0.25, 7), o)
		assert(t.column == -1 and t.row == -1)
		near(t.seam, 0.25)
		assert(P.panels(Vector3.new(5.1, 3.4, 0), o).id == s.id, "same panel, same id")
		assert(P.panels(Vector3.new(9, 3.5, 0), o).id ~= s.id)
		local framed = P.panels(Vector3.new(1, 5 + 3.5, 0), {
			projection = "planar" :: "planar",
			width = 4,
			height = 2,
			frame = CFrame.new(0, 5, 0) * CFrame.Angles(0, 0, 0),
			rowOffset = 0,
		})
		assert(framed.row == 1 and framed.column == 0)
	end)
	test("row offset and jitter shift panels as specified", function()
		local base = { projection = "planar" :: "planar", width = 1, height = 1, rowOffset = 0.5 }
		local s = P.panels(Vector3.new(0.5, 0.4, 0), base)
		assert(s.row == -1)
		near(s.v, 0.9)
		local jittered = P.panels(
			Vector3.new(0.5, 0.6, 0),
			{ projection = "planar" :: "planar", width = 1, height = 1, jitter = 1, seed = 4 }
		)
		near(jittered.u, (0.5 + (P.hash(0, 0, 0, 4) - 0.5)) % 1)
	end)
	test("cylindrical panels wrap seamlessly with a whole number of columns", function()
		local o = { width = 1, height = 2, radius = 3 }
		local count = math.floor(2 * math.pi * 3 + 0.5) -- 19 columns
		local seen = {}
		for k = 0, 399 do
			local a = k / 400 * 2 * math.pi
			local s = P.panels(Vector3.new(math.cos(a) * 3, 0.5, math.sin(a) * 3), o)
			assert(s.column >= 0 and s.column < count)
			seen[s.column] = true
		end
		for c = 0, count - 1 do
			assert(seen[c], "column " .. c .. " missing")
		end
		-- just either side of the seam angle (0 by default) are opposite edges of the panel ring
		local before = P.panels(Vector3.new(3 * math.cos(-1e-4), 0.5, 3 * math.sin(-1e-4)), o)
		local after = P.panels(Vector3.new(3 * math.cos(1e-4), 0.5, 3 * math.sin(1e-4)), o)
		assert(before.column == count - 1 and after.column == 0)
		near(before.seam, 3e-4, 1e-5)
		near(after.seam, 3e-4, 1e-5)
		-- seam distance is physical at the point's own radius
		local half = math.pi / count -- half a column in radians
		near(P.panels(Vector3.new(6 * math.cos(half), 1, 6 * math.sin(half)), o).seam, 6 * half, 1e-5)
		rejects(function()
			P.panels(Vector3.zero, { width = 1, height = 1 })
		end, "reference radius")
		rejects(function()
			P.panels(Vector3.zero, { projection = "planar" :: "planar", width = 0, height = 1 })
		end, "positive")
	end)
	test("streaks are narrow vertical curtains that continue downward and follow coverage", function()
		local side = Vector3.new(0, 0, -1)
		assert(P.streaks(Vector3.new(1, 2, 3), Vector3.yAxis) == 0)
		assert(P.streaks(Vector3.new(1, 2, 3), -Vector3.yAxis) == 0)
		assert(P.streaks(Vector3.new(1, 2, 3), side, { coverage = 0 }) == 0)
		local o = { spacing = 0.3, length = 6, width = 0.05, coverage = 0.6, seed = 5 }
		local step = 0.005
		local runs, continued, checked = 0, 0, 0
		for row = 0, 19 do
			local y = row * 1.37
			local inside, start = false, 0
			for i = 0, 2000 do
				local x = i * step
				local v = P.streaks(Vector3.new(x, y, 0.123), side, o)
				assert(v >= 0 and v <= 1)
				if v > 0 and not inside then
					inside, start = true, x
				elseif v == 0 and inside then
					inside = false
					runs += 1
					-- a curtain of radius `width` cuts a plane in a strip at most 2 * width wide
					assert(x - start <= 2 * o.width + 2 * step, "streak too wide: " .. (x - start))
					local mid = Vector3.new((start + x) / 2, y, 0.123)
					checked += 1
					if P.streaks(mid - Vector3.new(0, 0.05, 0), side, o) > 0 then
						continued += 1
					end
				end
			end
		end
		assert(runs > 10, "too few streaks: " .. runs)
		assert(continued >= checked * 0.9, "streaks broken along up: " .. continued .. "/" .. checked)
		local function fraction(coverage)
			local hits = 0
			for i = 0, 59 do
				for j = 0, 59 do
					if
						P.streaks(
							Vector3.new(i * 0.037, j * 0.31, 0.2),
							side,
							{ coverage = coverage, seed = 3 }
						) > 0
					then
						hits += 1
					end
				end
			end
			return hits
		end
		local low, high = fraction(0.1), fraction(0.9)
		assert(high > low * 2, "coverage " .. low .. " vs " .. high)
		rejects(function()
			P.streaks(Vector3.zero, side, { width = 0 })
		end, "Invalid streak options")
	end)
	test("cylindrical and planar streaks follow leaning surfaces; world curtains do not", function()
		-- a cone flaring outward toward the bottom: r = 4 + 0.3 * (10 - y)
		local function point(angle, y)
			local r = 4 + 0.3 * (10 - y)
			return Vector3.new(math.cos(angle) * r, y, math.sin(angle) * r),
				Vector3.new(math.cos(angle), 0.3, math.sin(angle)).Unit
		end
		local function continuation(options)
			local found, continued = 0, 0
			for row = 0, 7 do
				local y = 4 + row * 0.9
				for i = 0, 3999 do
					local angle = i / 4000 * 2 * math.pi
					local p, n = point(angle, y)
					if P.streaks(p, n, options) > 0.3 then
						found += 1
						local q, m = point(angle, y - 0.6)
						if P.streaks(q, m, options) > 0 then
							continued += 1
						end
					end
				end
			end
			return continued / math.max(found, 1), found
		end
		local base = { spacing = 0.3, length = 8, width = 0.06, coverage = 0.7, seed = 2 }
		local cyl = table.clone(base)
		cyl.projection, cyl.radius = "cylindrical", 4
		local world = table.clone(base)
		local c, cFound = continuation(cyl)
		local w = continuation(world)
		assert(cFound > 20, "no cylindrical streaks")
		assert(c > 0.8, "cylindrical continuation " .. c)
		assert(w < c * 0.5, "world curtains should break on a leaning surface: " .. w .. " vs " .. c)
		-- planar: depth along the frame's Z is ignored entirely
		local planar =
			{ projection = "planar", spacing = 0.3, length = 8, width = 0.06, coverage = 0.7, seed = 2 }
		for i = 0, 200 do
			local x, y = i * 0.013, 5 + (i % 7) * 0.4
			local n = Vector3.new(0, 0, -1)
			near(
				P.streaks(Vector3.new(x, y, 0), n, planar),
				P.streaks(Vector3.new(x, y, 3.7), n, planar),
				1e-12
			)
		end
		rejects(function()
			P.streaks(Vector3.zero, Vector3.xAxis, { projection = "cylindrical" })
		end, "reference radius")
		rejects(function()
			P.streaks(Vector3.zero, Vector3.xAxis, { projection = "spiral" :: any })
		end, "Unknown streak projection")
	end)
	local function ring(): any
		local m = E.Mesh.new()
		local ids = {}
		local n = 12
		for i = 0, n - 1 do
			local a = i / n * 2 * math.pi
			ids[i] = {
				m:addVertex(Vector3.new(math.cos(a) * 2, 0, math.sin(a) * 2)),
				m:addVertex(Vector3.new(math.cos(a) * 2, 4, math.sin(a) * 2)),
			}
		end
		for i = 0, n - 1 do
			local a, b = ids[i], ids[(i + 1) % n]
			m:addFace({ a[1], b[1], b[2], a[2] })
		end
		return m
	end
	test("cylindrical UV options move the seam and normalize into the margin box", function()
		local m = ring()
		local legacy = E.UV.cylindrical(m, Vector3.zero, 4)
		local defaults = E.UV.cylindrical(m, Vector3.zero, 4, {})
		for id, f in legacy.faces do
			for i, c in f.corners do
				local d = defaults.faces[id].corners[i].uv
				near(c.uv.X % 1, d.X % 1, 1e-5)
				near(c.uv.Y, d.Y, 1e-5)
			end
		end
		-- seam between the 90 and 120 degree vertices: u = (angle - seam) / 2pi, plus 1 on the
		-- one face that straddles the seam
		local seam = math.rad(105)
		local seamed = E.UV.cylindrical(m, Vector3.zero, 4, { seamAngle = seam })
		local wrapped = 0
		for _, f in seamed.faces do
			local straddles = false
			for i, c in f.corners do
				local p = seamed.vertices[f.vertices[i]]
				local expected = ((math.atan2(p.Z, p.X) - seam) % (2 * math.pi)) / (2 * math.pi)
				near((c.uv.X - expected + 0.5) % 1 - 0.5, 0, 1e-5)
				assert(c.uv.X >= 0 and c.uv.X <= 1 + 1 / 12 + 1e-5)
				if c.uv.X > 1 then
					straddles = true
				end
			end
			if straddles then
				wrapped += 1
			end
		end
		assert(wrapped == 1, "faces across the seam: " .. wrapped)
		local fitted = E.UV.cylindrical(m, Vector3.new(0, 10, 0), 50, { normalize = true, margin = 0.05 })
		local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
		for _, f in fitted.faces do
			for _, c in f.corners do
				lo, hi = lo:Min(c.uv), hi:Max(c.uv)
			end
		end
		near(lo.X, 0.05)
		near(lo.Y, 0.05)
		near(hi.X, 0.95)
		near(hi.Y, 0.95)
		rejects(function()
			E.UV.cylindrical(m, nil, 4, { normalize = true, margin = 0.5 })
		end, "margin")
	end)
	test("cylindrical UV axis option matches a rotated mesh with the default axis", function()
		local m = ring()
		local tilt = CFrame.Angles(0.4, 0.3, -0.2)
		local tilted = E.Deform.transform(m, tilt, nil, { normals = "transform" })
		local a = E.UV.cylindrical(m, Vector3.zero, 4, { seamAngle = 0.1 })
		local b = E.UV.cylindrical(tilted, Vector3.zero, 4, { seamAngle = 0.1, axis = tilt.UpVector })
		for id, f in a.faces do
			for i, c in f.corners do
				near(c.uv.Y, b.faces[id].corners[i].uv.Y, 1e-5)
			end
		end
		local du = (b.faces[1].corners[1].uv.X - a.faces[1].corners[1].uv.X) % 1
		for id, f in a.faces do
			for i, c in f.corners do
				-- a rotation about the axis only offsets u; the ring's spin is the same everywhere
				near((b.faces[id].corners[i].uv.X - c.uv.X - du + 0.5) % 1 - 0.5, 0, 1e-5)
			end
		end
	end)
	test("Deform.transform can keep authored normals through rotation, scale and mirroring", function()
		local m = E.Mesh.new()
		local a, b, c = m:addVertex(Vector3.zero), m:addVertex(Vector3.xAxis), m:addVertex(Vector3.yAxis)
		local bent = Vector3.new(1, 0, 1).Unit -- authored, not the face normal
		m:addFace({ a, b, c }, {
			{ normal = bent, tangent = Vector3.xAxis },
			{ normal = bent, tangent = Vector3.xAxis },
			{ normal = bent, tangent = Vector3.xAxis },
		})
		local frame = CFrame.new(1, 2, 3) * CFrame.Angles(0, math.pi / 2, 0)
		local scale = Vector3.new(2, 1, 1)
		local out = E.Deform.transform(m, frame, scale, { normals = "transform" })
		local expected = frame.Rotation:VectorToWorldSpace(bent / scale).Unit
		for _, corner in out.faces[1].corners do
			near((corner.normal - expected).Magnitude, 0, 1e-5)
			near((corner.tangent - frame.Rotation:VectorToWorldSpace(Vector3.xAxis)).Magnitude, 0, 1e-5)
		end
		near((out.vertices[b] - frame:PointToWorldSpace(Vector3.new(2, 0, 0))).Magnitude, 0, 1e-5)
		-- mirroring reverses winding; normals stay geometrically consistent (inverse transpose)
		local mirror =
			E.Deform.transform(m, CFrame.identity, Vector3.new(-1, 1, 1), { normals = "transform" })
		local mirrored = Vector3.new(-bent.X, bent.Y, bent.Z)
		for _, corner in mirror.faces[1].corners do
			near((corner.normal - mirrored).Magnitude, 0, 1e-5)
		end
		local faceNormal = mirror:faceNormal(1)
		near(faceNormal:Dot(Vector3.zAxis), 1, 1e-5) -- -X mirror of a +Z triangle still faces +Z
		-- default mode is unchanged: normals come from positions
		local recalculated = E.Deform.transform(m, frame, scale)
		near(
			(recalculated.faces[1].corners[1].normal - frame.Rotation:VectorToWorldSpace(Vector3.zAxis)).Magnitude,
			0,
			1e-5
		)
		rejects(function()
			E.Deform.transform(m, frame, scale, { normals = "keep" :: any })
		end, "Unknown normals mode")
	end)
	return report
end
