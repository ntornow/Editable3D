--!strict
local U = require(script.Parent.Util)
local A = require(script.Parent.AttributeCore)
local Edit = require(script.Parent.MeshEditCore)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
-- Options pass through to the island/packing/relaxation engines; see UV_MODELING.md.
export type UVOptions = { [string]: any }
-- Island, packing and relaxation reports carry operation-specific fields; see UV_MODELING.md.
export type UVReport = { [string]: any }
export type SeamReport = { complete: boolean, seams: { [string]: boolean }, work: number }
export type UVValidation = { valid: boolean, missingTriangles: number, degenerateTriangles: number }
export type TileProgress = { work: number, vertices: number, faces: number }
export type TileOptions = {
	maxTiles: number?,
	maxWork: number?,
	maxVertices: number?,
	maxFaces: number?,
	cancelled: (() -> boolean)?,
	checkpoint: ((TileProgress) -> ())?,
}
export type Tile = { mesh: Mesh, tile: number, column: number, row: number }
-- axis: cylinder axis through center (default +Y). seamAngle: angle about the axis where u wraps,
-- measured from the frame's X toward Z (default pi, the -X side). normalize rescales u and v
-- independently to fill [margin, 1 - margin] (margin default 0).
export type CylindricalOptions = { axis: Vector3?, seamAngle: number?, normalize: boolean?, margin: number? }
-- A clipped polygon point while splitting triangles across tile boundaries.
type ClipPoint = {
	key: string,
	position: Vector3,
	corner: Types.Corner,
	uv: { X: number, Y: number },
	refs: { { number } },
	edges: { [string]: boolean },
}
local UV = {}
function UV.islands(mesh: Mesh, options: UVOptions?): ({ any }, UVReport)
	local Core = require(script.Parent.UVIslandCore)
	local context = Core.prepare(mesh, options)
	local report = Core.summary(context)
	assert(not context.options.requireComplete or report.complete, "UV island discovery incomplete")
	return report.islands, report
end
function UV.analyze(mesh: Mesh, options: UVOptions?): UVReport
	return require(script.Parent.UVAnalysis).run(require(script.Parent.UVIslandCore).prepare(mesh, options))
end
-- transforms are per-island plans; see UV_MODELING.md.
function UV.transformIslands(mesh: Mesh, transforms: any, options: UVOptions?): (Mesh, UVReport)
	return require(script.Parent.UVIslandEdit).transform(mesh, transforms, options)
end
function UV.equalizeDensity(mesh: Mesh, options: UVOptions?): (Mesh, UVReport)
	return require(script.Parent.UVIslandEdit).density(mesh, options)
end
function UV.packIslands(mesh: Mesh, options: UVOptions?): (Mesh, UVReport)
	return require(script.Parent.UVPacking).run(mesh, options)
end
function UV.relax(mesh: Mesh, options: UVOptions?): (Mesh, UVReport)
	return require(script.Parent.UVRelax).run(mesh, options)
end
function UV.seamsFromIslands(mesh: Mesh, options: UVOptions?): (Mesh, SeamReport)
	local context = require(script.Parent.UVIslandCore).prepare(mesh, options)
	local complete = true
	for _, island in context.islands do
		complete = complete and #island.missing == 0
	end
	assert(not context.options.requireComplete or complete, "UV seam discovery incomplete")
	local out: Mesh = context.mesh:clone()
	local name = context.options.attribute or "uv_seam"
	local channel = out.attributes[name]
	if channel then
		assert(
			channel.domain == "edge" and channel.dataType == "boolean",
			"UV seams require a boolean edge channel"
		)
	else
		out = require(script.Parent.Attributes).create(out, name, "edge", "boolean", false)
		channel = out.attributes[name] :: Types.Channel
	end
	channel.values = {}
	for key in out:topology().edges do
		context.visit(1)
		channel.values[key] = context.boundaries[key] == true
	end
	return out, { complete = complete, seams = U.copy(context.boundaries), work = context.work }
