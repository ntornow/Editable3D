-- Private angle-weighted UV derivative frames, with explicit seam and failure handling.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Core = require(script.Parent.NormalCore)
return function(mesh, options)
	options = options or {}
	assert(
		options.mix == nil or options.mix == 1,
		"Tangent generation does not blend frame handedness; mix must be one"
	)
	local state = Core.setup(mesh, options)
	local _, membership = Core.fans(mesh, state, options)
	local epsilon = options.uvTolerance or 0
	assert(
		type(epsilon) == "number" and U.finite(epsilon) and epsilon >= 0,
		"Nonnegative UV determinant tolerance required"
	)
	local channel = options.uvChannel
		and assert(mesh.attributes[options.uvChannel], "Missing tangent UV channel")
	if channel then
		assert(
			channel.domain == "corner" and channel.dataType == "Vector2",
			"Tangent UV channel must be corner Vector2"
		)
	end
	local uv, normals, contributions = {}, {}, {}
	for key, c in state.index.corners do
		local value = channel and A.read(channel, key) or mesh.faces[c.face].corners[c.index].uv
		assert(
			typeof(value) == "Vector2" and U.finite(value.X) and U.finite(value.Y),
			"Tangents require finite UVs at every corner"
		)
		uv[key], normals[key], contributions[key] = value, state.source(key), {}
	end
	local report = state.report
	report.degenerateUVTriangles, report.fallbackCorners, report.groups = 0, 0, 0
	local handedness = {}
	for _, fid in U.keys(mesh.faces) do
		local f = mesh.faces[fid]
		for _, tri in
			mesh:faceTriangles(fid, {
				validateSimple = true,
				maxVertices = options.maxFaceVertices or 2000,
				maxWork = options.maxFaceWork or 5000000,
			})
		do
			state.visit()
			local keys = { fid .. ":" .. tri[1], fid .. ":" .. tri[2], fid .. ":" .. tri[3] }
			local a, b, c =
				mesh.vertices[f.vertices[tri[1]]],
				mesh.vertices[f.vertices[tri[2]]],
				mesh.vertices[f.vertices[tri[3]]]
			local ua, ub, uc = uv[keys[1]], uv[keys[2]], uv[keys[3]]
			local du1, dv1, du2, dv2 = ub.X - ua.X, ub.Y - ua.Y, uc.X - ua.X, uc.Y - ua.Y
			local determinant = du1 * dv2 - du2 * dv1
			if math.abs(determinant) <= epsilon then
				report.degenerateUVTriangles += 1
				continue
			end
			local ab, ac = b - a, c - a
			local tangent = Core.unit(
				Vector3.new(
					(ab.X * dv2 - ac.X * dv1) / determinant,
					(ab.Y * dv2 - ac.Y * dv1) / determinant,
					(ab.Z * dv2 - ac.Z * dv1) / determinant
				)
			)
			local bitangent = Core.unit(
				Vector3.new(
					(ac.X * du1 - ab.X * du2) / determinant,
					(ac.Y * du1 - ab.Y * du2) / determinant,
					(ac.Z * du1 - ab.Z * du2) / determinant
				)
			)
			local positions = { a, b, c }
			for i, key in keys do
				local sign = normals[key]:Cross(tangent):Dot(bitangent) < 0 and -1 or 1
				assert(
					not handedness[key] or handedness[key] == sign,
					"A polygon corner spans incompatible UV handedness; split its faces or UVs"
				)
				handedness[key] = sign
				local p = positions[i]
				local x = Core.unit(positions[i % 3 + 1] - p)
				local y = Core.unit(positions[(i + 1) % 3 + 1] - p)
				local weight = math.acos(math.clamp(x:Dot(y), -1, 1))
				table.insert(contributions[key], { tangent = tangent, weight = weight })
			end
		end
	end
	local groups, cornerGroups = {}, {}
	for _, key in U.keys(state.index.corners) do
		local fan = membership[key]
		groups[fan] = groups[fan] or {}
		local found
		for _, group in groups[fan] do
			state.visit()
			if group.normal == normals[key] and group.uv == uv[key] and group.sign == handedness[key] then
				found = group
				break
			end
		end
		if not found then
			found = {
				normal = normals[key],
				uv = uv[key],
				sign = handedness[key],
				x = 0,
				y = 0,
				z = 0,
				weight = 0,
			}
			table.insert(groups[fan], found)
			report.groups += 1
		end
		cornerGroups[key] = found
		for _, sample in contributions[key] do
			found.x += sample.tangent.X * sample.weight
			found.y += sample.tangent.Y * sample.weight
			found.z += sample.tangent.Z * sample.weight
			found.weight += sample.weight
		end
	end
	for _, key in U.keys(state.index.corners) do
		if state.weight(key) == 0 then
			continue
		end
		assert(state.weight(key) == 1, "Tangent masks must be boolean or zero/one weights")
		local group = cornerGroups[key]
		local tangent = Vector3.new(group.x, group.y, group.z)
		local n = normals[key]
		tangent -= n * tangent:Dot(n)
		if group.weight == 0 or tangent.Magnitude <= 1e-8 then
			report.fallbackCorners += 1
			assert(
				options.degenerate == "fallback",
				"Tangent frame is undefined; choose degenerate='fallback' for a deterministic orthogonal frame"
			)
			tangent = U.frame(n)
		end
		local c = state.index.corners[key]
		local corner = state.out.faces[c.face].corners[c.index]
		corner.normal = n
		corner.tangent = Core.unit(tangent)
		corner.tangentSign = group.sign or 1
		report.changedCorners += 1
		state.visit()
	end
	report.complete = report.degenerateUVTriangles == 0 and report.fallbackCorners == 0
	return state.finish()
end
