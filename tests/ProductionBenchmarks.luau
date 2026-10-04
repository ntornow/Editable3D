-- Gates count deterministic work/allocations and use generous wall-time ceilings.
return function(E)
	local rows = {}
	local function run(name, fn, maxWork, maxBytes)
		local progress
		local started = os.clock()
		fn({
			maxWork = maxWork,
			maxBytes = maxBytes,
			maxSeconds = 15,
			onComplete = function(p)
				progress = p
			end,
		})
		local seconds = os.clock() - started
		assert(progress and progress.work > 0 and progress.allocatedBytes > 0, "Missing benchmark counters")
		assert(seconds < 15, "Benchmark time regression: " .. name)
		table.insert(rows, {
			name = name,
			seconds = seconds,
			work = progress.work,
			allocatedBytes = progress.allocatedBytes,
			maxWork = maxWork,
			maxBytes = maxBytes,
			maxSeconds = 15,
		})
	end
	run("noise256", function(o)
		E.Texture.noise(256, 256, 8, 4, 7, o)
	end, 400000, 1100000)
	local image = E.Texture.new(256, 256)
	run("blur256radius4", function(o)
		image:blur(4, 2, o)
	end, 1400000, 2200000)
	local mesh = E.Mesh.new()
	for _, p in { Vector3.zero, Vector3.xAxis, Vector3.yAxis } do
		mesh:addVertex(p)
	end
	mesh:addFace({ 1, 2, 3 }, { { uv = Vector2.zero }, { uv = Vector2.xAxis }, { uv = Vector2.yAxis } })
	run("ao64samples8", function(o)
		o.samples = 8
		E.Bake.ambientOcclusion(mesh, 64, 64, o)
	end, 30000, 100000)
	return {
		success = true,
		benchmarks = rows,
		allocationMetric = "cumulative accounted bytes; not peak heap",
	}
end
