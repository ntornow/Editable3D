-- Private normal fan partition, weighted reductions and orthogonal frame editing.
local U = require(script.Parent.Util)
local C = require(script.Parent.Connectivity)
local A = require(script.Parent.AttributeCore)
local function unit(v)
	assert(U.vector(v), "Finite normal vector required")
	local scale = math.max(math.abs(v.X), math.abs(v.Y), math.abs(v.Z))
	assert(scale > 0, "Normal direction must be nonzero")
	local x, y, z = v.X / scale, v.Y / scale, v.Z / scale
	local length = math.sqrt(x * x + y * y + z * z)
	return Vector3.new(x / length, y / length, z / length)
end
local function angle(mesh, fid, i, normal)
	local vs = mesh.faces[fid].vertices
	local p = mesh.vertices[vs[i]]
	local a = unit(mesh.vertices[vs[(i - 2) % #vs + 1]] - p)
	local b = unit(mesh.vertices[vs[i % #vs + 1]] - p)
	local value = math.acos(math.clamp(a:Dot(b), -1, 1))
	return a:Cross(b):Dot(normal) > 0 and 2 * math.pi - value or value
end
local function setup(mesh, options)
	options = options or {}
	local index = C.index(mesh, options)
	A.validate(mesh)
	assert(
		mesh:validate({ minimumFaceArea = options.minimumFaceArea }).valid,
		"Normal editing requires a valid oriented mesh"
	)
	local mask = options.mask
	if mask then
		assert(type(mask) == "table", "Normal mask must be a corner dictionary")
		for key, w in mask do
			assert(
				index.corners[key]
					and (type(w) == "boolean" or type(w) == "number" and U.finite(w) and w >= 0 and w <= 1),
				"Invalid normal mask corner or weight"
			)
		end
	end
	local mix = options.mix or 1
	assert(type(mix) == "number" and U.finite(mix) and mix >= 0 and mix <= 1, "Normal mix must lie in [0,1]")
	local maximum = U.integer(options.maxWork or 5000000, 1)
	local work = 0
	local function visit()
		work += 1
		assert(work <= maximum, "Normal work budget exceeded")
		if work % 256 == 0 and options.checkpoint then
			options.checkpoint(work / maximum)
		end
	end
	local normals, areas = {}, {}
	for fid in mesh.faces do
		normals[fid], areas[fid] = mesh:faceNormal(fid)
		assert(
			U.finite(areas[fid]) and areas[fid] > 0,
			"Finite positive face area required for normal editing"
		)
		visit()
	end
	local out = mesh:clone()
	local report = { changedCorners = 0, tangentFallbacks = 0, zeroSums = 0 }
	local function weight(key)
		local value = mask and mask[key] or (mask and 0 or 1)
		return (type(value) == "boolean" and (value and 1 or 0) or value) * mix
	end
	local function source(key)
		local c = index.corners[key]
		return unit(mesh.faces[c.face].corners[c.index].normal or normals[c.face])
	end
	local function write(key, value)
		local c = assert(index.corners[key], "Unknown normal corner")
		local blendWeight = weight(key)
		if blendWeight == 0 then
			return
		end
		local n = unit(value)
		if blendWeight < 1 then
			local old = source(key)
			local blend = old * (1 - blendWeight) + n * blendWeight
			assert(
				blend.Magnitude > 1e-8,
				"Normal blend cancels; choose a non-antipodal target or a different mix"
			)
			n = unit(blend)
		end
		local corner = out.faces[c.face].corners[c.index]
		corner.normal = n
		if corner.tangent then
			local tangent = unit(corner.tangent)
			local projected = tangent - n * tangent:Dot(n)
			if projected.Magnitude <= 1e-8 then
				projected = U.frame(n)
				report.tangentFallbacks += 1
			end
			corner.tangent = unit(projected)
		end
		report.changedCorners += 1
		visit()
	end
	local function finish()
		out.revision += 1
		report.work = work
		return out, report
	end
	return {
		out = out,
		index = index,
		normals = normals,
		areas = areas,
		report = report,
		source = source,
		weight = weight,
		write = write,
		visit = visit,
		finish = finish,
	}
end
local function fans(mesh, state, options)
	options = options or {}
	local limit = options.angle or math.pi
	assert(
		type(limit) == "number" and U.finite(limit) and limit >= 0 and limit <= math.pi,
		"Normal angle must lie in [0,pi]"
	)
	local sharp = options.sharpEdges
	if sharp ~= nil then
		assert(type(sharp) == "table", "Sharp edges must be a dictionary")
		for key, value in sharp do
			assert(state.index.edges[key] and type(value) == "boolean", "Invalid sharp edge")
		end
	else
		local channel = mesh.attributes.sharp_edge
		if channel then
			assert(
				channel.domain == "edge" and channel.dataType == "boolean",
				"sharp_edge must be an edge boolean channel"
			)
			sharp = {}
			for key in state.index.edges do
				sharp[key] = A.read(channel, key)
			end
		end
	end
	local adjacent = {}
	for key in state.index.corners do
		adjacent[key] = {}
	end
	for key, e in state.index.edges do
		state.visit()
		if
			#e.faces == 2
			and not (sharp and sharp[key])
			and state.normals[e.faces[1]]:Dot(state.normals[e.faces[2]]) >= math.cos(limit) - 1e-8
		then
			for _, id in { e.a, e.b } do
				local a, b = state.index.corners[e.corners[1]], state.index.corners[e.corners[2]]
				local ca = a.vertex == id and e.corners[1] or a.next
				local cb = b.vertex == id and e.corners[2] or b.next
				table.insert(adjacent[ca], cb)
				table.insert(adjacent[cb], ca)
			end
		end
	end
	local result, membership, seen = {}, {}, {}
	for _, seed in U.keys(state.index.corners) do
		if not seen[seed] then
			local group, stack = {}, { seed }
			seen[seed] = true
			while #stack > 0 do
				local key = table.remove(stack)
				table.insert(group, key)
				membership[key] = #result + 1
				state.visit()
				for _, neighbor in adjacent[key] do
					if not seen[neighbor] then
						seen[neighbor] = true
						table.insert(stack, neighbor)
					end
				end
			end
			table.sort(group)
			table.insert(result, group)
		end
	end
	state.report.fans = result
	return result, membership
end
local function reduce(mesh, state, options, useCustom)
	options = options or {}
	local mode = options.weighting or "areaAngle"
	assert(
		mode == "uniform" or mode == "area" or mode == "angle" or mode == "areaAngle",
		"Unknown normal weighting"
	)
	local power = options.power or 1
	assert(
		type(power) == "number" and U.finite(power) and power >= 0 and power <= 16,
		"Normal weight power must lie in [0,16]"
	)
	local faceWeights, strengths = options.faceWeights or {}, options.faceStrength or {}
	for fid, w in faceWeights do
		assert(
			mesh.faces[fid] and type(w) == "number" and U.finite(w) and w >= 0,
			"Invalid normal face weight"
		)
	end
	for fid, s in strengths do
		assert(mesh.faces[fid] and type(s) == "number" and U.finite(s), "Invalid normal face strength")
	end
	for _, group in fans(mesh, state, options) do
		local strongest = -math.huge
		for _, key in group do
			strongest = math.max(strongest, strengths[state.index.corners[key].face] or 0)
		end
		local logs, maxLog = {}, -math.huge
		for i, key in group do
			local c = state.index.corners[key]
			local multiplier = faceWeights[c.face]
			if multiplier == nil then
				multiplier = 1
			end
			if (strengths[c.face] or 0) == strongest and multiplier > 0 then
				local w = math.log(multiplier)
				if mode == "area" or mode == "areaAngle" then
					w += power * math.log(state.areas[c.face])
				end
				if mode == "angle" or mode == "areaAngle" then
					local a = angle(mesh, c.face, c.index, state.normals[c.face])
					if a == 0 and power > 0 then
						w = -math.huge
					else
						w += power * (a > 0 and math.log(a) or 0)
					end
				end
				logs[i] = w
				maxLog = math.max(maxLog, w)
			end
			state.visit()
		end
		assert(maxLog > -math.huge, "Normal fan has no positive weight")
		local x, y, z = 0, 0, 0
		for i, key in group do
			if logs[i] then
				local n = useCustom and state.source(key) or state.normals[state.index.corners[key].face]
				local w = math.exp(logs[i] - maxLog)
				x += n.X * w
				y += n.Y * w
				z += n.Z * w
			end
		end
		local sum = Vector3.new(x, y, z)
		if sum.Magnitude <= 1e-8 then
			state.report.zeroSums += 1
			assert(
				options.zeroSum == "face",
				"Normal fan directions cancel; choose zeroSum='face' explicitly for per-face fallback"
			)
			for _, key in group do
				state.write(key, state.normals[state.index.corners[key].face])
			end
		else
			for _, key in group do
				state.write(key, sum)
			end
		end
	end
	return state.finish()
end
return { unit = unit, angle = angle, setup = setup, fans = fans, reduce = reduce }
