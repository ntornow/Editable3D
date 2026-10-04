-- Private geometry/data acceptance for a recognized whole-component phase.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Seams = require(script.Parent.AttributeSeams)
local G = require(script.Parent.PlanarReduceGeometry)
local Bound = require(script.Parent.UnsubdivideBound)
local Mesh = require(script.Parent.Mesh)
local P = {}
function P.accept(mesh, top, phase, triangles, options, work)
	for id, value in options.keepVertices or {} do
		work(1)
		if value and phase.roles[id] and phase.roles[id] ~= 1 then
			return nil, "keepVertex"
		end
	end
	if options.preserveSeams ~= false then
		local vertexSharpness = mesh.attributes.subdivision_vertex_sharpness
		if vertexSharpness then
			for id, role in phase.roles do
				work(1)
				if role ~= 1 and A.read(vertexSharpness, id) > 0 then
					return nil, "feature"
				end
			end
		end
		local names = { sharp_edge = true, uv_seam = true, subdivision_edge_sharpness = true }
		for _, name in options.seamAttributes or {} do
			names[name] = true
		end
		for _, center in phase.centers do
			for e in top.neighbors[center] do
				local key = U.edge(center, e)
				for name in names do
					work(1)
					local channel = mesh.attributes[name]
					if channel then
						local value = A.read(channel, key)
						if value == true or type(value) == "number" and value > 0 then
							return nil, "feature"
						end
					end
				end
				local edge = top.edges[key]
				assert(#edge.faces == 2, "Face center reached a boundary")
				local a, b = edge.faces[1], edge.faces[2]
				for _, v in { center, e } do
					work(1)
					if
						not Seams.same(
							mesh,
							a,
							table.find(mesh.faces[a].vertices, v),
							b,
							table.find(mesh.faces[b].vertices, v),
							options
						)
					then
						return nil, "seam"
					end
				end
			end
		end
		for e, ends in phase.edgeEnds do
			for _, channel in mesh.attributes do
				if channel.domain == "edge" then
					work(1)
					if A.read(channel, U.edge(ends[1], e)) ~= A.read(channel, U.edge(e, ends[2])) then
						return nil, "edgeData"
					end
				end
			end
		end
	end
	local maximum, minimumDot = 0, 1
	local groups = {}
	for _, group in phase.groups do
		local plane = G.plane(mesh, group.loop, work)
		if not plane or not G.polygon(mesh, group.loop, plane, work) then
			return nil, "coarsePolygon"
		end
		local target = Mesh.new()
		target.vertices = mesh.vertices
		local fid = target:addFace(group.loop)
		local coarseTriangles = target:faceTriangles(
			fid,
			{ validateSimple = true, maxVertices = 4, maxWork = 1000, _visit = work }
		)
		local bound, chart = Bound.patch(mesh, group, phase, triangles, coarseTriangles, work)
		maximum = math.max(maximum, bound)
		if maximum > options.maxDeviation then
			return nil, "deviation", maximum
		end
		-- Compare exactly the source/target pairs with positive UV overlap.
		for _, a in chart.source do
			local na = G.plane(mesh, a.ids, work)
			if not na then
				return nil, "degenerate"
			end
			for _, b in chart.target do
				if not Bound.overlaps(a, b) then
					continue
				end
				local nb = G.plane(mesh, b.ids, work)
				if not nb then
					return nil, "degenerate"
				end
				local dot = math.clamp(na.x * nb.x + na.y * nb.y + na.z * nb.z, -1, 1)
				minimumDot = math.min(minimumDot, dot)
				if dot < options.minimumNormalDot then
					return nil, "normal"
				end
			end
		end
		table.insert(groups, { group = group, errorBound = bound, plane = plane })
	end
	return { phase = phase, groups = groups, errorBound = maximum, minimumNormalDot = minimumDot }
end
return P
