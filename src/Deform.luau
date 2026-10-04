local U = require(script.Parent.Util)
local Spatial = require(script.Parent.Spatial)
local D = {}
function D.masked(mesh, operation, options)
	return require(script.Parent.DeformMasked)(mesh, operation, options)
end
function D.map(mesh, callback, mask)
	local out = mesh:clone()
	for id, p in mesh.vertices do
		local q = callback(p, id)
		assert(U.vector(q), "Deformation returned invalid position")
		out.vertices[id] = p:Lerp(q, U.weight(mask, id))
	end
	return out:recalculateNormals()
end
function D.transform(mesh, frame, scale)
	scale = scale or Vector3.one
	assert(scale.X ~= 0 and scale.Y ~= 0 and scale.Z ~= 0, "Scale must be nonsingular")
	local out = D.map(mesh, function(p)
		return frame:PointToWorldSpace(p * scale)
	end)
	if scale.X * scale.Y * scale.Z < 0 then
		out = require(script.Parent.Topology).reverse(out)
	end
	return out
end
function D.twist(mesh, radians, lo, hi, mask)
	assert(hi > lo)
	return D.map(mesh, function(p)
		local a = radians * (p.Y - lo) / (hi - lo)
		return Vector3.new(p.X * math.cos(a) - p.Z * math.sin(a), p.Y, p.X * math.sin(a) + p.Z * math.cos(a))
	end, mask)
end
function D.taper(mesh, bottom, top, lo, hi, mask)
	assert(hi > lo)
	return D.map(mesh, function(p)
		local s = bottom + (top - bottom) * math.clamp((p.Y - lo) / (hi - lo), 0, 1)
		return Vector3.new(p.X * s, p.Y, p.Z * s)
	end, mask)
end
function D.bend(mesh, curvature, mask)
	if math.abs(curvature) < 1e-10 then
		return mesh:clone()
	end
	return D.map(mesh, function(p)
		local a = p.Y * curvature
		local r = 1 / curvature + p.X
		return Vector3.new(math.cos(a) * r - 1 / curvature, math.sin(a) * r, p.Z)
	end, mask)
end
function D.lattice(mesh, lo, hi, controls, mask)
	assert(#controls == 8 and hi.X > lo.X and hi.Y > lo.Y and hi.Z > lo.Z)
	return D.map(mesh, function(p)
		local t = (p - lo) / (hi - lo)
		local x, y, z = math.clamp(t.X, 0, 1), math.clamp(t.Y, 0, 1), math.clamp(t.Z, 0, 1)
		local a = controls[1]:Lerp(controls[2], x):Lerp(controls[3]:Lerp(controls[4], x), y)
		local b = controls[5]:Lerp(controls[6], x):Lerp(controls[7]:Lerp(controls[8], x), y)
		return p + a:Lerp(b, z) -- controls are displacement vectors in x-fast order
	end, mask)
end
function D.shrinkwrap(mesh, target, offset, mask, maxDistance)
	local index = Spatial.new(target)
	return D.map(mesh, function(p)
		local h = index:closest(p, maxDistance)
		return h and h.position + h.normal * (offset or 0) or p
	end, mask)
end
function D.contact(mesh, field, clearance, mask, iterations)
	clearance = clearance or 0
	local epsilon = 1e-4
	return D.map(mesh, function(p)
		for _ = 1, iterations or 8 do
			local d = field(p)
			if d >= clearance - 1e-6 then
				break
			end
			local x, y, z = Vector3.xAxis * epsilon, Vector3.yAxis * epsilon, Vector3.zAxis * epsilon
			local g = Vector3.new(
				field(p + x) - field(p - x),
				field(p + y) - field(p - y),
				field(p + z) - field(p - z)
			) / (2 * epsilon)
			if g.Magnitude < 1e-10 then
				break
			end
			p += g * (clearance - d) / g:Dot(g)
		end
		return p
	end, mask)
end
function D.rbf(mesh, handles, radius, mask)
	assert(radius > 0 and #handles > 0)
	local n = #handles
	local matrix = {}
	local rhs = {}
	local function kernel(d)
		local r = d / radius
		return math.exp(-r * r)
	end
	for i, h in handles do
		matrix[i] = {}
		rhs[i] = h.to - h.from
		for j, k in handles do
			matrix[i][j] = kernel((h.from - k.from).Magnitude)
		end
	end
	-- Pivoted Gaussian elimination, shared factorization for three coordinates.
	for col = 1, n do
		local pivot = col
		for row = col + 1, n do
			if math.abs(matrix[row][col]) > math.abs(matrix[pivot][col]) then
				pivot = row
			end
		end
		assert(math.abs(matrix[pivot][col]) > 1e-12, "Duplicate or ill-conditioned RBF handles")
		matrix[col], matrix[pivot] = matrix[pivot], matrix[col]
		rhs[col], rhs[pivot] = rhs[pivot], rhs[col]
		local div = matrix[col][col]
		for j = col, n do
			matrix[col][j] /= div
		end
		rhs[col] /= div
		for row = 1, n do
			if row ~= col then
				local factor = matrix[row][col]
				for j = col, n do
					matrix[row][j] -= factor * matrix[col][j]
				end
				rhs[row] -= rhs[col] * factor
			end
		end
	end
	return D.map(mesh, function(p)
		local q = p
		for i, h in handles do
			q += rhs[i] * kernel((p - h.from).Magnitude)
		end
		return q
	end, mask)
end
function D.simple(mesh, mode, amount, options)
	return require(script.Parent.DeformOperations).simple(mesh, mode, amount, options)
end
function D.shear(mesh, factor, options)
	return require(script.Parent.DeformOperations).shear(mesh, factor, options)
end
function D.cast(mesh, shape, options)
	return require(script.Parent.DeformOperations).cast(mesh, shape, options)
end
function D.warp(mesh, from, to, options)
	return require(script.Parent.DeformOperations).warp(mesh, from, to, options)
end
function D.taperProfile(mesh, profile, options)
	return require(script.Parent.DeformOperations).taper(mesh, profile, options)
end
function D.curve(mesh, curve, options)
	return require(script.Parent.DeformCurve)(mesh, curve, options)
end
return D
