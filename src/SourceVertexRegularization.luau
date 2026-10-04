-- Private, explicit source-position regularization before winding classification.
local U = require(script.Parent.Util)
local X = require(script.Parent.ExpansionArithmetic)
local I = require(script.Parent.DirectedInterval)
local axes = { "X", "Y", "Z" }
local function difference(a, b)
	local r = {}
	for i, axis in axes do
		r[i] = X.difference(a[axis], b[axis])
	end
	return r
end
local function dot(a, b)
	local r = { 0 }
	for i = 1, 3 do
		r = X.add(r, X.multiply(a[i], b[i]))
	end
	return r
end
local function cross(a, b)
	local r = {}
	for i = 1, 3 do
		local j, k = i % 3 + 1, (i + 1) % 3 + 1
		r[i] = X.subtract(X.multiply(a[j], b[k]), X.multiply(a[k], b[j]))
	end
	return r
end
local function squared(a, b)
	local d = difference(a, b)
	return dot(d, d)
end
local function upper(e)
	if X.sign(e) == 0 then
		return 0
	end
	local r = { 0, 0 }
	for _, v in e do
		r = I.add(r, { v, v })
	end
	return I.sqrt({ math.max(0, r[1]), r[2] })[2]
end
return function(mesh, options, visit)
	local config = options.regularization
	assert(type(config) == "table", "Source regularization must be a table")
	assert(config.method == nil or config.method == "vertexClusters", "Unknown source regularization method")
	assert(
		config.edgePairs == nil or config.edgePairs == false,
		"Edge-pair regularization requires method features"
	)
	local radius = config.distance
	assert(
		type(radius) == "number" and U.finite(radius) and radius >= 2 ^ -126 and radius <= 2 ^ 130,
		"Source regularization distance must be between 2^-126 and 2^130"
	)
	if options.checkpoint then
		options.checkpoint({ stage = "regularize", progress = 0 })
	end
	assert(not options.cancelled or not options.cancelled(), "Source regularization cancelled")
	local radiusSquared = X.multiply({ radius }, { radius })
	local used, triangles = {}, {}
	for _, fid in U.keys(mesh.faces) do
		visit("regularize")
		local face = mesh.faces[fid]
		triangles[fid] = mesh:faceTriangles(fid, {
			validateSimple = true,
			maxVertices = options.maxFaceVertices or 2000,
			maxWork = options.maxFaceWork or options.maxWork or 5000000,
		})
		for _, id in face.vertices do
			visit("regularize")
			used[id] = true
		end
	end
	local ids = U.keys(used)
	assert(#ids <= (options.maxVertices or 100000), "Source regularization vertex budget exceeded")
	local function build(list)
		if #list == 0 then
			return nil
		end
		local lo, hi = mesh.vertices[list[1]], mesh.vertices[list[1]]
		for _, id in list do
			visit("regularize")
			local p = mesh.vertices[id]
			lo, hi = lo:Min(p), hi:Max(p)
		end
		local node = { lo = lo, hi = hi }
		if #list <= 8 then
			node.ids = list
			return node
		end
		local axis = "X"
		for _, key in { "Y", "Z" } do
			if hi[key] - lo[key] > hi[axis] - lo[axis] then
				axis = key
			end
		end
		table.sort(list, function(a, b)
			visit("regularize")
			local x, y = mesh.vertices[a][axis], mesh.vertices[b][axis]
			return x < y or x == y and a < b
		end)
		local left, right = {}, {}
		for i, id in list do
			table.insert(i <= math.floor(#list / 2) and left or right, id)
		end
		node.left, node.right = build(left), build(right)
		return node
	end
	local root = build(table.clone(ids))
	local out, representatives = mesh:clone(), {}
	local moved, clusters, maximum = 0, 0, { 0 }
	for _, id in ids do
		visit("regularize")
		local p, selected, best = mesh.vertices[id], nil, radiusSquared
		local function query(node)
			if not node then
				return
			end
			visit("regularize")
			local lower = { 0 }
			for _, axis in axes do
				local q = math.clamp(p[axis], node.lo[axis], node.hi[axis])
				local d = X.difference(p[axis], q)
				lower = X.add(lower, X.multiply(d, d))
			end
			if X.sign(X.subtract(lower, best)) > 0 then
				return
			end
			if node.ids then
				for _, candidate in node.ids do
					visit("regularize")
					if candidate >= id or representatives[candidate] ~= candidate then
						continue
					end
					local distance = squared(p, mesh.vertices[candidate])
					local sign = X.sign(X.subtract(distance, best))
					if sign < 0 or sign == 0 and (not selected or candidate < selected) then
						selected, best = candidate, distance
					end
				end
			else
				query(node.left)
				query(node.right)
			end
		end
		query(root)
		representatives[id] = selected or id
		if selected then
			out.vertices[id] = mesh.vertices[selected]
			if X.sign(best) > 0 then
				moved += 1
			end
			if X.sign(X.subtract(best, maximum)) > 0 then
				maximum = best
			end
		else
			clusters += 1
		end
	end
	local checked = 0
	for _, fid in U.keys(mesh.faces) do
		local face = mesh.faces[fid]
		for _, tri in triangles[fid] do
			visit("regularize")
			local a, b, c = face.vertices[tri[1]], face.vertices[tri[2]], face.vertices[tri[3]]
			local e0, f0 =
				difference(mesh.vertices[b], mesh.vertices[a]), difference(mesh.vertices[c], mesh.vertices[a])
			local e1, f1 =
				difference(out.vertices[b], out.vertices[a]), difference(out.vertices[c], out.vertices[a])
			-- The normal along linear vertex motion is a quadratic Bezier curve.
			-- Positive projection coefficients prove orientation for every time,
			-- including between the original and regularized endpoint meshes.
			local normal = cross(e0, f0)
			local first, last = dot(normal, normal), dot(normal, cross(e1, f1))
			local middle = X.add(dot(normal, cross(e0, f1)), dot(normal, cross(e1, f0)))
			assert(
				X.sign(first) > 0 and X.sign(middle) > 0 and X.sign(last) > 0,
				"Source regularization collapses or reverses a source triangle"
			)
			checked += 1
		end
		local actual = out:faceTriangles(fid, {
			validateSimple = true,
			maxVertices = options.maxFaceVertices or 2000,
			maxWork = options.maxFaceWork or options.maxWork or 5000000,
		})
		assert(#actual == #triangles[fid], "Source regularization changes face triangulation")
		for i, tri in actual do
			visit("regularize")
			for j = 1, 3 do
				assert(
					tri[j] == triangles[fid][i][j],
					"Source regularization changes face triangulation; triangulate the input first"
				)
			end
		end
	end
	local validation = out:validate()
	assert(validation.valid, "Source regularization produces invalid source topology")
	-- Matching barycentric points give the same bound across every triangle,
	-- in both directions. Exact membership also supplies the radius bound.
	local displacement = math.min(radius, upper(maximum))
	return out,
		{
			method = "vertexClusters",
			distance = radius,
			representatives = representatives,
			usedVertices = #ids,
			clusters = clusters,
			movedVertices = moved,
			triangles = checked,
			maxDisplacement = displacement,
			displacementCertified = true,
			sourceSurfaceHausdorffBound = displacement,
			sourceSurfaceBoundCertified = true,
			triangleHomotopyOrientationCertified = true,
			globalIsotopyCertified = false,
			originalSolidEqualityCertified = false,
		}
end
