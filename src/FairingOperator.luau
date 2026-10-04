-- Private fixed-reference uniform or cotangent stiffness and lumped mass.
local F = {}
function F.build(points, triangles, weights, visit)
	local n = #points
	local mass = table.create(n, 0)
	local edges = {}
	for _, triangle in triangles do
		visit(1)
		local a, b, c = points[triangle[1]], points[triangle[2]], points[triangle[3]]
		local x, y, z = b[1] - a[1], b[2] - a[2], b[3] - a[3]
		local u, v, w = c[1] - a[1], c[2] - a[2], c[3] - a[3]
		local cx, cy, cz = y * w - z * v, z * u - x * w, x * v - y * u
		local scale = math.max(math.abs(cx), math.abs(cy), math.abs(cz))
		local twice = scale > 0 and scale * math.sqrt((cx / scale) ^ 2 + (cy / scale) ^ 2 + (cz / scale) ^ 2)
			or 0
		assert(
			twice > 0 and twice < math.huge,
			"Degenerate or numerically unresolved fairing reference triangle"
		)
		for _, id in triangle do
			mass[id] += twice / 6
		end
		for i = 1, 3 do
			visit(1)
			local ia, ib, ic = triangle[i], triangle[i % 3 + 1], triangle[(i + 1) % 3 + 1]
			local pa, pb, pc = points[ia], points[ib], points[ic]
			local ax, ay, az = pa[1] - pc[1], pa[2] - pc[2], pa[3] - pc[3]
			local bx, by, bz = pb[1] - pc[1], pb[2] - pc[2], pb[3] - pc[3]
			local lo, hi = math.min(ia, ib), math.max(ia, ib)
			local key = lo .. ":" .. hi
			local edge = edges[key] or { a = lo, b = hi, weight = 0 }
			edge.weight = weights == "uniform" and 1
				or edge.weight + 0.5 * (ax * bx + ay * by + az * bz) / twice
			edges[key] = edge
		end
	end
	local ordered = {}
	for _, edge in edges do
		table.insert(ordered, edge)
	end
	table.sort(ordered, function(a, b)
		return a.a == b.a and a.b < b.b or a.a < b.a
	end)
	local diagonal = table.create(n, 0)
	local negative = 0
	for _, edge in ordered do
		visit(1)
		diagonal[edge.a] += edge.weight
		diagonal[edge.b] += edge.weight
		if edge.weight < 0 then
			negative += 1
		end
	end
	local inverseMass = {}
	for i = 1, n do
		visit(1)
		if weights == "uniform" then
			mass[i] = 1
		end
		inverseMass[i] = mass[i] > 0 and 1 / mass[i] or 0
	end
	local model = {
		diagonal = diagonal,
		mass = mass,
		inverseMass = inverseMass,
		edges = ordered,
		negativeWeights = negative,
	}
	function model.laplace(values)
		local result = table.create(n, 0)
		for _, edge in ordered do
			visit(1)
			local difference = edge.weight * (values[edge.a] - values[edge.b])
			result[edge.a] += difference
			result[edge.b] -= difference
		end
		return result
	end
	function model.apply(values, order)
		local result = model.laplace(values)
		if order == 2 then
			for i = 1, n do
				visit(1)
				result[i] *= inverseMass[i]
			end
			result = model.laplace(result)
		end
		return result
	end
	function model.hessianDiagonal(order)
		if order == 1 then
			return table.clone(diagonal)
		end
		local result = {}
		for i = 1, n do
			visit(1)
			result[i] = diagonal[i] ^ 2 * inverseMass[i]
		end
		for _, edge in ordered do
			visit(1)
			local square = edge.weight ^ 2
			result[edge.a] += square * inverseMass[edge.b]
			result[edge.b] += square * inverseMass[edge.a]
		end
		return result
	end
	function model.rowBounds(order)
		local bounds = {}
		for i = 1, n do
			visit(1)
			bounds[i] = math.abs(diagonal[i])
		end
		for _, edge in ordered do
			visit(1)
			local weight = math.abs(edge.weight)
			bounds[edge.a] += weight
			bounds[edge.b] += weight
		end
		if order == 1 then
			return bounds
		end
		local result = {}
		for i = 1, n do
			visit(1)
			result[i] = math.abs(diagonal[i]) * inverseMass[i] * bounds[i]
		end
		for _, edge in ordered do
			visit(1)
			local weight = math.abs(edge.weight)
			result[edge.a] += weight * inverseMass[edge.b] * bounds[edge.b]
			result[edge.b] += weight * inverseMass[edge.a] * bounds[edge.a]
		end
		return result
	end
	function model.energy(values, order)
		local energy = 0
		if order == 1 then
			for _, edge in ordered do
				visit(1)
				energy += edge.weight * (values[edge.a] - values[edge.b]) ^ 2
			end
		else
			local laplace = model.laplace(values)
			for i, value in laplace do
				visit(1)
				energy += value * value * inverseMass[i]
			end
		end
		return energy
	end
	return model
end
return F
