local F = {}
function F.sphere(center, radius)
	assert(radius > 0)
	return function(p)
		return (p - center).Magnitude - radius
	end
end
function F.box(center, halfSize)
	assert(halfSize.X > 0 and halfSize.Y > 0 and halfSize.Z > 0)
	return function(p)
		local d = p - center
		local q = Vector3.new(math.abs(d.X), math.abs(d.Y), math.abs(d.Z)) - halfSize
		return q:Max(Vector3.zero).Magnitude + math.min(math.max(q.X, q.Y, q.Z), 0)
	end
end
function F.capsule(a, b, radius)
	assert(radius > 0 and (b - a).Magnitude > 0)
	local ab = b - a
	return function(p)
		local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
		return (p - a - ab * t).Magnitude - radius
	end
end
function F.torus(center, major, minor)
	assert(major > minor and minor > 0)
	return function(p)
		local q = p - center
		return Vector2.new(Vector2.new(q.X, q.Z).Magnitude - major, q.Y).Magnitude - minor
	end
end
function F.plane(point, normal)
	assert(normal.Magnitude > 0)
	normal = normal.Unit
	return function(p)
		return (p - point):Dot(normal)
	end
end
function F.union(a, b)
	return function(p)
		return math.min(a(p), b(p))
	end
end
function F.intersect(a, b)
	return function(p)
		return math.max(a(p), b(p))
	end
end
function F.subtract(a, b)
	return function(p)
		return math.max(a(p), -b(p))
	end
end
function F.smoothUnion(a, b, radius)
	assert(radius > 0)
	return function(p)
		local x, y = a(p), b(p)
		local h = math.clamp(0.5 + 0.5 * (y - x) / radius, 0, 1)
		return y + (x - y) * h - radius * h * (1 - h)
	end
end
function F.offset(field, amount)
	return function(p)
		return field(p) - amount
	end
end
function F.shell(field, thickness)
	assert(thickness > 0)
	return function(p)
		return math.abs(field(p)) - thickness / 2
	end
end
function F.transform(field, frame, scale)
	scale = scale or 1
	assert(scale > 0)
	return function(p)
		return field(frame:PointToObjectSpace(p) / scale) * scale
	end
end
function F.fromMesh(mesh)
	local v = mesh:validate()
	assert(v.valid and v.closed, "Signed distance requires closed oriented manifold mesh")
	local index = require(script.Parent.Spatial).new(mesh)
	return function(p)
		return index:signedDistance(p)
	end
end
return F
