--!strict
-- Convex rigid bodies with full inertia tensors and sequential contact impulses.
local C = require(script.Parent.Convex)
local U = require(script.Parent.Util)
type Shape = C.Shape
type Tensor = C.Tensor
export type Body = {
	shape: Shape,
	mass: number,
	inverseMass: number,
	localCenter: Vector3,
	inertia: Tensor,
	inverseInertia: Tensor,
	position: Vector3,
	rotation: CFrame,
	velocity: Vector3,
	angularVelocity: Vector3,
	force: Vector3,
	torque: Vector3,
	friction: number,
	restitution: number,
	linearDamping: number,
	angularDamping: number,
	userData: any, -- caller-owned payload, never inspected
}
export type BodyOptions = {
	restitution: number?,
	friction: number?,
	linearDamping: number?,
	angularDamping: number?,
	userData: any,
}
-- World defaults (given to new) and per-step overrides (given to step/collisions).
export type DynamicsOptions = {
	gravity: Vector3?,
	substeps: number?,
	maxSubsteps: number?,
	velocityIterations: number?,
	positionIterations: number?,
	restitutionThreshold: number?,
	slop: number?,
	positionCorrection: number?,
	maxCorrection: number?,
	filter: ((number, number, Body, Body) -> boolean)?,
	tolerance: number?,
	maxAxes: number?,
	maxContacts: number?,
	parallelTolerance: number?,
}
-- A Convex contact tagged with the two body ids.
export type Manifold = C.OverlapContact
export type Energy = { kinetic: number, potential: number, total: number }
export type StepReport = {
	substeps: number,
	velocityIterations: number,
	positionIterations: number,
	contactPoints: number,
	maxPenetration: number,
}
export type Dynamics = {
	bodies: { [number]: Body },
	nextId: number,
	gravity: Vector3,
	options: DynamicsOptions,
	time: number,
	lastContacts: { Manifold },
	addConvex: (Dynamics, Shape, number, CFrame?, BodyOptions?) -> number,
	addBox: (Dynamics, Vector3, number, CFrame?, BodyOptions?) -> number,
	remove: (Dynamics, number) -> (),
	frame: (Dynamics, number) -> CFrame,
	setFrame: (Dynamics, number, CFrame) -> (),
	impulse: (Dynamics, number, Vector3, Vector3?) -> (),
	angularImpulse: (Dynamics, number, Vector3) -> (),
	force: (Dynamics, number, Vector3, Vector3?) -> (),
	torque: (Dynamics, number, Vector3) -> (),
	velocityAt: (Dynamics, number, Vector3) -> Vector3,
	momentum: (Dynamics) -> (Vector3, Vector3),
	energy: (Dynamics) -> Energy,
	collisions: (Dynamics, DynamicsOptions?) -> { Manifold },
	step: (Dynamics, number, DynamicsOptions?) -> StepReport,
}
type Self = Dynamics
type ContactConstraint = {
	a: Body,
	b: Body,
	normal: Vector3,
	t1: Vector3,
	t2: Vector3,
	ra: Vector3,
	rb: Vector3,
	normalMass: number,
	k11: number,
	k12: number,
	k22: number,
	normalImpulse: number,
	tangentImpulse: Vector2,
	friction: number,
	target: number,
	point: C.ContactPoint,
}
local D = {}
D.__index = D
local function tensorWorld(body: Body, vector: Vector3, inverse: boolean, rotation: CFrame?): Vector3
	local rotation: CFrame = rotation or body.rotation
	return rotation:VectorToWorldSpace(
		C.tensorMultiply(
			inverse and body.inverseInertia or body.inertia,
			rotation:VectorToObjectSpace(vector)
		)
	)
end
local function rotated(rotation: CFrame, angular: Vector3): CFrame
	local angle = angular.Magnitude
	if angle < 1e-12 then
		return rotation
	end
	local r = CFrame.fromAxisAngle(angular / angle, angle) * rotation
	local x = r.RightVector.Unit
	local y = (r.UpVector - x * r.UpVector:Dot(x)).Unit
	return CFrame.fromMatrix(Vector3.zero, x, y, x:Cross(y))
end
local function nonnegative(value: number, name: string): number
	assert(
		type(value) == "number" and U.finite(value) and value >= 0,
		name .. " must be finite and nonnegative"
	)
	return value
end
function D.new(options: DynamicsOptions?): Dynamics
	local options: DynamicsOptions = options or {}
	local gravity = options.gravity or Vector3.new(0, -9.81, 0)
	assert(U.vector(gravity))
	return setmetatable({
		bodies = {},
		nextId = 1,
		gravity = gravity,
		options = table.clone(options),
		time = 0,
		lastContacts = {},
	}, D) :: any
