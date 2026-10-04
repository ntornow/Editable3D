-- BSP and audited triangle-arrangement solid operations with source correspondence.
local Mesh = require(script.Parent.Mesh)
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local B = {}

local function attributes(a, b, t)
	local out = U.copy(a)
	for k, value in b do
		local av = a[k]
		if av ~= nil and typeof(av) == typeof(value) then
			local kind = typeof(value)
			if kind == "number" or kind == "Vector2" or kind == "Vector3" or kind == "Color3" then
				out[k] = U.mix(av, value, t)
			elseif kind == "table" then
				out[k] = attributes(av, value, t)
			end
		elseif t >= 0.5 then
			out[k] = U.copy(value)
		end
	end
	return out
end
local function scalarMap(a, b, t)
	local out = {}
	for k, v in a do
		out[k] = v * (1 - t)
	end
	for k, v in b do
		out[k] = (out[k] or 0) + v * t
	end
	return out
end
local function mixReferences(a, b, t)
	local values = {}
	for _, entry in a do
		values[entry[1]] = (values[entry[1]] or 0) + entry[2] * (1 - t)
	end
	for _, entry in b do
		values[entry[1]] = (values[entry[1]] or 0) + entry[2] * t
	end
	local refs = {}
	for _, id in U.keys(values) do
		if values[id] > 0 then
			table.insert(refs, { id, values[id] })
		end
	end
	return refs
end
local function interpolate(a, b, t)
	local corner = attributes(a.corner, b.corner, t)
	if corner.normal then
		corner.normal = U.unit(corner.normal)
	end
	local sourceEdges = {}
	for edge in a.sourceEdges do
		if b.sourceEdges[edge] then
			sourceEdges[edge] = true
		end
	end
	return {
		p = a.p:Lerp(b.p, t),
		corner = corner,
		weights = scalarMap(a.weights, b.weights, t),
		groups = scalarMap(a.groups, b.groups, t),
		vertexRefs = mixReferences(a.vertexRefs, b.vertexRefs, t),
		cornerRefs = mixReferences(a.cornerRefs, b.cornerRefs, t),
		sourceEdges = sourceEdges,
	}
end
local function polygon(vertices, material, source, epsilon)
	local clean = {}
	for _, v in vertices do
		if #clean == 0 or (clean[#clean].p - v.p).Magnitude > epsilon then
			table.insert(clean, v)
		end
	end
	if #clean > 1 and (clean[1].p - clean[#clean].p).Magnitude <= epsilon then
		table.remove(clean)
	end
	if #clean < 3 then
		return nil
	end
	local origin, normal = clean[1].p, Vector3.zero
	for i = 2, #clean - 1 do
		normal += (clean[i].p - origin):Cross(clean[i + 1].p - origin)
	end
	if normal.Magnitude <= epsilon * epsilon then
		return nil
	end
	normal = normal.Unit
	return {
		vertices = clean,
		normal = normal,
		distance = normal:Dot(origin),
		material = material,
		source = source,
	}
end
local function flip(poly)
	local vs = {}
	for i = #poly.vertices, 1, -1 do
		local v = U.copy(poly.vertices[i])
		if v.corner.normal then
			v.corner.normal = -v.corner.normal
		end
		if v.corner.tangentSign then
			v.corner.tangentSign = -v.corner.tangentSign
		end
		table.insert(vs, v)
	end
	poly.vertices, poly.normal, poly.distance = vs, -poly.normal, -poly.distance
