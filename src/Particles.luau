--!strict
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
export type Particle = {
	position: Vector3,
	velocity: Vector3,
	age: number,
	lifetime: number,
	rotation: CFrame?,
}
-- What an emit initializer returns; missing velocity/lifetime get defaults.
export type ParticleInit = {
	position: Vector3,
	velocity: Vector3?,
	lifetime: number?,
	rotation: CFrame?,
}
export type Particles = {
	particles: { [number]: Particle },
	nextId: number,
	random: Random,
	time: number,
	emit: (Particles, number, (Random, number) -> ParticleInit) -> { number },
	step: (Particles, number, ((Particle, number) -> Vector3)?, number?) -> Particles,
	instances: (Particles, Mesh, number?) -> Mesh,
}
type Self = Particles
local P = {}
P.__index = P
function P.new(seed: number?): Particles
	return setmetatable({ particles = {}, nextId = 1, random = Random.new(seed or 0), time = 0 }, P) :: any
end
function P.emit(self: Self, count: number, initializer: (Random, number) -> ParticleInit): { number }
	U.integer(count, 0)
	local ids = {}
	for i = 1, count do
		local p: Particle = initializer(self.random, i) :: any
		assert(U.vector(p.position))
		p.velocity = p.velocity or Vector3.zero
		p.age = 0
		p.lifetime = p.lifetime or math.huge
		assert(p.lifetime > 0)
		local id = self.nextId
		self.nextId += 1
		self.particles[id] = p
		table.insert(ids, id)
	end
	return ids
end
function P.step(self: Self, dt: number, force: ((Particle, number) -> Vector3)?, drag: number?): Particles
	assert(dt > 0)
	local drag: number = drag or 0
	assert(drag >= 0)
	for id, p in self.particles do
		p.age += dt
		if p.age >= p.lifetime then
			self.particles[id] = nil
		else
			local acceleration = force and force(p, self.time) or Vector3.zero
			p.velocity = (p.velocity + acceleration * dt) * math.exp(-drag * dt)
			p.position += p.velocity * dt
		end
	end
	self.time += dt
	return self
end
function P.instances(self: Self, mesh: Mesh, scale: number?): Mesh
	local frames = {}
	for _, id in U.keys(self.particles) do
		local p = self.particles[id]
		table.insert(frames, CFrame.new(p.position) * (p.rotation or CFrame.identity))
	end
	local base = scale
			and (require(script.Parent.Deform) :: any).transform(mesh, CFrame.identity, Vector3.one * scale)
		or mesh
	return require(script.Parent.Geometry).instance(base, frames)
end
return P
