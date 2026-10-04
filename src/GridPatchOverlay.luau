-- Exact small-integer overlays and outward rational affine displacement bounds.
-- Zero-chart-area boundary ears are extra native triangles. Splitting such a
-- triangle at the boundary midpoint maps it to the source's two-segment boundary;
-- the maximum displacement is the midpoint's distance from the endpoint chord.
local X = require(script.Parent.ExpansionArithmetic)
local I = require(script.Parent.DirectedInterval)
local O = {}
local function gcd(a, b)
	a, b = math.abs(a), math.abs(b)
	while b ~= 0 do
		a, b = b, a % b
	end
	return a
end
local function point(x, y, d)
	if d < 0 then
		x, y, d = -x, -y, -d
	end
	local divisor = gcd(gcd(x, y), d)
	return { x / divisor, y / divisor, d / divisor }
end
local function determinant(a, b, c)
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
end
local function side(a, b, p)
	return (b[1] - a[1]) * (p[2] - a[2] * p[3]) - (b[2] - a[2]) * (p[1] - a[1] * p[3])
end
local function inside(t, p)
	for i, a in t do
		if side(a, t[i % 3 + 1], p) < 0 then
			return false
		end
	end
	return true
end
function O.samples(a, b, visit)
	local output, seen = {}, {}
	local function add(p)
		local key = p[1] .. ":" .. p[2] .. ":" .. p[3]
		if not seen[key] then
			seen[key] = true
			table.insert(output, p)
		end
	end
	for _, pair in { { a, b }, { b, a } } do
		for _, p in pair[1] do
			visit(1)
			local q = { p[1], p[2], 1 }
			if inside(pair[2], q) then
				add(q)
			end
		end
	end
	for i, p in a do
		local q = a[i % 3 + 1]
		local dx, dy = q[1] - p[1], q[2] - p[2]
		for j, r in b do
			visit(1)
			local s = b[j % 3 + 1]
			local ex, ey = s[1] - r[1], s[2] - r[2]
			local denominator = dx * ey - dy * ex
			local numerator = (r[1] - p[1]) * ey - (r[2] - p[2]) * ex
			local other = (r[1] - p[1]) * dy - (r[2] - p[2]) * dx
			if denominator < 0 then
				denominator, numerator, other = -denominator, -numerator, -other
			end
			if
				denominator > 0
				and numerator >= 0
				and numerator <= denominator
				and other >= 0
				and other <= denominator
			then
				add(
					point(
						p[1] * denominator + dx * numerator,
						p[2] * denominator + dy * numerator,
						denominator
					)
				)
			end
		end
	end
	return output
end
local function orientation(a, b, c)
	return a[1] * (b[2] * c[3] - b[3] * c[2])
		- a[2] * (b[1] * c[3] - b[3] * c[1])
		+ a[3] * (b[1] * c[2] - b[2] * c[1])
end
function O.positive(samples)
	if #samples < 3 then
		return false
	end
	for i = 3, #samples do
		if orientation(samples[1], samples[2], samples[i]) ~= 0 then
			return true
		end
	end
	return false
end
local function weights(t, p)
	local area = determinant(t[1], t[2], t[3])
	assert(area > 0, "Positive chart triangle required")
	return { side(t[2], t[3], p), side(t[3], t[1], p), side(t[1], t[2], p) }, area * p[3]
end
local function numerator(triangle, p, positions)
	local w, d = weights(triangle.uv, p)
	local out = { { 0 }, { 0 }, { 0 } }
	for i, id in triangle.ids do
		local v = positions[id]
		for axis, value in { v.X, v.Y, v.Z } do
			out[axis] = X.add(out[axis], X.multiply({ value }, { w[i] }))
		end
	end
	return out, d
