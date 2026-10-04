-- Private transactional polygon builder with explicit source correspondence.
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local C = require(script.Parent.Connectivity)
local function active(value)
	return value == true or (type(value) == "number" and value > 0)
end
local function selection(mesh, selected)
	assert(type(selected) == "table", "Face selection required")
	local faces = {}
	for _, fid in U.keys(selected) do
		assert(mesh.faces[fid], "Unknown selected face")
		if active(selected[fid]) then
			table.insert(faces, fid)
		end
	end
	return faces
end
local function corner(mesh, refs)
	local fields, result = {}, {}
	for _, r in refs do
		for field in mesh.faces[r[1]].corners[r[2]] do
			fields[field] = true
		end
	end
	for field in fields do
		local values, weighted, kind = {}, {}, nil
		for i, r in refs do
			local value = mesh.faces[r[1]].corners[r[2]][field]
			if value ~= nil and (r[3] or 1) > 0 then
				kind = kind or typeof(value)
				assert(typeof(value) == kind, "Incompatible corner attribute types")
				values[i] = value
				table.insert(weighted, { i, r[3] or 1 })
			end
		end
		if #weighted > 0 then
			result[field] = A.blend({
				values = values,
				dataType = kind,
				interpolation = (kind == "boolean" or kind == "string") and "nearest" or "linear",
			}, weighted)
		end
	end
	return result
end
local function begin(mesh, options)
	options = options or {}
	C.index(mesh, options)
	A.validate(mesh)
	assert(mesh:validate().valid, "Mesh edit requires a valid oriented source")
	local vertexLimit, faceLimit =
		U.integer(options.maxVertices or 500000, 1), U.integer(options.maxFaces or 500000, 1)
	local vertices, faces = U.count(mesh.vertices), U.count(mesh.faces)
	assert(vertices <= vertexLimit and faces <= faceLimit, "Mesh edit allocation budget exceeded")
	if options.checkpoint then
		options.checkpoint({ stage = "begin", vertices = vertices, faces = faces })
	end
	local out = mesh:clone()
	local maps = { vertex = {}, edge = {}, face = {}, corner = {} }
	local report = { addedVertices = {}, addedFaces = {}, replacedFaces = {}, maps = maps }
	local work = 0
	local function checkpoint()
		work += 1
		if options.checkpoint and work % 256 == 0 then
			options.checkpoint({ stage = "build", vertices = vertices, faces = faces })
		end
	end
	local function vertex(position, refs)
		vertices += 1
		assert(vertices <= vertexLimit, "Mesh edit vertex budget exceeded")
		local id = out:addVertex(position)
		maps.vertex[id] = refs
		table.insert(report.addedVertices, id)
		checkpoint()
		return id
	end
	local function face(vs, refs, material, faceRefs, keepId)
		local corners = {}
		for i, cr in refs do
			corners[i] = corner(mesh, cr)
		end
		local fid
		if keepId then
			assert(out.faces[keepId], "Missing replacement face")
			fid = keepId
			out.faces[fid] = { vertices = table.clone(vs), corners = corners, material = material }
			report.replacedFaces[fid] = true
		else
			faces += 1
			assert(faces <= faceLimit, "Mesh edit face budget exceeded")
			fid = out:addFace(vs, corners, material)
			table.insert(report.addedFaces, fid)
		end
		maps.face[fid] = faceRefs and #faceRefs > 0 and faceRefs or nil
		for i, cr in refs do
			local references = {}
			for _, r in cr do
				table.insert(references, { r[1] .. ":" .. r[2], r[3] or 1 })
			end
			maps.corner[fid .. ":" .. i] = #references > 0 and references or nil
		end
		checkpoint()
		return fid
	end
	local function finish()
		local changed = table.clone(report.replacedFaces)
		for _, fid in report.addedFaces do
			changed[fid] = true
		end
		for fid in changed do
			if out.faces[fid] then
				out:faceTriangles(fid, {
					validateSimple = true,
					maxVertices = options.maxFaceVertices or 2000,
					maxWork = options.maxFaceWork or 5000000,
				})
			end
			checkpoint()
		end
		A.transfer(mesh, out, maps)
		A.vertexData(mesh, out, maps.vertex)
		out:recalculateNormals()
		local validation = out:validate()
		assert(validation.valid, "Mesh edit produced invalid topology or degenerate faces")
		report.validation = validation
		return out, report
	end
	return {
		out = out,
		maps = maps,
		report = report,
		vertex = vertex,
		face = face,
		finish = finish,
		checkpoint = checkpoint,
	}
end
return { begin = begin, selection = selection, corner = corner, active = active }
