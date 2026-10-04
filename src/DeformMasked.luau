-- Compose any topology-preserving positional operation with the shared masks.
local U = require(script.Parent.Util)
local Core = require(script.Parent.DeformCore)
return function(mesh, operation, options)
	assert(type(operation) == "function", "Masked deformation requires an operation callback")
	local source = mesh:clone()
	options = U.copy(options or {})
	local ctx = Core.prepare(source, options)
	local influenced = false
	for _, w in ctx.weights do
		if w ~= 0 then
			influenced = true
			break
		end
	end
	ctx.report.operatorInvoked = false
	if not influenced then
		return ctx.run(function(p)
			return p
		end)
	end
	local localMesh = source:clone()
	localMesh.vertices = U.copy(ctx.points)
	localMesh:recalculateNormals(options.normalAngle)
	ctx.checkpoint("operator")
	local result, operationReport = operation(localMesh)
	ctx.report.operatorInvoked = true
	assert(
		type(result) == "table" and type(result.vertices) == "table" and type(result.faces) == "table",
		"Masked operation must return an authoring mesh"
	)
	if operationReport ~= nil then
		assert(type(operationReport) == "table", "Masked operation report must be a table")
		assert(
			operationReport.complete ~= false and operationReport.success ~= false,
			"Masked operation reported incomplete output"
		)
		ctx.report.operationReport = operationReport
	end
	assert(
		U.count(result.vertices) == #ctx.ids and U.count(result.faces) == U.count(source.faces),
		"Masked operation must preserve vertex and face identities"
	)
	for _, id in ctx.ids do
		ctx.visit()
		assert(U.vector(result.vertices[id]), "Masked operation returned a missing or nonfinite position")
	end
	for fid, face in source.faces do
		local other = result.faces[fid]
		assert(
			type(other) == "table" and type(other.vertices) == "table" and #other.vertices == #face.vertices,
			"Masked operation changed face topology"
		)
		for i, id in face.vertices do
			ctx.visit()
			assert(other.vertices[i] == id, "Masked operation changed ordered face connectivity")
		end
	end
	return ctx.run(function(p, id, w)
		return p:Lerp(result.vertices[id], w)
	end)
end
