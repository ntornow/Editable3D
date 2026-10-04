-- A surjective simplicial correspondence bounds both directions of surface distance.
-- Every original triangle maps affinely onto a surviving triangle, edge or vertex.
-- Its displacement is a convex combination of its three vertex displacements.
local U = require(script.Parent.Util)
local X = require(script.Parent.ExpansionArithmetic)
local I = require(script.Parent.DirectedInterval)
local B = {}
function B.distance(a, b)
	local squared = { 0, 0 }
	for _, pair in { { a.X, b.X }, { a.Y, b.Y }, { a.Z, b.Z } } do
		local difference = X.subtract({ pair[1] }, { pair[2] })
		if X.sign(difference) ~= 0 then
			local component = { 0, 0 }
			for _, value in difference do
				component = I.add(component, { value, value })
			end
			squared = I.add(squared, I.square(component))
		end
	end
	return squared[2] == 0 and 0 or I.sqrt(squared)[2]
end
function B.check(source, target, representatives, visit)
	local topology = target:topology()
	local covered, used = {}, {}
	for fid, face in source.faces do
		visit(1)
		local ids, seen = {}, {}
		for _, original in face.vertices do
			used[original] = true
			local id = representatives[original]
			if not id or not target.vertices[id] then
				return nil, "missingRepresentative"
			end
			if not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
		if #ids == 3 then
			local image = target.faces[fid]
			if not image or #image.vertices ~= 3 then
				return nil, "missingTriangleImage"
			end
			for i, original in face.vertices do
				if image.vertices[i] ~= representatives[original] then
					return nil, "changedTriangleImage"
				end
			end
			covered[fid] = true
		elseif #ids == 2 then
			if not topology.edges[U.edge(ids[1], ids[2])] then
				return nil, "missingEdgeImage"
			end
		elseif #ids == 1 then
			if #topology.vertexFaces[ids[1]] == 0 then
				return nil, "missingSurfaceVertexImage"
			end
		else
			return nil, "emptyTriangleImage"
		end
	end
	for fid in target.faces do
		visit(1)
		if not covered[fid] then
			return nil, "uncoveredOutputTriangle"
		end
	end
	local maximum = 0
	for id in used do
		visit(1)
		maximum = math.max(maximum, B.distance(source.vertices[id], target.vertices[representatives[id]]))
	end
	return maximum
end
return B
