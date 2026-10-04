-- Private whole-patch bound on the common dyadic triangulation.
local X = require(script.Parent.ExpansionArithmetic)
local I = require(script.Parent.DirectedInterval)
local U = require(script.Parent.Util)
local B = {}
local samples = {}
for _, x in { 0, 2, 4 } do
	for _, y in { 0, 2, 4 } do
		table.insert(samples, { x, y })
	end
end
for _, p in { { 1, 1 }, { 3, 1 }, { 3, 3 }, { 1, 3 } } do
	table.insert(samples, p)
end
local function determinant(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end
local function weights(triangle, point)
	local a, b, c = triangle.uv[1], triangle.uv[2], triangle.uv[3]
	local denominator = determinant(a, b, c)
	assert(denominator == 4 or denominator == 16, "Unrecognized dyadic patch triangle")
	local x, y, z = determinant(b, c, point), determinant(c, a, point), determinant(a, b, point)
	if x < 0 or y < 0 or z < 0 then
		return nil
	end
	return { x / denominator, y / denominator, z / denominator }
end
function B.overlaps(source, target)
	-- Each coarse triangle is one half of the unit square. All source UV
	-- vertices lie in that square; a strict diagonal-side witness therefore
	-- proves a positive-area overlap, with exact small-integer arithmetic.
	for i, a in target.uv do
		local b = target.uv[i % 3 + 1]
		if math.abs(b[1] - a[1]) == 4 and math.abs(b[2] - a[2]) == 4 then
			for _, p in source.uv do
				if determinant(a, b, p) > 0 then
					return true
				end
			end
			return false
		end
	end
	error("Coarse triangle has no quad diagonal")
end
local function value(mesh, triangles, p, work)
	for _, triangle in triangles do
		work(1)
		local w = weights(triangle, p)
		if w then
			local result = { { 0 }, { 0 }, { 0 } }
			for i, id in triangle.ids do
				local v = mesh.vertices[id]
				for axis, coordinate in { v.X, v.Y, v.Z } do
					work(1)
					result[axis] = X.add(result[axis], X.multiply({ coordinate }, { w[i] }))
				end
			end
			return result
		end
	end
	error("Dyadic patch triangulation did not cover a sample")
end
local function differenceLength(a, b)
	local squared = { 0, 0 }
	for axis = 1, 3 do
		local e = X.subtract(a[axis], b[axis])
		if X.sign(e) ~= 0 then
			local component = { 0, 0 }
			for _, x in e do
				component = I.add(component, { x, x })
			end
			squared = I.add(squared, I.square(component))
		end
	end
	if squared[2] == 0 then
		return 0
	end
	return I.sqrt(squared)[2]
end
function B.patch(mesh, group, phase, sourceTriangles, targetTriangles, work)
	local uv = {}
	local corners = { { 0, 0 }, { 4, 0 }, { 4, 4 }, { 0, 4 } }
	for i, id in group.loop do
		uv[id] = corners[i]
	end
	uv[group.center] = { 2, 2 }
	for i, a in group.loop do
		local b = group.loop[i % 4 + 1]
		local e = assert(phase.coarseEdges[U.edge(a, b)])
		uv[e] = { (uv[a][1] + uv[b][1]) / 2, (uv[a][2] + uv[b][2]) / 2 }
	end
	local source, target = {}, {}
	for _, fid in group.faces do
		local face = mesh.faces[fid]
		assert(#sourceTriangles[fid] == 2, "Quad source must have two triangles")
		for _, triangle in sourceTriangles[fid] do
			local entry = { ids = {}, uv = {} }
			for i, corner in triangle do
				local id = face.vertices[corner]
				entry.ids[i], entry.uv[i] = id, assert(uv[id])
			end
			assert(
				determinant(entry.uv[1], entry.uv[2], entry.uv[3]) == 4,
				"Source quad chart changed orientation"
			)
			table.insert(source, entry)
		end
	end
	assert(#targetTriangles == 2, "Quad target must have two triangles")
	for _, triangle in targetTriangles do
		local entry = { ids = {}, uv = {} }
		for i, corner in triangle do
			local id = group.loop[corner]
			entry.ids[i], entry.uv[i] = id, uv[id]
		end
		assert(
			determinant(entry.uv[1], entry.uv[2], entry.uv[3]) == 16,
			"Target quad chart changed orientation"
		)
		table.insert(target, entry)
	end
	local maximum = 0
	for _, sample in samples do
		local a, b = value(mesh, source, sample, work), value(mesh, target, sample, work)
		maximum = math.max(maximum, differenceLength(a, b))
	end
	return maximum, { source = source, target = target }
end
return B