end
local function split(plane, poly, copFront, copBack, front, back, context)
	context.work += 1
	assert(context.work <= context.maxWork, "Boolean work budget exceeded")
	if context.work % 2048 == 0 then
		assert(not context.cancelled or not context.cancelled(), "Boolean cancelled")
		if context.yieldEvery then
			task.wait()
		end
	end
	local types, both = {}, 0
	for i, v in poly.vertices do
		local d = plane.normal:Dot(v.p) - plane.distance
		local kind = d > context.epsilon and 1 or (d < -context.epsilon and 2 or 0)
		types[i], both = kind, bit32.bor(both, kind)
	end
	if both == 0 then
		table.insert(plane.normal:Dot(poly.normal) >= 0 and copFront or copBack, poly)
	elseif both == 1 then
		table.insert(front, poly)
	elseif both == 2 then
		table.insert(back, poly)
	else
		local fv, bv = {}, {}
		for i, a in poly.vertices do
			local j = i % #poly.vertices + 1
			local b, ta, tb = poly.vertices[j], types[i], types[j]
			if ta ~= 2 then
				table.insert(fv, a)
			end
			if ta ~= 1 then
				table.insert(bv, a)
			end
			if bit32.bor(ta, tb) == 3 then
				local t = (plane.distance - plane.normal:Dot(a.p)) / plane.normal:Dot(b.p - a.p)
				local v = interpolate(a, b, math.clamp(t, 0, 1))
				table.insert(fv, v)
				table.insert(bv, v)
			end
		end
		local f = polygon(fv, poly.material, poly.source, context.epsilon)
		local b = polygon(bv, poly.material, poly.source, context.epsilon)
		if f then
			table.insert(front, f)
		end
		if b then
			table.insert(back, b)
		end
	end
end
local Node = {}
Node.__index = Node
function Node.new(context)
	return setmetatable({ polygons = {}, context = context }, Node)
