-- Small CPU SPH solver. All-pairs neighbors; caller controls CFL timestep and substeps.
local U = require(script.Parent.Util)
local Fluid = {}
Fluid.__index = Fluid
function Fluid.new(options)
	options = options or {}
	local h = options.radius or 0.25
	local rho = options.restDensity or 1000
	assert(h > 0 and rho > 0)
	return setmetatable({
		particles = {},
		radius = h,
		restDensity = rho,
		stiffness = options.stiffness or 200,
		viscosity = options.viscosity or 0.1,
		gravity = options.gravity or Vector3.new(0, -9.81, 0),
		mass = options.mass or rho * h ^ 3 / 8,
		bounds = options.bounds,
		maxParticles = options.maxParticles or 1000,
	}, Fluid)
end
function Fluid:add(position, velocity)
	assert(#self.particles < self.maxParticles and U.vector(position))
	table.insert(
		self.particles,
		{ position = position, velocity = velocity or Vector3.zero, density = 0, pressure = 0 }
	)
	return #self.particles
end
function Fluid:step(dt, substeps)
	assert(dt > 0)
	substeps = substeps or 4
	U.integer(substeps, 1)
	local step = dt / substeps
	local h = self.radius
	local mass = self.mass
	local poly6 = 315 / (64 * math.pi * h ^ 9)
	local spiky = -45 / (math.pi * h ^ 6)
	local visc = 45 / (math.pi * h ^ 6)
	for _ = 1, substeps do
		for _, a in self.particles do
			local density = 0
			for _, b in self.particles do
				local d = a.position - b.position
				local r2 = d:Dot(d)
				if r2 < h * h then
					density += mass * poly6 * (h * h - r2) ^ 3
				end
			end
			a.density = math.max(density, 1e-8)
			a.pressure = self.stiffness * math.max(a.density - self.restDensity, 0)
		end
		local accelerations = {}
		for i, a in self.particles do
			local force = Vector3.zero
			for j, b in self.particles do
				if i ~= j then
					local d = a.position - b.position
					local r = d.Magnitude
					if r > 1e-8 and r < h then
						local gradient = d / r * (spiky * (h - r) ^ 2)
						force -= gradient * (mass * (a.pressure + b.pressure) / (2 * b.density))
						force += (b.velocity - a.velocity) * (self.viscosity * mass / b.density * visc * (h - r))
					end
				end
			end
			accelerations[i] = self.gravity + force / a.density
		end
		for i, a in self.particles do
			a.velocity += accelerations[i] * step
			a.position += a.velocity * step
			if self.bounds then
				local lo, hi = self.bounds[1], self.bounds[2]
				local p, v = {}, {}
				for _, axis in { "X", "Y", "Z" } do
					p[axis] = math.clamp(a.position[axis], lo[axis], hi[axis])
					v[axis] = a.position[axis] ~= p[axis] and -a.velocity[axis] * 0.1 or a.velocity[axis]
				end
				a.position = Vector3.new(p.X, p.Y, p.Z)
				a.velocity = Vector3.new(v.X, v.Y, v.Z)
			end
			assert(U.vector(a.position), "Fluid diverged: reduce timestep or stiffness")
		end
	end
	return self
end
function Fluid:field(radius)
	radius = radius or self.radius * 0.6
	local centers = {}
	for i, p in self.particles do
		centers[i] = p.position
	end
	return function(p)
		local d = math.huge
		for _, c in centers do
			d = math.min(d, (p - c).Magnitude - radius)
		end
		return d
	end
end
return Fluid
