local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Edit = require(script.Parent.MeshEditCore)
local UV = {}
function UV.islands(mesh, options)
	local Core = require(script.Parent.UVIslandCore)
	local context = Core.prepare(mesh, options)
	local report = Core.summary(context)
	assert(not context.options.requireComplete or report.complete, "UV island discovery incomplete")
	return report.islands, report
end
function UV.analyze(mesh, options)
	return require(script.Parent.UVAnalysis).run(require(script.Parent.UVIslandCore).prepare(mesh, options))
end
function UV.transformIslands(mesh, transforms, options)
	return require(script.Parent.UVIslandEdit).transform(mesh, transforms, options)
end
function UV.equalizeDensity(mesh, options)
	return require(script.Parent.UVIslandEdit).density(mesh, options)
end
function UV.packIslands(mesh, options)
	return require(script.Parent.UVPacking).run(mesh, options)
end
function UV.relax(mesh, options)
	return require(script.Parent.UVRelax).run(mesh, options)
end
function UV.seamsFromIslands(mesh, options)
	local context = require(script.Parent.UVIslandCore).prepare(mesh, options)
	local complete = true
	for _, island in context.islands do
		complete = complete and #island.missing == 0
	end
	assert(not context.options.requireComplete or complete, "UV seam discovery incomplete")
	local out = context.mesh:clone()
	local name = context.options.attribute or "uv_seam"
	local channel = out.attributes[name]
	if channel then
		assert(
			channel.domain == "edge" and channel.dataType == "boolean",
			"UV seams require a boolean edge channel"
		)
	else
		out = require(script.Parent.Attributes).create(out, name, "edge", "boolean", false)
		channel = out.attributes[name]
	end
	channel.values = {}
	for key in out:topology().edges do
		context.visit(1)
		channel.values[key] = context.boundaries[key] == true
	end
	return out, { complete = complete, seams = U.copy(context.boundaries), work = context.work }
end
function UV.planar(mesh, frame, scale)
	frame = frame or CFrame.identity
	scale = scale or Vector2.one
	assert(scale.X ~= 0 and scale.Y ~= 0)
	local out = mesh:clone()
	for _, f in out.faces do
		for i, id in f.vertices do
			local p = frame:PointToObjectSpace(out.vertices[id])
			f.corners[i].uv = Vector2.new(p.X / scale.X + 0.5, p.Y / scale.Y + 0.5)
		end
	end
	return out
end
function UV.cylindrical(mesh, center, height)
	assert(height > 0)
	center = center or Vector3.zero
	local out = mesh:clone()
	for _, f in out.faces do
		local minU, maxU = math.huge, -math.huge
		for i, id in f.vertices do
			local p = out.vertices[id] - center
			local u = math.atan2(p.Z, p.X) / (2 * math.pi) + 0.5
			minU = math.min(minU, u)
			maxU = math.max(maxU, u)
			f.corners[i].uv = Vector2.new(u, p.Y / height + 0.5)
		end
		if maxU - minU > 0.5 then
			for _, c in f.corners do
				if c.uv.X < 0.5 then
					c.uv += Vector2.xAxis
				end
			end
		end
	end
	return out
end
function UV.spherical(mesh, center)
	center = center or Vector3.zero
	local out = mesh:clone()
	for _, f in out.faces do
		local minU, maxU = math.huge, -math.huge
		for i, id in f.vertices do
			local p = U.unit(out.vertices[id] - center)
			local u = math.atan2(p.Z, p.X) / (2 * math.pi) + 0.5
			minU = math.min(minU, u)
			maxU = math.max(maxU, u)
			f.corners[i].uv = Vector2.new(u, math.acos(math.clamp(p.Y, -1, 1)) / math.pi)
		end
		if maxU - minU > 0.5 then
			for _, c in f.corners do
				if c.uv.X < 0.5 then
					c.uv += Vector2.xAxis
				end
			end
		end
	end
	return out
