-- Private immutable input and disjoint normalized-domain preparation.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local D = require(script.Parent.Planar)
local T = {}
function T.controls(surface, options)
	assert(
		type(surface) == "table" and type(surface.control) == "table",
		"Rational surface control grid required"
	)
	local maximum = U.integer(options.maxControls or 10000, 4)
	local count = 0
	for _, row in surface.control do
		assert(type(row) == "table", "Surface control row required")
		count += #row
		assert(count <= maximum, "Trim surface control budget exceeded")
	end
end
local function array(t, message)
	assert(type(t) == "table", message)
	local n = 0
	for k in t do
		n += 1
		assert(type(k) == "number" and k % 1 == 0 and k >= 1 and k <= #t, message)
	end
	assert(n == #t, message)
	return #t
end
function T.snapshot(trimmed, options)
	assert(
		type(trimmed) == "table" and (trimmed.kind == "trimmedSurface" or trimmed.kind == "trimmedSurfaceSet"),
		"Trimmed surface required"
	)
	options = table.clone(options or {})
	T.controls(trimmed.surface, options)
	for _, key in { "closedU", "closedV" } do
		if options[key] == nil and trimmed.kind == "trimmedSurfaceSet" then
			options[key] = trimmed[key]
		end
		assert(
			options[key] == nil or type(options[key]) == "boolean",
			"Closed trim directions must be boolean"
		)
	end
	local source = trimmed.kind == "trimmedSurfaceSet" and trimmed.regions
		or { { outer = trimmed.outer, holes = trimmed.holes } }
	local maximum = U.integer(options.maxTrimVertices or 2000, 3)
	assert(
		array(source, "Trim regions must be a dense array") <= U.integer(options.maxRegions or 256, 1),
		"Trim region budget exceeded"
	)
	local regions, count = {}, 0
	for i, r in source do
		assert(type(r) == "table", "Trim region must be a table")
		local rings = { r.outer }
		array(r.holes or {}, "Trim holes must be a dense array")
		for _, ring in r.holes or {} do
			table.insert(rings, ring)
		end
		local copied = {}
		for j, ring in rings do
			local n = array(ring, "Trim loop must be a dense array")
			count += n
			assert(count <= maximum, "Trim input vertex budget exceeded")
			copied[j] = table.clone(ring)
			for _, p in copied[j] do
				assert(
					typeof(p) == "Vector2"
						and U.finite(p.X)
						and U.finite(p.Y)
						and p.X >= 0
						and p.X <= 1
						and p.Y >= 0
						and p.Y <= 1,
					"Trim coordinates must lie in the normalized unit domain"
				)
			end
		end
		regions[i] = { outer = copied[1], holes = {} }
		for j = 2, #copied do
			table.insert(regions[i].holes, copied[j])
		end
	end
	return {
		kind = trimmed.kind,
		surface = U.copy(trimmed.surface),
		regions = regions,
		closedU = trimmed.closedU,
		closedV = trimmed.closedV,
	},
		options
end
function T.classify(regions, uv)
	for _, region in regions do
		local where = P.pointInPolygon2D(uv, region.outer)
		if where == "boundary" then
			return where
		end
		if where == "inside" then
			local included = true
			for _, hole in region.holes do
				local inner = P.pointInPolygon2D(uv, hole)
				if inner == "boundary" then
					return inner
				end
				if inner == "inside" then
					included = false
					break
				end
			end
			if included then
				return "inside"
			end
		end
	end
	return "outside"
end
function T.prepare(regions, options, visit)
	local data = {
		points = {},
		triangles = {},
		boundaryLoops = {},
		area = 0,
		orientations = {},
		regions = {},
		loops = {},
	}
	for _, region in regions do
		local part = D.triangulate(region.outer, region.holes, {
			maxVertices = options.maxTrimVertices or 2000,
			maxWork = options.maxWork or 5000000,
			_visit = visit,
		})
		local offset = #data.points
		for _, p in part.points do
			visit()
			table.insert(data.points, p)
		end
		for _, tri in part.triangles do
			visit()
			table.insert(data.triangles, { tri[1] + offset, tri[2] + offset, tri[3] + offset })
		end
		local canonical = { holes = {} }
		for k, ring in part.boundaryLoops do
			local ids, loop = {}, {}
			for _, id in ring do
				visit()
				table.insert(ids, id + offset)
				table.insert(loop, part.points[id])
			end
			table.insert(data.boundaryLoops, ids)
			table.insert(data.loops, loop)
			table.insert(data.orientations, k == 1 and 1 or -1)
			if k == 1 then
				canonical.outer = loop
			else
				table.insert(canonical.holes, loop)
			end
		end
		data.area += part.area
		table.insert(data.regions, canonical)
	end
	if #regions > 1 then
		local hits = D.intersections(data.loops, {
			maxVertices = options.maxTrimVertices or 2000,
			maxWork = options.maxWork or 5000000,
			maxIntersections = 1,
			_visit = visit,
		})
		assert(#hits == 0, "Trim set boundaries intersect or touch; rebuild with SurfaceTrim.regions")
		for i, a in data.regions do
			for j, b in data.regions do
				if i ~= j then
					for _, p in b.outer do
						visit()
					end
					for _, hole in b.holes do
						for _, p in hole do
							visit()
						end
					end
					assert(
						T.classify({ b }, a.outer[1]) == "outside",
						"Trim set regions overlap; rebuild with SurfaceTrim.regions"
					)
				end
			end
		end
	end
	return data
end
return T