end
function Node:build(polys, depth)
	depth = depth or 0
	assert(depth <= self.context.maxDepth, "Boolean BSP depth budget exceeded")
	if #polys == 0 then
		return
	end
	assert(#polys <= self.context.maxPolygons, "Boolean polygon budget exceeded")
	if not self.plane then
		-- Pick a balanced plane from a bounded deterministic sample.
		local best, cost = polys[1], math.huge
		for sample = 0, math.min(7, #polys - 1) do
			local p = polys[1 + math.floor(sample * #polys / math.min(8, #polys))]
			local f, b, s = 0, 0, 0
			for _, q in polys do
				local above, below = false, false
				for _, v in q.vertices do
					local d = p.normal:Dot(v.p) - p.distance
					above = above or d > self.context.epsilon
					below = below or d < -self.context.epsilon
				end
				if above then
					f += 1
				end
				if below then
					b += 1
				end
				if above and below then
					s += 1
				end
			end
			local value = math.abs(f - b) + s * 3
			if value < cost then
				best, cost = p, value
			end
		end
		self.plane = { normal = best.normal, distance = best.distance }
	end
	local front, back = {}, {}
	for _, p in polys do
		split(self.plane, p, self.polygons, self.polygons, front, back, self.context)
	end
	if #front > 0 then
		self.front = self.front or Node.new(self.context)
		self.front:build(front, depth + 1)
	end
	if #back > 0 then
		self.back = self.back or Node.new(self.context)
		self.back:build(back, depth + 1)
	end
end
function Node:all(out)
	out = out or {}
	for _, p in self.polygons do
		table.insert(out, p)
	end
	if self.front then
		self.front:all(out)
	end
	if self.back then
		self.back:all(out)
	end
	return out
end
function Node:invert()
	for _, p in self.polygons do
		flip(p)
	end
	if self.plane then
		self.plane.normal = -self.plane.normal
		self.plane.distance = -self.plane.distance
	end
	if self.front then
		self.front:invert()
	end
	if self.back then
		self.back:invert()
	end
	self.front, self.back = self.back, self.front
end
function Node:clip(polys)
	if not self.plane then
		return table.clone(polys)
	end
	local front, back = {}, {}
	for _, p in polys do
		split(self.plane, p, front, back, front, back, self.context)
	end
	if self.front then
		front = self.front:clip(front)
	end
	back = self.back and self.back:clip(back) or {}
	for _, p in back do
		table.insert(front, p)
	end
	return front
end
function Node:clipTo(other)
	self.polygons = other:clip(self.polygons)
	if self.front then
		self.front:clipTo(other)
	end
	if self.back then
		self.back:clipTo(other)
	end
end
local function polygons(mesh, origin, mapping, offset, epsilon)
	local report = mesh:validate()
	assert(
		report.valid and report.closed and report.windingErrors == 0,
		"Boolean input must be a closed, consistently oriented manifold"
	)
	local out = {}
	for _, t in mesh:triangles() do
		local f, vs = mesh.faces[t.face], {}
		for i = 1, 3 do
			local groups = {}
			for name, values in mesh.groups do
				if values[t[i]] then
					groups[name] = values[t[i]]
				end
			end
			vs[i] = {
				p = mesh.vertices[t[i]] - origin,
				corner = U.copy(f.corners[t.corners[i]]),
				weights = U.copy(mesh.weights[t[i]] or {}),
				groups = groups,
				vertexRefs = { { mapping.vertex[t[i]], 1 } },
				cornerRefs = { { mapping.corner[t.face .. ":" .. t.corners[i]], 1 } },
				sourceEdges = {},
			}
			local corner = t.corners[i]
			for _, neighbor in
				{ f.vertices[corner % #f.vertices + 1], f.vertices[(corner - 2) % #f.vertices + 1] }
			do
				vs[i].sourceEdges[mapping.edge[U.edge(t[i], neighbor)]] = true
			end
		end
		local material = f.material
		if offset ~= 0 then
			assert(type(material) == "number", "Material offset requires numeric material IDs")
			material += offset
		end
		local p = polygon(vs, material, mapping.face[t.face], epsilon)
		if p then
			table.insert(out, p)
		end
	end
	if mesh:volume() < 0 then
		for _, p in out do
			flip(p)
		end
	end
	return out
end
local function kdBuild(points, axis)
	if #points == 0 then
		return nil
	end
	local name = ({ "X", "Y", "Z" })[axis]
	table.sort(points, function(a, b)
		return a.p[name] < b.p[name]
	end)
	local middle = math.ceil(#points / 2)
	local left, right = {}, {}
	for i = 1, middle - 1 do
		left[i] = points[i]
	end
	for i = middle + 1, #points do
		table.insert(right, points[i])
	end
	return {
		value = points[middle],
		axis = name,
		left = kdBuild(left, axis % 3 + 1),
		right = kdBuild(right, axis % 3 + 1),
	}
end
local function kdQuery(node, lo, hi, out)
	if not node then
		return
	end
	local p = node.value.p
	if p.X >= lo.X and p.Y >= lo.Y and p.Z >= lo.Z and p.X <= hi.X and p.Y <= hi.Y and p.Z <= hi.Z then
		table.insert(out, node.value)
	end
	if lo[node.axis] <= p[node.axis] then
		kdQuery(node.left, lo, hi, out)
	end
	if hi[node.axis] >= p[node.axis] then
		kdQuery(node.right, lo, hi, out)
	end
end
local function output(polys, origin, epsilon, source)
	local out, hash, points = Mesh.new(), {}, {}
	local maps = {
		vertex = {},
		edge = {},
		face = {},
		corner = {},
		identity = { vertex = false, edge = false, face = false, corner = false },
	}
	local edgeSources = {}
	local function face(vs, cs, records, poly)
		local fid = out:addFace(vs, cs, poly.material)
		maps.face[fid] = { { poly.source, 1 } }
		for i, id in vs do
			maps.corner[fid .. ":" .. i] = records[i].cornerRefs
			local j = i % #vs + 1
			local key = U.edge(id, vs[j])
			for edge in records[i].sourceEdges do
				if records[j].sourceEdges[edge] then
					edgeSources[key] = edgeSources[key] or {}
					edgeSources[key][edge] = true
				end
			end
		end
	end
	local function key(x, y, z)
		return x .. "," .. y .. "," .. z
	end
	local function weld(v)
		local p = v.p
		local x, y, z = math.floor(p.X / epsilon), math.floor(p.Y / epsilon), math.floor(p.Z / epsilon)
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					for _, id in hash[key(x + dx, y + dy, z + dz)] or {} do
						if (points[id].p - p).Magnitude <= epsilon then
							return id
						end
					end
				end
			end
		end
		local id = out:addVertex(p + origin)
		maps.vertex[id] = v.vertexRefs
		points[id] = { id = id, p = p }
		out.weights[id] = U.copy(v.weights)
		for name, value in v.groups do
			out.groups[name] = out.groups[name] or {}
			out.groups[name][id] = value
		end
		local k = key(x, y, z)
		hash[k] = hash[k] or {}
		table.insert(hash[k], id)
		return id
	end
	local records = {}
	for _, p in polys do
		local ids = {}
		for i, v in p.vertices do
			ids[i] = weld(v)
		end
		table.insert(records, { polygon = p, ids = ids })
	end
	local tree = kdBuild(table.clone(points), 1)
	local inserted = 0
	for _, record in records do
		local vs, cs, cornerRecords = {}, {}, {}
		local p = record.polygon
		local present = {}
		for _, id in record.ids do
			present[id] = true
		end
		local added = {}
		for i, a in record.ids do
			local j = i % #record.ids + 1
			local b = record.ids[j]
			local pa, pb = points[a].p, points[b].p
			if a ~= b then
				table.insert(vs, a)
				table.insert(cs, p.vertices[i].corner)
				table.insert(cornerRecords, p.vertices[i])
				local candidates = {}
				local pad = Vector3.one * epsilon
				kdQuery(tree, pa:Min(pb) - pad, pa:Max(pb) + pad, candidates)
				local between = {}
				local delta = pb - pa
				for _, v in candidates do
					if not present[v.id] and not added[v.id] then
						local t = (v.p - pa):Dot(delta) / delta:Dot(delta)
						if t > 0 and t < 1 and (pa + delta * t - v.p).Magnitude <= epsilon then
							table.insert(between, { id = v.id, t = t })
						end
					end
				end
				table.sort(between, function(x, y)
					return x.t < y.t
				end)
				for _, v in between do
					added[v.id] = true
					table.insert(vs, v.id)
					local interpolated = interpolate(p.vertices[i], p.vertices[j], v.t)
					table.insert(cs, interpolated.corner)
					table.insert(cornerRecords, interpolated)
					inserted += 1
				end
			end
		end
		if #vs == 3 then
			face(vs, cs, cornerRecords, p)
		elseif #vs > 3 then
			-- A center fan keeps every conformed boundary edge. Ear clipping near
			-- collinear float32 cut points can otherwise leave zero-area ears.
			local center = points[vs[1]].p
			local merged = {
				p = center,
				corner = cs[1],
				weights = out.weights[vs[1]] or {},
				groups = {},
				vertexRefs = maps.vertex[vs[1]],
				cornerRefs = cornerRecords[1].cornerRefs,
				sourceEdges = cornerRecords[1].sourceEdges,
			}
			for name, g in out.groups do
				merged.groups[name] = g[vs[1]] or 0
			end
			for i = 2, #vs do
				local groups = {}
				for name, g in out.groups do
					groups[name] = g[vs[i]] or 0
				end
				merged = interpolate(merged, {
					p = points[vs[i]].p,
					corner = cs[i],
					weights = out.weights[vs[i]] or {},
					groups = groups,
					vertexRefs = maps.vertex[vs[i]],
					cornerRefs = cornerRecords[i].cornerRefs,
					sourceEdges = cornerRecords[i].sourceEdges,
				}, 1 / i)
			end
			local id = out:addVertex(merged.p + origin)
			maps.vertex[id] = merged.vertexRefs
			out.weights[id] = merged.weights
			for name, value in merged.groups do
				out.groups[name][id] = value
			end
			for i, a in vs do
				local j = i % #vs + 1
				face(
					{ a, vs[j], id },
					{ cs[i], cs[j], merged.corner },
					{ cornerRecords[i], cornerRecords[j], merged },
					p
				)
			end
		end
	end
	out:removeUnused()
	for id in maps.vertex do
		if not out.vertices[id] then
			maps.vertex[id] = nil
		end
	end
	for edgeKey, refs in edgeSources do
		maps.edge[edgeKey] = {}
		for _, edge in U.keys(refs) do
			table.insert(maps.edge[edgeKey], { edge, 1 })
		end
	end
	A.transfer(source, out, maps)
	return out, inserted, maps
end
function B.apply(a, b, operation, options)
	options = options or {}
	local method = options.method or "bsp"
	assert(method == "bsp" or method == "arrangement", "Boolean method must be bsp or arrangement")
	if method == "arrangement" then
		local copies
		copies, options = require(script.Parent.ArrangementSnapshot)({ a, b }, options)
		a, b = copies[1], copies[2]
		assert(
			options.weldEpsilon == nil and options.maxDepth == nil,
			"weldEpsilon and maxDepth apply only to BSP Booleans"
		)
	else
		assert(
			options.windingRule == nil and options.windingRuleA == nil and options.windingRuleB == nil,
			"Winding rules require the arrangement Boolean method"
		)
		assert(
			options.regularization == nil
				and options.tolerance == nil
				and options.classificationOffset == nil
				and options.maxRayDirections == nil
				and options.windingPrecision == nil
				and options.maxExactBits == nil
				and options.maxExactCoefficients == nil,
			"Arrangement precision options require the arrangement Boolean method"
		)
		assert(
			options.vertexBlend == nil or options.vertexBlend == "first",
			"BSP Boolean vertex blending uses the first contributor"
		)
	end
	assert(
		operation == "union" or operation == "intersect" or operation == "subtract",
		"Unknown Boolean operation"
	)
	local function checkIntersections(mesh, stage)
		if not options.checkIntersections then
			return nil
		end
		local config = table.clone(options.intersectionOptions or {})
		if not config.checkpoint and (options.cancelled or options.yieldEvery) then
			config.checkpoint = function()
				assert(not options.cancelled or not options.cancelled(), "Boolean cancelled")
				if options.yieldEvery then
					task.wait()
				end
			end
		end
		local _, diagnostics = require(script.Parent.Intersections).mesh(mesh, config)
		assert(
			diagnostics.complete,
			"Boolean " .. stage .. " intersection validation incomplete: " .. tostring(diagnostics.reason)
		)
		assert(
			diagnostics.intersectionFree,
			"Boolean " .. stage .. " contains crossings, coplanar overlaps or unwelded contacts"
		)
		return diagnostics
	end
	local inputIntersections = { a = checkIntersections(a, "input A"), b = checkIntersections(b, "input B") }
	if method == "arrangement" then
		return require(script.Parent.BooleanArrangement)(a, b, operation, options, inputIntersections)
	end
	assert(not options.cancelled or not options.cancelled(), "Boolean cancelled")
	for _, source in { a, b } do
		local validation = source:validate()
		assert(
			validation.valid and (validation.closed or not next(source.faces)),
			"Boolean input must be closed and valid"
		)
	end
	local joined, forward, inputMaps = require(script.Parent.BooleanSources)(a, b, options.materialOffsetB)
	if not next(a.faces) or not next(b.faces) then
		local result = Mesh.new()
		local maps = {
			vertex = {},
			edge = {},
			face = {},
			corner = {},
			identity = { vertex = false, edge = false, face = false, corner = false },
		}
		if operation == "union" or (operation == "subtract" and next(a.faces)) then
			local source = next(a.faces) and a or b
			local valid = source:validate()
			assert(not next(source.faces) or (valid.valid and valid.closed), "Boolean input must be closed")
			result = source:clone():removeUnused()
			local original = forward[source == a and "a" or "b"]
			for _, domain in { "vertex", "edge", "face", "corner" } do
				for id in A.keys(result, domain) do
					maps[domain][id] = { { original[domain][id], 1 } }
				end
			end
			if source == b and (options.materialOffsetB or 0) ~= 0 then
				for _, f in result.faces do
					f.material += options.materialOffsetB or 0
				end
			end
		end
		A.transfer(joined, result, maps)
		local validation = result:validate()
		return result,
			{
				method = "bsp",
				operation = operation,
				complete = validation.valid and (not next(result.faces) or validation.closed),
				maps = maps,
				inputMaps = inputMaps,
				epsilon = options.epsilon or 0,
				work = 0,
				insertedEdgeVertices = 0,
				validation = validation,
				inputIntersections = options.checkIntersections and inputIntersections or nil,
				intersections = checkIntersections(result, "output"),
				empty = not next(result.faces),
			}
	end
	local alo, ahi = a:bounds()
	local blo, bhi = b:bounds()
	local lo, hi = alo:Min(blo), ahi:Max(bhi)
	local epsilon = options.epsilon or math.max((hi - lo).Magnitude * 1e-6, 1e-6)
	assert(U.finite(epsilon) and epsilon > 0, "Positive finite epsilon required")
	local weldEpsilon = options.weldEpsilon or epsilon * 4
	assert(
		U.finite(weldEpsilon) and weldEpsilon >= epsilon,
		"Weld epsilon must be finite and at least epsilon"
	)
	local origin = (lo + hi) / 2
	local context = {
		epsilon = epsilon,
		work = 0,
		maxWork = options.maxWork or 2000000,
		maxPolygons = options.maxPolygons or 100000,
		maxDepth = options.maxDepth or 256,
		cancelled = options.cancelled,
		yieldEvery = options.yieldEvery,
	}
	local pa = polygons(a, origin, forward.a, 0, epsilon)
	local pb = polygons(b, origin, forward.b, options.materialOffsetB or 0, epsilon)
	local left, right = Node.new(context), Node.new(context)
	left:build(pa)
	right:build(pb)
	if operation == "union" then
		left:clipTo(right)
		right:clipTo(left)
		right:invert()
		right:clipTo(left)
		right:invert()
		left:build(right:all())
	elseif operation == "subtract" then
		left:invert()
		left:clipTo(right)
		right:clipTo(left)
		right:invert()
		right:clipTo(left)
		right:invert()
		left:build(right:all())
		left:invert()
	else
		left:invert()
		right:clipTo(left)
		right:invert()
		left:clipTo(right)
		right:clipTo(left)
		left:build(right:all())
		left:invert()
	end
	local mesh, inserted, maps = output(left:all(), origin, weldEpsilon, joined)
	local validation = mesh:validate()
	local empty = U.count(mesh.faces) == 0
	assert(
		options.allowInvalid
			or empty
			or (validation.valid and validation.closed and validation.windingErrors == 0),
		"Boolean output failed manifold validation; adjust epsilon or repair touching/degenerate input"
	)
	return mesh,
		{
			method = "bsp",
			operation = operation,
			complete = validation.valid and (empty or validation.closed),
			maps = maps,
			inputMaps = inputMaps,
			epsilon = epsilon,
			weldEpsilon = weldEpsilon,
			work = context.work,
			insertedEdgeVertices = inserted,
			validation = validation,
			inputIntersections = options.checkIntersections and inputIntersections or nil,
			intersections = checkIntersections(mesh, "output"),
			empty = empty,
		}
end
function B.union(a, b, options)
	return B.apply(a, b, "union", options)
end
function B.intersect(a, b, options)
	return B.apply(a, b, "intersect", options)
end
function B.subtract(a, b, options)
	return B.apply(a, b, "subtract", options)
end
return B