end
function D.addConvex(self: Self, shape: Shape, mass: number, frame: CFrame?, options: BodyOptions?): number
	local options: BodyOptions = options or {}
	local frame: CFrame = frame or CFrame.identity
	local properties = C.massProperties(shape, mass)
	local id = self.nextId
	self.nextId += 1
	local restitution = nonnegative(options.restitution or 0, "Restitution")
	assert(restitution <= 1)
	self.bodies[id] = {
		shape = shape,
		mass = mass,
		inverseMass = mass > 0 and 1 / mass or 0,
		localCenter = properties.center,
		inertia = properties.inertia,
		inverseInertia = properties.inverseInertia,
		position = frame:PointToWorldSpace(properties.center),
		rotation = frame.Rotation,
		velocity = Vector3.zero,
		angularVelocity = Vector3.zero,
		force = Vector3.zero,
		torque = Vector3.zero,
		friction = nonnegative(options.friction or 0.5, "Friction"),
		restitution = restitution,
		linearDamping = nonnegative(options.linearDamping or 0, "Linear damping"),
		angularDamping = nonnegative(options.angularDamping or 0, "Angular damping"),
		userData = options.userData,
	}
	return id
end
function D.addBox(self: Self, size: Vector3, mass: number, frame: CFrame?, options: BodyOptions?): number
	return self:addConvex(C.box(size), mass, frame, options)
end
function D.remove(self: Self, id: number)
	assert(self.bodies[id], "Unknown body")
	self.bodies[id] = nil
end
function D.frame(self: Self, id: number): CFrame
	local b = assert(self.bodies[id], "Unknown body")
	return CFrame.new(b.position) * b.rotation * CFrame.new(-b.localCenter)
end
function D.setFrame(self: Self, id: number, frame: CFrame)
	local b = assert(self.bodies[id], "Unknown body")
	b.position, b.rotation = frame:PointToWorldSpace(b.localCenter), frame.Rotation
end
function D.impulse(self: Self, id: number, impulse: Vector3, point: Vector3?)
	assert(U.vector(impulse) and (point == nil or U.vector(point)))
	local b = assert(self.bodies[id], "Unknown body")
	if b.inverseMass == 0 then
		return
	end
	b.velocity += impulse * b.inverseMass
	if point then
		b.angularVelocity += tensorWorld(b, (point - b.position):Cross(impulse), true)
	end
end
function D.angularImpulse(self: Self, id: number, impulse: Vector3)
	assert(U.vector(impulse))
	local b = assert(self.bodies[id], "Unknown body")
	if b.inverseMass > 0 then
		b.angularVelocity += tensorWorld(b, impulse, true)
	end
end
function D.force(self: Self, id: number, force: Vector3, point: Vector3?)
	assert(U.vector(force) and (point == nil or U.vector(point)))
	local b = assert(self.bodies[id], "Unknown body")
	if b.inverseMass == 0 then
		return
	end
	b.force += force
	if point then
		b.torque += (point - b.position):Cross(force)
	end
end
function D.torque(self: Self, id: number, torque: Vector3)
	assert(U.vector(torque))
	local b = assert(self.bodies[id], "Unknown body")
	if b.inverseMass > 0 then
		b.torque += torque
	end
end
function D.velocityAt(self: Self, id: number, point: Vector3): Vector3
	local b = assert(self.bodies[id], "Unknown body")
	return b.velocity + b.angularVelocity:Cross(point - b.position)
end
function D.momentum(self: Self): (Vector3, Vector3)
	local linear, angular = Vector3.zero, Vector3.zero
	for _, id in U.keys(self.bodies) do
		local b = self.bodies[id]
		local p = b.velocity * b.mass
		linear += p
		angular += b.position:Cross(p) + tensorWorld(b, b.angularVelocity, false)
	end
	return linear, angular
end
function D.energy(self: Self): Energy
	local kinetic, potential = 0, 0
	for _, id in U.keys(self.bodies) do
		local b = self.bodies[id]
		kinetic += 0.5 * b.mass * b.velocity:Dot(b.velocity) + 0.5 * b.angularVelocity:Dot(
			tensorWorld(b, b.angularVelocity, false)
		)
		potential -= b.mass * self.gravity:Dot(b.position)
	end
	return { kinetic = kinetic, potential = potential, total = kinetic + potential }
