-- Private final conformity of selected boundary chains after coplanar ownership.
local U = require(script.Parent.Util)
return function(data, selection, options)
	options = options or {}
	local edges, boundaryNodes = {}, {}
	for fi, fragment in data.fragments do
		if not selection[fi] then
			continue
		end
		for i, a in fragment.records do
			local b = fragment.records[i % 3 + 1]
			local key = U.edge(a.node, b.node)
			edges[key] = edges[key] or { a = a.node, b = b.node, faces = {} }
			table.insert(edges[key].faces, fi)
		end
	end
	for _, edge in edges do
		if #edge.faces == 1 then
			boundaryNodes[edge.a], boundaryNodes[edge.b] = true, true
		end
	end
	local groups = {}
	local report = { edgeSplits = 0, addedFragments = 0, maxDisplacement = 0 }
	local tolerance = data.report.tolerance
	for _, key in U.keys(edges) do
		local edge = edges[key]
		if #edge.faces ~= 1 then
			continue
		end
		local a, b = data.nodes[edge.a].position, data.nodes[edge.b].position
		local x, y, z = b.X - a.X, b.Y - a.Y, b.Z - a.Z
		local denominator = x * x + y * y + z * z
		local cuts = {}
		for _, id in U.keys(boundaryNodes) do
			data.visit("conform")
			if id == edge.a or id == edge.b then
				continue
			end
			local p = data.nodes[id].position
			local t = ((p.X - a.X) * x + (p.Y - a.Y) * y + (p.Z - a.Z) * z) / denominator
			if t <= 0 or t >= 1 then
				continue
			end
			local dx, dy, dz = p.X - (a.X + t * x), p.Y - (a.Y + t * y), p.Z - (a.Z + t * z)
			local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			if distance > tolerance then
				continue
			end
			table.insert(cuts, { node = id, t = t })
			report.maxDisplacement = math.max(report.maxDisplacement, distance)
		end
		if #cuts == 0 then
			continue
		end
		table.sort(cuts, function(aCut, bCut)
			return aCut.t < bCut.t
		end)
		local fi = edge.faces[1]
		groups[fi] = groups[fi] or {}
		table.insert(groups[fi], { edge = edge, cuts = cuts })
	end
	local maxFaces = U.integer(options.maxFaces or 200000, 1)
	for _, fi in U.keys(groups) do
		local original = data.fragments[fi]
		local context = data.triangles[original.triangle]
		local children = { original.records }
		for _, group in groups[fi] do
			local first, last = group.edge.a, group.edge.b
			for _, cut in group.cuts do
				local found = false
				for ti, rs in children do
					for i, r in rs do
						local j, k = i % 3 + 1, (i + 1) % 3 + 1
						if r.node ~= first or rs[j].node ~= last then
							continue
						end
						local nextRecord = context.records[cut.node]
						if not nextRecord then
							local p, q, s =
								data.nodes[first].position,
								data.nodes[last].position,
								data.nodes[cut.node].position
							local delta = q - p
							local t = math.clamp((s - p):Dot(delta) / delta:Dot(delta), 0, 1)
							local w, sourceEdges = {}, {}
							for wi = 1, 3 do
								w[wi] = r.weights[wi] * (1 - t) + rs[j].weights[wi] * t
							end
							for e in r.sourceEdges do
								if rs[j].sourceEdges[e] then
									sourceEdges[e] = true
								end
							end
							nextRecord = {
								node = cut.node,
								weights = w,
								sourceEdges = sourceEdges,
								binding = "t:" .. context.index .. ":" .. cut.node,
							}
							context.records[cut.node] = nextRecord
						end
						local left, right = { r, nextRecord, rs[k] }, { nextRecord, rs[j], rs[k] }
						for _, tri in { left, right } do
							local aPos, bPos, cPos =
								data.nodes[tri[1].node].position,
								data.nodes[tri[2].node].position,
								data.nodes[tri[3].node].position
							assert(
								(bPos - aPos):Cross(cPos - aPos):Dot(context.normal) > 0,
								"Boundary conformity collapses or reverses a fragment"
							)
						end
						children[ti] = left
						table.insert(children, right)
						report.edgeSplits += 1
						found = true
						break
					end
					if found then
						break
					end
				end
				assert(found, "Selected boundary edge lost during conformity")
				first = cut.node
			end
		end
		for i, records in children do
			local fragment = { triangle = original.triangle, face = original.face, records = records }
			if i == 1 then
				data.fragments[fi] = fragment
			else
				assert(#data.fragments < maxFaces, "Boundary conformity face budget exceeded")
				table.insert(data.fragments, fragment)
				selection[#data.fragments] = selection[fi]
				report.addedFragments += 1
			end
		end
	end
	return report
end
