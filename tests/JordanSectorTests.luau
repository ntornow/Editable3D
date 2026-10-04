return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local M, S, V = E.Mesh, E.Subdivision, Vector3.new
	local fixture = game:GetService("HttpService"):JSONDecode(require(script.Parent.JordanSectorFixtures))
	local function scalar(q)
		return assert(tonumber(q[1])) / assert(tonumber(q[2]))
	end
	local function near(a, b, tolerance)
		assert((a - b).Magnitude <= (tolerance or 1e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function fan()
		local m = M.new()
		for _, p in { V(0, 0.5, 0), V(-2, 0, 0), V(0, 1, 2), V(2, 0, 0), V(-1, 2, 3), V(1, 2, 0) } do
			m:addVertex(p)
		end
		m:addFace({ 1, 2, 5, 3 })
		m:addFace({ 1, 3, 6, 4 })
		return S.crease(m, nil, { [1] = 10 })
	end
	local function expected(m)
		return (m.vertices[2] - m.vertices[1]):Cross(m.vertices[4] - m.vertices[1]).Unit
	end
	local function grid(basis)
		local m = M.new()
		local ids = {}
		for y = 0, 4 do
			ids[y] = {}
			for x = -3, 3 do
				ids[y][x] = m:addVertex(V(x, y, (basis[1] == x and basis[2] == y) and 1 or 0))
			end
		end
		for y = 0, 3 do
			for x = -3, 2 do
				m:addFace({ ids[y][x], ids[y][x + 1], ids[y + 1][x + 1], ids[y + 1][x] })
			end
		end
		return S.crease(m, nil, { [ids[0][0]] = 10 })
	end
	test("225 independent annular operator coefficients match full-cage Catmull-Clark masks", function()
		for column, basis in fixture.coordinates do
			local refined = S.catmullClark(grid(basis), 1)
			for row, c in fixture.coordinates do
				local found
				for _, p in refined.vertices do
					if p.X == c[1] / 2 and p.Y == c[2] / 2 then
						assert(found == nil)
						found = p.Z
					end
				end
				assert(
					found ~= nil and found == scalar(fixture.matrix[row][column]),
					"Production annular mask mismatch"
				)
			end
		end
	end)
	test(
		"Exact half-eigenvalue projection includes the whole halo and has only the transverse Jordan coupling",
		function()
			local work = 0
			local R = require(script.Parent.ExactRational)(function(n)
				work += n or 1
				assert(work < 50000000)
			end, 8192)
			local zero, half = R.number(0), R.number(0.5)
			local function matrix(source)
				local out = {}
				for i, row in source do
					out[i] = {}
					for j, q in row do
						out[i][j] = R.div(R.number(tonumber(q[1])), R.number(tonumber(q[2])))
					end
				end
				return out
			end
			local function product(a, b)
				local out = {}
				for i = 1, 15 do
					out[i] = {}
					for j = 1, 15 do
						local value = zero
						for k = 1, 15 do
							value = R.add(value, R.mul(a[i][k], b[k][j]))
						end
						out[i][j] = value
					end
				end
				return out
			end
			local function equal(a, b)
				for i = 1, 15 do
					for j = 1, 15 do
						assert(R.equal(a[i][j], b[i][j]), "Exact annular matrix identity failed")
					end
				end
			end
			local a, p, n = matrix(fixture.matrix), matrix(fixture.projector), matrix(fixture.nilpotent)
			equal(product(p, p), p)
			equal(product(p, n), n)
			equal(product(n, p), n)
			local ap, nn = product(a, p), product(n, n)
			for i, c in fixture.coordinates do
				for j, d in fixture.coordinates do
					assert(R.equal(ap[i][j], R.add(R.mul(half, p[i][j]), n[i][j])))
					assert(nn[i][j].sign == 0)
					local s = d[2] == 0 and (d[1] == 0 and -2 or math.abs(d[1]) == 1 and 1 or 0) or 0
					assert(R.equal(n[i][j], R.div(R.number(c[2] * s), R.number(12))))
				end
			end
			local residual = {}
			for i, c in fixture.coordinates do
				residual[i] = {}
				local w = R.div(
					R.number(tonumber(fixture.generalizedMode[i][1])),
					R.number(tonumber(fixture.generalizedMode[i][2]))
				)
				for j, d in fixture.coordinates do
					local center = d[1] == 0 and d[2] == 0
					local s = d[2] == 0 and (center and -2 or math.abs(d[1]) == 1 and 1 or 0) or 0
					local t = d[2] == 0 and math.abs(d[1]) == 1 and d[1] / 2 or 0
					local av = center and R.number(-1)
						or d[2] == 1 and (math.abs(d[1]) == 1 and R.div(R.number(1), R.number(6)) or d[1] == 0 and R.div(
							R.number(2),
							R.number(3)
						) or zero)
						or zero
					local expected = R.add(
						R.add(R.mul(R.number(c[1]), R.number(t)), R.mul(R.number(c[2]), av)),
						R.mul(w, R.number(s))
					)
					assert(R.equal(p[i][j], expected), "Generalized eigenfunction decomposition differs")
					residual[i][j] = R.sub(
						R.sub(R.sub(a[i][j], center and R.number(1) or zero), R.mul(half, p[i][j])),
						n[i][j]
					)
				end
			end
			local annihilator = residual
			for _, entry in fixture.spectrum do
				local lambda = R.div(R.number(tonumber(entry[1][1])), R.number(tonumber(entry[1][2])))
				if R.compare(lambda, half) >= 0 then
					continue
				end
				assert(R.compare(lambda, R.number(0.25)) <= 0)
				local factor = {}
				for i = 1, 15 do
					factor[i] = {}
					for j = 1, 15 do
						factor[i][j] = R.sub(residual[i][j], i == j and lambda or zero)
					end
				end
				for _ = 1, entry[2] do
					annihilator = product(annihilator, factor)
				end
			end
			for _, row in annihilator do
				for _, x in row do
					assert(x.sign == 0, "A halo mode failed the strict subdominant annihilator")
				end
			end
		end
	)
	for _, boundary in { "edge", "fixed" } do
		test("A two-face star reaches the proved annular halo with " .. boundary .. " boundaries", function()
			local m = fan()
			m.groups.x = { [1] = 0, [2] = 1, [3] = 0, [4] = -1, [5] = 1, [6] = -1 }
			m.groups.y = { [1] = 0, [2] = 0, [3] = 1, [4] = 0, [5] = 1, [6] = 1 }
			local before = S.catmullClark(m, 2, { boundary = boundary })
			local after = S.catmullClark(before, 1, { boundary = boundary })
			local function extract(mesh, scale)
				local out = {}
				for row, c in fixture.coordinates do
					for id, p in mesh.vertices do
						if mesh.groups.x[id] == c[1] * scale and mesh.groups.y[id] == c[2] * scale then
							assert(not out[row])
							out[row] = p
						end
					end
					assert(out[row])
				end
				return out
			end
			local first, second = extract(before, 0.25), extract(after, 0.125)
			for i, row in fixture.matrix do
				local value = V(0, 0, 0)
				for j, q in row do
					value += first[j] * scalar(q)
				end
				near(value, second[i], 1e-6)
			end
		end)
	end
	test(
		"Fixed noncollinear two-face corners have an oriented normal and no finite two-partial jet",
		function()
			local m = fan()
			for face = 1, 2 do
				local r = S.limit(m, face, 0, 0)
				assert(
					r.complete
						and r.normalAvailable
						and r.oneSided
						and not r.derivativesAvailable
						and r.derivativeReason
				)
				assert(r.normalMethod == "fixedCornerJordan" and r.normalSectorFaces == 2)
				near(r.normal, expected(m), r.normalErrorBound)
			end
		end
	)
	test(
		"Annular analytic derivatives have the independently predicted logarithmic cross-product coefficient",
		function()
			local m = fan()
			local target = (m.vertices[2] - m.vertices[1]):Cross(m.vertices[4] - m.vertices[1]) / 6
			local evaluator = S.prepareLimit(m, { maxDepth = 24, maxWork = 20000000, tolerance = 1e-14 })
			for face = 1, 2 do
				for _, point in { { 0.75, 0 }, { 0.375, 0.25 }, { 0.75, 0.75 }, { 0, 0.75 } } do
					local values = {}
					for i, k in { 12, 16 } do
						local r = evaluator:evaluate(face, point[1] * 2 ^ -k, point[2] * 2 ^ -k)
						assert(
							r.derivativesAvailable
								and (r.method == "bicubic" or r.method == "bicubicOneSided")
						)
						values[i] = r.derivativeU:Cross(r.derivativeV)
					end
					near((values[2] - values[1]) / 4, target, 0.003)
				end
			end
		end
	)
	test("Cyclic face-corner mappings preserve the fixed Jordan normal orientation", function()
		for shift = 0, 3 do
			local m = fan()
			for _, face in m.faces do
				local v, c = table.clone(face.vertices), table.clone(face.corners)
				for j = 1, 4 do
					face.vertices[j] = v[(j + shift - 1) % 4 + 1]
					face.corners[j] = c[(j + shift - 1) % 4 + 1]
				end
			end
			local uv = ({ { 0, 0 }, { 0, 1 }, { 1, 1 }, { 1, 0 } })[shift + 1]
			for face = 1, 2 do
				local r = S.limit(m, face, uv[1], uv[2])
				assert(r.normalMethod == "fixedCornerJordan")
				near(r.normal, expected(m))
			end
		end
	end)
	test("Native scales and reflections preserve the bounded two-face normal", function()
		for _, scale in { 2 ^ -60, 1, 2 ^ 60 } do
			local m = fan()
			for id, p in m.vertices do
				m.vertices[id] = V(-p.Z, p.X, p.Y) * scale
			end
			local r = S.limit(m, 1, 0, 0, { tolerance = math.max(1e-12, scale * 1e-6) })
			assert(r.normalAvailable and not r.derivativesAvailable)
			near(r.normal, V(1, 0, 0), r.normalErrorBound)
		end
	end)
	test("Collinear and unresolved near-collinear fixed boundaries do not assert a normal", function()
		for _, epsilon in { 0, 2 ^ -80 } do
			local m = fan()
			m.vertices[1] = V(0, 0, 0)
			m.vertices[2] = V(1, 0, 0)
			m.vertices[4] = V(2, epsilon, 0)
			local r = S.limit(m, 1, 0, 0)
			assert(r.complete and not r.normalAvailable and not r.derivativesAvailable and r.normalReason)
		end
	end)
	test("Nonplanar interior controls do not change the fixed Jordan boundary normal", function()
		for seed = 1, 16 do
			local m = fan()
			for _, id in { 3, 5, 6 } do
				m.vertices[id] = V(seed - id, seed * id, id * id - seed * seed)
			end
			local r = S.limit(m, 1, 0, 0)
			assert(r.normalMethod == "fixedCornerJordan")
			near(r.normal, expected(m))
		end
	end)

	test("Opposed unequal collinear boundary rays retain the transverse limiting normal", function()
		local m = fan()
		m.vertices[1], m.vertices[2], m.vertices[4] = V(0, 0, 0), V(-1, 0, 0), V(3, 0, 0)
		local t = (m.vertices[2] - m.vertices[4]) / 2
		local a = (4 * m.vertices[3] + m.vertices[5] + m.vertices[6] - 6 * m.vertices[1]) / 6
		local normal = t:Cross(a).Unit
		local evaluator = S.prepareLimit(m, { maxDepth = 24, maxWork = 20000000, tolerance = 1e-14 })
		for face = 1, 2 do
			local r = evaluator:evaluate(face, 0, 0)
			assert(
				r.normalAvailable and not r.derivativesAvailable and r.normalMethod == "fixedCollinearJordan"
			)
			near(r.normal, normal, r.normalErrorBound)
			for _, point in { { 0.75, 0 }, { 0.375, 0.25 }, { 0.75, 0.75 }, { 0, 0.75 } } do
				local nearby = evaluator:evaluate(face, point[1] * 2 ^ -16, point[2] * 2 ^ -16)
				assert(nearby.normalAvailable)
				near(nearby.normal, normal, 0.001)
			end
		end
	end)
	test("Exact generalized annular mode has bounded horizontal control differences", function()
		for row = 0, 2 do
			for column = 1, 4 do
				local a, b =
					fixture.generalizedMode[row * 5 + column], fixture.generalizedMode[row * 5 + column + 1]
				assert(math.abs(scalar(a) - scalar(b)) <= 0.5)
			end
		end
		local F = require(script.Parent.SubdivisionFeaturePatch)
		local work = function() end
		assert(F.originalOpposed({ 0, 0, 0, 0 }, { -1, 0, 0, 0 }, { 3, 0, 0, 0 }, work))
		assert(not F.originalOpposed({ 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { 3, 0, 0, 0 }, work))
		assert(not F.originalOpposed({ 0, 0, 0, 1e-30 }, { -1, 0, 0, 0 }, { 3, 0, 0, 0 }, work))
	end)
	if not (settings and settings.skipNative) then
		test("Jordan corner normals and separate UVs survive native EditableMesh conversion", function()
			local source = fan()
			local r = S.limit(source, 1, 0, 0)
			local m = M.new()
			for _, id in { 1, 2, 4 } do
				m:addVertex(source.vertices[id])
			end
			m:addFace({ 1, 2, 3 }, {
				{ normal = r.normal, uv = Vector2.new(0, 0) },
				{ normal = r.normal, uv = Vector2.new(1, 0) },
				{ normal = r.normal, uv = Vector2.new(0, 1) },
			})
			local h = E.Roblox.toEditable(m)
			local ok, err = pcall(function()
				local copy = E.Roblox.fromEditable(h.editable)
				local count = 0
				for _, face in copy.faces do
					for _, corner in face.corners do
						near(corner.normal, r.normal)
						assert(corner.uv)
						count += 1
					end
				end
				assert(count == 3)
			end)
			h.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