end
function UV.planar(mesh: Mesh, frame: CFrame?, scale: Vector2?): Mesh
	local frame: CFrame = frame or CFrame.identity
	local scale: Vector2 = scale or Vector2.one
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
local function axisFrame(axis: Vector3): CFrame
	assert(axis.Magnitude > 0, "Cylinder axis must be nonzero")
	local y = axis.Unit
	if (y - Vector3.yAxis).Magnitude < 1e-9 then
		return CFrame.identity
	end
	local x = (if math.abs(y.X) < 0.9 then Vector3.xAxis else Vector3.zAxis):Cross(y).Unit
	x = y:Cross(x).Unit
	return CFrame.fromMatrix(Vector3.zero, x, y, x:Cross(y))
end
local function fitUVs(out: Mesh, margin: number)
	assert(margin >= 0 and margin < 0.5, "UV margin must be in [0, 0.5)")
	local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for _, f in out.faces do
		for _, c in f.corners do
			local uv = c.uv :: Vector2
			lo, hi = lo:Min(uv), hi:Max(uv)
		end
	end
	local span = hi - lo
	local sx, sy = if span.X > 0 then 1 / span.X else 0, if span.Y > 0 then 1 / span.Y else 0
	local fill = 1 - 2 * margin
	for _, f in out.faces do
		for _, c in f.corners do
			local t = (c.uv :: Vector2) - lo
			c.uv = Vector2.new(margin + fill * t.X * sx, margin + fill * t.Y * sy)
		end
	end
end
local function cylindricalWith(mesh: Mesh, center: Vector3, height: number, o: CylindricalOptions): Mesh
	local frame = axisFrame(o.axis or Vector3.yAxis)
	local seam = o.seamAngle or math.pi
	local out = mesh:clone()
	for _, f in out.faces do
		local minU, maxU = math.huge, -math.huge
		for i, id in f.vertices do
			local p = frame:VectorToObjectSpace(out.vertices[id] - center)
			local u = ((math.atan2(p.Z, p.X) - seam) % (2 * math.pi)) / (2 * math.pi)
			minU = math.min(minU, u)
			maxU = math.max(maxU, u)
			f.corners[i].uv = Vector2.new(u, p.Y / height + 0.5)
		end
		if maxU - minU > 0.5 then
			for _, c in f.corners do
				local uv = c.uv :: Vector2
				if uv.X < 0.5 then
					c.uv = uv + Vector2.xAxis
				end
			end
		end
	end
	if o.normalize then
		fitUVs(out, o.margin or 0)
	end
	return out
end
function UV.cylindrical(mesh: Mesh, center: Vector3?, height: number, options: CylindricalOptions?): Mesh
	assert(height > 0)
	local center: Vector3 = center or Vector3.zero
	if options then
		return cylindricalWith(mesh, center, height, options)
	end
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
				local uv = c.uv :: Vector2 -- assigned for every corner in the loop above
				if uv.X < 0.5 then
					c.uv = uv + Vector2.xAxis
				end
			end
		end
	end
	return out
