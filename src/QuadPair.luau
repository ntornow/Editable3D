-- Deterministic shape-ranked pairing, delimited by source data and crease edges.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Seams = require(script.Parent.AttributeSeams)
local G = require(script.Parent.PlanarReduceGeometry)
local Q = require(script.Parent.QuadGeometry)
local Bound = require(script.Parent.QuadPatchBound)
local Corner = require(script.Parent.MeshEditCore).corner
local Mesh = require(script.Parent.Mesh)
local R = {}
function R.protected(mesh, edge, options, visit)
	visit(1)
	if #edge.faces ~= 2 then
		return true, "boundary"
	end
	for name, channel in mesh.attributes do
		visit(1)
		if channel.domain == "edge" then
			local value = A.read(channel, U.edge(edge.a, edge.b))
			if
				value ~= channel.default
				or options._featureChannels[name]
					and (value == true or type(value) == "number" and value > 0)
			then
				return true, "edgeData"
			end
		end
	end
	local a, b = edge.faces[1], edge.faces[2]
	for _, id in { edge.a, edge.b } do
		local ai, bi = table.find(mesh.faces[a].vertices, id), table.find(mesh.faces[b].vertices, id)
		if not Seams.same(mesh, a, ai, b, bi, options) then
			return true, "seam"
		end
	end
	local na, nb = G.plane(mesh, mesh.faces[a].vertices, visit), G.plane(mesh, mesh.faces[b].vertices, visit)
	if
		not na
		or not nb
		or na.x * nb.x + na.y * nb.y + na.z * nb.z < math.cos(options.featureAngle) - 2 ^ -45
	then
		return true, "featureAngle"
	end
	return false
end
function R.pair(source, context)
	local visit, options = context.visit, context.options
	visit(U.count(source.vertices) + 3 * U.count(source.faces))
	local top = source:topology()
	local candidates, rejections = {}, {}
	local function reject(reason)
		rejections[reason] = (rejections[reason] or 0) + 1
	end
	for _, key in U.keys(top.edges) do
		local edge = top.edges[key]
		local protected, why = R.protected(source, edge, options, visit)
		if protected then
			reject(why)
			continue
		end
		local fa, fb = edge.faces[1], edge.faces[2]
		local function sourceRegion(fid)
			local f = source.faces[fid]
			local corners = {}
			for i in f.vertices do
				corners[i] = { fid, i, 1 }
			end
			return { loop = f.vertices, corners = corners, faces = { fid } }
		end
		local region = G.union(sourceRegion(fa), sourceRegion(fb), {}, visit)
		if not region or #region.loop ~= 4 then
			reject("topology")
			continue
		end
		local shape = Q.shape(source, region.loop, visit)
		if
			not shape
			or shape.minimumScaledJacobian < options.minimumScaledJacobian
			or shape.aspectRatio > options.maximumAspectRatio
		then
			reject("shape")
			continue
		end
		local uv = {}
		for i, id in region.loop do
			uv[id] = ({ { 0, 0 }, { 6, 0 }, { 6, 6 }, { 0, 6 } })[i]
		end
		local temporary = Mesh.new()
		temporary.vertices = source.vertices
		local fid = temporary:addFace(region.loop)
		local a, b = Q.triangles(source, { fa, fb }, uv, visit), Q.triangles(temporary, { fid }, uv, visit)
		local error, detail = Bound.check(a, b, source.vertices, false, visit)
		if not error then
			reject(detail)
			continue
		end
		local angle = Q.normalChange(a, b, detail.pairs, source.vertices, visit)
		if not angle or angle > options.maxNormalAngle then
			reject("normalLimit")
			continue
		end
		if error > context.remainingDeviation then
			reject("deviation")
			continue
		end
		table.insert(
			candidates,
			{ key = key, fa = fa, fb = fb, region = region, shape = shape, error = error, angle = angle }
		)
	end
	table.sort(candidates, function(a, b)
		visit(1)
		local x, y = a.shape.minimumScaledJacobian, b.shape.minimumScaledJacobian
		if x ~= y then
			return x > y
		end
		if a.shape.aspectRatio ~= b.shape.aspectRatio then
			return a.shape.aspectRatio < b.shape.aspectRatio
		end
		return a.key < b.key
	end)
	local out = source:clone()
	local maps = { face = {}, corner = {} }
	local used, paired, maximum, normalAngle = {}, 0, 0, 0
	for _, entry in candidates do
		visit(1)
		local a, b = entry.fa, entry.fb
		if used[a] or used[b] then
			continue
		end
		used[a], used[b] = true, true
		local id = math.min(a, b)
		local corners = {}
		for i, v in entry.region.loop do
			local refs, cr = {}, {}
			for _, fid in { a, b } do
				local index = table.find(source.faces[fid].vertices, v)
				if index then
					local area = G.plane(source, source.faces[fid].vertices, visit).area
					table.insert(refs, { fid, index, area })
					table.insert(cr, { fid .. ":" .. index, area })
				end
			end
			corners[i] = Corner(source, refs)
			corners[i].normal, corners[i].tangent, corners[i].tangentSign = nil, nil, nil
			maps.corner[id .. ":" .. i] = cr
		end
		out.faces[a], out.faces[b] = nil, nil
		out.faces[id] = {
			vertices = table.clone(entry.region.loop),
			corners = corners,
			material = source.faces[a].material,
		}
		maps.face[id] = { { a, 1 }, { b, 1 } }
		maximum = math.max(maximum, entry.error)
		normalAngle = math.max(normalAngle, entry.angle)
		paired += 1
	end
	context.transfer(source, out, maps)
	return out,
		{
			paired = paired,
			rejections = rejections,
			errorBound = maximum,
			maximumNormalAngle = normalAngle,
			maps = maps,
		}
end
return R
