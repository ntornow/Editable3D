-- Private bounded bevel geometry, interpolation and profile helpers.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local Core = require(script.Parent.MeshEditCore)
local C = require(script.Parent.Connectivity)
local A = require(script.Parent.AttributeCore)
local function mix(a, b, t)
	local out = {}
	for _, r in a do
		table.insert(out, { r[1], r[2] * (1 - t) })
	end
	for _, r in b do
		table.insert(out, { r[1], r[2] * t })
	end
	return out
end
local function mixCorners(a, b, t)
	local out = {}
	for _, r in a do
		table.insert(out, { r[1], r[2], r[3] * (1 - t) })
	end
	for _, r in b do
		table.insert(out, { r[1], r[2], r[3] * t })
	end
	return out
end
local function project(normal)
	local axis = math.abs(normal.X) > math.abs(normal.Y)
			and (math.abs(normal.X) > math.abs(normal.Z) and "X" or "Z")
		or (math.abs(normal.Y) > math.abs(normal.Z) and "Y" or "Z")
	return function(p)
		return axis == "X" and Vector2.new(p.Y, p.Z)
			or (axis == "Y" and Vector2.new(p.Z, p.X) or Vector2.new(p.X, p.Y))
	end
end
local function prepare(mesh, width, options)
	options = options or {}
	assert(type(width) == "number" and U.finite(width) and width > 0, "Positive finite bevel width required")
	local segments = U.integer(options.segments or 1, 1)
	assert(segments <= 64, "Bevel segment limit is 64")
	local profile = options.profile or "round"
	if type(profile) == "table" then
		assert(
			#profile >= 2
				and #profile <= 129
				and profile[1] == Vector2.new(1, 0)
				and profile[#profile] == Vector2.new(0, 1),
			"Custom profile must run from (1,0) to (0,1)"
		)
		for i, p in profile do
			assert(
				typeof(p) == "Vector2"
					and U.finite(p.X)
					and U.finite(p.Y)
					and p.X >= 0
					and p.X <= 1
					and p.Y >= 0
					and p.Y <= 1,
				"Profile coordinates must be finite inside [0,1]"
			)
			if i > 1 then
				assert(
					p.X <= profile[i - 1].X and p.Y >= profile[i - 1].Y and p ~= profile[i - 1],
					"Custom profile must be monotone with distinct samples"
				)
			end
		end
	else
		assert(profile == "round" or profile == "linear", "Bevel profile must be round, linear or an array")
	end
	local join = options.join or "patch"
	assert(join == "patch" or join == "cutoff", "Bevel join must be patch or cutoff")
	local miterLimit = options.miterLimit or 16
	assert(
		type(miterLimit) == "number" and U.finite(miterLimit) and miterLimit >= 1,
		"Bevel miter limit must be finite and at least one"
	)
	if options.material ~= nil then
		U.integer(options.material, 1)
	end
	local tolerance = options.planarTolerance or 1e-5
	assert(
		type(tolerance) == "number" and U.finite(tolerance) and tolerance >= 0,
		"Nonnegative bevel planar tolerance required"
	)
	local maximum = U.integer(options.maxWork or 5000000, 1)
	local work = 0
	local edit, index = Core.begin(mesh, options), C.index(mesh, options)
	edit.report.flatProfiles, edit.report.affineRoundProfiles = 0, 0
	local owner, refs, cornerRefs, edgeCuts, cache, faceData = {}, {}, {}, {}, {}, {}
	local offsets = {}
	local function visit()
		work += 1
		assert(work <= maximum, "Bevel work budget exceeded")
		edit.checkpoint()
	end
	local function face(fid)
		if faceData[fid] then
			return faceData[fid]
		end
		local f = mesh.faces[fid]
		local normal = mesh:faceNormal(fid)
		local origin = mesh.vertices[f.vertices[1]]
		local projection = project(normal)
		local points = {}
		for i, id in f.vertices do
			assert(
				math.abs((mesh.vertices[id] - origin):Dot(normal)) <= tolerance,
				"Bevel requires planar source polygons; triangulate nonplanar faces explicitly"
			)
			points[i] = projection(mesh.vertices[id])
			visit()
		end
		local triangles = mesh:faceTriangles(fid, {
			validateSimple = true,
			maxVertices = options.maxFaceVertices or 2000,
			maxWork = options.maxFaceWork or 5000000,
		})
		local value = { normal = normal, project = projection, points = points, triangles = triangles }
		faceData[fid] = value
		return value
	end
	local function interpolate(fid, p)
		local data, f = face(fid), mesh.faces[fid]
		local q = data.project(p)
		for _, tri in data.triangles do
			visit()
			local a, b, c = data.points[tri[1]], data.points[tri[2]], data.points[tri[3]]
			local sign, den = P.orient2D(a, b, c)
			local sa, wa = P.orient2D(b, c, q)
			local sb, wb = P.orient2D(c, a, q)
			local sc, wc = P.orient2D(a, b, q)
			if sa * sign >= 0 and sb * sign >= 0 and sc * sign >= 0 then
				local vr, cr = {}, {}
				for k, w in { wa / den, wb / den, wc / den } do
					table.insert(vr, { f.vertices[tri[k]], math.max(0, w) })
					table.insert(cr, { fid, tri[k], math.max(0, w) })
				end
				return vr, cr
			end
		end
		error("Bevel offset leaves its source polygon; reduce width")
	end
	local function vertex(p, vr, cr, v, offset)
		local id = edit.vertex(p, vr)
		owner[id], refs[id], cornerRefs[id] = v, vr, cr
		offsets[id] = offset or (p - mesh.vertices[v])
		return id
	end
	local function edgePoint(v, other, distance, fid)
		local length = (mesh.vertices[other] - mesh.vertices[v]).Magnitude
		assert(distance > 0 and distance < length, "Bevel consumes a source edge; reduce width")
		local t = distance / length
		local key = U.edge(v, other)
		local low, high = math.min(v, other), math.max(v, other)
		local u = v == low and t or 1 - t
		local p = mesh.vertices[low]:Lerp(mesh.vertices[high], u)
		assert(
			p ~= mesh.vertices[v] and p ~= mesh.vertices[other],
			"Bevel width collapses at native precision"
		)
		cache[key] = cache[key] or {}
		local i = assert(table.find(mesh.faces[fid].vertices, v))
		local j = assert(table.find(mesh.faces[fid].vertices, other))
		local cr = { { fid, i, 1 - t }, { fid, j, t } }
		for _, cut in cache[key] do
			if math.abs(cut.t - u) <= 1e-12 or edit.out.vertices[cut.id] == p then
				assert(owner[cut.id] == v, "Bevel endpoint cuts collide")
				return cut.id, cr
			end
		end
		local id =
			vertex(p, { { low, 1 - u }, { high, u } }, cr, v, (mesh.vertices[other] - mesh.vertices[v]) * t)
		table.insert(cache[key], { t = u, id = id })
		edgeCuts[key] = cache[key]
		return id, cr
	end
	local function curve(v, a, b, axis, ar, br)
		local o = mesh.vertices[v]
		local pa, pb = edit.out.vertices[a], edit.out.vertices[b]
		local da, db = offsets[a] or (pa - o), offsets[b] or (pb - o)
		local za, zb = da:Dot(axis), db:Dot(axis)
		local ra, rb = da - axis * za, db - axis * zb
		local lengthA, lengthB = ra.Magnitude, rb.Magnitude
		assert(lengthA > 0 and lengthB > 0, "Degenerate bevel profile rails")
		local ua, ub = ra / lengthA, rb / lengthB
		local cosine = math.clamp(ua:Dot(ub), -1, 1)
		local center, radius, sphere
		if profile == "round" and cosine > -1 + 1e-7 and cosine < 1 - 1e-7 then
			-- Equal offsets admit a circle tangent to both incident face directions.
			local determinant = 1 - cosine * cosine
			center = ua * ((lengthA - cosine * lengthB) / determinant)
				+ ub * ((lengthB - cosine * lengthA) / determinant)
			local r1, r2 = (ra - center).Magnitude, (rb - center).Magnitude
			if math.abs(r1 - r2) <= math.max(r1, r2) * 1e-5 then
				radius = (r1 + r2) / 2
				if math.abs(za - zb) <= width * 1e-5 then
					sphere = { offset = center + axis * ((za + zb) / 2), radius = radius }
				end
			else
				center = nil
			end
		end
		local ids, crs = { a }, { ar }
		if cosine <= -1 + 1e-7 then
			edit.report.flatProfiles += 1
		elseif profile == "round" and not center then
			edit.report.affineRoundProfiles += 1
		end
		for step = 1, segments - 1 do
			local t = step / segments
			local delta
			if profile == "linear" or cosine <= -1 + 1e-7 then
				delta = da:Lerp(db, t)
			elseif center then
				local va, vb = (ra - center).Unit, (rb - center).Unit
				local angle = math.acos(math.clamp(va:Dot(vb), -1, 1))
				local direction = angle > 1e-7
						and (va * (math.sin((1 - t) * angle) / math.sin(angle)) + vb * (math.sin(t * angle) / math.sin(
							angle
						)))
					or va
				delta = center + direction * radius + axis * (za * (1 - t) + zb * t)
			else
				local coefficient
				if type(profile) == "table" then
					local pos = t * (#profile - 1)
					local i = math.min(math.floor(pos) + 1, #profile - 1)
					coefficient = profile[i]:Lerp(profile[i + 1], pos - (i - 1))
				else
					coefficient = Vector2.new(1 - math.sin(t * math.pi / 2), 1 - math.cos(t * math.pi / 2))
				end
				delta = ra * coefficient.X + rb * coefficient.Y + axis * (za * (1 - t) + zb * t)
			end
			local vr = mix(refs[a] or { { a, 1 } }, refs[b] or { { b, 1 } }, t)
			local cr = mixCorners(ar, br, t)
			table.insert(ids, vertex(o + delta, vr, cr, v, delta))
			table.insert(crs, cr)
			visit()
		end
		table.insert(ids, b)
		table.insert(crs, br)
		return ids, crs, sphere
	end
	local function prune()
		edit.out:removeUnused()
		for domain, map in edit.maps do
			local keys = A.keys(edit.out, domain)
			for key in map do
				if not keys[key] then
					map[key] = nil
				end
			end
		end
	end
	return {
		edit = edit,
		index = index,
		owner = owner,
		offsets = offsets,
		refs = refs,
		cornerRefs = cornerRefs,
		edgeCuts = edgeCuts,
		face = face,
		interpolate = interpolate,
		vertex = vertex,
		edgePoint = edgePoint,
		curve = curve,
		visit = visit,
		prune = prune,
		segments = segments,
		join = join,
		width = width,
		options = options,
		work = function()
			return work
		end,
	}
end
return { prepare = prepare, mix = mix, mixCorners = mixCorners, project = project }
