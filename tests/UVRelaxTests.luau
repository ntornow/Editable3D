return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(
			math.abs(a - b) <= (tolerance or 1e-6) * math.max(1, math.abs(b)),
			tostring(a) .. " differs from " .. tostring(b)
		)
	end
	local fixtures = require(script.Parent.UVRelaxFixtures)
	local function fixtureMesh(fixture)
		local m = E.Mesh.new()
		for _, p in fixture.positions do
			m:addVertex(Vector3.new(p[1], p[2], p[3]))
		end
		for _, tri in fixture.triangles do
			local corners = {}
			for i, id in tri do
				local uv = fixture.uv[id]
				corners[i] = { uv = Vector2.new(uv[1], uv[2]) }
			end
			m:addFace(tri, corners)
		end
		return m
	end
	local function setUV(mesh, id, uv)
		for _, face in mesh.faces do
			for i, vertex in face.vertices do
				if id == vertex then
					face.corners[i].uv = uv
				end
			end
		end
	end
	local function readUV(mesh, id)
		for _, face in mesh.faces do
			for i, vertex in face.vertices do
				if id == vertex then
					return face.corners[i].uv
				end
			end
		end
		error("UV vertex missing")
	end
	local function cornerKey(mesh, id)
		for fid, face in mesh.faces do
			for i, vertex in face.vertices do
				if id == vertex then
					return fid .. ":" .. i
				end
			end
		end
		error("Corner vertex missing")
	end
	local function transformUV(mesh, fn)
		for _, face in mesh.faces do
			for _, corner in face.corners do
				corner.uv = fn(corner.uv)
			end
		end
	end
	local function triangle(uv)
		local m = E.Mesh.new()
		m:addVertex(Vector3.zero)
		m:addVertex(Vector3.xAxis)
		m:addVertex(Vector3.yAxis)
		m:addFace({ 1, 2, 3 }, { { uv = uv[1] }, { uv = uv[2] }, { uv = uv[3] } })
		return m
	end
	test("Planar analytic center and zero-distortion energies are recovered", function()
		for _, method in { "angle", "symmetricDirichlet" } do
			local m = fixtureMesh(fixtures[1])
			local out, r = E.UV.relax(m, { method = method, requireComplete = true })
			assert(r.complete and r.applied and r.nativeOrientation and r.overlapFree)
			local uv = readUV(out, 5)
			near(uv.X, 0.5)
			near(uv.Y, 0.5)
			near(r.islands[1].energy, method == "angle" and 0 or 4, 1e-10)
		end
	end)
	test(
		"Eight independent dense BFGS references match native relaxation energies and coordinates",
		function()
			for _, fixture in fixtures do
				local out, r = E.UV.relax(fixtureMesh(fixture), { method = fixture.method })
				assert(r.complete and r.overlapFree)
				near(r.islands[1].energy, fixture.referenceEnergy, 1e-8)
				for i, id in fixture.movable do
					local uv = readUV(out, id)
					near(uv.X, fixture.referenceCoordinates[2 * i - 1], 1e-5)
					near(uv.Y, fixture.referenceCoordinates[2 * i], 1e-5)
				end
				local history = r.islands[1].history
				for i = 2, #history do
					assert(history[i].energy < history[i - 1].energy)
				end
			end
		end
	)
	test("Both analytic energy gradients agree with central differences in either winding", function()
		local Core = require(script.Parent.UVIslandCore)
		local Chart = require(script.Parent.UVRelaxChart)
		local Energy = require(script.Parent.UVRelaxEnergy)
		for _, mirror in { false, true } do
			local m = fixtureMesh(fixtures[5])
			if mirror then
				transformUV(m, function(uv)
					return Vector2.new(-uv.X, uv.Y)
				end)
			end
			local context = Core.prepare(m)
			local chart = Chart.prepare(context, context.islands[1], m:topology(), {}, nil)
			for _, method in { "angle", "symmetricDirichlet" } do
				local _, gradient = Energy.evaluate(
					chart.coordinates,
					chart.triangles,
					method,
					function() end
				)
				for i in chart.coordinates do
					local a, b = table.clone(chart.coordinates), table.clone(chart.coordinates)
					a[i] += 1e-6
					b[i] -= 1e-6
					local x = Energy.evaluate(a, chart.triangles, method, function() end)
					local y = Energy.evaluate(b, chart.triangles, method, function() end)
					near(gradient[i], (x - y) / 2e-6, 1e-7)
				end
			end
		end
	end)
	test("Uniformly mirrored islands remain mirrored and retain the same optimum", function()
		for _, fixture in { fixtures[5], fixtures[6] } do
			local m = fixtureMesh(fixture)
			transformUV(m, function(uv)
				return Vector2.new(-uv.X, uv.Y)
			end)
			local out, r = E.UV.relax(m, { method = fixture.method })
			assert(r.complete and r.nativeOrientation and r.overlapFree)
			near(r.islands[1].energy, fixture.referenceEnergy, 1e-8)
			assert(E.UV.analyze(out).negativeTriangles == #fixture.triangles)
		end
	end)
	test("Non-square texture coordinates use the intended pixel metric", function()
		for _, fixture in { fixtures[3], fixtures[4] } do
			local m = fixtureMesh(fixture)
			transformUV(m, function(uv)
				return Vector2.new(uv.X / 1024, uv.Y / 512)
			end)
			local out, r = E.UV.relax(m, { method = fixture.method, textureSize = Vector2.new(1024, 512) })
			assert(r.complete)
			near(r.islands[1].energy, fixture.referenceEnergy, 1e-8)
			local uv = readUV(out, 13)
			near(uv.X * 1024, 0.5)
			near(uv.Y * 512, 0.5)
		end
	end)
	test("Existing corner seams separate shared geometry samples during relaxation", function()
		local m = fixtureMesh(fixtures[3])
		for _, face in m.faces do
			local right = true
			for _, id in face.vertices do
				right = right and m.vertices[id].X >= 0.5
			end
			if right then
				for _, corner in face.corners do
					corner.uv += Vector2.new(0.25, 0)
				end
			end
		end
		local before = E.UV.islands(m)
		assert(#before == 2)
		local out, r = E.UV.relax(m)
		assert(r.complete and #r.islands == 2 and #E.UV.islands(out) == 2)
		local values = {}
		for _, face in out.faces do
			for i, id in face.vertices do
				if id == 13 then
					values[tostring(face.corners[i].uv)] = true
				end
			end
		end
		local n = 0
		for _ in values do
			n += 1
		end
		assert(n == 2)
	end)
	test("One unselected corner pins its entire connected UV node", function()
		local m = fixtureMesh(fixtures[1])
		local selected = {}
		local skipped = false
		for fid, face in m.faces do
			for i, id in face.vertices do
				if id == 5 then
					if skipped then
						selected[fid .. ":" .. i] = true
					else
						skipped = true
					end
				end
			end
		end
		local before = E.IO.encode(m)
		local fixed, r = E.UV.relax(m, { corners = selected })
		assert(r.complete and not r.applied and E.IO.encode(fixed) == before)
		for fid, face in m.faces do
			for i, id in face.vertices do
				if id == 5 then
					selected[fid .. ":" .. i] = true
				end
			end
		end
		local moved, q = E.UV.relax(m, { corners = selected })
		assert(q.complete and q.applied)
		near(readUV(moved, 5).X, 0.5)
	end)
	test("Explicit corner pins propagate across a node without constraining unrelated samples", function()
		local m = fixtureMesh(fixtures[3])
		local uv = readUV(m, 13)
		local out, r = E.UV.relax(m, { pins = { [cornerKey(m, 13)] = true } })
		assert(r.complete and r.applied and readUV(out, 13) == uv)
		assert(readUV(out, 7) ~= readUV(m, 7))
	end)
	test("Holed charts preserve every boundary sample while their interiors relax", function()
		local m = fixtureMesh(fixtures[7])
		m.faces[37], m.faces[38] = nil, nil
		local boundary = {}
		for _, edge in m:topology().edges do
			if #edge.faces == 1 then
				boundary[edge.a], boundary[edge.b] = true, true
			end
		end
		local out, r = E.UV.relax(m, { iterations = 200 })
		assert(r.complete and r.applied and r.overlapFree)
		for id in boundary do
			assert(readUV(out, id) == readUV(m, id))
		end
	end)
	test("Free boundaries get two deterministic existing anchors and lower angular distortion", function()
		local m = triangle({ Vector2.zero, Vector2.xAxis, Vector2.new(0.2, 0.7) })
		local out, r = E.UV.relax(m, { pinBoundary = false })
		assert(r.complete and #r.islands[1].automaticPins == 2 and r.islands[1].pinnedNodes == 2)
		assert(readUV(out, 1) == Vector2.zero and readUV(out, 2) == Vector2.xAxis)
		near(readUV(out, 3).X, 0)
		near(readUV(out, 3).Y, 1)
	end)
	test("Island selection retains every unselected UV exactly", function()
		local a, b = fixtureMesh(fixtures[1]), fixtureMesh(fixtures[1])
		b = E.Deform.transform(b, CFrame.new(3, 0, 0))
		transformUV(b, function(uv)
			return uv + Vector2.new(2, 0)
		end)
		local m = E.Topology.join({ a, b })
		local islands = E.UV.islands(m)
		local out, r = E.UV.relax(m, { islands = { [islands[1].id] = true } })
		assert(r.complete and #r.islands == 1 and r.applied)
		for _, fid in islands[2].faces do
			for i, corner in m.faces[fid].corners do
				assert(out.faces[fid].corners[i].uv == corner.uv)
			end
		end
	end)
	test("All data domains are retained and only changed UVs invalidate tangent frames", function()
		local m = fixtureMesh(fixtures[1])
		m = E.Attributes.create(m, "v", "vertex", "number", 2)
		m = E.Attributes.create(m, "e", "edge", "boolean", true)
		m = E.Attributes.create(m, "f", "face", "string", "face")
		m = E.Attributes.create(m, "c", "corner", "Vector2", Vector2.one)
		m.attributes.c.values["1:1"] = Vector2.new(8, 9)
		m.weights[5] = { joint = 1 }
		m.groups.mask = { [5] = 0.5 }
		m.faces[1].material = 8
		for _, face in m.faces do
			for _, c in face.corners do
				c.normal = Vector3.zAxis
				c.tangent = Vector3.xAxis
				c.tangentSign = 1
			end
		end
		local before = E.IO.encode(m)
		local out, r = E.UV.relax(m)
		assert(
			r.complete
				and E.IO.encode(m) == before
				and out.weights[5].joint == 1
				and out.groups.mask[5] == 0.5
				and out.faces[1].material == 8
		)
		assert(out.attributes.c.values["1:1"] == Vector2.new(8, 9))
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
		for fid, face in out.faces do
			for i, c in face.corners do
				assert(c.normal == Vector3.zAxis)
				if c.uv ~= m.faces[fid].corners[i].uv then
					assert(c.tangent == nil and c.tangentSign == nil)
				else
					assert(c.tangent == Vector3.xAxis and c.tangentSign == 1)
				end
			end
		end
	end)
	test("Callbacks cannot change captured geometry pins or options", function()
		local m = fixtureMesh(fixtures[1])
		local pins = {}
		local options = { pins = pins }
		options.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[5] = Vector3.new(99, 99, 99)
				pins[cornerKey(m, 5)] = true
				options.iterations = 0
				options.method = "unknown"
			end
		end
		local out, r = E.UV.relax(m, options)
		assert(r.complete and out.vertices[5] == Vector3.new(0.5, 0.5, 0))
		near(readUV(out, 5).X, 0.5)
	end)
	test("Allocation work cancellation and callback errors leave source data untouched", function()
		local m = fixtureMesh(fixtures[3])
		local before = E.IO.encode(m)
		for _, options in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{ maxTriangles = 1 },
				{ maxWork = 1 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(s)
						if s.stage == "relaxIteration" then
							error("stop")
						end
					end,
				},
			}
		do
			assert(not pcall(E.UV.relax, m, options))
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Soft iteration limits return safe progress and distinguish convergence", function()
		local m = fixtureMesh(fixtures[3])
		local before = E.IO.encode(m)
		local unchanged, a = E.UV.relax(m, { iterations = 0 })
		assert(
			not a.complete
				and not a.applied
				and a.reason == "optimization"
				and E.IO.encode(unchanged) == before
		)
		local _, b = E.UV.relax(m, { iterations = 1 })
		assert(
			not b.complete
				and b.applied
				and b.nativeOrientation
				and b.overlapFree
				and b.islands[1].energy < b.islands[1].initialEnergy
		)
		assert(not pcall(E.UV.relax, m, { iterations = 0, requireComplete = true }))
	end)
	test("Unattainable precision remains an explicit native line-search failure", function()
		local _, r = E.UV.relax(fixtureMesh(fixtures[5]), { gradientTolerance = 1e-20, iterations = 200 })
		assert(not r.complete and r.islands[1].reason == "lineSearch" and r.islands[1].gradientNorm > 1e-20)
	end)
	test("Missing folded and degenerate layouts return unchanged diagnostic results", function()
		for _, kind in { "missing", "fold", "degenerate" } do
			local m = fixtureMesh(fixtures[1])
			if kind == "missing" then
				m.faces[1].corners[1].uv = nil
			elseif kind == "fold" then
				setUV(m, 5, Vector2.new(2, 2))
			else
				setUV(m, 5, Vector2.zero)
			end
			local before = E.IO.encode(m)
			local out, r = E.UV.relax(m)
			assert(not r.complete and not r.applied and E.IO.encode(out) == before)
			assert(r.reason == (kind == "missing" and "missingUV" or "inputOrientation"))
		end
	end)
	test(
		"Global overlaps are distinguished from local orientation and can be explicitly unrequested",
		function()
			local a = fixtureMesh(fixtures[1])
			local b = E.Deform.transform(a, CFrame.new(3, 0, 0))
			local m = E.Topology.join({ a, b })
			local out, r = E.UV.relax(m)
			assert(not r.complete and r.reason == "inputOverlap" and E.IO.encode(out) == E.IO.encode(m))
			local _, q = E.UV.relax(m, { checkOverlaps = false })
			assert(q.complete and not q.overlapChecked and q.overlapFree == nil)
		end
	)
	test("New collisions with fixed islands roll back the entire candidate layout", function()
		local a = triangle({ Vector2.zero, Vector2.xAxis, Vector2.new(0.1, 0.2) })
		local b = triangle({ Vector2.new(0.1, 0.4), Vector2.new(0.2, 0.4), Vector2.new(0.1, 0.5) })
		b = E.Deform.transform(b, CFrame.new(3, 0, 0))
		local m = E.Topology.join({ a, b })
		local before = E.IO.encode(m)
		local out, r = E.UV.relax(m, { pinBoundary = false, islands = { [1] = true } })
		assert(
			not r.complete
				and not r.applied
				and r.reason == "outputOverlap"
				and r.overlapCount > 0
				and r.changedCorners == 0
		)
		assert(E.IO.encode(out) == before and r.candidateChangedCorners > 0)
	end)
	test("Geometry and UV scales preserve normalized relaxation behavior", function()
		for _, scale in { 2 ^ -60, 2 ^ 60 } do
			local m = fixtureMesh(fixtures[5])
			for id, p in m.vertices do
				m.vertices[id] = Vector3.new(p.Y * scale, p.X * scale, -p.Z * scale)
			end
			transformUV(m, function(uv)
				return uv * scale
			end)
			local _, r = E.UV.relax(m)
			assert(r.complete)
			near(r.islands[1].energy, fixtures[5].referenceEnergy, 1e-8)
		end
	end)
	test("Sparse source IDs and loose vertices survive unchanged", function()
		local source, m = fixtureMesh(fixtures[1]), E.Mesh.new()
		for id, p in source.vertices do
			m.vertices[101 * id + 11] = p
		end
		for id, face in source.faces do
			local f = require(script.Parent.Util).copy(face)
			for i, v in f.vertices do
				f.vertices[i] = 101 * v + 11
			end
			m.faces[13 * id + 7] = f
		end
		m.vertices[9999] = Vector3.one
		m.nextVertex, m.nextFace = 10000, 10000
		local out, r = E.UV.relax(m)
		assert(r.complete and r.islands[1].id == 20 and out.vertices[9999] == Vector3.one)
		near(readUV(out, 516).X, 0.5)
	end)
	test("Invalid controls reject and nonfinite numerical energy cannot succeed", function()
		local m = fixtureMesh(fixtures[1])
		for _, options in
			{
				{ method = "bad" },
				{ gradientTolerance = 0 },
				{ pinBoundary = 1 },
				{ iterations = 1001 },
				{ lineSearchSteps = 65 },
				{ historySize = 33 },
				{ density = 0 },
				{ pins = { ["999:1"] = true } },
				{ corners = { ["1:1"] = 1 } },
				{ textureSize = Vector2.new(1.5, 2) },
			}
		do
			assert(not pcall(E.UV.relax, m, options))
		end
		local out, r = E.UV.relax(m, { method = "symmetricDirichlet", density = 1e300 })
		assert(not r.complete and r.reason == "nonfiniteEnergy" and E.IO.encode(out) == E.IO.encode(m))
	end)
	test("Empty unselected and fully pinned inputs are exact constrained identities", function()
		local empty, r = E.UV.relax(E.Mesh.new())
		assert(r.complete and not r.applied and next(empty.faces) == nil)
		local m = fixtureMesh(fixtures[1])
		local before = E.IO.encode(m)
		for _, options in { { islands = {} }, { corners = {} } } do
			local out, q = E.UV.relax(m, options)
			assert(q.complete and not q.applied and E.IO.encode(out) == before)
		end
	end)
	test("Relaxed curved panel survives native UV and normal conversion", function()
		local result = require(script.Parent.Examples.RelaxedUVPanel)(E)
		assert(result.relaxation.complete and result.relaxation.applied)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			local analysis = E.UV.analyze(restored)
			assert(
				restored:validate().valid
					and analysis.complete
					and analysis.overlapFree
					and analysis.allPositive
			)
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
