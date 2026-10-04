-- Exact native-coordinate reflection and atomic edge-orbit descriptions.
local U = require(script.Parent.Util)
local X = require(script.Parent.ExpansionArithmetic)
local S = {}
local function coordinate(p, axis)
	return axis == "X" and p.X or axis == "Y" and p.Y or p.Z
end
local function key(p)
	local function number(v)
		return v == 0 and "0" or string.format("%.17g", v)
	end
	return number(p.X) .. "," .. number(p.Y) .. "," .. number(p.Z)
end
local function triangle(a, b, c)
	if a <= b and a <= c then
		return a .. ":" .. b .. ":" .. c
	end
	if b <= a and b <= c then
		return b .. ":" .. c .. ":" .. a
	end
	return c .. ":" .. a .. ":" .. b
end
function S.reflect(p, settings)
	local axis, origin = settings.axis, settings.origin or 0
	local value = 2 * origin - coordinate(p, axis)
	local result =
		Vector3.new(axis == "X" and value or p.X, axis == "Y" and value or p.Y, axis == "Z" and value or p.Z)
	if not U.vector(result) then
		return nil
	end
	local sum = X.add({ coordinate(p, axis) }, { coordinate(result, axis) })
	if X.sign(X.subtract(sum, X.multiply({ origin }, { 2 }))) ~= 0 then
		return nil
	end
	return result
end
function S.build(mesh, settings, visit)
	if settings == nil then
		return nil
	end
	assert(type(settings) == "table", "Decimation symmetry must be an axis-plane record")
	assert(
		settings.axis == "X" or settings.axis == "Y" or settings.axis == "Z",
		"Invalid decimation symmetry axis"
	)
	assert(
		settings.origin == nil
			or type(settings.origin) == "number"
				and U.finite(settings.origin)
				and math.abs(settings.origin) <= 3.4028234663852886e38,
		"Invalid decimation symmetry origin"
	)
	local positions, map, faces = {}, {}, {}
	for id, p in mesh.vertices do
		visit(1)
		local k = key(p)
		if positions[k] then
			return nil, "ambiguousSymmetryVertex"
		end
		positions[k] = id
	end
	for id, p in mesh.vertices do
		visit(1)
		local mirrored = S.reflect(p, settings)
		local other = mirrored and positions[key(mirrored)]
		if not other then
			return nil, "asymmetricPositions"
		end
		map[id] = other
	end
	for id, other in map do
		if map[other] ~= id then
			return nil, "nonInvolutiveSymmetry"
		end
	end
	for _, f in mesh.faces do
		faces[triangle(f.vertices[1], f.vertices[2], f.vertices[3])] = true
	end
	for _, f in mesh.faces do
		visit(1)
		local a, b, c = map[f.vertices[1]], map[f.vertices[2]], map[f.vertices[3]]
		if not faces[triangle(a, c, b)] then
			return nil, "asymmetricTriangulation"
		end
	end
	return map
end
function S.orbit(a, b, map)
	if not map then
		return { kind = "single", a = a, b = b }
	end
	local ma, mb = map[a], map[b]
	if ma == a and mb == b then
		return { kind = "single", a = a, b = b }
	end
	if ma == b and mb == a then
		return { kind = "crossing", a = a, b = b }
	end
	if ma == a then
		return { kind = "shared", a = a, b = b, other = mb }
	end
	if mb == b then
		return { kind = "shared", a = b, b = a, other = ma }
	end
	return { kind = "pair", a = a, b = b, ma = ma, mb = mb }
end
return S
