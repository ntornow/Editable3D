-- Private profile rotation/translation with welded seams and axis poles.
local U = require(script.Parent.Util)
local C = require(script.Parent.Connectivity)
local Core = require(script.Parent.MeshEditCore)
return function(mesh, profile, origin, axis, angle, steps, options)
	options = options or {}
	assert(
		U.vector(origin) and U.vector(axis) and axis.Magnitude > 0 and U.finite(axis.Magnitude),
		"Finite spin origin and nonzero axis required"
	)
	assert(type(angle) == "number" and U.finite(angle) and angle ~= 0, "Nonzero finite spin angle required")
	U.integer(steps, 1)
	U.integer(options.maxSteps or 10000, 1)
	if options.material ~= nil then
		U.integer(options.material, 1)
	end
	assert(
		steps <= (options.maxSteps or 10000) and math.abs(angle / steps) < math.pi,
		"Spin step budget or angular resolution exceeded"
	)
	local rise, tolerance = options.rise or 0, options.axisTolerance or 0
	assert(type(rise) == "number" and U.finite(rise), "Finite spin rise required")
	assert(
		type(tolerance) == "number" and U.finite(tolerance) and tolerance >= 0,
		"Nonnegative axis tolerance required"
	)
	assert(rise ~= 0 or math.abs(angle) <= 2 * math.pi + 1e-12, "Multiple rotations require nonzero rise")
	local merged = options.merge ~= false and rise == 0 and math.abs(math.abs(angle) - 2 * math.pi) <= 1e-12
	local closed = options.closedProfile == true
	assert(type(profile) == "table" and #profile >= (closed and 3 or 2), "Ordered spin profile required")
	assert(options.uv == nil or options.uv == "preserve" or options.uv == "sweep", "Unknown spin UV mode")
	local edit, index = Core.begin(mesh, options), C.index(mesh, options)
	axis = axis.Unit
	local ids, seen, direction, attached = table.clone(profile), {}, nil, false
	for _, id in ids do
		assert(mesh.vertices[id] and not seen[id], "Profile vertices must exist and be distinct")
		seen[id] = true
	end
	local edges = closed and #ids or #ids - 1
	for i = 1, edges do
		local edge = index.edges[U.edge(ids[i], ids[i % #ids + 1])]
		if edge then
			attached = true
			assert(
				#edge.corners == 1 and not merged,
				"Spin attachment requires an open sweep and boundary edges"
			)
			local d = index.corners[edge.corners[1]].vertex == ids[i]
			assert(direction == nil or direction == d, "Inconsistent profile boundary orientation")
			direction = d
		end
	end
	if direction then
		for i = 1, math.floor(#ids / 2) do
			ids[i], ids[#ids - i + 1] = ids[#ids - i + 1], ids[i]
		end
	end
	assert(not options.cap or closed and not attached, "Spin caps require a detached closed profile")
	local refs, poles, distances = {}, {}, { 0 }
	for i, id in ids do
		local d = mesh.vertices[id] - origin
		local radius = (d - axis * d:Dot(axis)).Magnitude
		poles[id] = rise == 0 and radius <= tolerance
		if poles[id] and radius > 0 then
			edit.out:setPosition(id, origin + axis * d:Dot(axis))
		end
		local ck = index.vertices[id].corners[1]
		local c = ck and index.corners[ck]
		refs[id] = c and { { c.face, c.index, 1 } } or {}
		if i > 1 then
			distances[i] = distances[i - 1] + (mesh.vertices[id] - mesh.vertices[ids[i - 1]]).Magnitude
		end
	end
	local length = distances[#ids]
		+ (closed and (mesh.vertices[ids[1]] - mesh.vertices[ids[#ids]]).Magnitude or 0)
	assert(length > 0, "Spin profile has zero length")
	local rings = { table.clone(ids) }
	for step = 1, steps do
		local ring, t = {}, step / steps
		local rotation = CFrame.fromAxisAngle(axis, angle * t)
		for i, id in ids do
			if poles[id] or merged and step == steps then
				ring[i] = id
			else
				ring[i] = edit.vertex(
					origin + rotation:VectorToWorldSpace(mesh.vertices[id] - origin) + axis * (rise * t),
					{ { id, 1 } }
				)
			end
		end
		rings[step + 1] = ring
		for i = 1, edges do
			local j = i % #ids + 1
			local vs, cr, localPoints = {}, {}, {}
			for _, item in
				{
					{ rings[step][i], i, step - 1 },
					{ rings[step][j], j, step - 1 },
					{ ring[j], j, step },
					{ ring[i], i, step },
				}
			do
				if not table.find(vs, item[1]) then
					table.insert(vs, item[1])
					table.insert(cr, refs[ids[item[2]]])
					table.insert(localPoints, item)
				end
			end
			if #vs >= 3 then
				local edge = index.edges[U.edge(ids[i], ids[j])]
				local faceRefs = edge and { { edge.faces[1], 1 } } or nil
				local material = options.material or (edge and mesh.faces[edge.faces[1]].material) or 1
				local fid = edit.face(vs, cr, material, faceRefs)
				for k, item in localPoints do
					local corner = edit.out.faces[fid].corners[k]
					if corner.tangent then
						corner.tangent = CFrame.fromAxisAngle(axis, angle * item[3] / steps)
							:VectorToWorldSpace(corner.tangent)
					end
					if options.uv == "sweep" or #cr[k] == 0 then
						corner.uv = Vector2.new(
							item[3] / steps,
							(item[2] == 1 and j == 1 and i ~= 1) and 1 or distances[item[2]] / length
						)
					end
				end
			end
			if ring[i] ~= ring[j] and index.edges[U.edge(ids[i], ids[j])] then
				edit.maps.edge[U.edge(ring[i], ring[j])] = { { U.edge(ids[i], ids[j]), 1 } }
			end
		end
	end
	if options.cap and not merged then
		for _, last in { false, true } do
			local vs, cr = {}, {}
			for i = 1, #ids do
				local k = last and i or #ids - i + 1
				vs[i], cr[i] = rings[last and #rings or 1][k], refs[ids[k]]
			end
			local fid = edit.face(vs, cr, options.material or 1, nil)
			local x, y = U.frame((edit.out:faceNormal(fid)))
			local start = edit.out.vertices[vs[1]]
			for i, corner in edit.out.faces[fid].corners do
				if last and corner.tangent then
					corner.tangent = CFrame.fromAxisAngle(axis, angle):VectorToWorldSpace(corner.tangent)
				end
				if options.uv == "sweep" or #cr[i] == 0 then
					local d = edit.out.vertices[vs[i]] - start
					corner.uv = Vector2.new(d:Dot(x), d:Dot(y))
				end
			end
		end
	end
	assert(#edit.report.addedFaces > 0, "Spin generated no surface")
	edit.report.rings, edit.report.profile, edit.report.merged, edit.report.poles = rings, ids, merged, poles
	return edit.finish()
end