end
function UV.faceCharts(mesh, padding)
	-- Deterministic nonoverlapping planar chart per polygon, not LSCM.
	padding = padding or 0.04
	assert(padding >= 0 and padding < 0.5)
	local out = mesh:clone()
	local ids = U.keys(out.faces)
	local columns = math.ceil(math.sqrt(#ids))
	if #ids == 0 then
		return out
	end
	for index, fid in ids do
		local f = out.faces[fid]
		local n = out:faceNormal(fid)
		local x, y = U.frame(n)
		local coords = {}
		local lo = Vector2.new(math.huge, math.huge)
		local hi = -lo
		for i, id in f.vertices do
			local p = out.vertices[id]
			local uv = Vector2.new(p:Dot(x), p:Dot(y))
			coords[i] = uv
			lo = lo:Min(uv)
			hi = hi:Max(uv)
		end
		local extent = hi - lo
		local length = math.max(extent.X, extent.Y, 1e-10)
		local cell = Vector2.new((index - 1) % columns, math.floor((index - 1) / columns))
		for i, uv in coords do
			f.corners[i].uv = (cell + Vector2.one * 0.5 + (uv - (lo + hi) * 0.5) / length * (1 - 2 * padding))
				/ columns
		end
	end
	return out
end
function UV.transform(mesh, scale, offset, angle)
	angle = angle or 0
	local c, s = math.cos(angle), math.sin(angle)
	local out = mesh:clone()
	for _, f in out.faces do
		for _, corner in f.corners do
			local p = (corner.uv or Vector2.zero) * scale
			corner.uv = Vector2.new(c * p.X - s * p.Y, s * p.X + c * p.Y) + offset
		end
	end
	return out
end
function UV.validate(mesh)
	local missing, degenerate = 0, 0
	for _, t in mesh:triangles() do
		local f = mesh.faces[t.face]
		local a, b, c = f.corners[t.corners[1]].uv, f.corners[t.corners[2]].uv, f.corners[t.corners[3]].uv
		if not a or not b or not c then
			missing += 1
		else
			local x, y = b - a, c - a
			if math.abs(x.X * y.Y - x.Y * y.X) < 1e-12 then
				degenerate += 1
			end
		end
	end
	return {
		valid = missing == 0 and degenerate == 0,
		missingTriangles = missing,
		degenerateTriangles = degenerate,
	}
end
function UV.splitTiles(mesh, columns, rows, options)
	U.integer(columns, 1)
	U.integer(rows, 1)
	options = options or {}
	A.validate(mesh)
	assert(columns * rows <= U.integer(options.maxTiles or 4096, 1), "UV tile budget exceeded")
	local maxWork = U.integer(options.maxWork or 2000000, 1)
	local maxVertices = U.integer(options.maxVertices or 500000, 1)
	local maxFaces = U.integer(options.maxFaces or 500000, 1)
	local work, vertices, faces = 0, 0, 0
	local function checkpoint()
		assert(not options.cancelled or not options.cancelled(), "UV tiling cancelled")
		if options.checkpoint then
			options.checkpoint({ work = work, vertices = vertices, faces = faces })
		end
	end
	local function step()
		work += 1
		assert(work <= maxWork, "UV tiling work budget exceeded")
		if work % 256 == 0 then
			checkpoint()
		end
	end
	checkpoint()
	local Mesh = require(script.Parent.Mesh)
	local tiles = {}
	local triangles = mesh:triangles()
	for _, f in mesh.faces do
		for _, c in f.corners do
			assert(
				c.uv and c.uv.X >= -1e-8 and c.uv.X <= 1 + 1e-8 and c.uv.Y >= -1e-8 and c.uv.Y <= 1 + 1e-8,
				"Texture tiling requires UVs within [0,1]"
			)
		end
	end
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local out = Mesh.new()
			local maps = {
				vertex = {},
				edge = {},
				face = {},
				corner = {},
				identity = { vertex = false, edge = false, face = false, corner = false },
			}
			local pooled = {}
			local tile = 1 + column + columns * row
			local function interpolate(a, b, t, axis, boundary)
				local weights, refs, edges = {}, {}, {}
				for _, r in a.refs do
					weights[r[2]] = (weights[r[2]] or 0) + r[3] * (1 - t)
				end
				for _, r in b.refs do
					weights[r[2]] = (weights[r[2]] or 0) + r[3] * t
				end
				for _, i in U.keys(weights) do
					if weights[i] > 0 then
						table.insert(refs, { a.refs[1][1], i, weights[i] })
					end
				end
				for key in a.edges do
					if b.edges[key] then
						edges[key] = true
					end
				end
				local corner = Edit.corner(mesh, refs)
				local uv = { X = a.uv.X + (b.uv.X - a.uv.X) * t, Y = a.uv.Y + (b.uv.Y - a.uv.Y) * t }
				uv[axis] = boundary
				if corner.normal then
					corner.normal = U.unit(corner.normal)
				end
				local ak, bk = a.key, b.key
				if ak > bk then
					ak, bk = bk, ak
				end
				return {
					key = "(" .. ak .. "," .. bk .. ")" .. axis .. boundary,
					position = a.position:Lerp(b.position, t),
					corner = corner,
					uv = uv,
					refs = refs,
					edges = edges,
				}
			end
			local function clip(poly, axis, boundary, sign)
				local result = {}
				for i, a in poly do
					step()
					local b = poly[i % #poly + 1]
					local da = (a.uv[axis] - boundary) * sign
					local db = (b.uv[axis] - boundary) * sign
					if da >= -1e-10 then
						table.insert(result, a)
					end
					if (da > 1e-10 and db < -1e-10) or (da < -1e-10 and db > 1e-10) then
						table.insert(result, interpolate(a, b, da / (da - db), axis, boundary))
					end
				end
				return result
			end
			for _, tri in triangles do
				step()
				local f = mesh.faces[tri.face]
				local poly = {}
				for i = 1, 3 do
					local corner = U.copy(f.corners[tri.corners[i]])
					local uv = corner.uv
					local ci = tri.corners[i]
					table.insert(poly, {
						key = tri[i] .. "/" .. uv.X .. "," .. uv.Y,
						position = mesh.vertices[tri[i]],
						corner = corner,
						uv = { X = uv.X, Y = uv.Y },
						refs = { { tri.face, ci, 1 } },
						edges = {
							[U.edge(tri[i], f.vertices[ci % #f.vertices + 1])] = true,
							[U.edge(tri[i], f.vertices[(ci - 2) % #f.vertices + 1])] = true,
						},
					})
				end
				poly = clip(poly, "X", column / columns, 1)
				if #poly >= 3 then
					poly = clip(poly, "X", (column + 1) / columns, -1)
				end
				if #poly >= 3 then
					poly = clip(poly, "Y", row / rows, 1)
				end
				if #poly >= 3 then
					poly = clip(poly, "Y", (row + 1) / rows, -1)
				end
				if #poly >= 3 then
					local vs, cs, records = {}, {}, {}
					local seen = {}
					for _, p in poly do
						if not pooled[p.key] then
							vertices += 1
							assert(vertices <= maxVertices, "UV tiling vertex budget exceeded")
							pooled[p.key] = out:addVertex(p.position)
							local refs = {}
							for _, r in p.refs do
								table.insert(refs, { mesh.faces[r[1]].vertices[r[2]], r[3] })
							end
							maps.vertex[pooled[p.key]] = refs
						end
						local id = pooled[p.key]
						if not seen[id] then
							seen[id] = true
							table.insert(vs, id)
							table.insert(records, p)
							local c = U.copy(p.corner)
							c.uv = Vector2.new(p.uv.X * columns - column, p.uv.Y * rows - row)
							table.insert(cs, c)
						end
					end
					if #vs >= 3 then
						local area = Vector3.zero
						for i, id in vs do
							area += out.vertices[id]:Cross(out.vertices[vs[i % #vs + 1]])
						end
						if area.Magnitude > 1e-10 then
							faces += 1
							assert(faces <= maxFaces, "UV tiling face budget exceeded")
							local fid = out:addFace(vs, cs, tile)
							maps.face[fid] = { { tri.face, 1 } }
							for i, record in records do
								local refs = {}
								for _, r in record.refs do
									table.insert(refs, { r[1] .. ":" .. r[2], r[3] })
								end
								maps.corner[fid .. ":" .. i] = refs
								local j = i % #records + 1
								for key in record.edges do
									if records[j].edges[key] then
										maps.edge[U.edge(vs[i], vs[j])] = { { key, 1 } }
									end
								end
							end
						end
					end
				end
			end
			if next(out.faces) then
				out:removeUnused()
				for id in maps.vertex do
					if not out.vertices[id] then
						maps.vertex[id] = nil
					end
				end
				A.transfer(mesh, out, maps)
				for name in mesh.groups do
					out.groups[name] = {}
				end
				A.vertexData(mesh, out, maps.vertex)
				assert(
					out:validate().valid,
					"UV tile construction collapsed or disconnected a vertex fan at native precision"
				)
				table.insert(tiles, { mesh = out, tile = tile, column = column, row = row })
			end
		end
	end
	checkpoint()
	return tiles
end
return UV
