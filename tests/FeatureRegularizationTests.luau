return function(E, settings)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local regularize = require(script.Parent.SourceFeatureRegularization)
	local V = Vector3.new
	local function config(distance)
		return {
			regularization = { method = "features", distance = distance or 1 / 512 },
			tolerance = 1e-7,
			windingPrecision = "exact",
			maxWork = 50000000,
		}
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 1e-8), tostring(a) .. " ~= " .. tostring(b))
	end
	local function check(out, r)
		assert(r.complete, r.reason)
		assert(r.validation.valid and (r.validation.closed or r.empty))
		assert(r.intersections.complete and r.intersections.intersectionFree)
		local s = assert(r.arrangement.regularization)
		assert(
			s.displacementCertified
				and s.sourceSurfaceBoundCertified
				and s.triangleHomotopyOrientationCertified
		)
		assert(s.maxDisplacement == s.sourceSurfaceHausdorffBound and s.maxDisplacement <= s.distance)
		assert(not s.globalIsotopyCertified and not s.originalSolidEqualityCertified)
	end
	local function direct(mesh, distance, extra)
		local options = extra or config(distance)
		options.regularization = { method = "features", distance = distance }
		local work = 0
		return regularize(mesh, options, function(_, n)
			work += n or 1
			assert(work <= 50000000, "Fixture work cap")
		end)
	end
	local function meshWithPoints(target, sources)
		local m = E.Mesh.new()
		for _, point in target do
			m:addVertex(point)
		end
		local polygon = {}
		for i = 1, #target do
			polygon[i] = i
		end
		m:addFace(polygon)
		for _, tri in sources do
			local ids = {}
			for _, p in tri do
				table.insert(ids, m:addVertex(p))
			end
			m:addFace(ids)
		end
		return m
	end
	local target = { V(0, 0, 0), V(4, 0, 0), V(0, 4, 0) }
	local function sample(p, points)
		return meshWithPoints(points or target, { { p, V(p.X, p.Y, 2), V(p.X + 1, p.Y, 2) } })
	end
	local function pair()
		local a, b = E.Primitives.box(), E.Primitives.box()
		local selected = {}
		for fid, face in b.faces do
			local left = true
			for _, id in face.vertices do
				if b.vertices[id].X ~= -1 then
					left = false
				end
			end
			if left then
				selected[fid] = true
			end
		end
		local poke
		b, poke = E.MeshEdit.poke(b, selected)
		for _, id in poke.centers do
			b.vertices[id] = V(-1, 0.25, 0.125)
		end
		for id, p in b.vertices do
			b.vertices[id] = p + V(2 + 1 / 1024, 0, 0)
		end
		return a, b
	end
	local function joined()
		local a, b = pair()
		return E.Topology.join({ a, b })
	end
	test("144 independent exact closest-feature KKT witnesses", function()
		local work = 0
		local function tick(n)
			work += n or 1
			assert(work <= 10000000)
		end
		local R = require(script.Parent.ExactRational)(tick, 8192)
		local G = require(script.Parent.ExactFeatureClosest)(R, tick)
		local fixtures = game:GetService("HttpService")
			:JSONDecode(require(script.Parent.FeatureClosestFixtures))
		local function scalar(pair)
			return R.div(R.number(pair[1]), R.number(pair[2]))
		end
		local function vector(values)
			local out = {}
			for i, x in values do
				out[i] = scalar(x)
			end
			return out
		end
		for _, case in fixtures do
			local triangle = {}
			for i, row in case.triangle do
				triangle[i] = vector(row)
			end
			local result = G.triangle(vector(case.point), triangle)
			assert(result.dimension == case.dimension and R.equal(result.squared, scalar(case.squared)))
			for axis = 1, 3 do
				assert(
					R.equal(result.position[axis], scalar(case.closest[axis]))
						and R.equal(result.weights[axis], scalar(case.weights[axis]))
				)
			end
		end
		assert(#fixtures == 144)
	end)
	test("216 exact motion coefficients match independent determinant interpolation", function()
		local work = 0
		local function tick(n)
			work += n or 1
			assert(work <= 20000000)
		end
		local R = require(script.Parent.ExactRational)(tick, 8192)
		local G = require(script.Parent.ExactFeatureClosest)(R, tick)
		local fixtures = game:GetService("HttpService")
			:JSONDecode(require(script.Parent.FeatureMotionFixtures))
		local function scalar(p)
			return R.div(R.number(p[1]), R.number(p[2]))
		end
		local function points(values)
			local out = {}
			for i, p in values do
				out[i] = {}
				for j, x in p do
					out[i][j] = scalar(x)
				end
			end
			return out
		end
		for _, case in fixtures do
			local valid, coefficients = G.orientation(points(case.reference), points(case.current))
			assert(valid == case.valid)
			for i, x in coefficients do
				assert(R.equal(x, scalar(case.coefficients[i])))
			end
			for i, value in case.samples do
				local t = R.div(R.number(i - 1), R.number(8))
				local s = R.sub(R.number(1), t)
				local x = R.add(
					R.add(R.mul(coefficients[1], R.mul(s, s)), R.mul(coefficients[2], R.mul(s, t))),
					R.mul(coefficients[3], R.mul(t, t))
				)
				assert(R.equal(x, scalar(value)))
			end
		end
		assert(#fixtures == 72)
	end)
	for _, case in
		{
			{ "vertex", V(-0.01, -0.01, 0.01), 0.02, 0, 2, 0 },
			{ "edge", V(2, -0.01, 0.01), 0.02, 1, 3, 1 },
			{ "face", V(1, 1, 0.01), 0.02, 2, 4, 1 },
			{
				"oblique rational projection",
				V(1, 1, 0.3),
				0.1,
				2,
				4,
				1,
				{ V(0, 0, 0), V(3, 1, 0), V(1, 3, 1) },
			},
			{
				"shared triangulation edge",
				V(2, 2, 0.01),
				0.02,
				1,
				5,
				1,
				{
					V(0, 0, 0),
					V(4, 0, 0),
					V(4, 4, 0),
					V(0, 4, 0),
				},
			},
		}
	do
		test("Conforming " .. case[1] .. " source snap preserves separate identities", function()
			local mesh = sample(case[2], case[7])
			local before = E.IO.encode(mesh)
			local out, r = direct(mesh, case[3])
			assert(
				#r.snaps == 1
					and r.snaps[1].dimension == case[4]
					and r.triangles == case[5]
					and r.addedVertices == case[6]
			)
			local snap = r.snaps[1]
			assert(
				snap.sourceVertex ~= snap.targetVertex
					and out.vertices[snap.sourceVertex] == out.vertices[snap.targetVertex]
			)
			assert(r.maxDisplacement <= case[3] and out:validate().valid and E.IO.encode(mesh) == before)
		end)
	end
	test("Exact radius boundary includes equality and excludes smaller radii", function()
		local m = sample(V(1, 1, 1 / 64))
		local out, r = direct(m, 1 / 64)
		assert(r.addedVertices == 1 and out.vertices[4] == V(1, 1, 0))
		local _, other = direct(m, 1 / 64 - 2 ^ -30)
		assert(#other.snaps == 0)
	end)
	test("Native projection rounding outside the exact movement radius rejects", function()
		local m = sample(V(1, 1, 0.3), { V(0, 0, 0), V(3, 1, 0), V(1, 3, 1) })
		local before = E.IO.encode(m)
		local ok, err = pcall(direct, m, 0.046499066583766464)
		assert(
			not ok and tostring(err):find("Native feature snap exceeds", 1, true) and E.IO.encode(m) == before
		)
	end)
	test("A collapsed source triangle rejects transactionally", function()
		local m = meshWithPoints(target, { { V(1, 1, 1 / 64), V(1, 2, 1 / 128), V(1, 3, 1 / 128) } })
		local before = E.IO.encode(m)
		local ok, err = pcall(direct, m, 1 / 32)
		assert(not ok and tostring(err):find("collapses or reverses", 1, true) and E.IO.encode(m) == before)
	end)
	test("Repeated shared-edge insertions split every incident triangle", function()
		local square = { V(0, 0, 0), V(4, 0, 0), V(4, 4, 0), V(0, 4, 0) }
		local probes = {
			{ V(1, 1, 1 / 64), V(1, 1, 2), V(2, 1, 2) },
			{ V(2, 2, 1 / 64), V(2, 2, 3), V(3, 2, 3) },
			{ V(3, 3, 1 / 64), V(3, 3, 4), V(4, 3, 4) },
		}
		local m = meshWithPoints(square, probes)
		local out, r = direct(m, 1 / 32)
		assert(r.addedVertices == 3 and r.triangles == 11 and out:validate().valid)
		for _, snap in r.snaps do
			local count = 0
			for _, face in out.faces do
				for _, id in face.vertices do
					if id == snap.targetVertex then
						count += 1
					end
				end
			end
			assert(count >= 4)
		end
		local area = 0
		for fid, face in out.faces do
			if r.maps.face[fid][1][1] == 1 then
				local _, a = out:faceNormal(fid)
				area += a
			end
		end
		near(area, 16)
	end)
	test("Small and large native scales retain exact source movement bounds", function()
		for _, scale in { 2 ^ -5, 2 ^ 10 } do
			local m = sample(V(1, 1, 1 / 64))
			for id, p in m.vertices do
				m.vertices[id] = p * scale
			end
			local out, r = direct(m, scale / 64)
			assert(out:validate().valid and r.addedVertices == 1 and r.maxDisplacement <= scale / 64)
		end
	end)
	local repaired
	test("Mismatched face meshes close a gap with the analytic outer volume", function()
		local source = joined()
		local before = E.IO.encode(source)
		local out, r = E.MeshRepair.resolveIntersections(source, config())
		check(out, r)
		near(out:volume(), 16 + 4 / 1024)
		assert(
			r.validation.surfaceComponents == 1
				and r.arrangement.regularization.addedVertices == 1
				and E.IO.encode(source) == before
		)
		repaired = out
	end)
	for _, operation in { "union", "intersect", "subtract" } do
		test("Feature refinement preserves Boolean operand ownership for " .. operation, function()
			local a, b = pair()
			local options = config()
			options.method = "arrangement"
			local out, r = E.Boolean.apply(a, b, operation, options)
			check(out, r)
			near(out:volume(), operation == "union" and 16 + 4 / 1024 or operation == "subtract" and 8 or 0)
			for _, refs in r.maps.face do
				for _, ref in refs do
					assert(r.inputMaps.face[ref[1]])
				end
			end
		end)
	end
	test(
		"Oblique exact rotations translations and operand reversal retain closed repaired volumes",
		function()
			for _, reverse in { false, true } do
				local a, b = pair()
				for _, mesh in { a, b } do
					for id, p in mesh.vertices do
						mesh.vertices[id] = V(p.X + p.Z + 16, p.Y - 8, p.Z - p.X + 4)
					end
				end
				local source = E.Topology.join(reverse and { b, a } or { a, b })
				local out, r = E.MeshRepair.resolveIntersections(source, config())
				check(out, r)
				near(out:volume(), 32 + 8 / 1024, 1e-6)
			end
		end
	)
	test("Refined corner references retain original triangle coverage and barycentric position", function()
		local source = sample(V(1, 1, 0.3), { V(0, 0, 0), V(3, 1, 0), V(1, 3, 1) })
		local out, r = direct(source, 0.1)
		local area = 0
		for fid, face in out.faces do
			if r.maps.face[fid][1][1] == 1 then
				local reference = {}
				for i, id in face.vertices do
					local p = Vector3.zero
					local total = 0
					for _, ref in r.maps.corner[fid .. ":" .. i] do
						local original, corner = ref[1]:match("^(%d+):(%d+)$")
						assert(tonumber(original) == 1 and ref[2] > 0)
						p += source.vertices[source.faces[tonumber(original)].vertices[tonumber(corner)]] * ref[2]
						total += ref[2]
					end
					near(total, 1)
					reference[i] = p / total
					assert(
						(out.vertices[id] - reference[i]).Magnitude <= r.sourceSurfaceHausdorffBound + 1e-6
					)
				end
				area += (reference[2] - reference[1]):Cross(reference[3] - reference[1]).Magnitude / 2
			end
		end
		local _, originalArea = source:faceNormal(1)
		near(area, originalArea, 1e-6)
	end)
	test("A repaired feature mesh has no further displacement or refinement", function()
		assert(repaired)
		local out, r = E.MeshRepair.resolveIntersections(repaired, config())
		check(out, r)
		near(out:volume(), repaired:volume())
		assert(
			r.arrangement.regularization.addedVertices == 0
				and r.arrangement.regularization.maxDisplacement == 0
		)
	end)
	test("Invalid feature settings and exact allocation caps reject on empty input", function()
		for _, distance in { 0, -1, math.huge, 0 / 0, 2 ^ -130, 2 ^ 131 } do
			assert(not pcall(E.MeshRepair.resolveIntersections, E.Mesh.new(), config(distance)))
		end
		for _, value in { 0, -1, 0.5, math.huge, 0 / 0 } do
			local options = config()
			options.maxExactCoefficients = value
			assert(not pcall(E.MeshRepair.resolveIntersections, E.Mesh.new(), options))
		end
		local out, r = E.MeshRepair.resolveIntersections(E.Mesh.new(), config())
		check(out, r)
		assert(r.empty and r.arrangement.regularization.usedVertices == 0)
	end)
	test("Feature repair enforces work vertex face bit and coefficient budgets", function()
		local source = joined()
		local before = E.IO.encode(source)
		for _, entry in
			{
				{ "maxWork", 20 },
				{ "maxVertices", 17 },
				{ "maxFaces", 12 },
				{ "maxExactBits", 4 },
				{ "maxExactCoefficients", 10 },
			}
		do
			local options = config()
			options[entry[1]] = entry[2]
			local ok, err = pcall(E.MeshRepair.resolveIntersections, source, options)
			assert(not ok and tostring(err):find("budget", 1, true), entry[1] .. ":" .. tostring(err))
		end
		assert(E.IO.encode(source) == before)
	end)
	test("Cancellation and callback error identity survive feature refinement", function()
		local source = joined()
		local before = E.IO.encode(source)
		local options = config()
		options.cancelled = function()
			return true
		end
		assert(not pcall(E.MeshRepair.resolveIntersections, source, options))
		local token = {}
		options = config()
		options.checkpoint = function(s)
			if s.stage == "regularize" then
				error(token)
			end
		end
		local ok, err = pcall(E.MeshRepair.resolveIntersections, source, options)
		assert(not ok and err == token and E.IO.encode(source) == before)
	end)
	test("Feature settings and geometry are detached before progress callbacks", function()
		local source = joined()
		local options = config()
		local fired = false
		options.checkpoint = function(s)
			if s.stage == "regularize" and not fired then
				fired = true
				options.regularization.distance = 4
				options.regularization.method = "unknown"
				source.vertices[1] = V(999, 999, 999)
			end
		end
		local out, r = E.MeshRepair.resolveIntersections(source, options)
		check(out, r)
		near(out:volume(), 16 + 4 / 1024)
		assert(fired and r.arrangement.regularization.distance == 1 / 512)
	end)
	test(
		"Original typed vertex edge face corner data skin groups and UVs compose through refinement",
		function()
			local source = joined()

			local values = { vertex = {}, edge = {}, face = {}, corner = {} }
			local cornerUV = {}
			for id, p in source.vertices do
				values.vertex[id] = p.X + 2 * p.Y - 3 * p.Z
				source.weights[id] = { Left = (id % 4) / 4, Right = 1 - (id % 4) / 4 }
				source.groups.test = source.groups.test or {}
				source.groups.test[id] = id / 100
			end
			for fid, face in source.faces do
				values.face[fid] = "face" .. fid
				face.material = values.face[fid]
				for i, id in face.vertices do
					local key = fid .. ":" .. i
					values.corner[key] = source.vertices[id].X + 4 * source.vertices[id].Z
					face.corners[i].uv = Vector2.new(values.corner[key], fid * 32 + source.vertices[id].Y)
					cornerUV[key] = face.corners[i].uv
				end
			end
			for key in E.Connectivity.index(source).edges do
				values.edge[key] = 7
			end
			for _, domain in { "vertex", "edge", "face", "corner" } do
				local kind = domain == "face" and "string" or "number"
				source = E.Attributes.set(
					E.Attributes.create(source, domain, domain, kind, kind == "string" and "" or 0),
					domain,
					values[domain]
				)
			end
			local before = E.IO.encode(source)
			local options = {
				regularization = { method = "features", distance = 1 / 512 },
				tolerance = 1e-7,
				windingPrecision = "exact",
				maxWork = 50000000,
			}
			local out, r = E.MeshRepair.resolveIntersections(source, options)
			assert(r.complete)
			local function near(a, b)
				assert(math.abs(a - b) < 1e-5, tostring(a) .. " vs " .. tostring(b))
			end
			for id in out.vertices do
				local expected, total, skin, group = 0, 0, 0, 0
				for _, ref in r.maps.vertex[id] do
					assert(values.vertex[ref[1]])
					expected += values.vertex[ref[1]] * ref[2]
					total += ref[2]
					skin += source.weights[ref[1]].Left * ref[2]
					group += source.groups.test[ref[1]] * ref[2]
				end
				near(E.Attributes.get(out, "vertex", id), expected / total)
				near(out.weights[id].Left or 0, skin / total)
				near(out.groups.test[id], group / total)
			end
			for fid, face in out.faces do
				assert(E.Attributes.get(out, "face", fid) == face.material)
				for i in face.vertices do
					local key = fid .. ":" .. i
					local value, total, uvx, uvy = 0, 0, 0, 0
					for _, ref in r.maps.corner[key] do
						assert(values.corner[ref[1]])
						value += values.corner[ref[1]] * ref[2]
						total += ref[2]
						uvx += cornerUV[ref[1]].X * ref[2]
						uvy += cornerUV[ref[1]].Y * ref[2]
					end
					near(E.Attributes.get(out, "corner", key), value / total)
					near(face.corners[i].uv.X, uvx / total)
					near(face.corners[i].uv.Y, uvy / total)
				end
			end
			for key, refs in r.maps.edge do
				assert(#refs > 0 and E.Attributes.get(out, "edge", key) == 7)
			end
			assert(E.IO.encode(source) == before)
		end
	)
	if not settings or not settings.skipNative then
		test("A face-refined repaired boundary round-trips through native EditableMesh", function()
			assert(repaired)
			local handle = E.Roblox.toEditable(repaired)
			local ok, err = pcall(function()
				local restored = E.Roblox.fromEditable(handle.editable)
				assert(
					restored:validate().closed and E.Connectivity.analyze(restored).eulerCharacteristic == 2
				)
				near(restored:volume(), 16 + 4 / 1024, 1e-5)
			end)
			handle.editable:Destroy()
			assert(ok, err)
		end)
	end
	report.success = report.failed == 0
	return report
end
