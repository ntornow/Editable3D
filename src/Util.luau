-- Shared deterministic helpers. No services or instances are created on require.
local U = {}
function U.keys(t)
	local r = {}
	for k in t do
		table.insert(r, k)
	end
	table.sort(r)
	return r
end
function U.copy(t)
	if type(t) ~= "table" then
		return t
	end
	local r = {}
	for k, v in t do
		r[k] = U.copy(v)
	end
	return r
end
function U.finite(x)
	return x == x and math.abs(x) < math.huge
end
function U.vector(v)
	return typeof(v) == "Vector3" and U.finite(v.X) and U.finite(v.Y) and U.finite(v.Z)
end
function U.unit(v, fallback)
	return v.Magnitude > 1e-12 and v.Unit or (fallback or Vector3.yAxis)
end
function U.edge(a, b)
	return a < b and a .. ":" .. b or b .. ":" .. a
end
function U.weight(mask, id)
	return mask == nil and 1 or math.clamp(mask[id] or 0, 0, 1)
end
function U.smooth(x)
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end
function U.count(t)
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end
function U.integer(n, min)
	assert(type(n) == "number" and n % 1 == 0 and n >= (min or 0), "Expected integer >= " .. (min or 0))
	return n
end
function U.frame(tangent, up)
	local z = U.unit(tangent)
	local x = (up or Vector3.yAxis):Cross(z)
	if x.Magnitude < 1e-8 then
		x = Vector3.xAxis:Cross(z)
	end
	x = x.Unit
	return x, z:Cross(x), z
end
function U.mix(a, b, t)
	if typeof(a) == "number" then
		return a + (b - a) * t
	end
	return a:Lerp(b, t)
end
return U