end
function D.collisions(self: Self, options: DynamicsOptions?): { Manifold }
	local options: DynamicsOptions = options or self.options
	local ids: { number }, transforms: { [number]: CFrame }, bounds: { [number]: { Vector3 } } =
		U.keys(self.bodies), {}, {}
	for _, id in ids do
		transforms[id] = self:frame(id)
		local lo, hi = C.bounds(self.bodies[id].shape, transforms[id])
		bounds[id] = { lo, hi }
	end
	local contacts: { Manifold } = {}
	for i, idA in ids do
		local a = self.bodies[idA]
		for j = i + 1, #ids do
			local idB, b = ids[j], self.bodies[ids[j]]
			if a.inverseMass == 0 and b.inverseMass == 0 then
				continue
			end
			if options.filter and not options.filter(idA, idB, a, b) then
				continue
			end
			local epsilon = options.tolerance or math.max(a.shape.tolerance, b.shape.tolerance)
			local al, ah, bl, bh = bounds[idA][1], bounds[idA][2], bounds[idB][1], bounds[idB][2]
			if
				ah.X + epsilon < bl.X
				or bh.X + epsilon < al.X
				or ah.Y + epsilon < bl.Y
				or bh.Y + epsilon < al.Y
				or ah.Z + epsilon < bl.Z
				or bh.Z + epsilon < al.Z
			then
				continue
			end
			local contact = C.contact(a.shape, transforms[idA], b.shape, transforms[idB], options)
			if contact.overlap then
				contact.bodyA, contact.bodyB = idA, idB
				table.insert(contacts, contact)
			end
		end
	end
	return contacts
end
local function applyPair(a: Body, b: Body, impulse: Vector3, ra: Vector3, rb: Vector3)
	if a.inverseMass > 0 then
		a.velocity -= impulse * a.inverseMass
		a.angularVelocity -= tensorWorld(a, ra:Cross(impulse), true)
	end
	if b.inverseMass > 0 then
		b.velocity += impulse * b.inverseMass
		b.angularVelocity += tensorWorld(b, rb:Cross(impulse), true)
	end
end
local function relative(a: Body, b: Body, ra: Vector3, rb: Vector3): Vector3
	return b.velocity + b.angularVelocity:Cross(rb) - a.velocity - a.angularVelocity:Cross(ra)
end
local function effective(a: Body, b: Body, ra: Vector3, rb: Vector3, x: Vector3, y: Vector3): number
	return (a.inverseMass + b.inverseMass) * x:Dot(y)
		+ ra:Cross(x):Dot(tensorWorld(a, ra:Cross(y), true))
		+ rb:Cross(x):Dot(tensorWorld(b, rb:Cross(y), true))
end
local function constraints(
	world: Dynamics,
	manifolds: { Manifold },
	restitutionThreshold: number
): { ContactConstraint }
	local list: { ContactConstraint } = {}
	for _, manifold in manifolds do
		local a, b = world.bodies[manifold.bodyA :: number], world.bodies[manifold.bodyB :: number]
		local n = manifold.normal
		local t1, t2 = U.frame(n)
		for _, point in manifold.contacts do
			local ra, rb = point.position - a.position, point.position - b.position
			local initial = relative(a, b, ra, rb):Dot(n)
			local k11, k12, k22 =
				effective(a, b, ra, rb, t1, t1),
				effective(a, b, ra, rb, t1, t2),
				effective(a, b, ra, rb, t2, t2)
			table.insert(list, {
				a = a,
				b = b,
				normal = n,
				t1 = t1,
				t2 = t2,
				ra = ra,
				rb = rb,
				normalMass = effective(a, b, ra, rb, n, n),
				k11 = k11,
				k12 = k12,
				k22 = k22,
				normalImpulse = 0,
				tangentImpulse = Vector2.zero,
				friction = math.sqrt(a.friction * b.friction),
				target = initial < -restitutionThreshold
						and -math.max(a.restitution, b.restitution) * initial
					or 0,
				point = point,
			})
		end
	end
	return list
