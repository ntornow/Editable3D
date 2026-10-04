--!strict
-- Shared deterministic helpers. No services or instances are created on require.
local U = {}
-- Sorted keys. Callers pass homogeneous number or string keys.
function U.keys(t: { [any]: any }): { any }
	local r = {}
	for k in t do
		table.insert(r, k)
	end
	table.sort(r)
	return r
end
function U.copy<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end
	local r = {}
	for k, v in t :: any do
		r[k] = U.copy(v)
	end
	return r :: any
end
function U.finite(x: number): boolean
	return x == x and math.abs(x) < math.huge
end
function U.vector(v: any): boolean
	return typeof(v) == "Vector3" and U.finite(v.X) and U.finite(v.Y) and U.finite(v.Z)
end
function U.unit(v: Vector3, fallback: Vector3?): Vector3
	return v.Magnitude > 1e-12 and v.Unit or (fallback or Vector3.yAxis)
end
function U.edge(a: number, b: number): string
	return a < b and a .. ":" .. b or b .. ":" .. a
end
function U.weight(mask: { [any]: number }?, id: any): number
	if mask == nil then
		return 1
	end
	return math.clamp(mask[id] or 0, 0, 1)
end
function U.smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end
function U.count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end
function U.integer(n: any, min: number?): number
	assert(type(n) == "number" and n % 1 == 0 and n >= (min or 0), "Expected integer >= " .. (min or 0))
	return n
end
function U.frame(tangent: Vector3, up: Vector3?): (Vector3, Vector3, Vector3)
	local z = U.unit(tangent)
	local x = (up or Vector3.yAxis):Cross(z)
	if x.Magnitude < 1e-8 then
		x = Vector3.xAxis:Cross(z)
	end
	x = x.Unit
	return x, z:Cross(x), z
end
-- Interpolates numbers, or any value with :Lerp (Vector2, Vector3, Color3, CFrame).
function U.mix(a: any, b: any, t: number): any
	if typeof(a) == "number" then
		return a + (b - a) * t
	end
	return a:Lerp(b, t)
end
return U
