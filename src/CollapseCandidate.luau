-- Segment placements, atomic symmetry groups and verified collapse transactions.
local U = require(script.Parent.Util)
local Q = require(script.Parent.CollapseQuadric)
local B = require(script.Parent.CollapseBound)
local S = require(script.Parent.CollapseSymmetry)
local Core = require(script.Parent.DecimateCore)
local Transfer = require(script.Parent.CollapseTransfer)
local A = require(script.Parent.AttributeCore)
local K = {}
local function interpolate(a, b, t)
	if t == 0 then
		return a
	elseif t == 1 then
		return b
	end
	return Vector3.new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end
function K.link(top, a, b, boundary, visit)
	local edge = top.edges[U.edge(a, b)]
	if not edge or #edge.faces < 1 or #edge.faces > 2 then
		return false
	end
	if #edge.faces == 2 and boundary[a] and boundary[b] then
		return false
	end
	local common = 0
	for id in top.neighbors[a] do
		visit(1)
		if top.neighbors[b][id] then
			common += 1
		end
	end
	return common == #edge.faces
end
function K.boundary(top)
	local result = {}
	for _, edge in top.edges do
		if #edge.faces == 1 then
			result[edge.a], result[edge.b] = true, true
		end
	end
	return result
end
function K.plan(context, mesh, top, boundary, protected, map, a, b)
	local options = context.options
	local orbit = S.orbit(a, b, map)
	a, b = orbit.a, orbit.b
	local required
	local function force(t)
		if required ~= nil and required ~= t then
			return false
		end
		required = t
		return true
	end
	if orbit.kind == "crossing" then
		required = 0.5
	end
	if orbit.kind == "shared" then
		required = 0
	end
	if context.fixed[a] and not force(0) or context.fixed[b] and not force(1) then
		return nil, "pins"
	end
	if orbit.kind == "pair" then
		if context.fixed[orbit.ma] and not force(0) or context.fixed[orbit.mb] and not force(1) then
			return nil, "pins"
		end
	elseif orbit.kind == "shared" and context.fixed[orbit.other] then
		return nil, "pins"
	end
	local q = Q.add(context.quadrics[a], context.quadrics[b])
	local pa, pb = context.coordinates(a, mesh.vertices[a]), context.coordinates(b, mesh.vertices[b])
	local t = required
	if t == nil then
		if options.placement == "midpoint" then
			t = 0.5
		elseif options.placement == "endpoints" then
			t = Q.value(q, pa) <= Q.value(q, pb) and 0 or 1
		else
			local _p, parameter = Q.segment(q, pa, pb)
			t = parameter
		end
	end
	local p = interpolate(mesh.vertices[a], mesh.vertices[b], t)
	if not U.vector(p) then
		return nil, "nativeOverflow"
	end
	local operations = { { a = a, b = b, t = t, position = p } }
	if orbit.kind == "pair" then
		local mirror = S.reflect(p, options.symmetry)
		if not mirror then
			return nil, "nativeSymmetry"
		end
		table.insert(operations, { a = orbit.ma, b = orbit.mb, t = t, position = mirror })
	elseif orbit.kind == "shared" then
		table.insert(operations, { a = a, b = orbit.other, t = 0, position = p })
	elseif orbit.kind == "crossing" or map then
		local mirror = S.reflect(p, options.symmetry)
		if mirror ~= p then
			return nil, "nativeSymmetry"
		end
	end
	local cost, priority = 0, 0
	for _, op in operations do
		context.visit(1)
		if op.t == 1 then
			op.a, op.b, op.t = op.b, op.a, 0
		end
		if protected[op.a] or protected[op.b] then
			return nil, "features"
		end
		if options.preserveBoundary ~= false and (boundary[op.a] or boundary[op.b]) then
			return nil, "boundary"
		end
		if context.fixed[op.b] or context.fixed[op.a] and op.position ~= mesh.vertices[op.a] then
			return nil, "pins"
		end
		if not K.link(top, op.a, op.b, boundary, context.visit) then
			return nil, "link"
		end
		if options.maxDeviation then
			for _, id in { op.a, op.b } do
				for _, original in context.clusters[id] do
					context.visit(1)
					if B.distance(context.mesh.vertices[original], op.position) > options.maxDeviation then
						return nil, "deviation"
					end
				end
			end
		end
		local quadric = Q.add(context.quadrics[op.a], context.quadrics[op.b])
		local value = math.max(0, Q.value(quadric, context.coordinates(op.a, op.position)))
		local span = context.components[op.a].span
		value *= span ^ 4
		if not U.finite(value) then
			return nil, "quadricOverflow"
		end
		local wa, wb = context.weights[op.a], context.weights[op.b]
		local weight = wa == 0 and wb or wb == 0 and wa or math.min(wa, wb)
		if weight == 0 then
			return nil, "mask"
		end
		cost += value
		priority += value == 0 and 0 or value / (weight ^ options.weightFactor)
	end
	if options.maxError and cost > options.maxError then
		return nil, "quadricLimit"
	end
	return { operations = operations, cost = cost, priority = priority, key = U.edge(a, b), kind = orbit.kind }
