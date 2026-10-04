return function(E)
	local D, A = E.Deform, E.Attributes
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) < (tolerance or 2e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function vec(a, b, tolerance)
		assert((a - b).Magnitude < (tolerance or 2e-5), tostring(a) .. " ~= " .. tostring(b))
	end
	local function points(values)
		local m = E.Mesh.new()
		for _, p in values do
			m:addVertex(p)
		end
		return m
	end
	local function tube(length, segments)
		local rings = {}
		for i = 0, segments do
			local ring = {}
			for j = 0, 7 do
				local a = 2 * math.pi * j / 8
				ring[j + 1] = Vector3.new(length * i / segments, 0.2 * math.cos(a), 0.2 * math.sin(a))
			end
			table.insert(rings, ring)
		end
		return E.Curves.loft(rings, true)
	end
	local function decorated(m)
		local values = { vertex = {}, edge = {}, face = {}, corner = {} }
		m.groups.keep = {}
		for id in m.vertices do
			values.vertex[id] = false
			m.groups.keep[id] = 0.6
			m.weights[id] = { [1] = 0.3, [2] = 0.7 }
		end
		for fid, f in m.faces do
			values.face[fid] = 7
			for i in f.vertices do
				values.corner[fid .. ":" .. i] = "region"
			end
		end
		for key in E.Connectivity.index(m).edges do
			values.edge[key] = 9
		end
		for _, c in
			{
				{ "flag", "vertex", "boolean", true },
				{ "edge", "edge", "number", 0 },
				{ "region", "face", "number", 0 },
				{ "chart", "corner", "string", "" },
			}
		do
			m = A.set(A.create(m, c[1], c[2], c[3], c[4]), c[1], values[c[2]])
		end
		return m
	end
	local function metadata(source, out)
		assert(#A.names(out) == 4 and #A.names(E.IO.decode(E.IO.encode(out))) == 4)
		for id in source.vertices do
			assert(A.get(out, "flag", id) == false)
			near(out.groups.keep[id], 0.6)
			near(out.weights[id][2], 0.7)
		end
		for fid, f in source.faces do
			assert(A.get(out, "region", fid) == 7 and out.faces[fid].material == f.material)
			for i, id in f.vertices do
				assert(
					out.faces[fid].vertices[i] == id
						and A.get(out, "chart", fid .. ":" .. i) == "region"
						and out.faces[fid].corners[i].uv == f.corners[i].uv
				)
			end
		end
		for key in E.Connectivity.index(out).edges do
			near(A.get(out, "edge", key), 9)
		end
	end
	test("Oriented shear preserves independent coordinates volume and all source domains", function()
		local base = decorated(E.Primitives.box())
		local frame = CFrame.new(3, -4, 2) * CFrame.Angles(0.4, -0.6, 0.3)
		local source = D.transform(base, frame)
		local before = E.IO.encode(source)
		local out, r = D.shear(source, 0.7, { frame = frame })
		assert(r.complete and out:validate().closed)
		near(out:volume(), 8, 5e-5)
		for id, p in base.vertices do
			vec(out.vertices[id], frame:PointToWorldSpace(Vector3.new(p.X + 0.7 * p.Y, p.Y, p.Z)))
		end
		metadata(source, out)
		assert(E.IO.encode(source) == before)
	end)
	test("Shear limits pivot and axis locks have explicit local coordinate behavior", function()
		local source = points({ Vector3.new(1, -3, 2), Vector3.new(2, 0, 3), Vector3.new(3, 4, 4) })
		local out =
			D.shear(source, 2, { axis = "Z", direction = "Y", pivot = 0.5, range = Vector2.new(-1, 1) })
		for id, p in source.vertices do
			vec(out.vertices[id], Vector3.new(p.X, p.Y, p.Z + 2 * (math.clamp(p.Y, -1, 1) - 0.5)))
		end
		local locked, r = D.shear(source, 2, { axis = "Z", direction = "Y", lockAxes = { Z = true } })
		assert(r.modifiedVertices == 0)
		for id, p in source.vertices do
			assert(locked.vertices[id] == p)
		end
	end)
	test("Dictionary group attribute field and inverted masks multiply consistently", function()
		local source = points({ Vector3.new(0, 1, 0), Vector3.new(2, 1, 0), Vector3.new(4, 1, 0) })
		source.groups.g = { [1] = 0.4, [2] = 1, [3] = 1 }
		source = A.create(source, "mask", "vertex", "number", 0.5)
		local options = {
			mask = { [1] = true, [2] = 0.5, [3] = false },
			group = "g",
			attribute = "mask",
			maskField = function()
				return 0.5
			end,
			strength = 2,
		}
		local out, r = D.shear(source, 1, options)
		near(out.vertices[1].X, 0.2)
		near(out.vertices[2].X, 2.25)
		assert(out.vertices[3] == source.vertices[3] and r.maskedVertices == 1)
		options.invertMask = true
		out = D.shear(source, 1, options)
		near(out.vertices[1].X, 0.8)
		near(out.vertices[2].X, 2.75)
		near(out.vertices[3].X, 5)
	end)
	test("Simple twist follows right handed rotation on every local axis", function()
		local source = points({ Vector3.new(0.7, 0.4, 0.3), Vector3.new(-0.2, -0.6, 0.8) })
		for name, axis in { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis } do
			local out = D.simple(source, "twist", 1.2, { axis = name, range = Vector2.new(-1, 1) })
			for id, p in source.vertices do
				vec(out.vertices[id], CFrame.fromAxisAngle(axis, 1.2 * p[name] / 2):VectorToWorldSpace(p))
			end
		end
	end)
	test("Simple bend has analytic circular coordinates and tangent endpoint extension", function()
		local source =
			points({ Vector3.new(0.3, -2, 0.2), Vector3.new(0.2, 0.5, 0.1), Vector3.new(-0.1, 2, 0) })
		local out = D.simple(source, "bend", 1, { axis = "Y", range = Vector2.new(-1, 1), radialAxis = "X" })
		for id, p in source.vertices do
			local s = math.clamp(p.Y, -1, 1)
			local a = s * 0.5
			local radius = 2 + p.X
			local d = p.Y - s
			vec(
				out.vertices[id],
				Vector3.new(
					math.cos(a) * radius - 2 - d * math.sin(a),
					math.sin(a) * radius + d * math.cos(a),
					p.Z
				)
			)
		end
		local tiny = D.simple(source, "bend", 1e-10, { range = Vector2.new(-1, 1) })
		for id, p in source.vertices do
			vec(tiny.vertices[id], p, 1e-7)
		end
	end)
	test("Simple taper and stretch follow their independent scale formulas", function()
		local source = points({ Vector3.new(1, -1, 2), Vector3.new(1, 0, 2), Vector3.new(1, 1, 2) })
		local taper = D.simple(source, "taper", 0.6, { range = Vector2.new(-1, 1) })
		local stretch = D.simple(source, "stretch", 0.3, { range = Vector2.new(-1, 1) })
		for id, p in source.vertices do
			vec(taper.vertices[id], Vector3.new(p.X * (1 + 0.3 * p.Y), p.Y, p.Z * (1 + 0.3 * p.Y)))
			local s = 0.7 + 0.3 * p.Y * p.Y
			vec(stretch.vertices[id], Vector3.new(p.X * s, p.Y * 1.3, p.Z * s))
		end
	end)
	test("Sphere ellipsoid cylinder and cuboid casts reach independently defined surfaces", function()
		local source = points({ Vector3.new(2, 1, 0.5), Vector3.new(-1, 0.4, 2), Vector3.zero })
		local sphere, r = D.cast(source, "sphere", { size = 2 })
		assert(r.singularVertices == 1)
		local ellipse = D.cast(source, "sphere", { size = Vector3.new(2, 3, 4) })
		local cylinder = D.cast(source, "cylinder", { size = Vector3.new(2, 3, 4), axis = "Y" })
		local box = D.cast(source, "cuboid", { size = Vector3.new(2, 3, 4) })
		for id = 1, 2 do
			near(sphere.vertices[id].Magnitude, 2)
			near((ellipse.vertices[id] / Vector3.new(2, 3, 4)).Magnitude, 1)
			local p = cylinder.vertices[id]
			near((p.X / 2) ^ 2 + (p.Z / 4) ^ 2, 1)
			near(p.Y, source.vertices[id].Y)
			p = box.vertices[id] / Vector3.new(2, 3, 4)
			near(math.max(math.abs(p.X), math.abs(p.Y), math.abs(p.Z)), 1)
		end
	end)
	test("Cast component restrictions influence radius and negative strength are explicit", function()
		local source = points({ Vector3.new(1, 1, 0), Vector3.new(3, 4, 0) })
		local out, r =
			D.cast(source, "sphere", { size = 2, axes = { X = true }, radius = 2, strength = -0.5 })
		near(out.vertices[1].X, 1 - (math.sqrt(2) - 1) * 0.5)
		near(out.vertices[1].Y, 1)
		assert(out.vertices[2] == source.vertices[2] and r.radiusExcluded == 1)
	end)
	test("Warp transports a rigid frame exactly and preserves radius at partial rotations", function()
		local source = points({ Vector3.xAxis, Vector3.yAxis, Vector3.zAxis })
		local from = CFrame.identity
		local to = CFrame.new(3, -2, 1) * CFrame.Angles(0, math.pi, 0)
		local full = D.warp(source, from, to)
		for id, p in source.vertices do
			vec(full.vertices[id], to:PointToWorldSpace(p))
		end
		local half = D.warp(source, from, CFrame.Angles(0, math.pi, 0), { strength = 0.5 })
		for _, p in half.vertices do
			near(p.Magnitude, 1)
		end
		local linear =
			D.warp(source, from, CFrame.Angles(0, math.pi, 0), { strength = 0.5, preserveRotation = false })
		assert(linear.vertices[1].Magnitude < 1e-5)
	end)
	test("Warp radius falloffs and field masks have analytic translation influence", function()
		local source = points({ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 2, Vector3.xAxis * 3 })
		for name, expected in
			{
				constant = 1,
				linear = 0.5,
				smooth = 0.5,
				sharp = 0.25,
				root = math.sqrt(0.5),
				sphere = math.sqrt(0.75),
				inverseSquare = 0.75,
			}
		do
			local out = D.warp(source, CFrame.identity, CFrame.new(0, 2, 0), { radius = 2, falloff = name })
			near(out.vertices[1].Y, 2)
			near(out.vertices[2].Y, expected * 2)
			assert(out.vertices[3] == source.vertices[3] and out.vertices[4] == source.vertices[4])
		end
	end)
	test("Taper profiles support knots callbacks and anisotropic transverse scaling", function()
		local source = points({ Vector3.new(2, 0, 3), Vector3.new(2, 0.25, 3), Vector3.new(2, 1, 3) })
		local out = D.taperProfile(source, { Vector2.new(0, 1), Vector2.new(0.5, 2), Vector2.new(1, 1) })
		vec(out.vertices[2], Vector3.new(3, 0.25, 4.5))
		out = D.taperProfile(source, function(t)
			return Vector2.new(1 + t, 2 - t)
		end)
		vec(out.vertices[2], Vector3.new(3.5, 0.25, 3.75))
	end)
	test(
		"Rational taper graphs invert horizontal coordinates instead of assuming uniform parameters",
		function()
			local graph =
				E.NURBS.curve({ Vector3.new(0, 1, 0), Vector3.new(0, 1.5, 0), Vector3.new(1, 2, 0) }, 2)
			local source = points({ Vector3.new(1, 0, 1), Vector3.new(1, 0.25, 1), Vector3.new(1, 1, 1) })
			local out = D.taperProfile(source, graph)
			vec(out.vertices[2], Vector3.new(1.5, 0.25, 1.5))
			assert(
				not pcall(
					D.taperProfile,
					points({ Vector3.new(1, 0.37, 1) }),
					graph,
					{ range = Vector2.new(0, 1), maxProfileIterations = 1 }
				)
			)
		end
	)
	test("Closed meshes retain metadata through composed local frame workflows", function()
		local source = decorated(tube(3, 8))
		local before = E.IO.encode(source)
		local out = D.simple(source, "twist", 0.3, { axis = "X" })
		out = D.taperProfile(out, function(t)
			return 1 + 0.2 * math.sin(math.pi * t)
		end, { axis = "X" })
		out = D.shear(out, 0.1, { axis = "Z", direction = "X" })
		assert(out:validate().closed)
		metadata(source, out)
		assert(E.IO.encode(source) == before)
	end)
	test("Curve deformation uses physical distance on nonuniform rational parameterizations", function()
		local curve = E.NURBS.curve(
			{ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 4 },
			2,
			{ weights = { 1, 0.1, 7 } }
		)
		local source =
			points({ Vector3.new(0, 0.2, 0.3), Vector3.new(1, 0.2, 0.3), Vector3.new(4, 0.2, 0.3) })
		local out, r = D.curve(source, curve, { tolerance = 1e-5 })
		assert(r.complete and r.curve.queries == 3 and r.curve.maximumDistanceError <= 1e-5)
		for id, p in source.vertices do
			vec(out.vertices[id], p, 2e-5)
		end
	end)
	test("Curve deformation has independent circular centerline and cross section coordinates", function()
		local curve = E.Surfaces.arc(CFrame.identity, 3, 0, math.pi / 2)
		local source = points({
			Vector3.new(0, 0.2, 0.1),
			Vector3.new(1.7, -0.1, 0.2),
			Vector3.new(3 * math.pi / 2, 0.3, -0.2),
		})
		local out, r = D.curve(source, curve, { up = Vector3.zAxis, tolerance = 0.0002 })
		assert(r.complete and r.curve.frameSamples > 4)
		for id, p in source.vertices do
			local a = p.X / 3
			vec(out.vertices[id], Vector3.new((3 + p.Z) * math.cos(a), (3 + p.Z) * math.sin(a), p.Y), 0.0004)
		end
	end)
	test("Curve fit ranges negative axes and all six directions preserve straight coordinates", function()
		local source = points({ Vector3.new(1, 2, 3), Vector3.new(-1, -2, -3) })
		for name, axis in { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis } do
			for _, sign in { 1, -1 } do
				local curve = E.NURBS.curve({ axis * (-5 * sign), axis * (5 * sign) }, 1)
				local out = D.curve(
					source,
					curve,
					{ axis = (sign < 0 and "-" or "") .. name, offset = 5, tolerance = 1e-5 }
				)
				for id, p in source.vertices do
					vec(out.vertices[id], p, 3e-5)
				end
			end
		end
		local shifted =
			points({ Vector3.new(10, 0.2, 0.1), Vector3.new(15, 0.2, 0.1), Vector3.new(20, 0.2, 0.1) })
		local out = D.curve(
			shifted,
			E.NURBS.curve({ Vector3.zero, Vector3.xAxis * 4 }, 1),
			{ fit = true, tolerance = 1e-5 }
		)
		for id, p in shifted.vertices do
			vec(out.vertices[id], Vector3.new((p.X - 10) * 0.4, p.Y, p.Z), 2e-5)
		end
	end)
	test("Curve endpoint extension clamping and explicit rejection use endpoint tangents", function()
		local curve = E.NURBS.curve({ Vector3.new(0, 1, 0), Vector3.new(0, 3, 0) }, 1)
		local source = points({ Vector3.new(-1, 0, 0), Vector3.new(3, 0, 0) })
		local extended = D.curve(source, curve, { up = Vector3.zAxis })
		vec(extended.vertices[1], Vector3.zero)
		vec(extended.vertices[2], Vector3.new(0, 4, 0))
		local clamped = D.curve(source, curve, { outside = "clamp", up = Vector3.zAxis })
		vec(clamped.vertices[1], Vector3.new(0, 1, 0))
		vec(clamped.vertices[2], Vector3.new(0, 3, 0))
		assert(not pcall(D.curve, source, curve, { outside = "error" }))
	end)
	test(
		"Curve roll and radius profiles rotate and scale cross sections without moving the centerline",
		function()
			local source = points({ Vector3.new(0, 1, 0), Vector3.new(1, 1, 0), Vector3.new(2, 1, 0) })
			local curve = E.NURBS.curve({ Vector3.zero, Vector3.xAxis * 2 }, 1)
			local out = D.curve(source, curve, {
				roll = function(f)
					return math.pi * f / 2
				end,
				radiusProfile = function(f)
					return 1 + f
				end,
				tolerance = 1e-5,
			})
			for id, p in source.vertices do
				local f = p.X / 2
				vec(
					out.vertices[id],
					Vector3.new(p.X, (1 + f) * math.cos(math.pi * f / 2), (1 + f) * math.sin(math.pi * f / 2)),
					2e-5
				)
			end
		end
	)
	test("Cyclic curve frames close the seam and wrap longitudinal offsets", function()
		local curve = E.Cyclic.curve({
			Vector3.new(2, 0, 0),
			Vector3.new(1, 2, 0.7),
			Vector3.new(-1, 1, 1.3),
			Vector3.new(-2, -0.5, -0.2),
			Vector3.new(0, -2, -0.6),
		}, 3)
		local source =
			points({ Vector3.new(0, 0.2, 0.1), Vector3.new(1, 0.2, 0.1), Vector3.new(2, 0.2, 0.1) })
		local out, r =
			D.curve(source, curve, { sourceRange = Vector2.new(0, 1), tolerance = 0.001, up = Vector3.zAxis })
		assert(r.curve.closed and r.complete)
		vec(out.vertices[1], out.vertices[2], 0.0002)
		vec(out.vertices[1], out.vertices[3], 0.0002)
	end)
	test("Bezier and polyline inputs preserve endpoint behavior including stationary endpoints", function()
		local source = points({ Vector3.new(0, 0.1, 0), Vector3.new(1, 0.1, 0) })
		local c = E.NURBS.curve({ Vector3.zero, Vector3.zero, Vector3.xAxis, Vector3.xAxis }, 3)
		local out, r = D.curve(source, c)
		assert(r.curve.stationarySamples == 2)
		for id, p in source.vertices do
			vec(out.vertices[id], p)
		end
		local b = E.Bezier.new({ Vector3.zero, Vector3.xAxis })
		out = D.curve(source, b)
		for id, p in source.vertices do
			vec(out.vertices[id], p)
		end
		out = D.curve(
			points({ Vector3.new(1.5, 0, 0) }),
			{ Vector3.zero, Vector3.xAxis, Vector3.new(1, 1, 0) },
			{ up = Vector3.zAxis, tolerance = 1e-5 }
		)
		vec(out.vertices[1], Vector3.new(1, 0.5, 0), 2e-5)
	end)
	test("Curve mapping is covariant under shared frame transformations", function()
		local frame = CFrame.new(8, -3, 6) * CFrame.Angles(0.3, 0.5, -0.2)
		local source =
			points({ Vector3.new(0, 0.1, 0.2), Vector3.new(1, 0.1, 0.2), Vector3.new(2, 0.1, 0.2) })
		local curve = E.Surfaces.arc(CFrame.identity, 3, 0, math.pi / 2)
		local base = D.curve(source, curve, { up = Vector3.zAxis, tolerance = 0.002 })
		local out = D.curve(D.transform(source, frame), curve, {
			frame = frame,
			pathFrame = frame,
			up = frame:VectorToWorldSpace(Vector3.zAxis),
			tolerance = 0.002,
		})
		for id, p in base.vertices do
			vec(out.vertices[id], frame:PointToWorldSpace(p), 0.003)
		end
	end)
	test("Nonlinear curve deformation preserves channels groups skin and native UV topology", function()
		local source = decorated(tube(3, 10))
		local before = E.IO.encode(source)
		local curve = E.Surfaces.arc(CFrame.identity, 3, 0, math.pi / 2)
		local out, r = D.curve(source, curve, { fit = true, up = Vector3.zAxis, tolerance = 0.001 })
		assert(r.complete and out:validate().closed)
		metadata(source, out)
		assert(E.IO.encode(source) == before)
		local rig = E.Rig.new()
		rig:addBone("A")
		rig:addBone("B")
		local handle = E.Roblox.toEditable(out, { rig = rig })
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().closed)
			near(restored:volume(), out:volume(), 0.0001)
			for _, weights in restored.weights do
				local total = 0
				for _, w in weights do
					total += w
				end
				near(total, 1)
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	test("Deformation invalid outputs budgets callbacks and masks reject transactionally", function()
		local source = decorated(E.Primitives.box())
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxVertices = 1 },
				{ maxWork = 1 },
				{ mask = { [999] = 1 } },
				{ mask = { [1] = -1 } },
				{ group = "absent" },
				{ attribute = "region" },
				{
					maskField = function()
						return 2
					end,
				},
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function()
						error("cancel")
					end,
				},
			}
		do
			assert(not pcall(D.shear, source, 0.2, options))
		end
		assert(not pcall(D.taperProfile, source, 0))
		local _, invalid = D.taperProfile(source, 0, { allowInvalid = true })
		assert(not invalid.complete and not invalid.validation.valid)
		assert(E.IO.encode(source) == before)
	end)
	test("Curve reversals incompatible closed seams and numerical budgets reject explicitly", function()
		local source = points({ Vector3.zero, Vector3.xAxis, Vector3.xAxis * 2 })
		local curve = E.Surfaces.arc(CFrame.identity, 3, 0, math.pi / 2)
		local before = E.IO.encode(source)
		for _, options in
			{
				{ maxFrameSamples = 2 },
				{ maxCurveNodes = 1, tolerance = 1e-7 },
				{ maxCurveQueries = 1 },
				{ arcLength = { maxNodes = 1, tolerance = 1e-9 } },
				{ closed = true },
				{ outside = "wrap" },
			}
		do
			assert(not pcall(D.curve, source, curve, options))
		end
		assert(not pcall(D.curve, source, { Vector3.zero, Vector3.xAxis, Vector3.zero }))
		assert(not pcall(D.curve, source, { Vector3.zero, Vector3.zero }))
		assert(E.IO.encode(source) == before)
	end)
	test("Falloff callbacks run only for affected vertices inside a finite influence radius", function()
		local source = points({ Vector3.xAxis, Vector3.xAxis * 3 })
		local calls = 0
		local function falloff(t)
			calls += 1
			near(t, 0.5)
			return 1 - t
		end
		local out = D.cast(source, "sphere", { size = 2, radius = 2, falloff = falloff })
		assert(calls == 1)
		vec(out.vertices[1], Vector3.xAxis * 1.5)
		vec(out.vertices[2], source.vertices[2])
		D.warp(source, CFrame.identity, CFrame.new(0, 1, 0), { radius = 2, mask = {}, falloff = falloff })
		assert(calls == 1)
		D.cast(source, "sphere", { radius = 0, falloff = falloff })
		assert(calls == 1)
		assert(not pcall(D.cast, source, "sphere", { falloff = "unknown" }))
	end)
	report.success = report.failed == 0
	return report
end