end
-- Box projection: each face is projected along the axis of `frame` closest to its normal, into
-- one of up to six rectangular charts (+x, -x, +y, -y, +z, -z) that share a single scale (texels
-- per stud stay uniform) and are shelf-packed into [margin, 1 - margin]. Works on any face soup:
-- no welding, manifold or orientation requirement, unlike island-based packing. Charts can
-- overlap only where a surface folds back over itself along the same axis.
export type BoxOptions = { margin: number? }
export type BoxReport = { scale: number, charts: number }
function UV.box(mesh: Mesh, frame: CFrame?, options: BoxOptions?): (Mesh, BoxReport)
	local frame: CFrame = frame or CFrame.identity
	local margin = options and options.margin or 0.01
	assert(margin >= 0 and margin < 0.25, "Box UV margin must be in [0, 0.25)")
	local out = mesh:clone()
	type Chart = { lo: Vector2, hi: Vector2, faces: { number } }
	local charts: { [string]: Chart } = {}
	local order: { string } = {}
	for _, fid in U.keys(out.faces) do
		local f = out.faces[fid]
		local normal = out:faceNormal(fid)
		local n = frame:VectorToObjectSpace(normal)
		local ax, ay, az = math.abs(n.X), math.abs(n.Y), math.abs(n.Z)
		local key: string
		if ax >= ay and ax >= az then
			key = if n.X >= 0 then "+x" else "-x"
		elseif ay >= az then
			key = if n.Y >= 0 then "+y" else "-y"
		else
			key = if n.Z >= 0 then "+z" else "-z"
		end
		local chart = charts[key]
		if not chart then
			chart = {
				lo = Vector2.new(math.huge, math.huge),
				hi = Vector2.new(-math.huge, -math.huge),
				faces = {},
			}
			charts[key] = chart
			table.insert(order, key)
		end
		for i, v in f.vertices do
			local q = frame:PointToObjectSpace(out.vertices[v])
			local uv: Vector2
			if key == "+x" then
				uv = Vector2.new(-q.Z, -q.Y)
			elseif key == "-x" then
				uv = Vector2.new(q.Z, -q.Y)
			elseif key == "+y" then
				uv = Vector2.new(q.X, q.Z)
			elseif key == "-y" then
				uv = Vector2.new(q.X, -q.Z)
			elseif key == "+z" then
				uv = Vector2.new(q.X, -q.Y)
			else
				uv = Vector2.new(-q.X, -q.Y)
			end
			f.corners[i].uv = uv
			chart.lo, chart.hi = chart.lo:Min(uv), chart.hi:Max(uv)
		end
		table.insert(chart.faces, fid)
	end
	table.sort(order, function(a: string, b: string): boolean
		local ha, hb = charts[a].hi.Y - charts[a].lo.Y, charts[b].hi.Y - charts[b].lo.Y
		if ha ~= hb then
			return ha > hb
		end
		return a < b
	end)
	-- shelf packing at a shared scale; bisect the largest scale that fits
	local function place(scale: number): { [string]: Vector2 }?
		local x, y, row = margin, margin, 0
		local positions: { [string]: Vector2 } = {}
		for _, key in order do
			local size = (charts[key].hi - charts[key].lo) * scale
			if size.X > 1 - 2 * margin then
				return nil
			end
			if x + size.X > 1 - margin then
				x, y, row = margin, y + row + margin, 0
			end
			positions[key] = Vector2.new(x, y)
			x += size.X + margin
			row = math.max(row, size.Y)
		end
		if y + row > 1 - margin then
			return nil
		end
		return positions
	end
	local lo, hi = 0, 1
	while hi < 1e9 and place(hi) do
		hi *= 2
	end
	for _ = 1, 48 do
		local mid = (lo + hi) / 2
		if place(mid) then
			lo = mid
		else
			hi = mid
		end
	end
	local positions = place(lo)
	if positions then
		for key, chart in charts do
			for _, fid in chart.faces do
				for _, corner in out.faces[fid].corners do
					corner.uv = positions[key] + ((corner.uv :: Vector2) - chart.lo) * lo
				end
			end
		end
	end
	return out, { scale = lo, charts = #order }
end
function UV.spherical(mesh: Mesh, center: Vector3?): Mesh
	local center: Vector3 = center or Vector3.zero
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
				local uv = c.uv :: Vector2 -- assigned for every corner in the loop above
				if uv.X < 0.5 then
					c.uv = uv + Vector2.xAxis
				end
			end
		end
	end
	return out
end
function UV.faceCharts(mesh: Mesh, padding: number?): Mesh
	-- Deterministic nonoverlapping planar chart per polygon, not LSCM.
	local padding: number = padding or 0.04
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
		local coords: { Vector2 } = {}
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
-- scale multiplies UVs (a Vector2 or a uniform number) before rotation by angle and offset.
function UV.transform(mesh: Mesh, scale: Vector2 | number, offset: Vector2, angle: number?): Mesh
	local angle: number = angle or 0
	local c, s = math.cos(angle), math.sin(angle)
	local out = mesh:clone()
	for _, f in out.faces do
		for _, corner in f.corners do
			local p: Vector2 = (corner.uv or Vector2.zero) * (scale :: any)
			corner.uv = Vector2.new(c * p.X - s * p.Y, s * p.X + c * p.Y) + offset
		end
	end
	return out
end
function UV.validate(mesh: Mesh): UVValidation
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
function UV.splitTiles(mesh: Mesh, columns: number, rows: number, options: TileOptions?): { Tile }
	U.integer(columns, 1)
	U.integer(rows, 1)
	local options: TileOptions = options or {}
	A.validate(mesh)
	assert(columns * rows <= U.integer(options.maxTiles or 4096, 1), "UV tile budget exceeded")
	local maxWork = U.integer(options.maxWork or 2000000, 1)
	local maxVertices = U.integer(options.maxVertices or 500000, 1)
	local maxFaces = U.integer(options.maxFaces or 500000, 1)
	local work, vertices, faces = 0, 0, 0
	local function checkpoint()
		local cancelled = options.cancelled
		assert(not cancelled or not cancelled(), "UV tiling cancelled")
		-- Read after cancelled() runs, matching the original evaluation order.
		local onCheckpoint = options.checkpoint
		if onCheckpoint then
			onCheckpoint({ work = work, vertices = vertices, faces = faces })
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
	local tiles: { Tile } = {}
	local triangles = mesh:triangles()
	for _, f in mesh.faces do
		for _, c in f.corners do
			assert(
				c.uv
					and (c.uv :: Vector2).X >= -1e-8
					and c.uv.X <= 1 + 1e-8
					and c.uv.Y >= -1e-8
					and c.uv.Y <= 1 + 1e-8,
				"Texture tiling requires UVs within [0,1]"
			)
		end
	end
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			local out = Mesh.new()
			local maps: { [string]: any } = {
				vertex = {},
				edge = {},
				face = {},
				corner = {},
				identity = { vertex = false, edge = false, face = false, corner = false },
			}
			local pooled: { [string]: number } = {}
			local tile = 1 + column + columns * row
			local function interpolate(
				a: ClipPoint,
				b: ClipPoint,
				t: number,
				axis: string,
				boundary: number
			): ClipPoint
				local weights: { [number]: number }, refs: { { number } }, edges: { [string]: boolean } =
					{}, {}, {}
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
				(uv :: any)[axis] = boundary
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
			local function clip(
				poly: { ClipPoint },
				axis: string,
				boundary: number,
				sign: number
			): { ClipPoint }
				local result: { ClipPoint } = {}
				for i, a in poly do
					step()
					local b = poly[i % #poly + 1]
					local da = ((a.uv :: any)[axis] - boundary) * sign
					local db = ((b.uv :: any)[axis] - boundary) * sign
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
				local poly: { ClipPoint } = {}
				for i = 1, 3 do
					local corner = U.copy(f.corners[tri.corners[i]])
					local uv = corner.uv :: Vector2
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
					local vs: { number }, cs: { Types.Corner }, records: { ClipPoint } = {}, {}, {}
					local seen: { [number]: boolean } = {}
					for _, p in poly do
						if not pooled[p.key] then
							vertices += 1
							assert(vertices <= maxVertices, "UV tiling vertex budget exceeded")
							pooled[p.key] = out:addVertex(p.position)
							local refs: { { number } } = {}
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
								local refs: { { any } } = {}
								for _, r in record.refs do
									table.insert(refs, { r[1] .. ":" .. r[2], r[3] } :: { any })
								end
								maps.corner[fid .. ":" .. i] = refs
								local j = i % #records + 1
								for key in record.edges do
									if records[j].edges[key] then
										maps.edge[U.edge(vs[i], vs[j])] = { { key, 1 } :: { any } }
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
