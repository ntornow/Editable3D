return function(E)
	local D, A = E.Deform, E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, t)
		assert((a - b).Magnitude < (t or 3e-6), tostring(a) .. " ~= " .. tostring(b))
	end
	local function rejects(fn)
		assert(not pcall(fn), "Expected rejection")
	end
	local function panel(size, z)
		local m = E.Mesh.new()
		size = size or 2
		for i = 0, 2 do
			for j = 0, 2 do
				m:addVertex(Vector3.new((i - 1) * size / 2, (j - 1) * size / 2, z or 0))
			end
		end
		for i = 0, 1 do
			for j = 0, 1 do
				local a = i * 3 + j + 1
				m:addFace({ a, a + 3, a + 4, a + 1 }, {
					{ uv = Vector2.new(i / 2, j / 2) },
					{ uv = Vector2.new((i + 1) / 2, j / 2) },
					{ uv = Vector2.new((i + 1) / 2, (j + 1) / 2) },
					{ uv = Vector2.new(i / 2, (j + 1) / 2) },
				})
			end
		end
		return m:recalculateNormals()
	end
	local function move(m)
		return D.map(m, function(p)
			return p + Vector3.new(0, 0, 1)
		end)
	end
	test("Dictionary group channel inversion field and signed strength compose analytically", function()
		local m = panel()
		local mask, group, values = {}, {}, {}
		for id in m.vertices do
			mask[id] = if id == 1 then false else 0.5
			group[id] = 0.5
			values[id] = 0.25
		end
		m.groups.influence = group
		m = A.set(A.create(m, "influence", "vertex", "number", 0), "influence", values)
		local fields = 0
		local out, r = D.masked(m, move, {
			mask = mask,
			group = "influence",
			attribute = "influence",
			invertMask = true,
			maskField = function(p, id)
				fields += 1
				assert(m.vertices[id] == p)
				return 0.5
			end,
			strength = -2,
		})
		assert(r.complete and r.operatorInvoked and fields == 9 and r.modifiedVertices == 9)
		for id, p in m.vertices do
			near(out.vertices[id], p - Vector3.zAxis * (1 - (id == 1 and 0 or 0.5) * 0.5 * 0.25))
		end
	end)
	test("Legacy lattice gains channel masks while preserving its displacement convention", function()
		local m = panel()
		m = A.set(A.create(m, "weight", "vertex", "number", 0.25), "weight", { [5] = 1 })
		local controls = table.create(8, Vector3.new(0, 0, 2))
		local out, r = D.masked(m, function(localMesh)
			return D.lattice(localMesh, Vector3.new(-2, -2, -2), Vector3.new(2, 2, 2), controls)
		end, { attribute = "weight" })
		assert(r.complete)
		for id, p in m.vertices do
			near(out.vertices[id], p + Vector3.zAxis * (id == 5 and 2 or 0.5))
		end
	end)
	test("Legacy shrinkwrap and contact combine with masks and spatial fields", function()
		local m = panel()
		local target = panel(6, 2)
		local out = D.masked(m, function(localMesh)
			return D.shrinkwrap(localMesh, target, 0.3)
		end, {
			maskField = function(p)
				return (p.X + 1) / 2
			end,
		})
		for id, p in m.vertices do
			near(out.vertices[id], p + Vector3.zAxis * (2.3 * (p.X + 1) / 2))
		end
		out = D.masked(m, function(localMesh)
			return D.contact(localMesh, function(p)
				return p.Z - 1
			end, 0)
		end, { strength = 0.4 })
		for id, p in m.vertices do
			near(out.vertices[id], p + Vector3.zAxis * 0.4)
		end
	end)
	test("Legacy RBF receives shared influence with an independent Gaussian displacement", function()
		local m = panel()
		local delta = Vector3.new(0.1, 0.2, 0.3)
		local out = D.masked(m, function(localMesh)
			return D.rbf(localMesh, { { from = Vector3.zero, to = delta } }, 2)
		end, { strength = 0.4 })
		for id, p in m.vertices do
			near(out.vertices[id], p + delta * (0.4 * math.exp(-p:Dot(p) / 4)))
		end
	end)
	test("Legacy twist taper and bend retain their full-strength formulas", function()
		local m = panel()
		for _, item in
			{
				{
					function(x)
						return D.twist(x, 0.4, -1, 1)
					end,
					function(p)
						local a = 0.4 * (p.Y + 1) / 2
						return Vector3.new(p.X * math.cos(a), p.Y, p.X * math.sin(a))
					end,
				},
				{
					function(x)
						return D.taper(x, 0.8, 1.2, -1, 1)
					end,
					function(p)
						return Vector3.new(p.X * (0.8 + 0.4 * (p.Y + 1) / 2), p.Y, 0)
					end,
				},
				{
					function(x)
						return D.bend(x, 0.2)
					end,
					function(p)
						return Vector3.new(
							math.cos(p.Y * 0.2) * (5 + p.X) - 5,
							math.sin(p.Y * 0.2) * (5 + p.X),
							0
						)
					end,
				},
			}
		do
			local out = D.masked(m, item[1], { strength = 0.3 })
			for id, p in m.vertices do
				near(out.vertices[id], p:Lerp(item[2](p), 0.3))
			end
		end
	end)
	test("Surface attachment and sculpt smoothing compose through the same positional mask", function()
		local m = panel()
		local target = panel(4)
		local posed = D.transform(target, CFrame.new(0, 0, 1))
		local out = D.masked(m, function(localMesh)
			local bind = E.SurfaceDeform.bind(localMesh, target)
			return bind:evaluate(posed)
		end, { mask = { [5] = 0.5 } })
		for id, p in m.vertices do
			near(out.vertices[id], p + Vector3.zAxis * (id == 5 and 0.5 or 0))
		end
		m.vertices[5] += Vector3.zAxis
		out = D.masked(m, function(localMesh)
			return E.Sculpt.smooth(localMesh, nil, 1, { taubin = false })
		end, { mask = { [5] = 0.25 } })
		near(out.vertices[5], Vector3.new(0, 0, 0.875))
	end)
	test("Operations see a local-frame mesh and locks restore local components", function()
		local m = panel()
		local frame = CFrame.new(7, 3, -2) * CFrame.Angles(0.3, 0.7, -0.2)
		for id, p in m.vertices do
			m.vertices[id] = frame:PointToWorldSpace(p)
		end
		m:recalculateNormals()
		local out = D.masked(m, function(localMesh)
			near(localMesh.vertices[5], Vector3.zero)
			near(localMesh.faces[1].corners[1].normal, Vector3.zAxis)
			return D.map(localMesh, function(p)
				return p + Vector3.new(0.3, 0.6, 1)
			end)
		end, { frame = frame, lockAxes = { X = true }, strength = 0.5 })
		for id, p in m.vertices do
			near(out.vertices[id], p + frame:VectorToWorldSpace(Vector3.new(0, 0.3, 0.5)))
		end
	end)
	test("Zero influence skips the whole operation and keeps source positions exact", function()
		local m = panel()
		local called = false
		local out, r = D.masked(m, function()
			called = true
			error("should not run")
		end, { mask = {} })
		assert(not called and not r.operatorInvoked and r.maskedVertices == 9 and r.complete)
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
	end)
	test("Operation data edits are isolated and only validated positions are blended", function()
		local m = panel()
		m.groups.keep = { [5] = 0.4 }
		m.weights[5] = { Bone = 1 }
		for _, schema in
			{
				{ "v", "vertex", "number", 3 },
				{ "e", "edge", "boolean", false },
				{ "f", "face", "string", "keep" },
				{ "c", "corner", "Vector2", Vector2.one },
			}
		do
			m = A.create(m, table.unpack(schema))
		end
		local before = E.IO.encode(m)
		local out = D.masked(m, function(localMesh)
			localMesh.groups = {}
			localMesh.weights = {}
			localMesh.attributes = {}
			for _, f in localMesh.faces do
				f.material = 99
				for _, c in f.corners do
					c.uv = Vector2.zero
				end
			end
			for id, p in localMesh.vertices do
				localMesh.vertices[id] = p + Vector3.zAxis
			end
			return localMesh, { complete = true, customValue = 17 }
		end, { strength = 0.2, recalculateNormals = false })
		assert(E.IO.encode(m) == before and out.groups.keep[5] == 0.4 and out.weights[5].Bone == 1)
		for name, c in m.attributes do
			assert(out.attributes[name].default == c.default and out.attributes[name].domain == c.domain)
		end
		for fid, f in m.faces do
			assert(out.faces[fid].material == f.material)
			for i, c in f.corners do
				assert(out.faces[fid].corners[i].uv == c.uv and out.faces[fid].corners[i].normal == c.normal)
			end
		end
	end)
	test("Callback mutations cannot change the snapshotted masks locks or original mesh", function()
		local m = panel()
		local o = { mask = { [5] = 0.5 }, lockAxes = { X = true } }
		local before = E.IO.encode(m)
		local out = D.masked(m, function(localMesh)
			o.mask[5] = 0
			o.lockAxes.X = false
			return D.map(localMesh, function(p)
				return p + Vector3.new(1, 0, 1)
			end)
		end, o)
		assert(E.IO.encode(m) == before)
		near(out.vertices[5], m.vertices[5] + Vector3.zAxis * 0.5)
	end)
	test("Topology changes missing identities and malformed outputs reject transactionally", function()
		local m = panel()
		local before = E.IO.encode(m)
		for _, operation in
			{
				function(x)
					return E.Modifiers.array(x, 2, CFrame.new(0, 0, 1))
				end,
				function(x)
					return E.Topology.reverse(x)
				end,
				function(x)
					x.vertices[20] = x.vertices[1]
					x.vertices[1] = nil
					return x
				end,
				function(x)
					x.faces[1].vertices = { 1, 2, 3 }
					return x
				end,
				function()
					return nil
				end,
				function(x)
					return x, 2
				end,
			}
		do
			rejects(function()
				D.masked(m, operation)
			end)
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Incomplete operation reports and invalid masked-out positions reject", function()
		local m = panel()
		for _, r in { { complete = false }, { success = false } } do
			rejects(function()
				D.masked(m, function(x)
					return x, r
				end)
			end)
		end
		rejects(function()
			D.masked(m, function(x)
				x.vertices[1] = Vector3.new(0 / 0, 0, 0)
				return x
			end, { mask = { [5] = 1 } })
		end)
	end)
	test("Partial blending can preserve geometry even when the full candidate collapses", function()
		local m = panel()
		local collapse = function(x)
			for id in x.vertices do
				x.vertices[id] = Vector3.zero
			end
			return x
		end
		local out, r = D.masked(m, collapse, { strength = 0.5 })
		assert(r.complete)
		for id, p in m.vertices do
			near(out.vertices[id], p * 0.5)
		end
		rejects(function()
			D.masked(m, collapse)
		end)
		out, r = D.masked(m, collapse, { allowInvalid = true })
		assert(not r.complete and not r.validation.valid and out.vertices[1] == Vector3.zero)
	end)
	test("Normal retention and optional recomputation have explicit independent behavior", function()
		local m = panel()
		for _, f in m.faces do
			for _, c in f.corners do
				c.normal = Vector3.xAxis
			end
		end
		local out = D.masked(m, move, { recalculateNormals = false })
		assert(out.faces[1].corners[1].normal == Vector3.xAxis)
		out = D.masked(m, move)
		near(out.faces[1].corners[1].normal, Vector3.zAxis)
	end)
	test("Work vertex limits callback failure and cancellation leave the input unchanged", function()
		local m = panel()
		local before = E.IO.encode(m)
		for _, o in
			{
				{ maxWork = 1 },
				{ maxVertices = 2 },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(s)
						if s.stage == "operator" then
							error("stop")
						end
					end,
				},
			}
		do
			rejects(function()
				D.masked(m, move, o)
			end)
		end
		rejects(function()
			D.masked(m, function(x)
				x.vertices[1] = Vector3.zero
				error("fail")
			end)
		end)
		assert(E.IO.encode(m) == before)
		local stopped = false
		rejects(function()
			D.masked(m, function(x)
				stopped = true
				return x
			end, {
				cancelled = function()
					return stopped
				end,
			})
		end)
	end)
	test("Invalid masks and frames use the shared validation contract", function()
		local m = panel()
		for _, o in
			{
				{ mask = { [99] = 1 } },
				{ mask = { [1] = 2 } },
				{ group = "missing" },
				{ attribute = "missing" },
				{
					maskField = function()
						return 2
					end,
				},
				{ frame = "invalid" },
				{ lockAxes = { other = true } },
				{ strength = 0 / 0 },
			}
		do
			rejects(function()
				D.masked(m, move, o)
			end)
		end
		rejects(function()
			D.masked(m, nil)
		end)
	end)
	test("Sparse vertex face identities and callback reports survive composition", function()
		local source = panel()
		local m = E.Mesh.new()
		for id, p in source.vertices do
			m.vertices[11 * id + 5] = p
		end
		for fid, f in source.faces do
			local c = table.clone(f.vertices)
			for i, v in c do
				c[i] = 11 * v + 5
			end
			m.faces[7 * fid + 3] = { vertices = c, corners = table.clone(f.corners), material = f.material }
		end
		local out, r = D.masked(m, function(x)
			return move(x), { complete = true, samples = 9 }
		end, { mask = { [60] = 0.25 } })
		assert(r.operationReport.samples == 9 and out.faces[10])
		for id, p in m.vertices do
			near(out.vertices[id], p + Vector3.zAxis * (id == 60 and 0.25 or 0))
		end
	end)
	test("Identity operations retain exact native positions in translated rotated frames", function()
		local m = panel()
		local before = E.IO.encode(m)
		local out, r = D.masked(m, function(x)
			return x
		end, {
			frame = CFrame.new(1000, -2000, 700) * CFrame.Angles(0.13, 0.2, 0.3),
			recalculateNormals = false,
		})
		assert(r.modifiedVertices == 0 and r.complete)
		for id, p in m.vertices do
			assert(out.vertices[id] == p)
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Masked lattice output retains native UVs normals and typed authoring data", function()
		local result = require(script.Parent.Examples.MaskedLattice)(E)
		assert(
			result.mesh.attributes.lattice_influence
				and not result.mesh.attributes.lattice_influence.values[999]
		)
		local h = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(h.editable)
			assert(restored:validate().valid)
			for _, f in restored.faces do
				for _, c in f.corners do
					assert(
						c.normal
							and math.abs(c.normal.Magnitude - 1) < 1e-5
							and c.uv
							and c.uv.X >= 0
							and c.uv.X <= 1
							and c.uv.Y >= 0
							and c.uv.Y <= 1
					)
				end
			end
		end)
		h.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