end
function K.apply(context, mesh, plan)
	local out = mesh
	local representatives = table.clone(context.representatives)
	for _, op in plan.operations do
		context.visit(U.count(out.vertices) + 4 * U.count(out.faces))
		local top = out:topology()
		if not K.link(top, op.a, op.b, K.boundary(top), context.visit) then
			return nil, "pairedLink"
		end
		local transfer = Transfer(out, op.a, op.b, op.t, top, context.options)
		out = out:clone()
		out.vertices[op.a] = op.position
		for fid, face in out.faces do
			local seen, duplicate = {}, false
			for i, id in face.vertices do
				if id == op.b then
					id = op.a
					face.vertices[i] = id
				end
				if seen[id] then
					duplicate = true
				end
				seen[id] = true
			end
			if duplicate then
				out.faces[fid] = nil
			end
		end
		out.vertices[op.b] = nil
		for original, id in representatives do
			context.visit(1)
			if id == op.b then
				representatives[original] = op.a
			end
		end
		transfer(out)
	end
	local maximumAngle = 0
	for fid, face in out.faces do
		context.visit(1)
		local normal = Core.normal(out, face.vertices)
		if not normal then
			return nil, "degenerateTriangle"
		end
		local reference = context.normals[fid]
		local dot =
			math.clamp(reference.x * normal.x + reference.y * normal.y + reference.z * normal.z, -1, 1)
		maximumAngle = math.max(maximumAngle, math.acos(dot))
		if dot < context.options.minimumNormalDot then
			return nil, "normalLimit"
		end
	end
	local connectivity = context.connectivity(out)
	if not connectivity.valid or not out:validate({ minimumFaceArea = 0 }).valid then
		return nil, "topology"
	end
	if #connectivity.components ~= #context.reference.components then
		return nil, "components"
	end
	local seen = {}
	for _, component in connectivity.components do
		local index
		for id in component.vertices do
			local original = context.components[id].index
			if index and index ~= original then
				return nil, "joinedComponents"
			end
			index = original
		end
		if seen[index] then
			return nil, "splitComponent"
		end
		seen[index] = true
		local reference = context.reference.components[index]
		if
			component.eulerCharacteristic ~= reference.eulerCharacteristic
			or component.boundaryLoops ~= reference.boundaryLoops
		then
			return nil, "topologyType"
		end
	end
	local bound, reason = B.check(context.mesh, out, representatives, context.visit)
	if not bound then
		return nil, reason
	end
	if context.options.maxDeviation and bound > context.options.maxDeviation then
		return nil, "deviation"
	end
	local symmetry
	if context.options.symmetry then
		symmetry, reason = S.build(out, context.options.symmetry, context.visit)
		if not symmetry then
			return nil, reason
		end
	end
	A.validate(out)
	return {
		mesh = out,
		representatives = representatives,
		errorBound = bound,
		maximumNormalAngle = maximumAngle,
		symmetry = symmetry,
	}
end
function K.commit(context, plan, result)
	for _, op in plan.operations do
		context.quadrics[op.a] = Q.add(context.quadrics[op.a], context.quadrics[op.b])
		context.quadrics[op.b] = nil
		for _, original in context.clusters[op.b] do
			table.insert(context.clusters[op.a], original)
		end
		context.clusters[op.b] = nil
		context.weights[op.a] = context.weights[op.a] * (1 - op.t) + context.weights[op.b] * op.t
		context.weights[op.b] = nil
	end
	context.representatives = result.representatives
end
return K
