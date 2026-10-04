local U = require(script.Parent.Util)
local Topology = require(script.Parent.Topology)
local Deform = require(script.Parent.Deform)
local M = {}
function M.bevel(mesh, width, options)
	options = options or {}
	local mode = options.affect or "edges"
	assert(mode == "edges" or mode == "vertices", "Bevel affect must be edges or vertices")
	local selection = options.selection and table.clone(options.selection) or {}
	if not options.selection then
		if mode == "vertices" then
			for id in mesh.vertices do
				selection[id] = true
			end
		else
			local angle = options.angle or 0
			assert(
				type(angle) == "number" and U.finite(angle) and angle >= 0 and angle <= math.pi,
				"Bevel angle must lie in [0,pi]"
			)
			for key, edge in mesh:topology().edges do
				if
					#edge.faces == 2
					and mesh:faceNormal(edge.faces[1]):Dot(mesh:faceNormal(edge.faces[2]))
						< math.cos(angle) - 1e-8
				then
					selection[key] = true
				end
			end
		end
	end
	if options.weightAttribute then
		local A = require(script.Parent.AttributeCore)
		A.validate(mesh)
		local channel = assert(mesh.attributes[options.weightAttribute], "Missing bevel weight channel")
		assert(
			channel.domain == (mode == "edges" and "edge" or "vertex") and channel.dataType == "number",
			"Bevel weights require a numeric channel in the affected domain"
		)
		for key, value in selection do
			local weight = A.read(channel, key)
			assert(weight >= 0 and weight <= 1, "Bevel weights must lie in [0,1]")
			selection[key] = (type(value) == "boolean" and (value and 1 or 0) or value) * weight
		end
	end
	local edit = require(script.Parent.MeshEdit)
	return (mode == "edges" and edit.bevelEdges or edit.bevelVertices)(mesh, selection, width, options)
end
function M.array(mesh, count, step)
	U.integer(count, 1)
	local copies = {}
	local frame = CFrame.identity
	for _ = 1, count do
		table.insert(copies, Deform.transform(mesh, frame))
		frame *= step
	end
	return Topology.join(copies)
end
function M.mirror(mesh, axis, weldTolerance)
	assert(axis == "X" or axis == "Y" or axis == "Z")
	local scale = axis == "X" and Vector3.new(-1, 1, 1)
		or axis == "Y" and Vector3.new(1, -1, 1)
		or Vector3.new(1, 1, -1)
	local result = Topology.join({ mesh, Deform.transform(mesh, CFrame.identity, scale) })
	if weldTolerance then
		result = Topology.weld(result, weldTolerance)
	end
	return result
end
function M.solidify(mesh, thickness, options)
	local result = require(script.Parent.MeshSolidify)(mesh, thickness, options)
	return result
end
function M.shell(mesh, thickness, options)
	return require(script.Parent.MeshSolidify)(mesh, thickness, options, true)
end
function M.clipPlane(mesh, point, normal, cap, options)
	local config = table.clone(options or {})
	config.keep = "negative"
	config.cap = cap ~= false
	if config.tolerance == nil then
		local lo, hi = mesh:bounds()
		config.tolerance = math.max(math.max(hi.X - lo.X, hi.Y - lo.Y, hi.Z - lo.Z) * 1e-6, 1e-7)
	end
	local result = require(script.Parent.MeshBisect)(mesh, point, normal, config)
	return result
end
function M.bevelConvex(mesh, width)
	assert(type(width) == "number" and U.finite(width) and width > 0, "Positive finite bevel width required")
	require(script.Parent.AttributeCore).validate(mesh)
	local report = mesh:validate()
	assert(report.valid and report.closed, "Convex bevel requires a closed oriented mesh")
	local normals = {}
	for fid, f in mesh.faces do
		local n = mesh:faceNormal(fid)
		normals[fid] = n
		local origin = mesh.vertices[f.vertices[1]]
		for _, p in mesh.vertices do
			assert((p - origin):Dot(n) <= 1e-6, "bevelConvex supports convex meshes only")
		end
	end
	local planes = {}
	for _, e in mesh:topology().edges do
		local n1, n2 = normals[e.faces[1]], normals[e.faces[2]]
		if n1:Dot(n2) < 1 - 1e-6 then
			local n = U.unit(n1 + n2)
			table.insert(planes, { mesh.vertices[e.a] - n * width, n })
		end
	end
	local result = mesh:clone()
	for _, plane in planes do
		result = require(script.Parent.ConvexPlaneClip)(result, plane[1], plane[2])
		assert(next(result.faces), "Bevel width consumed mesh")
	end
	return result
end
function M.stack(mesh, operations)
	local m = mesh:clone()
	for _, op in operations do
		m = op(m)
		assert(m and m.vertices, "Modifier must return a mesh")
	end
	return m
end
return M
