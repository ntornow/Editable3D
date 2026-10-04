-- Pass the Editable3D API table, or call with nil after package installation.
return function(API)
	API = API or require(script.Parent.Parent)
	local B, L, I = API.BSDF, API.Lighting, API.Integrator
	local tests, report = {}, { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		table.insert(tests, { name, fn })
	end
	local function near(a, b, epsilon)
		assert(math.abs(a - b) <= (epsilon or 1e-5), tostring(a) .. " != " .. tostring(b))
	end
	local function vector(a, b, epsilon)
		near((a - b).Magnitude, 0, epsilon)
	end
	local function hemisphere(fn, rows, columns)
		local sum = 0
		for y = 0, rows - 1 do
			local cosine = (y + 0.5) / rows
			local sine = math.sqrt(1 - cosine * cosine)
			for x = 0, columns - 1 do
				local phi = 2 * math.pi * (x + 0.5) / columns
				sum += fn(Vector3.new(sine * math.cos(phi), cosine, sine * math.sin(phi)))
			end
		end
		return sum * 2 * math.pi / (rows * columns)
	end
	local function plane(height, material, size)
		local m = API.Mesh.new()
		size = size or 2
		local ids = {}
		for _, p in
			{
				Vector3.new(-size, height, -size),
				Vector3.new(-size, height, size),
				Vector3.new(size, height, size),
				Vector3.new(size, height, -size),
			}
		do
			table.insert(ids, m:addVertex(p))
		end
		m:addFace(ids, nil, material)
		return m
	end
	test("Fresnel normal incidence, reciprocity and total internal reflection", function()
		near(B.fresnelDielectric(1, 1, 1.5), 0.04)
		near(B.fresnelDielectric(0, 1, 1), 0)
		near(B.fresnelDielectric(0.5, 1.5, 1), 1)
		local ci = 0.8
		local ct = math.sqrt(1 - (1 / 1.5) ^ 2 * (1 - ci * ci))
		near(B.fresnelDielectric(ci, 1, 1.5), B.fresnelDielectric(ct, 1.5, 1))
	end)
	test("Diffuse sample integrates albedo without variance", function()
		local m, random = B.diffuse(Color3.new(0.2, 0.4, 0.8)), Random.new(6)
		for _ = 1, 100 do
			local s = B.sample(m, Vector3.yAxis, Vector3.yAxis, random)
			vector(s.weight, Vector3.new(0.2, 0.4, 0.8))
			near(s.pdf, s.direction.Y / math.pi)
		end
	end)
	test("GGX projected distribution normalization", function()
		for _, alpha in { 0.4, 0.8, 1 } do
			local mass = hemisphere(function(w)
				return B.distributionGGX(w.Y, alpha) * w.Y
			end, 512, 8)
			near(mass, 1, 0.001)
		end
	end)
	test("GGX visible-normal sampling matches independent solid-angle integration", function()
		local m = B.resolve(B.ggx({ roughness = 0.8, f0 = Color3.new(1, 1, 1) }))
		local wo = Vector3.new(0.8, 0.6, 0)
		local mass = hemisphere(function(w)
			return B.pdf(m, Vector3.yAxis, wo, w)
		end, 96, 192)
		local moment = hemisphere(function(w)
			return B.pdf(m, Vector3.yAxis, wo, w) * w.Y
		end, 96, 192)
		local accepted, sampledMoment, random, count = 0, 0, Random.new(53), 12000
		for _ = 1, count do
			local s = B.sample(m, Vector3.yAxis, wo, random)
			if s then
				accepted += 1
				sampledMoment += s.direction.Y
				near(s.pdf, B.pdf(m, Vector3.yAxis, wo, s.direction), 1e-6)
				assert(s.weight.X >= 0 and s.weight.X <= 1.0001)
			end
		end
		near(accepted / count, mass, 0.015)
		near(sampledMoment / count, moment, 0.015)
		assert(accepted < count, "Below-surface samples must remain null events")
	end)
	test("Reciprocal BRDF and white-furnace energy bound", function()
		local wo, wi = Vector3.new(0.6, 0.8, 0), Vector3.new(-0.3, 0.4, 0.8660254).Unit
		for _, material in
			{
				B.ggx({ roughness = 0.7, f0 = Color3.new(1, 1, 1) }),
				B.metallicRoughness({ baseColor = Color3.new(1, 1, 1), roughness = 0.6 }),
				B.metallicRoughness({ baseColor = Color3.new(0.8, 0.5, 0.2), roughness = 0.6, metallic = 1 }),
				B.metallicRoughness({
					baseColor = Color3.new(1, 1, 1),
					f0 = Color3.new(1, 1, 1),
					roughness = 0.6,
				}),
			}
		do
			local m = B.resolve(material)
			vector(B.evaluate(m, Vector3.yAxis, wo, wi), B.evaluate(m, Vector3.yAxis, wi, wo), 1e-5)
			local energy = hemisphere(function(w)
				return B.evaluate(m, Vector3.yAxis, wo, w).X * w.Y
			end, 96, 192)
			assert(energy > 0 and energy <= 1.005, "Energy gain: " .. energy)
		end
	end)
	test("Texture-valued materials and mixture PDFs", function()
		local texture = API.Texture.new(2, 2, Color3.new(0.2, 0.4, 0.8), 1)
		local m = B.resolve(
			B.metallicRoughness({
				baseColor = texture,
				roughness = function(hit)
					return hit.uv.X
				end,
			}),
			{ uv = Vector2.new(0.5, 0.2) }
		)
		vector(m.baseColor, Vector3.new(0.2, 0.4, 0.8))
		near(m.alpha, 0.25)
		local a, b = B.diffuse(Color3.new(1, 0, 0)), B.ggx({ roughness = 0.7 })
		local mixed = B.mix(a, b, 0.3)
		local wi, wo = Vector3.new(0.6, 0.8, 0), Vector3.yAxis
		near(B.pdf(mixed, wo, wo, wi), B.pdf(a, wo, wo, wi) * 0.7 + B.pdf(b, wo, wo, wi) * 0.3)
		vector(
			B.evaluate(mixed, wo, wo, wi),
			B.evaluate(a, wo, wo, wi) * 0.7 + B.evaluate(b, wo, wo, wi) * 0.3
		)
	end)
	test("Ideal dielectric transmission carries radiance eta-squared factor", function()
		local s = B.sample(B.dielectric(1.5), Vector3.yAxis, Vector3.yAxis, function()
			return 0.9
		end, true)
		assert(s.transmission and s.delta)
		vector(s.direction, -Vector3.yAxis)
		near(s.weight.X, 1 / 2.25)
		local tir = B.sample(
			B.dielectric(1.5),
			Vector3.yAxis,
			Vector3.new(math.sqrt(0.75), 0.5, 0),
			function()
				return 0.9
			end,
			false
		)
		assert(tir.delta and not tir.transmission)
		near(tir.pdf, 1)
	end)
	test("Environment texel sampling uses solid angle, including polar caps", function()
		local tex = API.Texture.generate(8, 4, function(_, x, y)
			return Color3.new((x + 1) * (y + 1), 0, 0), 1
		end)
		local env, random = L.environment(tex), Random.new(90)
		local integral = 0
		for index, omega in env.solidAngles do
			integral += env.weights[index] / (env.total * omega) * omega
		end
		near(integral, 1)
		local bins = table.create(32, 0)
		for _ = 1, 12000 do
			local s = L.sampleEnvironment(env, random)
			near(s.pdf, L.environmentPDF(env, s.direction), 1e-6)
			local u = (math.atan2(s.direction.Z, s.direction.X) / (2 * math.pi) + 0.5) % 1
			local v = math.acos(math.clamp(s.direction.Y, -1, 1)) / math.pi
			local index = math.min(3, math.floor(v * 4)) * 8 + math.min(7, math.floor(u * 8)) + 1
			bins[index] += 1
		end
		for index, count in bins do
			near(count / 12000, env.weights[index] / env.total, 0.008)
		end
		local black = L.environment(API.Texture.new(2, 2))
		near(L.sampleEnvironment(black, random).pdf, 1 / (4 * math.pi))
	end)
	test("Area-light sampling and hit PDF agree", function()
		local mesh = plane(2)
		local materials = { { kind = "diffuse", emission = Color3.new(3, 2, 1), twoSidedEmission = true } }
		local set, random = L.new(mesh, materials), Random.new(44)
		local index = API.Spatial.new(mesh)
		for _ = 1, 100 do
			local s = set:sample(Vector3.zero, random)
			local hit = index:raycast(Vector3.zero, s.direction)
			near(s.pdf, set:pdf(Vector3.zero, s.direction, hit), 1e-5)
			vector(s.radiance, Vector3.new(3, 2, 1))
		end
	end)
	test("Point-light inverse-square direct illumination and occlusion", function()
		local mesh = plane(0)
		local opts = {
			bounces = 1,
			lights = { L.point(Vector3.new(0, 2, 0), Color3.new(4 * math.pi, 4 * math.pi, 4 * math.pi)) },
		}
		local materials = { B.diffuse(Color3.new(1, 1, 1)) }
		local scene = I.prepare(mesh, materials, opts)
		local value = I.trace(scene, Vector3.new(0, 0.5, 0), -Vector3.yAxis, opts)
		vector(value, Vector3.one, 1e-5)
		local blocker = API.Topology.join({ mesh, plane(1, 1, 0.5) })
		local shadow =
			I.trace(I.prepare(blocker, materials, opts), Vector3.new(0, 0.5, 0), -Vector3.yAxis, opts)
		vector(shadow, Vector3.zero)
	end)
	test("MIS neither doubles nor loses uniform environment energy", function()
		local mesh, opts = plane(0), { bounces = 1, environment = Color3.new(1, 1, 1), rouletteDepth = 10 }
		local scene = I.prepare(mesh, { B.diffuse(Color3.new(0.7, 0.7, 0.7)) }, opts)
		local sum, random = 0, Random.new(71)
		for _ = 1, 6000 do
			sum += I.trace(scene, Vector3.yAxis, -Vector3.yAxis, opts, random).X
		end
		near(sum / 6000, 0.7, 0.015)
		local noDirect = I.trace(
			scene,
			Vector3.yAxis,
			-Vector3.yAxis,
			{ bounces = 1, directLighting = false },
			Random.new(12)
		)
		near(noDirect.X, 0.7, 1e-5)
	end)
	test("Deterministic HDR rendering, cancellation and explicit tone mapping", function()
		local camera = API.Camera.new(CFrame.lookAt(Vector3.new(0, 0, 4), Vector3.zero), 35, 4, 4)
		local materials = { { kind = "diffuse", baseColor = Color3.new(), emission = Color3.new(2, 3, 4) } }
		local opts = { samples = 2, bounces = 1, seed = 25 }
		local a = I.render(API.Primitives.box(), camera, materials, opts)
		local b = I.render(API.Primitives.box(), camera, materials, opts)
		assert(buffer.tostring(a.pixels) == buffer.tostring(b.pixels))
		near(a:get(2, 2).R, 2)
		near(I.toneMap(a):get(2, 2).R, 2 / 3)
		local noImage, report = I.render(API.Primitives.box(), camera, materials, {
			cancelled = function()
				return true
			end,
		})
		assert(noImage == nil and report.cancelled and report.completedRows == 0)
	end)
	test("Invalid material parameters fail explicitly and grazing evaluation stays finite", function()
		assert(not pcall(function()
			B.resolve(B.ggx({ roughness = -1 }))
		end))
		assert(not pcall(function()
			B.resolve(B.diffuse(Color3.new(2, 0, 0)))
		end))
		local material = B.ggx({ roughness = 0 })
		vector(B.evaluate(material, Vector3.yAxis, Vector3.xAxis, Vector3.yAxis), Vector3.zero)
		near(B.pdf(material, Vector3.yAxis, Vector3.yAxis, -Vector3.yAxis), 0)
		assert(B.sample(material, Vector3.yAxis, -Vector3.yAxis, Random.new(1)) == nil)
	end)
	for _, entry in tests do
		local start = os.clock()
		local ok, err = xpcall(entry[2], debug.traceback)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, {
			name = entry[1],
			passed = ok,
			seconds = os.clock() - start,
			error = not ok and tostring(err) or nil,
		})
	end
	report.success = report.failed == 0
	return report
end