end
function O.distance(a, b, p, positions)
	local av, ad = numerator(a, p, positions)
	local bv, bd = numerator(b, p, positions)
	local squared = { 0, 0 }
	for axis = 1, 3 do
		local exact = X.subtract(X.multiply(av[axis], { bd }), X.multiply(bv[axis], { ad }))
		if X.sign(exact) ~= 0 then
			local sum = { 0, 0 }
			for _, value in exact do
				sum = I.add(sum, { value, value })
			end
			local divided = I.div(sum, { ad * bd, ad * bd })
			squared = I.add(squared, I.square(divided))
		end
	end
	return squared[2] == 0 and 0 or I.sqrt(squared)[2]
end
local function flap(triangle, positions)
	for axis = 1, 2 do
		local other = 3 - axis
		local value = triangle.uv[1][axis]
		if (value == 0 or value == 4) and triangle.uv[2][axis] == value and triangle.uv[3][axis] == value then
			local entries = { 1, 2, 3 }
			table.sort(entries, function(a, b)
				return triangle.uv[a][other] < triangle.uv[b][other]
			end)
			if
				triangle.uv[entries[1]][other] ~= 0
				or triangle.uv[entries[2]][other] ~= 2
				or triangle.uv[entries[3]][other] ~= 4
			then
				return nil
			end
			local a, m, b =
				positions[triangle.ids[entries[1]]],
				positions[triangle.ids[entries[2]]],
				positions[triangle.ids[entries[3]]]
			local squared = { 0, 0 }
			for _, v in { { a.X, m.X, b.X }, { a.Y, m.Y, b.Y }, { a.Z, m.Z, b.Z } } do
				local exact = X.subtract(X.multiply({ v[2] }, { 2 }), X.add({ v[1] }, { v[3] }))
				if X.sign(exact) ~= 0 then
					local sum = { 0, 0 }
					for _, x in exact do
						sum = I.add(sum, { x, x })
					end
					squared = I.add(squared, I.square(I.div(sum, { 2, 2 })))
				end
			end
			return squared[2] == 0 and 0 or I.sqrt(squared)[2], { axis = axis, value = value }
		end
	end
	return nil
end
function O.bound(source, target, positions, visit)
	local area, maximum = 0, 0
	local positive, flaps = {}, {}
	for i, t in target do
		for _, p in t.uv do
			assert(
				(p[1] == 0 or p[1] == 2 or p[1] == 4) and (p[2] == 0 or p[2] == 2 or p[2] == 4),
				"Noncanonical UV"
			)
		end
		local det = determinant(t.uv[1], t.uv[2], t.uv[3])
		if det < 0 then
			return nil, "reversedChart"
		end
		if det == 0 then
			local bound, side = flap(t, positions)
			if not bound then
				return nil, "degenerateChart"
			end
			maximum = math.max(maximum, bound)
			flaps[i] = side
		else
			area += det
			for _, j in positive do
				if O.positive(O.samples(t.uv, target[j].uv, visit)) then
					return nil, "overlappingChart"
				end
			end
			table.insert(positive, i)
		end
	end
	if area ~= 32 then
		return nil, "incompleteChart"
	end
	local overlaps, flapPairs, sampleCount = {}, {}, 0
	for i, a in source do
		for _, j in positive do
			local b = target[j]
			local samples = O.samples(a.uv, b.uv, visit)
			if O.positive(samples) then
				table.insert(overlaps, { i, j })
			end
			for _, p in samples do
				visit(1)
				sampleCount += 1
				maximum = math.max(maximum, O.distance(a, b, p, positions))
			end
		end
		for j, side in flaps do
			for k, p in a.uv do
				visit(1)
				local q = a.uv[k % 3 + 1]
				if
					p[side.axis] == side.value
					and q[side.axis] == side.value
					and p[3 - side.axis] ~= q[3 - side.axis]
				then
					table.insert(flapPairs, { i, j })
					break
				end
			end
		end
	end
	return maximum, { overlaps = overlaps, flapPairs = flapPairs, samples = sampleCount }
end
return O
