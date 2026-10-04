return function(E)
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function near(a, b, tolerance)
		assert(math.abs(a - b) <= (tolerance or 1e-6), tostring(a) .. " differs from " .. tostring(b))
	end
	local function grid(n, size)
		n, size = n or 8, size or 4
		local mesh = E.Mesh.new()
		local function id(i, j)
			return j * (n + 1) + i + 1
		end
		for j = 0, n do
			for i = 0, n do
				mesh:addVertex(Vector3.new((i / n - 0.5) * size, (j / n - 0.5) * size, 0))
			end
		end
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				mesh:addFace({ id(i, j), id(i + 1, j), id(i + 1, j + 1) })
				mesh:addFace({ id(i, j), id(i + 1, j + 1), id(i, j + 1) })
			end
		end
		return mesh, id
	end
	test("Named and custom radial falloffs match independent single-dab formulas", function()
		local m, id = grid()
		local expected = {
			constant = 1,
			linear = 0.5,
			smooth = 0.5,
			smoother = 0.5,
			sharp = 0.25,
			sharper = 0.0625,
			root = math.sqrt(0.5),
			sphere = math.sqrt(0.75),
			inverseSquare = 0.75,
		}
		for name, weight in expected do
			local out, r = E.Sculpt.brush(
				m,
				Vector3.zero,
				{ normal = Vector3.zAxis, radius = 1, strength = 0.2, falloff = name }
			)
			assert(r.complete and r.applied and r.sampling.dabs == 1)
			near(out.vertices[id(5, 4)].Z, 0.2 * weight)
			assert(out.vertices[id(6, 4)] == m.vertices[id(6, 4)])
		end
		local out = E.Sculpt.brush(m, Vector3.zero, {
			normal = Vector3.zAxis,
			radius = 1,
			strength = 0.2,
			falloff = function(t)
				return 1 - t ^ 3
			end,
		})
		near(out.vertices[id(5, 4)].Z, 0.175)
	end)
	test("Pressure size and strength are independent and zero pressure can be an exact identity", function()
		local m, id = grid()
		local out, r = E.Sculpt.brush(
			m,
			Vector3.zero,
			{ normal = Vector3.zAxis, radius = 1, pressure = 0.5, pressureSize = true, strength = 0.2 }
		)
		assert(r.complete)
		near(out.vertices[id(4, 4)].Z, 0.05)
		assert(out.vertices[id(5, 4)] == m.vertices[id(5, 4)])
		local stationary, q = E.Sculpt.brush(m, Vector3.zero, { normal = Vector3.zAxis, pressure = 0 })
		assert(q.complete and not q.applied and E.IO.encode(stationary) == E.IO.encode(m))
		local constant = E.Sculpt.brush(
			m,
			Vector3.zero,
			{ normal = Vector3.zAxis, pressure = 0, pressureStrength = false, strength = 0.2 }
		)
		near(constant.vertices[id(4, 4)].Z, 0.2)
	end)
	test("Spacing ignores inserted collinear input samples and interpolates pressure", function()
		local m = grid()
		local a = {
			{ position = Vector3.new(-1, 0, 0), pressure = 0.25 },
			{ position = Vector3.new(1, 0, 0), pressure = 0.75 },
		}
		local b = { a[1], { position = Vector3.zero, pressure = 0.5 }, a[2] }
		local options = { normal = Vector3.zAxis, radius = 0.75, spacing = 0.5, strength = 0.1 }
		local x, xr = E.Sculpt.stroke(m, a, options)
		local y, yr = E.Sculpt.stroke(m, b, options)
		assert(xr.complete and yr.complete and xr.sampling.dabs == yr.sampling.dabs)
		assert(E.IO.encode(x) == E.IO.encode(y))
	end)
	test("Distance-adjusted strength has an analytic spacing-independent dose", function()
		local m = grid(2, 0.5)
		local samples = { { position = Vector3.new(-1, 0, 0) }, { position = Vector3.new(1, 0, 0) } }
		for _, spacing in { 0.1, 0.25, 0.5, 1 } do
			local out, r = E.Sculpt.stroke(m, samples, {
				normal = Vector3.zAxis,
				radius = 4,
				strength = 0.125,
				spacing = spacing,
				includeEnd = spacing ~= 1,
				falloff = "constant",
				adjustStrengthForSpacing = true,
			})
			assert(r.complete)
			for _, p in out.vertices do
				near(p.Z, 0.25)
			end
		end
	end)
	test("Mirror overlap feathering preserves one-dab strength and simultaneous symmetry", function()
		local m, id = grid()
		local options = {
			normal = Vector3.zAxis,
			radius = 0.75,
			strength = 0.1,
			falloff = "constant",
			symmetry = { mirror = { X = true } },
		}
		local out, r = E.Sculpt.brush(m, Vector3.new(0.5, 0, 0), options)
		assert(r.complete and r.symmetryCopies == 2)
		near(out.vertices[id(4, 4)].Z, 0.075)
		for j = 0, 8 do
			for i = 0, 8 do
				near(out.vertices[id(i, j)].Z, out.vertices[id(8 - i, j)].Z)
			end
		end
		options.feather = false
		local added = E.Sculpt.brush(m, Vector3.new(0.5, 0, 0), options)
		near(added.vertices[id(4, 4)].Z, 0.15)
	end)
	test("Radial copies and explicit tiles have exact cardinal positions", function()
		local m, id = grid()
		local out, r = E.Sculpt.brush(m, Vector3.xAxis, {
			normal = Vector3.zAxis,
			radius = 0.4,
			strength = 0.25,
			symmetry = { radial = { axis = "Z", count = 4 } },
		})
		assert(r.complete and r.symmetryCopies == 4)
		for _, vertex in { id(6, 4), id(2, 4), id(4, 6), id(4, 2) } do
			near(out.vertices[vertex].Z, 0.1)
		end
		local tiled, q = E.Sculpt.brush(m, Vector3.zero, {
			normal = Vector3.zAxis,
			radius = 0.4,
			strength = 0.25,
			symmetry = { tileOffsets = { Vector3.zero, Vector3.xAxis, Vector3.xAxis } },
		})
		assert(q.complete and q.symmetryCopies == 2)
		near(tiled.vertices[id(4, 4)].Z, 0.1)
		near(tiled.vertices[id(6, 4)].Z, 0.1)
	end)
	test("Move flatten pinch crease smooth and inflation implement their stated local fields", function()
		local m, id = grid()
		local center = id(4, 4)
		local common = { radius = 2, strength = 0.25, falloff = "constant", normal = Vector3.zAxis }
		local options = table.clone(common)
		options.brush, options.delta = "move", Vector3.new(0, 0, 0.4)
		local moved, r = E.Sculpt.brush(m, Vector3.zero, options)
		assert(r.complete)
		near(moved.vertices[center].Z, 0.1)
		options.brush = "inflate"
		local inflated = E.Sculpt.brush(m, Vector3.zero, options)
		near(inflated.vertices[center].Z, 0.5)
		options.brush = "pinch"
		local pinched = E.Sculpt.brush(m, Vector3.zero, options)
		near(pinched.vertices[id(5, 4)].X, 0.375)
		options.brush = "crease"
		local creased = E.Sculpt.brush(m, Vector3.zero, options)
		near(creased.vertices[center].Z, -0.5)
		options.brush = "flatten"
		m.vertices[center] = Vector3.new(0, 0, 0.4)
		local flat = E.Sculpt.brush(m, Vector3.zero, options)
		near(flat.vertices[center].Z, 0.3)
		options.brush = "smooth"
		local smooth = E.Sculpt.brush(m, Vector3.zero, options)
		near(smooth.vertices[center].Z, 0.3)
	end)
	test("Explicit detail bases retain the original per-vertex residual while moving the base", function()
		local base, id = grid()
		local detailed = base:clone()
		for vertex, p in detailed.vertices do
			detailed.vertices[vertex] = p + Vector3.new(0, 0, 0.02 * math.cos(3 * p.X) * math.cos(2 * p.Y))
		end
		local options = {
			brush = "move",
			delta = Vector3.new(0, 0, 0.2),
			radius = 1.5,
			strength = 0.5,
			detailBase = base,
		}
		local out, r = E.Sculpt.brush(detailed, Vector3.zero, options)
		options.detailBase = nil
		local moved = E.Sculpt.brush(base, Vector3.zero, options)
		assert(r.complete and r.detailPreserved and out.vertices[id(4, 4)].Z > detailed.vertices[id(4, 4)].Z)
		for vertex, p in out.vertices do
			near(p.Z - moved.vertices[vertex].Z, detailed.vertices[vertex].Z - base.vertices[vertex].Z)
		end
	end)
	test("Mask dictionaries groups attributes fields pins and locks compose multiplicatively", function()
		local m, id = grid()
		m = E.Attributes.create(m, "influence", "vertex", "number", 0.5)
		m.groups.region = {}
		local mask = {}
		for vertex in m.vertices do
			mask[vertex] = 0.5
			m.groups.region[vertex] = 0.5
		end
		local out, r = E.Sculpt.brush(m, Vector3.zero, {
			brush = "move",
			delta = Vector3.new(0.2, 0.4, 0.8),
			strength = 1,
			radius = 3,
			falloff = "constant",
			mask = mask,
			group = "region",
			attribute = "influence",
			maskField = function()
				return 0.5
			end,
			pins = { [id(3, 4)] = true },
			lockAxes = { X = true, Y = true },
		})
		assert(r.complete and out.vertices[id(3, 4)] == m.vertices[id(3, 4)])
		near(out.vertices[id(4, 4)].Z, 0.05)
		for vertex, p in out.vertices do
			assert(p.X == m.vertices[vertex].X and p.Y == m.vertices[vertex].Y)
		end
	end)
	test("Boundary and typed seam protection are explicit constraints", function()
		local m, id = grid()
		m = E.Attributes.create(m, "sharp_edge", "edge", "boolean", false)
		local a, b = id(4, 4), id(5, 4)
		m.attributes.sharp_edge.values[math.min(a, b) .. ":" .. math.max(a, b)] = true
		local out, r = E.Sculpt.brush(m, Vector3.zero, {
			normal = Vector3.zAxis,
			radius = 5,
			strength = 0.02,
			falloff = "constant",
			pinBoundary = true,
			preserveSeams = true,
		})
		assert(r.complete and out.vertices[a] == m.vertices[a] and out.vertices[b] == m.vertices[b])
		for vertex in E.Selection.boundary(m) do
			assert(out.vertices[vertex] == m.vertices[vertex])
		end
		near(out.vertices[id(3, 4)].Z, 0.1)
	end)
	test("Projected influence and front-face filtering distinguish parallel surface sheets", function()
		local a = grid(2, 1)
		local b = a:clone()
		for id, p in b.vertices do
			b.vertices[id] = p + Vector3.new(0, 0, 2)
		end
		for _, face in b.faces do
			local vertices = face.vertices
			vertices[2], vertices[3] = vertices[3], vertices[2]
		end
		local m = E.Topology.join({ a, b })
		local options = {
			brush = "move",
			delta = Vector3.new(0, 0, 0.1),
			normal = Vector3.zAxis,
			radius = 1,
			strength = 1,
			falloff = "constant",
		}
		local sphere = E.Sculpt.brush(m, Vector3.zero, options)
		near(sphere.vertices[5].Z, 0.1)
		near(sphere.vertices[14].Z, 2)
		options.shape = "projected"
		local projected, r = E.Sculpt.brush(m, Vector3.zero, options)
		assert(r.complete)
		near(projected.vertices[14].Z, 2.1)
		options.frontFace = true
		local front = E.Sculpt.brush(m, Vector3.zero, options)
		near(front.vertices[5].Z, 0.1)
		near(front.vertices[14].Z, 2)
	end)
	test("Explicit dabs preserve stationary events while spaced paths suppress repeated positions", function()
		local m, id = grid()
		local samples = { { position = Vector3.zero }, { position = Vector3.zero } }
		local options = { normal = Vector3.zAxis, shape = "projected", strength = 0.1, sampling = "dabs" }
		local out, r = E.Sculpt.stroke(m, samples, options)
		assert(r.complete and r.sampling.dabs == 2)
		near(out.vertices[id(4, 4)].Z, 0.2)
		options.sampling = "spaced"
		local single, q = E.Sculpt.stroke(m, samples, options)
		assert(q.complete and q.sampling.dabs == 1)
		near(single.vertices[id(4, 4)].Z, 0.1)
	end)
	test("Frame-conjugated symmetry commutes with a rigid transformation", function()
		local m = grid()
		local options =
			{ normal = Vector3.zAxis, radius = 0.75, strength = 0.1, symmetry = { mirror = { X = true } } }
		local a, ar = E.Sculpt.brush(m, Vector3.xAxis, options)
		assert(ar.complete)
		local frame = CFrame.new(3, 4, 5) * CFrame.Angles(0.3, 0.4, 0.2)
		local transformed = E.Deform.transform(m, frame)
		options.normal = frame:VectorToWorldSpace(Vector3.zAxis)
		options.symmetry.frame = frame
		local b, br = E.Sculpt.brush(transformed, frame:PointToWorldSpace(Vector3.xAxis), options)
		assert(br.complete)
		for id, p in a.vertices do
			local expected = frame:PointToWorldSpace(p)
			near((b.vertices[id] - expected).Magnitude, 0, 2e-6)
		end
	end)
	test("Native geometry scales and large translations preserve the local brush footprint", function()
		for _, scale in { 2 ^ -40, 2 ^ 40 } do
			local m, id = grid()
			for vertex, p in m.vertices do
				m.vertices[vertex] = p * scale
			end
			local out, r =
				E.Sculpt.brush(m, Vector3.zero, { normal = Vector3.zAxis, radius = scale, strength = 0.2 })
			assert(r.complete)
			near(out.vertices[id(4, 4)].Z / scale, 0.2)
		end
		local m, id = grid()
		local shift = Vector3.new(2 ^ 20, -(2 ^ 20), 2 ^ 17)
		for vertex, p in m.vertices do
			m.vertices[vertex] = p + shift
		end
		local out, r = E.Sculpt.brush(m, shift, { normal = Vector3.zAxis, radius = 1, strength = 0.125 })
		assert(r.complete)
		near(out.vertices[id(4, 4)].Z - shift.Z, 0.125)
	end)
	test("Source samples detail bases nested symmetry and options are captured before callbacks", function()
		local m = grid(4)
		local base = m:clone()
		local samples = { { position = Vector3.zero } }
		local options = {
			normal = Vector3.zAxis,
			strength = 0.1,
			detailBase = base,
			symmetry = { mirror = { X = true } },
		}
		local expected = E.Sculpt.stroke(m, samples, options)
		options.checkpoint = function(status)
			if status.stage == "begin" then
				m.vertices[13] = Vector3.new(99, 99, 99)
				base.vertices[13] = Vector3.new(8, 8, 8)
				samples[1].position = Vector3.new(20, 20, 20)
				options.symmetry.mirror.Z = true
				options.strength = 10
			end
		end
		local out, r = E.Sculpt.stroke(m, samples, options)
		assert(r.complete and E.IO.encode(out) == E.IO.encode(expected))
	end)
	test("Geometry edits preserve every data domain and invalidate only intrinsic tangent frames", function()
		local m = grid(4)
		for name, spec in
			{
				v = { "vertex", "number", 2 },
				e = { "edge", "boolean", true },
				f = { "face", "string", "face" },
				c = { "corner", "Vector2", Vector2.one },
			}
		do
			m = E.Attributes.create(m, name, spec[1], spec[2], spec[3])
		end
		m.groups.sample = { [13] = 0.5 }
		m.weights[13] = { joint = 1 }
		m.faces[1].material = 7
		for _, face in m.faces do
			for _, corner in face.corners do
				corner.uv = Vector2.new(3, 4)
				corner.normal = Vector3.zAxis
				corner.tangent = Vector3.xAxis
				corner.tangentSign = 1
			end
		end
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.brush(
			m,
			Vector3.zero,
			{ normal = Vector3.zAxis, radius = 2, recalculateNormals = false }
		)
		assert(
			r.complete
				and E.IO.encode(m) == before
				and out.groups.sample[13] == 0.5
				and out.weights[13].joint == 1
				and out.faces[1].material == 7
		)
		for name, channel in m.attributes do
			assert(
				out.attributes[name].default == channel.default
					and out.attributes[name].domain == channel.domain
			)
		end
		for _, face in out.faces do
			for _, corner in face.corners do
				assert(
					corner.uv == Vector2.new(3, 4)
						and corner.normal == Vector3.zAxis
						and corner.tangent == nil
						and corner.tangentSign == nil
				)
			end
		end
	end)
	test("Normal change and introduced collisions reject the whole stroke transaction", function()
		local m = grid(4)
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.brush(
			m,
			Vector3.zero,
			{ normal = Vector3.zAxis, radius = 2, strength = 0.2, normalLimit = 0.001 }
		)
		assert(
			not r.complete
				and r.reason == "geometry"
				and r.geometry.reason == "normalLimit"
				and E.IO.encode(out) == before
		)
		local a = grid(2, 1)
		local b = a:clone()
		for id, p in b.vertices do
			b.vertices[id] = p + Vector3.new(0, 0, 1)
		end
		m = E.Topology.join({ a, b })
		local mask = {}
		for id in a.vertices do
			mask[id] = true
		end
		before = E.IO.encode(m)
		local result, q = E.Sculpt.brush(m, Vector3.zero, {
			brush = "move",
			delta = Vector3.zAxis,
			radius = 2,
			strength = 1,
			falloff = "constant",
			mask = mask,
		})
		assert(
			not q.complete
				and not q.applied
				and q.reason == "outputIntersections"
				and E.IO.encode(result) == before
		)
	end)
	test("Incomplete scans and strict mode expose failure without source mutation", function()
		local m = grid(4)
		local before = E.IO.encode(m)
		local options = { normal = Vector3.zAxis, intersectionOptions = { maxTests = 1 } }
		local out, r = E.Sculpt.brush(m, Vector3.zero, options)
		assert(not r.complete and r.reason == "inputIntersections" and E.IO.encode(out) == before)
		options.requireComplete = true
		assert(not pcall(E.Sculpt.brush, m, Vector3.zero, options))
		assert(E.IO.encode(m) == before)
	end)
	test("Native overflow returns an explicit unchanged result", function()
		local m = grid(2)
		local before = E.IO.encode(m)
		local out, r =
			E.Sculpt.brush(m, Vector3.zero, { normal = Vector3.zAxis, radius = 1e30, strength = 1e30 })
		assert(
			not r.complete and not r.applied and r.reason == "nativeOverflow" and E.IO.encode(out) == before
		)
	end)
	test("Dab sample symmetry and work limits and cancellation are transactional", function()
		local m = grid(4)
		local before = E.IO.encode(m)
		for _, options in
			{
				{ maxVertices = 1 },
				{ maxFaces = 1 },
				{ maxCorners = 1 },
				{ maxTriangles = 1 },
				{ maxWork = 1 },
				{ maxSamples = 1 },
				{ maxDabs = 1 },
				{ maxCopies = 1, symmetry = { mirror = { X = true } } },
				{
					cancelled = function()
						return true
					end,
				},
				{
					checkpoint = function(s)
						if s.stage == "dab" then
							error("stop")
						end
					end,
				},
				{ intersectionOptions = {
					cancelled = function()
						return true
					end,
				} },
			}
		do
			options.normal = Vector3.zAxis
			assert(
				not pcall(
					E.Sculpt.stroke,
					m,
					{ { position = Vector3.zero }, { position = Vector3.xAxis } },
					options
				)
			)
		end
		assert(E.IO.encode(m) == before)
	end)
	test("Invalid sample mask symmetry and numerical schemas cannot become successful identities", function()
		local m = grid(2)
		for _, options in
			{
				{ radius = 0 },
				{ spacing = 0 },
				{ strength = math.huge },
				{ normal = Vector3.zero },
				{ pressure = 2 },
				{ brush = "unknown" },
				{ shape = "unknown" },
				{ sampling = "unknown" },
				{ symmetry = false },
				{ symmetry = { mirror = false } },
				{ symmetry = { radial = false } },
				{ symmetry = { radial = { count = 0 } } },
				{ symmetry = { tileOffsets = false } },
				{ pins = false },
				{ lockAxes = { Q = true } },
				{ mask = { [1] = 2 } },
				{ detailBase = false },
				{
					falloff = function()
						return 2
					end,
				},
			}
		do
			if options.normal == nil then
				options.normal = Vector3.zAxis
			end
			if options.sampling then
				assert(not pcall(E.Sculpt.stroke, m, { { position = Vector3.zero } }, options))
			else
				assert(not pcall(E.Sculpt.brush, m, Vector3.zero, options))
			end
		end
		assert(not pcall(E.Sculpt.stroke, m, {}, { normal = Vector3.zAxis }))
	end)
	test("A distant symmetry frame cannot perturb an identity brush image", function()
		local m = grid(4)
		local options = { normal = Vector3.zAxis, radius = 2 }
		local a = E.Sculpt.brush(m, Vector3.zero, options)
		options.symmetry = { frame = CFrame.new(1e30, -1e30, 1e30) * CFrame.Angles(0.2, 0.3, 0.4) }
		local b, r = E.Sculpt.brush(m, Vector3.zero, options)
		assert(r.complete and E.IO.encode(a) == E.IO.encode(b))
	end)
	test("Sparse vertex and face IDs retain deterministic position correspondence", function()
		local source = grid(4)
		local expected = E.Sculpt.brush(source, Vector3.zero, { normal = Vector3.zAxis, radius = 2 })
		local sparse = E.Mesh.new()
		for id, p in source.vertices do
			sparse.vertices[id * 101 + 7] = p
		end
		for id, face in source.faces do
			local other = require(script.Parent.Util).copy(face)
			for i, vertex in face.vertices do
				other.vertices[i] = vertex * 101 + 7
			end
			sparse.faces[id * 13 + 2] = other
		end
		sparse.nextVertex, sparse.nextFace = 10000, 10000
		local out, r = E.Sculpt.brush(sparse, Vector3.zero, { normal = Vector3.zAxis, radius = 2 })
		assert(r.complete)
		for id, p in expected.vertices do
			assert(out.vertices[id * 101 + 7] == p)
		end
	end)
	test("Empty masked and axis-locked edits preserve exact source snapshots", function()
		local empty, er = E.Sculpt.brush(E.Mesh.new(), Vector3.zero, { normal = Vector3.zAxis })
		assert(er.complete and not er.applied and next(empty.vertices) == nil)
		local m = grid(2)
		local before = E.IO.encode(m)
		for _, options in { { mask = {} }, { lockAxes = { X = true, Y = true, Z = true } } } do
			options.normal = Vector3.zAxis
			local out, r = E.Sculpt.brush(m, Vector3.zero, options)
			assert(r.complete and not r.applied and E.IO.encode(out) == before)
		end
	end)
	test("Input intersections and invalid detail-base topology cannot succeed", function()
		local a = grid(2)
		local m = E.Topology.join({ a, a })
		local before = E.IO.encode(m)
		local out, r = E.Sculpt.brush(m, Vector3.zero, { normal = Vector3.zAxis })
		assert(not r.complete and r.reason == "inputIntersections" and E.IO.encode(out) == before)
		local base = a:clone()
		base.faces[1].vertices[2], base.faces[1].vertices[3] =
			base.faces[1].vertices[3], base.faces[1].vertices[2]
		assert(not pcall(E.Sculpt.brush, a, Vector3.zero, { normal = Vector3.zAxis, detailBase = base }))
	end)
	test("Optional endpoints are explicit and cancelling normal interpolation rejects", function()
		local m = grid(2)
		local samples = { { position = Vector3.zero }, { position = Vector3.new(1, 0, 0) } }
		local _, r =
			E.Sculpt.stroke(m, samples, { normal = Vector3.zAxis, spacing = 0.4, includeEnd = false })
		local _, q = E.Sculpt.stroke(m, samples, { normal = Vector3.zAxis, spacing = 0.4 })
		assert(r.complete and q.complete and r.sampling.dabs == 3 and q.sampling.dabs == 4)
		samples[1].normal, samples[2].normal = Vector3.zAxis, -Vector3.zAxis
		assert(not pcall(E.Sculpt.stroke, m, samples, { spacing = 0.5 }))
	end)
	test("Brush edits compose with multires local-frame residual transport", function()
		local coarse = grid(2)
		local stack = E.Subdivision.multires(coarse, 1)
		local fine, reference = stack:get(), stack:get()
		for id, p in fine.vertices do
			fine.vertices[id] = p + Vector3.new(0, 0, 0.01 * math.sin(id))
		end
		stack:commit(fine)
		local low = stack:select(1)
		local changed, r =
			E.Sculpt.brush(low, Vector3.zero, { normal = Vector3.zAxis, radius = 3, strength = 0.05 })
		assert(r.complete)
		stack:commit(changed)
		local actual, newBase = stack:select(2), E.Subdivision.catmullClark(changed, 1)
		for id, p in actual.vertices do
			near((p - newBase.vertices[id]).Magnitude, (fine.vertices[id] - reference.vertices[id]).Magnitude)
		end
	end)
	test("A symmetric sculpted stroke survives native position UV and normal conversion", function()
		local result = require(script.Parent.Examples.SymmetricStroke)(E)
		assert(result.stroke.complete and result.stroke.applied)
		local handle = E.Roblox.toEditable(result.mesh)
		local ok, err = pcall(function()
			local restored = E.Roblox.fromEditable(handle.editable)
			assert(restored:validate().valid)
			local _, scan = E.Intersections.mesh(restored)
			assert(scan.complete and scan.intersectionFree)
			for _, face in restored.faces do
				for _, corner in face.corners do
					assert(corner.uv and corner.normal and math.abs(corner.normal.Magnitude - 1) < 1e-5)
				end
			end
		end)
		handle.editable:Destroy()
		assert(ok, err)
	end)
	report.success = report.failed == 0
	return report
end
