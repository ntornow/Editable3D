local U = require(script.Parent.Util)
local P = {}
P.__index = P
function P.new(seed)
	return setmetatable({ particles = {}, nextId = 1, random = Random.new(seed or 0), time = 0 }, P)
end
function P:emit(count, initializer)
	U.integer(count, 0)
	local ids = {}
	for i = 1, count do
		local p = initializer(self.random, i)
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
function P:step(dt, force, drag)
	assert(dt > 0)
	drag = drag or 0
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
function P:instances(mesh, scale)
	local frames = {}
	for _, id in U.keys(self.particles) do
		local p = self.particles[id]
		table.insert(frames, CFrame.new(p.position) * (p.rotation or CFrame.identity))
	end
	local base = scale and require(script.Parent.Deform).transform(mesh, CFrame.identity, Vector3.one * scale)
		or mesh
	return require(script.Parent.Geometry).instance(base, frames)
end
return P
