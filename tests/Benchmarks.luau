-- Optional, explicit benchmarks. No scene modifications or asset uploads.
return function(E)
	local results = {}
	local function measure(name, fn)
		local start = os.clock()
		local result = fn()
		table.insert(results, { name = name, seconds = os.clock() - start, result = result })
	end
	measure("subdivide_sphere_two_levels", function()
		local m = E.Subdivision.catmullClark(E.Primitives.sphere(1, 32, 16), 2)
		return { vertices = m:validate().vertices, triangles = #m:triangles() }
	end)
	measure("BVH_1000_closest_queries", function()
		local m = E.Primitives.sphere(1, 48, 24)
		local index = E.Spatial.new(m)
		for i = 1, 1000 do
			index:closest(Vector3.new(math.sin(i), math.cos(i), 2))
		end
		return { queries = 1000, triangles = #m:triangles() }
	end)
	measure("256px_noise_and_blur", function()
		local t = E.Texture.noise(256, 256, 8, 4, 3):blur(3)
		return { width = t.width, height = t.height }
	end)
	measure("local_refine_300_splits_on_65024_triangles", function()
		local input = E.Primitives.sphere(1, 256, 128)
		local started = os.clock()
		local mesh, report = E.Adaptive.refine(input, 0.01, {
			maxOperations = 300,
			region = function(p)
				return p.X > 0.9
			end,
		})
		return {
			refineSeconds = os.clock() - started,
			splits = report.splits,
			triangles = #mesh:triangles(),
			closed = report.validation.closed,
		}
	end)
	return results
end
