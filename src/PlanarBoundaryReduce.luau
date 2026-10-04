-- Private conforming simplification of degree-two region boundary chains.
local U = require(script.Parent.Util)
local P = require(script.Parent.Predicates)
local A = require(script.Parent.AttributeCore)
local G = require(script.Parent.PlanarReduceGeometry)
local function reversed(list)
	local out = {}
	for i = #list, 1, -1 do
		table.insert(out, list[i])
	end
	return out
end
local function collinear(a, b, p)
	return P.orient2D(Vector2.new(a.X, a.Y), Vector2.new(b.X, b.Y), Vector2.new(p.X, p.Y)) == 0
		and P.orient2D(Vector2.new(a.Y, a.Z), Vector2.new(b.Y, b.Z), Vector2.new(p.Y, p.Z)) == 0
		and P.orient2D(Vector2.new(a.Z, a.X), Vector2.new(b.Z, b.X), Vector2.new(p.Z, p.X)) == 0
end
return function(mesh, regions, normals, triangles, options, work, checkpoint)
	local paths = {}
	local removed, maximum = 0, 0
	local function build()
		local edges, neighbors, incident = {}, {}, {}
		for fid, region in regions do
			for i, a in region.loop do
				work(1)
				local b = region.loop[i % #region.loop + 1]
				local key = U.edge(a, b)
				edges[key] = true
				paths[key] = paths[key] or { math.min(a, b), math.max(a, b) }
				neighbors[a], neighbors[b] = neighbors[a] or {}, neighbors[b] or {}
				neighbors[a][b], neighbors[b][a] = true, true
				incident[a] = incident[a] or {}
				incident[a][fid] = i
			end
		end
		return edges, neighbors, incident
	end
	local function pathError(path)
		local a, b = mesh.vertices[path[1]], mesh.vertices[path[#path]]
		local dx, dy, dz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
		local length2 = dx * dx + dy * dy + dz * dz
		if length2 == 0 then
			return nil
		end
		local maximumError, exact = 0, true
		for _, id in path do
			work(8)
			local p = mesh.vertices[id]
			local x, y, z = p.X - a.X, p.Y - a.Y, p.Z - a.Z
			local t = (x * dx + y * dy + z * dz) / length2
			if t < 0 or t > 1 then
				return nil
			end
			local isCollinear = collinear(a, b, p)
			exact = exact and isCollinear
			local distance = isCollinear and 0
				or math.sqrt((x - t * dx) ^ 2 + (y - t * dy) ^ 2 + (z - t * dz) ^ 2)
			maximumError = math.max(maximumError, distance)
		end
		if options.angleLimit == 0 and not exact then
			return nil
		end
		if maximumError > options.maxBoundaryDeviation then
			return nil
		end
		return maximumError
	end
	local function compatible(path)
		if options.preserveSeams == false then
			return true
		end
		for _, channel in mesh.attributes do
			if channel.domain == "edge" then
				local first = A.read(channel, U.edge(path[1], path[2]))
				for i = 2, #path - 1 do
					work(1)
					if first ~= A.read(channel, U.edge(path[i], path[i + 1])) then
						return false
					end
				end
			end
		end
		return true
	end
	while true do
		local edges, neighbors, incident = build()
		local accepted
		for _, v in U.keys(neighbors) do
			work(1)
			local adjacent = U.keys(neighbors[v])
			if #adjacent ~= 2 then
				continue
			end
			local a, b = adjacent[1], adjacent[2]
			local key = U.edge(a, b)
			if edges[key] then
				continue
			end
			local change, valid = {}, true
			for fid, i in incident[v] do
				local region = regions[fid]
				if not region.selected or #region.loop <= 3 then
					valid = false
					break
				end
				local out = {
					loop = table.clone(region.loop),
					corners = table.clone(region.corners),
					faces = region.faces,
					selected = true,
				}
				table.remove(out.loop, i)
				table.remove(out.corners, i)
				if
					not G.accept(
						mesh,
						out,
						normals,
						options.angleLimit,
						options.maxPlaneDeviation,
						options.maxFaceVertices,
						work,
						triangles
					)
				then
					valid = false
					break
				end
				change[fid] = out
			end
			if not valid then
				continue
			end
			local first, second = paths[U.edge(a, v)], paths[U.edge(v, b)]
			first = first[1] == a and table.clone(first) or reversed(first)
			second = second[#second] == b and second or reversed(second)
			for i = 2, #second do
				table.insert(first, second[i])
			end
			local errorValue = pathError(first)
			if errorValue == nil or not compatible(first) then
				continue
			end
			-- The original chain stays within the angle cone of its final chord.
			local pa, pb = mesh.vertices[a], mesh.vertices[b]
			local dx, dy, dz = pb.X - pa.X, pb.Y - pa.Y, pb.Z - pa.Z
			local length = math.sqrt(dx * dx + dy * dy + dz * dz)
			for i = 1, #first - 1 do
				work(1)
				local p, q = mesh.vertices[first[i]], mesh.vertices[first[i + 1]]
				local x, y, z = q.X - p.X, q.Y - p.Y, q.Z - p.Z
				local segment = math.sqrt(x * x + y * y + z * z)
				local angle = collinear(pa, pb, q) and collinear(pa, pb, p) and 0
					or math.acos(math.clamp((x * dx + y * dy + z * dz) / (segment * length), -1, 1))
				if angle > options.angleLimit then
					valid = false
					break
				end
			end
			if valid then
				accepted = { key = key, path = first, changes = change, error = errorValue }
				break
			end
		end
		if not accepted then
			return { complete = true, removed = removed, maximumDeviation = maximum, paths = paths }
		end
		if removed == options.maxBoundaryRemovals then
			return { complete = false, removed = removed, maximumDeviation = maximum, paths = paths }
		end
		for fid, region in accepted.changes do
			regions[fid] = region
		end
		paths[accepted.key] = accepted.path
		maximum = math.max(maximum, accepted.error)
		removed += 1
		checkpoint("boundary")
	end
end
