local harness = require(script.Parent.TestHarness)
return function(E)
	local report, test, rejects = harness()
	local T, B = E.Texture, E.Bake
	local function quad()
		local m = E.Mesh.new()
		for _, v in { Vector3.new(0, 0, 0), Vector3.new(1, 0, 0), Vector3.new(1, 1, 0), Vector3.new(0, 1, 0) } do
			m:addVertex(v)
		end
		m:addFace({ 1, 2, 3, 4 }, {
			{ uv = Vector2.new(0, 0) },
			{ uv = Vector2.new(1, 0) },
			{ uv = Vector2.new(1, 1) },
			{
				uv = Vector2.new(0, 1),
			},
		})
		return m
	end
	test("Texture limits reject before invoking generator", function()
		local calls = 0
		for _, options in { { maxPixels = 3 }, { maxBytes = 63 } } do
			rejects(function()
				T.generate(2, 2, function()
					calls += 1
					return Color3.new()
				end, options)
			end, "limit")
		end
		assert(calls == 0)
	end)
	test("Texture cancellation interrupts pixels and preserves input", function()
		local source = T.new(8, 8, Color3.new(1, 0, 0))
		local bytes = buffer.tostring(source.pixels)
		local calls = 0
		rejects(function()
			source:map(function(c)
				calls += 1
				return c, 1
			end, {
				checkpointEvery = 1,
				cancelled = function()
					return calls >= 4
				end,
			})
		end, "cancelled")
		assert(calls == 4 and buffer.tostring(source.pixels) == bytes)
	end)
	test("All texture transforms enforce shared work limits", function()
		local t = T.new(8, 8)
		local options = { maxWork = 1 }
		for _, fn in
			{
				function()
					return t:clone(options)
				end,
				function()
					return t:resize(4, 4, options)
				end,
				function()
					return t:blend(t, 1, options)
				end,
				function()
					return t:blur(2, 1, options)
				end,
				function()
					return t:normalFromHeight(1, options)
				end,
				function()
					return t:paint(Vector2.one, 1, Color3.new(), 1, options)
				end,
				function()
					return t:toRGBA8(false, options)
				end,
				function()
					return T.fromRGBA8(8, 8, buffer.create(256), false, options)
				end,
				function()
					return T.noise(8, 8, 1, 2, 1, options)
				end,
				function()
					return t:tiles(2, options)
				end,
			}
		do
			rejects(fn, "work limit")
		end
	end)
	test("Blur and tiled images cannot reset allocation limits", function()
		local t = T.new(8, 8)
		rejects(function()
			t:blur(1, 1, { maxBytes = 1500 })
		end, "allocation limit")
		rejects(function()
			t:tiles(2, { maxBytes = 1000 })
		end, "allocation limit")
	end)
	test("Nested operations notify completion once with cumulative usage", function()
		local calls = 0
		local progress
		local out = T.new(4, 4):blur(1, 1, {
			onComplete = function(p)
				calls += 1
				progress = p
			end,
		})
		assert(
			out.width == 4
				and calls == 1
				and progress.allocatedBytes >= 512
				and progress.work > 32
				and progress.operation == "Texture.blur"
		)
	end)
	test("Generator and progress exceptions propagate", function()
		rejects(function()
			T.generate(2, 2, function()
				error("shader error")
			end)
		end, "shader error")
		rejects(function()
			T.new(2, 2, nil, nil, {
				checkpoint = function()
					error("checkpoint error")
				end,
			})
		end, "checkpoint error")
	end)
	test("Bake rejects triangle overflow before shader execution", function()
		local called = false
		rejects(function()
			B.rasterize(quad(), 8, 8, function()
				called = true
				return Color3.new()
			end, { maxTriangles = 1 })
		end, "triangle limit")
		assert(not called)
	end)
	test("Bake cancellation and padding preserve source and coverage", function()
		local m = quad()
		local calls = 0
		rejects(function()
			B.rasterize(m, 8, 8, function()
				calls += 1
				return Color3.new()
			end, {
				checkpointEvery = 1,
				cancelled = function()
					return calls >= 3
				end,
			})
		end, "cancelled")
		assert(calls == 3 and #m.faces[1].vertices == 4)
		local t = T.new(4, 4)
		local coverage = buffer.create(16)
		buffer.writeu8(coverage, 0, 1)
		local before = buffer.tostring(coverage)
		rejects(function()
			B.dilate(t, coverage, 3, { maxBytes = 550 })
		end, "allocation limit")
		assert(buffer.tostring(coverage) == before and t:get(0, 0).R == 0)
		rejects(function()
			B.dilate(t, buffer.create(1), 1)
		end, "Coverage size")
	end)
	test("Bake work budget includes padding and ambient rays", function()
		local m = quad()
		local _, plain = B.rasterize(m, 4, 4, function()
			return Color3.new(1, 1, 1)
		end)
		rejects(function()
			B.rasterize(m, 4, 4, function()
				return Color3.new()
			end, { padding = 2, maxWork = plain.operation.work + 1 })
		end, "work limit")
		rejects(function()
			B.ambientOcclusion(m, 8, 8, { samples = 100, maxWork = 100 })
		end, "work limit")
	end)
	test("Bake emits one completion and reports actual covered pixels", function()
		local calls = 0
		local last
		local out, r = B.ambientOcclusion(quad(), 4, 4, {
			samples = 2,
			padding = 1,
			onComplete = function(p)
				calls += 1
				last = p
			end,
		})
		assert(
			calls == 1
				and r.coveredPixels == 16
				and r.operation == last
				and out.width == 4
				and last.operation == "Bake.ambientOcclusion"
		)
	end)
	return report
end
