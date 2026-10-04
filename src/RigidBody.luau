-- Deterministic sphere rigid bodies with angular motion and impulse contacts.
local U = require(script.Parent.Util)
local World = {}
World.__index = World
function World.new(options)
	options = options or {}
	return setmetatable(
		{ bodies = {}, colliders = {}, gravity = options.gravity or Vector3.new(0, -9.81, 0), nextId = 1 },
		World
	)
end
function World:addSphere(radius, mass, frame, options)
	assert(radius > 0 and mass >= 0)
	options = options or {}
	frame = frame or CFrame.identity
	local id = self.nextId
	self.nextId += 1
	self.bodies[id] = {
		radius = radius,
		inverseMass = mass > 0 and 1 / mass or 0,
		inverseInertia = mass > 0 and 2.5 / (mass * radius * radius) or 0,
		position = frame.Position,
		rotation = frame.Rotation,
		velocity = Vector3.zero,
		angularVelocity = Vector3.zero,
		restitution = options.restitution or 0,
		friction = options.friction or 0.5,
	}
	return id
end
function World:addCollider(field)
	table.insert(self.colliders, field)
end
function World:impulse(id, impulse, point)
	local b = assert(self.bodies[id])
	b.velocity += impulse * b.inverseMass
	if point then
		b.angularVelocity += (point - b.position):Cross(impulse) * b.inverseInertia
	end
end
function World:frame(id)
	local b = assert(self.bodies[id])
	return CFrame.new(b.position) * b.rotation
end
local function contact(a, b, normal, penetration)
	local wa, wb = a.inverseMass, b and b.inverseMass or 0
	local sum = wa + wb
	if sum == 0 then
		return
	end
	a.position -= normal * (math.max(penetration - 1e-6, 0) * wa / sum)
	if b then
		b.position += normal * (math.max(penetration - 1e-6, 0) * wb / sum)
	end
	local ra, rb = normal * a.radius, b and -normal * b.radius or Vector3.zero
	local va = a.velocity + a.angularVelocity:Cross(ra)
	local vb = b and b.velocity + b.angularVelocity:Cross(rb) or Vector3.zero
	local relative = vb - va
	local vn = relative:Dot(normal)
	if vn >= 0 then
		return
	end
	local restitution = b and math.min(a.restitution, b.restitution) or a.restitution
	local j = -(1 + restitution) * vn / sum
	local impulse = normal * j
	a.velocity -= impulse * wa
	if b then
		b.velocity += impulse * wb
	end
	local tangent = relative - normal * vn
	if tangent.Magnitude < 1e-10 then
		return
	end
	tangent = tangent.Unit
	local denom = sum
		+ a.inverseInertia * ra:Cross(tangent).Magnitude ^ 2
		+ (b and b.inverseInertia * rb:Cross(tangent).Magnitude ^ 2 or 0)
	local mu = b and math.sqrt(a.friction * b.friction) or a.friction
	local jt = math.clamp(-relative:Dot(tangent) / denom, -mu * j, mu * j)
	local friction = tangent * jt
	a.velocity -= friction * wa
	a.angularVelocity -= ra:Cross(friction) * a.inverseInertia
	if b then
		b.velocity += friction * wb
		b.angularVelocity += rb:Cross(friction) * b.inverseInertia
	end
end
function World:step(dt, substeps, iterations)
	assert(dt > 0)
	substeps = substeps or 4
	iterations = iterations or 4
	U.integer(substeps, 1)
	U.integer(iterations, 1)
	local h = dt / substeps
	for _ = 1, substeps do
		for _, b in self.bodies do
			if b.inverseMass > 0 then
				b.velocity += self.gravity * h
				b.position += b.velocity * h
				local speed = b.angularVelocity.Magnitude
				if speed > 1e-10 then
					b.rotation = CFrame.fromAxisAngle(b.angularVelocity / speed, speed * h) * b.rotation
				end
			end
		end
		for _ = 1, iterations do
			local ids = U.keys(self.bodies)
			for i, id in ids do
				local a = self.bodies[id]
				for j = i + 1, #ids do
					local b = self.bodies[ids[j]]
					local d = b.position - a.position
					local distance = d.Magnitude
					if distance < a.radius + b.radius then
						contact(a, b, U.unit(d, Vector3.xAxis), a.radius + b.radius - distance)
					end
				end
				if a.inverseMass > 0 then
					for _, field in self.colliders do
						local distance = field(a.position)
						if distance < a.radius then
							local p = a.position
							local e = 1e-4
							local normal = Vector3.new(
								field(p + Vector3.xAxis * e) - field(p - Vector3.xAxis * e),
								field(p + Vector3.yAxis * e) - field(p - Vector3.yAxis * e),
								field(p + Vector3.zAxis * e) - field(p - Vector3.zAxis * e)
							)
							if normal.Magnitude > 1e-10 then
								contact(a, nil, -normal.Unit, a.radius - distance)
							end
						end
					end
				end
			end
		end
	end
	return self
end
return World
