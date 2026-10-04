-- Numerical fixtures use explicit texel values and analytic interpolation/compositing.
return function(E)
	local T = E.Texture
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) <= (tolerance or 2e-6), tostring(a) .. " != " .. tostring(b))
	end
	local function color(actual, expected, tolerance)
		near(actual.R, expected[1], tolerance)
		near(actual.G, expected[2], tolerance)
		near(actual.B, expected[3], tolerance)
	end
	local function redBlue(width, height)
		return T.generate(width or 2, height or 1, function(_, x)
			return x == 0 and Color3.new(1, 0, 0) or Color3.new(0, 0, 1), 1
		end)
	end
	local function sameBytes(a, b)
		assert(a.width == b.width and a.height == b.height)
		assert(buffer.tostring(a.pixels) == buffer.tostring(b.pixels), "Pixel bytes changed")
	end
	test("Texture sampling reproduces non-square texel centers including HDR and alpha", function()
		local t = T.generate(3, 5, function(_, x, y)
			return Color3.new(x * 2, y / 4, -x), (x + y) / 8
		end)
		for y = 0, 4 do
			for x = 0, 2 do
				local c, a = t:sample(Vector2.new((x + 0.5) / 3, (y + 0.5) / 5))
				color(c, { x * 2, y / 4, -x })
				near(a, (x + y) / 8)
			end
		end
	end)
	test("Bilinear texture sampling matches independent four-corner weights", function()
		local t = T.new(2, 2)
		t:set(0, 0, Color3.new(1, 0, 0), 0)
		t:set(1, 0, Color3.new(0, 1, 0), 0.25)
		t:set(0, 1, Color3.new(0, 0, 1), 0.5)
		t:set(1, 1, Color3.new(1, 1, 1), 1)
		local c, a = t:sample(Vector2.new(0.375, 0.625))
		-- Weights: 3/16, 1/16, 9/16, 3/16. RGBA are independent data channels.
		color(c, { 6 / 16, 4 / 16, 12 / 16 })
		near(a, 31 / 64)
	end)
	test("Clamped texture edges extend the boundary texels", function()
		local t = redBlue(2, 2)
		for _, y in { -20, 0, 0.5, 1, 20 } do
			for _, x in { -20, 0, 0.125, 0.25 } do
				color(t:sample(Vector2.new(x, y)), { 1, 0, 0 })
			end
			for _, x in { 0.75, 0.875, 1, 20 } do
				color(t:sample(Vector2.new(x, y)), { 0, 0, 1 })
			end
		end
	end)
	test("Repeat sampling interpolates continuously across both texture seams", function()
		local horizontal = redBlue()
		local vertical = T.generate(1, 2, function(_, _, y)
			return y == 0 and Color3.new(1, 0, 0) or Color3.new(0, 0, 1), 1
		end)
		for _, delta in { -1e-6, 0, 1e-6 } do
			color(horizontal:sample(Vector2.new(delta, 0.5), true), { 0.5, 0, 0.5 }, 3e-6)
			color(vertical:sample(Vector2.new(0.5, delta), true), { 0.5, 0, 0.5 }, 3e-6)
		end
	end)
	test("Repeat sampling blends all four texture corners at a tile corner", function()
		local t = T.new(2, 2)
		t:set(0, 0, Color3.new(1, 0, 0), 0)
		t:set(1, 0, Color3.new(0, 1, 0), 0.25)
		t:set(0, 1, Color3.new(0, 0, 1), 0.75)
		t:set(1, 1, Color3.new(1, 1, 1), 1)
		local c, a = t:sample(Vector2.zero, true)
		color(c, { 0.5, 0.5, 0.5 })
		near(a, 0.5)
	end)
	test("Repeated texture sampling is invariant under negative and positive whole tiles", function()
		local t = redBlue()
		for _, x in { -9, -1, 0, 1, 8 } do
			for _, y in { -7, 0, 3 } do
				color(t:sample(Vector2.new(x + 0.375, y + 0.5), true), { 0.75, 0, 0.25 })
			end
		end
	end)
	test("One-pixel textures and one-pixel axes retain their values", function()
		local single = T.new(1, 1, Color3.new(4, -1, 0.25), 0.125)
		for _, wrap in { false, true } do
			for _, uv in { Vector2.zero, Vector2.one, Vector2.new(-3.5, 20.25) } do
				local c, a = single:sample(uv, wrap)
				color(c, { 4, -1, 0.25 })
				near(a, 0.125)
			end
		end
		color(redBlue():sample(Vector2.new(0.25, -99), true), { 1, 0, 0 })
	end)
	test("Texture addressing can repeat longitude while clamping latitude", function()
		local t = T.new(2, 2)
		t:set(0, 0, Color3.new(1, 0, 0), 1)
		t:set(1, 0, Color3.new(0, 0, 1), 1)
		t:set(0, 1, Color3.new(0, 1, 0), 1)
		t:set(1, 1, Color3.new(0, 1, 0), 1)
		color(t:sample(Vector2.new(0, -1), true, false), { 0.5, 0, 0.5 })
		color(t:sample(Vector2.new(0, 2), true, false), { 0, 1, 0 })
		color(t:sample(Vector2.new(-1, 0), false, true), { 0.5, 0.5, 0 })
	end)
	test("Texture sampling rejects nonfinite coordinates without changing its source", function()
		local t = redBlue()
		local before = t:clone()
		for _, value in { math.huge, -math.huge, 0 / 0 } do
			for _, wrap in { false, true } do
				assert(not pcall(function()
					t:sample(Vector2.new(value, 0.5), wrap)
				end))
			end
		end
		sameBytes(t, before)
	end)
	test("Same-size texture resize is an independent byte-exact copy", function()
		for _, size in { Vector2.new(2, 1), Vector2.new(3, 5), Vector2.new(1, 7) } do
			local t = T.generate(size.X, size.Y, function(_, x, y)
				return Color3.new(x * 3 - 1, y * 0.125, (x + y) % 2), y % 2
			end)
			local out = t:resize(size.X, size.Y)
			sameBytes(t, out)
			assert(out ~= t and out.pixels ~= t.pixels)
			out:set(0, 0, Color3.new(100, 100, 100), 1)
			assert(t:get(0, 0).R == -1)
		end
	end)
	test("Texture upsampling follows explicit half-texel interpolation fixtures", function()
		local out = redBlue():resize(4, 3)
		local red = { 1, 0.75, 0.25, 0 }
		for y = 0, 2 do
			for x = 0, 3 do
				local c, a = out:get(x, y)
				color(c, { red[x + 1], 0, 1 - red[x + 1] })
				near(a, 1)
			end
		end
	end)
	test("Texture downsampling matches analytic two-by-two averages at sample centers", function()
		local t = T.generate(4, 4, function(_, x, y)
			return Color3.new(x, y, x * y), (x + y) / 8
		end)
		local out = t:resize(2, 2)
		for y = 0, 1 do
			for x = 0, 1 do
				local px, py = 2 * x + 0.5, 2 * y + 0.5
				local c, a = out:get(x, y)
				color(c, { px, py, px * py })
				near(a, (px + py) / 8)
			end
		end
	end)
	test("Painting on transparent pixels excludes hidden RGB", function()
		local out = T.new(3, 3, Color3.new(1, 0, 0), 0):paint(Vector2.one, 1, Color3.new(0, 0, 1), 0.5)
		local c, a = out:get(1, 1)
		color(c, { 0, 0, 1 })
		near(a, 0.5)
	end)
	test("Painting partially transparent pixels uses straight-alpha source-over", function()
		local out = T.new(1, 1, Color3.new(1, 0, 0), 0.25):paint(Vector2.zero, 1, Color3.new(0, 0, 1), 0.5)
		local c, a = out:get(0, 0)
		color(c, { 0.2, 0, 0.8 })
		near(a, 0.625)
	end)
	test("Paint falloff scales source coverage before alpha compositing", function()
		local out = T.new(5, 5, Color3.new(1, 0, 0), 0.25)
			:paint(Vector2.new(2, 2), 2, Color3.new(0, 0, 1), 0.5)
		local c, a = out:get(3, 2)
		color(c, { 3 / 7, 0, 4 / 7 })
		near(a, 7 / 16)
		local edge, alpha = out:get(4, 2)
		color(edge, { 1, 0, 0 })
		near(alpha, 0.25)
	end)
	test("Zero-opacity and out-of-image paint preserve even hidden pixel data", function()
		local t = T.new(3, 3, Color3.new(2, -1, 0.75), 0)
		sameBytes(t, t:paint(Vector2.one, 2, Color3.new(0, 0, 1), 0))
		sameBytes(t, t:paint(Vector2.one, 2, Color3.new(0, 0, 1), -1))
		sameBytes(t, t:paint(Vector2.new(-10, -10), 1, Color3.new(0, 0, 1), 1))
	end)
	test("Clipped paint and opaque overwrite leave source and unaffected pixels intact", function()
		local t = T.new(3, 3, Color3.new(1, 0, 0), 0.25)
		local before = t:clone()
		local out = t:paint(Vector2.zero, 1, Color3.new(0, 0, 1), 2)
		local c, a = out:get(0, 0)
		color(c, { 0, 0, 1 })
		near(a, 1)
		color(out:get(1, 1), { 1, 0, 0 })
		sameBytes(t, before)
	end)
	test("Repeated paint coverage and image blend agree with analytic source-over", function()
		local t = T.new(1, 1, Color3.new(1, 0, 0), 0)
		local once = t:paint(Vector2.zero, 1, Color3.new(0, 0, 1), 0.25)
		local twice = once:paint(Vector2.zero, 1, Color3.new(0, 0, 1), 0.25)
		local c, a = twice:get(0, 0)
		color(c, { 0, 0, 1 })
		near(a, 7 / 16)
		local blend = t:blend(T.new(1, 1, Color3.new(0, 0, 1), 1), 0.25)
		sameBytes(once, blend)
	end)
	test("Image blending preserves hidden data for zero contribution and tiny nonzero coverage", function()
		local hidden = T.new(1, 1, Color3.new(2, -1, 0.75), 0)
		sameBytes(hidden, hidden:blend(T.new(1, 1, Color3.new(0, 0, 1), 1), 0))
		sameBytes(hidden, hidden:blend(T.new(1, 1, Color3.new(0, 1, 0), 0)))
		local tiny = hidden:blend(T.new(1, 1, Color3.new(0, 0, 1), 1), 1e-15)
		local c, a = tiny:get(0, 0)
		color(c, { 0, 0, 1 })
		near(a / 1e-15, 1)
	end)
	test("Environment radiance is continuous across longitude without blending poles", function()
		local env = E.Lighting.environment(redBlue(2, 2))
		for _, z in { -1e-6, 0, 1e-6 } do
			local c = E.Lighting.environmentRadiance(env, Vector3.new(-1, 0, z).Unit)
			near(c.X, 0.5, 3e-6)
			near(c.Z, 0.5, 3e-6)
		end
		local poles = T.generate(2, 2, function(_, _, y)
			return y == 0 and Color3.new(1, 0, 0) or Color3.new(0, 0, 1), 1
		end)
		local polar = E.Lighting.environment(poles)
		local north = E.Lighting.environmentRadiance(polar, Vector3.yAxis)
		local south = E.Lighting.environmentRadiance(polar, -Vector3.yAxis)
		near(north.X, 1)
		near(north.Z, 0)
		near(south.X, 0)
		near(south.Z, 1)
	end)
	test("Camera projection baking preserves an aligned image at pixel centers", function()
		local m = E.Mesh.new()
		for _, p in
			{ Vector3.new(-1, 1, -1), Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, 1, -1) }
		do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3, 4 }, {
			{ uv = Vector2.new(0, 0) },
			{ uv = Vector2.new(0, 1) },
			{ uv = Vector2.new(1, 1) },
			{
				uv = Vector2.new(1, 0),
			},
		})
		local source = T.generate(4, 4, function(_, x, y)
			return Color3.new(x / 3, y / 3, (x + y) % 2), 1
		end)
		local out, coverage = E.Bake.project(m, source, E.Camera.new(CFrame.identity, 90, 4, 4), 4, 4)
		assert(coverage.coveredPixels == 16)
		for y = 0, 3 do
			for x = 0, 3 do
				color(out:get(x, y), { x / 3, y / 3, (x + y) % 2 })
			end
		end
	end)
	report.success = report.failed == 0
	test("Guided filter keeps the guide's edges and smooths elsewhere", function()
		-- guide: a sharp vertical step; input: the same step blurred plus noise
		local w, h = 32, 16
		local guide = T.generate(w, h, function(_, x)
			return x < 16 and Color3.new(0, 0, 0) or Color3.new(1, 1, 1), 1
		end)
		local input = T.generate(w, h, function(_, x, y)
			local soft = 1 / (1 + math.exp(-(x - 15.5) / 2.5))
			local noise = ((x * 7 + y * 13) % 5 - 2) * 0.02
			return Color3.new(soft + noise, soft, soft), 0.5
		end)
		local out = input:guided(guide, 3, 1e-4)
		-- far from the edge the result is flat (noise removed) and on each side of the step it
		-- jumps between neighbouring columns much more sharply than the input did
		local left = out:get(4, 8)
		local right = out:get(28, 8)
		near(left.G, (input:get(4, 8)).G, 0.05)
		assert(right.G > 0.9 and left.G < 0.1)
		local jumpIn = (input:get(16, 8)).G - (input:get(15, 8)).G
		local jumpOut = (out:get(16, 8)).G - (out:get(15, 8)).G
		assert(jumpOut > jumpIn * 2, "edge not sharpened: " .. jumpOut .. " vs " .. jumpIn)
		local _, alpha = out:get(5, 5)
		near(alpha, 0.5)
		local ok = pcall(function()
			input:guided(T.new(4, 4), 2, 1e-3)
		end)
		assert(not ok, "size mismatch accepted")
	end)
	return report
end