end
local function solveVelocity(c: ContactConstraint)
	local a, b, ra, rb, n = c.a, c.b, c.ra, c.rb, c.normal
	local vn = relative(a, b, ra, rb):Dot(n)
	local accumulated = math.max(0, c.normalImpulse + (c.target - vn) / c.normalMass)
	applyPair(a, b, n * (accumulated - c.normalImpulse), ra, rb)
	c.normalImpulse = accumulated
	local velocity = relative(a, b, ra, rb)
	local v1, v2 = velocity:Dot(c.t1), velocity:Dot(c.t2)
	local determinant = c.k11 * c.k22 - c.k12 * c.k12
	if determinant <= 1e-20 then
		return
	end
	local delta =
		Vector2.new((-c.k22 * v1 + c.k12 * v2) / determinant, (c.k12 * v1 - c.k11 * v2) / determinant)
	local tangent = c.tangentImpulse + delta
	local limit = c.friction * c.normalImpulse
	if tangent.Magnitude > limit then
		tangent = tangent.Unit * limit
	end
	local change = tangent - c.tangentImpulse
	applyPair(a, b, c.t1 * change.X + c.t2 * change.Y, ra, rb)
	c.tangentImpulse = tangent
	c.point.normalImpulse, c.point.tangentImpulse = c.normalImpulse, tangent
end
local function correctPosition(a: Body, b: Body, point: Vector3, normal: Vector3, amount: number)
	local ra, rb = point - a.position, point - b.position
	local denominator = effective(a, b, ra, rb, normal, normal)
	if denominator <= 0 then
		return
	end
	local impulse = normal * (amount / denominator)
	if a.inverseMass > 0 then
		a.position -= impulse * a.inverseMass
		a.rotation = rotated(a.rotation, -tensorWorld(a, ra:Cross(impulse), true))
	end
	if b.inverseMass > 0 then
		b.position += impulse * b.inverseMass
		b.rotation = rotated(b.rotation, tensorWorld(b, rb:Cross(impulse), true))
	end
end
function D.step(self: Self, dt: number, options: DynamicsOptions?): StepReport
	assert(dt > 0 and U.finite(dt), "Positive finite dt required")
	local options: DynamicsOptions = options or {}
	local config = table.clone(self.options)
	for k, v in options do
		(config :: any)[k] = v
	end
	local substeps = U.integer(config.substeps or 4, 1)
	local velocityIterations = U.integer(config.velocityIterations or 12, 1)
	local positionIterations = U.integer(config.positionIterations or 4, 0)
	assert(
		substeps <= (config.maxSubsteps or 1024) and velocityIterations <= 1000 and positionIterations <= 1000,
		"Dynamics iteration budget exceeded"
	)
	local threshold = nonnegative(config.restitutionThreshold or 0.5, "Restitution threshold")
	local slop = nonnegative(config.slop or 0.0005, "Penetration slop")
	local correction = config.positionCorrection or 0.4
	assert(correction > 0 and correction <= 1)
	local maxCorrection = config.maxCorrection or 0.2
	assert(maxCorrection > 0 and U.finite(maxCorrection))
	local h = dt / substeps
	local report: StepReport = {
		substeps = substeps,
		velocityIterations = velocityIterations,
		positionIterations = positionIterations,
		contactPoints = 0,
		maxPenetration = 0,
	}
	for _ = 1, substeps do
		for _, id in U.keys(self.bodies) do
			local b = self.bodies[id]
			if b.inverseMass == 0 then
				continue
			end
			b.velocity = (b.velocity + (self.gravity + b.force * b.inverseMass) * h)
				* math.exp(-b.linearDamping * h)
			b.position += b.velocity * h
			local momentum = (tensorWorld(b, b.angularVelocity, false) + b.torque * h)
				* math.exp(-b.angularDamping * h)
			local omega = tensorWorld(b, momentum, true)
			-- Fixed-count midpoint orientation estimate; world angular momentum is retained.
			for _ = 1, 2 do
				omega = tensorWorld(b, momentum, true, rotated(b.rotation, omega * (h * 0.5)))
			end
			b.rotation = rotated(b.rotation, omega * h)
			b.angularVelocity = tensorWorld(b, momentum, true)
		end
		local manifolds = self:collisions(config)
		local contacts = constraints(self, manifolds, threshold)
		report.contactPoints += #contacts
		for _, m in manifolds do
			report.maxPenetration = math.max(report.maxPenetration, m.penetration)
		end
		for _ = 1, velocityIterations do
			for _, contact in contacts do
				solveVelocity(contact)
			end
		end
		for _ = 1, positionIterations do
			for _, m in self:collisions(config) do
				local a, b = self.bodies[m.bodyA :: number], self.bodies[m.bodyB :: number]
				for _, point in m.contacts do
					local error = math.min(maxCorrection, math.max(0, point.penetration - slop))
					correctPosition(a, b, point.position, m.normal, error * correction / #m.contacts)
				end
			end
		end
		self.lastContacts = manifolds
	end
	for _, b in self.bodies do
		b.force, b.torque = Vector3.zero, Vector3.zero
	end
	self.time += dt
	return report
end
return D
