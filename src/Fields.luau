--!strict
local Types = require(script.Parent.Types)
local F = {}
export type Field = (Vector3) -> number
function F.sphere(center: Vector3, radius: number): Field
	assert(radius > 0)
	return function(p: Vector3): number
		return (p - center).Magnitude - radius
	end
end
function F.box(center: Vector3, halfSize: Vector3): Field
	assert(halfSize.X > 0 and halfSize.Y > 0 and halfSize.Z > 0)
	return function(p: Vector3): number
		local d = p - center
		local q = Vector3.new(math.abs(d.X), math.abs(d.Y), math.abs(d.Z)) - halfSize
		return q:Max(Vector3.zero).Magnitude + math.min(math.max(q.X, q.Y, q.Z), 0)
	end
end
function F.capsule(a: Vector3, b: Vector3, radius: number): Field
	assert(radius > 0 and (b - a).Magnitude > 0)
	local ab = b - a
	return function(p: Vector3): number
		local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
		return (p - a - ab * t).Magnitude - radius
	end
end
function F.torus(center: Vector3, major: number, minor: number): Field
	assert(major > minor and minor > 0)
	return function(p: Vector3): number
		local q = p - center
		return Vector2.new(Vector2.new(q.X, q.Z).Magnitude - major, q.Y).Magnitude - minor
	end
end
function F.plane(point: Vector3, normal: Vector3): Field
	assert(normal.Magnitude > 0)
	normal = normal.Unit
	return function(p: Vector3): number
		return (p - point):Dot(normal)
	end
end
function F.union(a: Field, b: Field): Field
	return function(p: Vector3): number
		return math.min(a(p), b(p))
	end
end
function F.intersect(a: Field, b: Field): Field
	return function(p: Vector3): number
		return math.max(a(p), b(p))
	end
end
function F.subtract(a: Field, b: Field): Field
	return function(p: Vector3): number
		return math.max(a(p), -b(p))
	end
end
function F.smoothUnion(a: Field, b: Field, radius: number): Field
	assert(radius > 0)
	return function(p: Vector3): number
		local x, y = a(p), b(p)
		local h = math.clamp(0.5 + 0.5 * (y - x) / radius, 0, 1)
		return y + (x - y) * h - radius * h * (1 - h)
	end
end
function F.offset(field: Field, amount: number): Field
	return function(p: Vector3): number
		return field(p) - amount
	end
end
function F.shell(field: Field, thickness: number): Field
	assert(thickness > 0)
	return function(p: Vector3): number
		return math.abs(field(p)) - thickness / 2
	end
end
function F.transform(field: Field, frame: CFrame, scale: number?): Field
	local scale: number = scale or 1
	assert(scale > 0)
	return function(p: Vector3): number
		return field(frame:PointToObjectSpace(p) / scale) * scale
	end
end
function F.fromMesh(mesh: Types.Mesh): Field
	local v = mesh:validate()
	assert(v.valid and v.closed, "Signed distance requires closed oriented manifold mesh")
	local index = require(script.Parent.Spatial).new(mesh)
	return function(p: Vector3): number
		return index:signedDistance(p)
	end
end
return F
