return function(E)
	local A, S = E.Attributes, E.Selection
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b)
		assert(math.abs(a - b) < 1e-6, tostring(a) .. " ~= " .. tostring(b))
	end
	local function fixture()
		local m = E.Mesh.new()
		for _, p in { Vector3.zero, Vector3.xAxis, Vector3.yAxis, Vector3.new(2, 1, 0), Vector3.new(7, 7, 7) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 3 })
		m:addFace({ 2, 4, 3 })
		local channels = {
			vertex = { [1] = 0, [2] = 2, [3] = 4, [4] = 8 },
			edge = { ["1:2"] = 1, ["1:3"] = 3, ["2:3"] = 5, ["2:4"] = 7, ["3:4"] = 9 },
			face = { [1] = 10, [2] = 20 },
			corner = { ["1:1"] = 1, ["1:2"] = 2, ["1:3"] = 3, ["2:1"] = 4, ["2:2"] = 5, ["2:3"] = 6 },
		}
		for domain, values in channels do
			m = A.set(A.create(m, domain, domain, "number", 7), domain, values)
		end
		return m
	end
	test("Vertex domain converts by direct endpoints face vertices and directed corners", function()
		local m = fixture()
		local edge = A.convertDomain(m, "vertex", "edge")
		near(A.get(edge, "vertex", "2:3"), 3)
		near(A.get(edge, "vertex", "3:4"), 6)
		local face = A.convertDomain(m, "vertex", "face")
		near(A.get(face, "vertex", 1), 2)
		near(A.get(face, "vertex", 2), 14 / 3)
		local corner = A.convertDomain(m, "vertex", "corner")
		near(A.get(corner, "vertex", "2:1"), 2)
		near(A.get(corner, "vertex", "2:3"), 4)
	end)
	test("Edge domain averages each incident edge once including both corner sides", function()
		local m = fixture()
		local vertex, r = A.convertDomain(m, "edge", "vertex")
		near(A.get(vertex, "edge", 2), 13 / 3)
		near(A.get(vertex, "edge", 5), 7)
		assert(r.defaulted == 1)
		local face = A.convertDomain(m, "edge", "face")
		near(A.get(face, "edge", 2), 7)
		local corner = A.convertDomain(m, "edge", "corner")
		near(A.get(corner, "edge", "1:2"), 3)
		near(A.get(corner, "edge", "2:1"), 6)
	end)
	test("Face domain uses distinct incident faces and preserves face corners", function()
		local m = fixture()
		local vertex = A.convertDomain(m, "face", "vertex")
		near(A.get(vertex, "face", 2), 15)
		near(A.get(vertex, "face", 4), 20)
		local edge = A.convertDomain(m, "face", "edge")
		near(A.get(edge, "face", "2:3"), 15)
		near(A.get(edge, "face", "1:2"), 10)
		local corner = A.convertDomain(m, "face", "corner")
		near(A.get(corner, "face", "2:1"), 20)
	end)
	test("Corner domain reduction retains both sides of seams in its incidence average", function()
		local m = fixture()
		local vertex = A.convertDomain(m, "corner", "vertex")
		near(A.get(vertex, "corner", 2), 3)
		near(A.get(vertex, "corner", 3), 4.5)
		local edge = A.convertDomain(m, "corner", "edge")
		near(A.get(edge, "corner", "2:3"), 3.75)
		near(A.get(edge, "corner", "1:2"), 1.5)
		local face = A.convertDomain(m, "corner", "face")
		near(A.get(face, "corner", 1), 2)
		near(A.get(face, "corner", 2), 5)
	end)
	test("Domain conversion copies sparse defaults and permits a separately named output", function()
		local m = fixture()
		local encoded = E.IO.encode(m)
		local out = A.convertDomain(m, "vertex", "vertex", { name = "copy" })
		assert(A.get(out, "copy", 5) == 7 and not out.attributes.copy.values[5])
		out.attributes.copy.values[1] = 99
		assert(E.IO.encode(m) == encoded and A.get(out, "vertex", 1) == 0)
		local restored = E.IO.decode(E.IO.encode(A.convertDomain(m, "face", "corner")))
		assert(A.get(restored, "face", "2:2") == 20 and restored:validate().valid)
	end)
	test("Weighted domain reductions honor source weights and zero contribution defaults", function()
		local m = fixture()
		local out = A.convertDomain(m, "face", "vertex", {
			weight = function(source, target)
				return target == 1 and 0 or source
			end,
		})
		near(A.get(out, "face", 2), 50 / 3)
		near(A.get(out, "face", 1), 7)
		out = A.convertDomain(m, "face", "vertex", { interpolation = "nearest" })
		assert(A.get(out, "face", 2) == 10)
	end)
	test("Boolean and string reductions keep false values and deterministic categorical ties", function()
		local m = fixture()
		m = A.set(A.create(m, "enabled", "face", "boolean", true, "min"), "enabled", { [2] = false })
		m = A.set(A.create(m, "label", "face", "string", "none"), "label", { [1] = "first", [2] = "second" })
		local out = A.convertDomain(m, "enabled", "vertex")
		assert(not A.get(out, "enabled", 2) and A.get(out, "enabled", 1))
		out = A.convertDomain(m, "label", "edge")
		assert(A.get(out, "label", "2:3") == "first")
		assert(not pcall(A.convertDomain, m, "label", "edge", { interpolation = "linear" }))
	end)
	test("Vector and color domain interpolation uses native typed values", function()
		local m = fixture()
		m = A.set(
			A.create(m, "v", "face", "Vector3", Vector3.zero),
			"v",
			{ [1] = Vector3.xAxis, [2] = Vector3.yAxis }
		)
		m = A.set(
			A.create(m, "c", "face", "Color3", Color3.new()),
			"c",
			{ [1] = Color3.new(1, 0, 0), [2] = Color3.new(0, 0, 1) }
		)
		local out = A.convertDomain(m, "v", "edge")
		assert(A.get(out, "v", "2:3") == Vector3.new(0.5, 0.5, 0))
		out = A.convertDomain(m, "c", "edge")
		assert(A.get(out, "c", "2:3") == Color3.new(0.5, 0, 0.5))
	end)
	test("Mask domain conversion supports all any and mean with unselected defaults", function()
		local m = fixture()
		local all = S.convertDomain(m, { [1] = true, [2] = true }, "vertex", "face")
		assert(next(all) == nil)
		local any = S.convertDomain(m, { [1] = true }, "vertex", "face", { mode = "any" })
		assert(any[1] == 1 and not any[2])
		local mean = S.convertDomain(m, { [1] = 0.6 }, "vertex", "face", { mode = "mean" })
		near(mean[1], 0.2)
		local vs = S.convertDomain(m, { [1] = true }, "face", "vertex", { mode = "all" })
		assert(vs[1] == 1 and not vs[2] and not vs[5])
	end)
	test("Invalid domains references budgets weights and cancellation leave inputs intact", function()
		local m = fixture()
		local before = E.IO.encode(m)
		for _, options in
			{
				{ name = "edge" },
				{ maxReferences = 1 },
				{ maxElements = 2 },
				{
					weight = function()
						return -1
					end,
				},
				{
					weight = function()
						return math.huge
					end,
				},
				{
					checkpoint = function()
						error("cancelled")
					end,
				},
			}
		do
			assert(not pcall(A.convertDomain, m, "vertex", "face", options))
		end
		assert(not pcall(A.convertDomain, m, "vertex", "bad"))
		assert(not pcall(S.convertDomain, m, { [99] = true }, "vertex", "face"))
		assert(not pcall(S.convertDomain, m, { [1] = 1.01 }, "vertex", "face"))
		assert(E.IO.encode(m) == before)
	end)
	report.success = report.failed == 0
	return report
end
