-- XPBD particles, distance constraints and tetrahedral volume constraints.
local U = require(script.Parent.Util)
local Sim = {}
Sim.__index = Sim
function Sim.new(options)
	options = options or {}
	return setmetatable({
		particles = {},
		constraints = {},
		colliders = {},
		gravity = options.gravity or Vector3.new(0, -9.81, 0),
		damping = options.damping or 0.01,
		nextId = 1,
		time = 0,
	}, Sim)
end
function Sim:addParticle(position, mass)
	assert(U.vector(position) and (mass == nil or mass >= 0))
	local id = self.nextId
	self.nextId += 1
	self.particles[id] =
		{ position = position, velocity = Vector3.zero, inverseMass = mass == 0 and 0 or 1 / (mass or 1) }
	return id
end
function Sim:pin(id, position)
	local p = assert(self.particles[id])
	p.inverseMass = 0
	p.position = position or p.position
	p.velocity = Vector3.zero
end
function Sim:addDistance(a, b, compliance, restLength)
	assert(a ~= b and self.particles[a] and self.particles[b])
	local length = restLength or (self.particles[a].position - self.particles[b].position).Magnitude
	assert(length > 0 and (compliance or 0) >= 0)
	local c = { kind = "distance", a = a, b = b, rest = length, compliance = compliance or 0, lambda = 0 }
	table.insert(self.constraints, c)
	return c
end
function Sim:addVolume(a, b, c, d, compliance)
	local ids = { a, b, c, d }
	local p = {}
	for i, id in ids do
		p[i] = assert(self.particles[id]).position
	end
	local volume = (p[2] - p[1]):Dot((p[3] - p[1]):Cross(p[4] - p[1])) / 6
	assert(math.abs(volume) > 1e-12 and (compliance or 0) >= 0)
	local constraint = { kind = "volume", ids = ids, rest = volume, compliance = compliance or 0, lambda = 0 }
	table.insert(self.constraints, constraint)
	return constraint
end
function Sim:addCollider(field, clearance)
	table.insert(self.colliders, { field = field, clearance = clearance or 0 })
end
function Sim:step(dt, substeps, iterations)
	assert(dt > 0 and U.finite(dt))
	substeps = substeps or 4
	iterations = iterations or 8
	U.integer(substeps, 1)
	U.integer(iterations, 1)
	local h = dt / substeps
	for _ = 1, substeps do
		for _, p in self.particles do
			p.previous = p.position
			if p.inverseMass > 0 then
				p.velocity += self.gravity * h
				p.position += p.velocity * h
			end
		end
		for _, c in self.constraints do
			c.lambda = 0
		end
		for _ = 1, iterations do
			for _, c in self.constraints do
				local alpha = c.compliance / (h * h)
				if c.kind == "distance" then
					local a, b = self.particles[c.a], self.particles[c.b]
					local d = a.position - b.position
					local length = d.Magnitude
					local denom = a.inverseMass + b.inverseMass + alpha
					if length > 1e-12 and denom > 0 then
						local dl = (-(length - c.rest) - alpha * c.lambda) / denom
						local n = d / length
						c.lambda += dl
						a.position += n * (dl * a.inverseMass)
						b.position -= n * (dl * b.inverseMass)
					end
				else
					local ps = {}
					for i, id in c.ids do
						ps[i] = self.particles[id].position
					end
					local a, b, d = ps[2] - ps[1], ps[3] - ps[1], ps[4] - ps[1]
					local g2, g3, g4 = b:Cross(d) / 6, d:Cross(a) / 6, a:Cross(b) / 6
					local grads = { -(g2 + g3 + g4), g2, g3, g4 }
					local denom = alpha
					for i, id in c.ids do
						denom += self.particles[id].inverseMass * grads[i]:Dot(grads[i])
					end
					if denom > 1e-15 then
						local dl = (-(a:Dot(b:Cross(d)) / 6 - c.rest) - alpha * c.lambda) / denom
						c.lambda += dl
						for i, id in c.ids do
							local p = self.particles[id]
							p.position += grads[i] * (p.inverseMass * dl)
						end
					end
				end
			end
			for _, p in self.particles do
				if p.inverseMass > 0 then
					for _, collider in self.colliders do
						local f = collider.field
						local d = f(p.position)
						if d < collider.clearance then
							local q = p.position
							local e = 1e-4
							local g = Vector3.new(
								f(q + Vector3.xAxis * e) - f(q - Vector3.xAxis * e),
								f(q + Vector3.yAxis * e) - f(q - Vector3.yAxis * e),
								f(q + Vector3.zAxis * e) - f(q - Vector3.zAxis * e)
							) / (2 * e)
							if g.Magnitude > 1e-10 then
								p.position += g * (collider.clearance - d) / g:Dot(g)
							end
						end
					end
				end
			end
		end
		for _, p in self.particles do
			p.velocity = (p.position - p.previous) / h * math.exp(-self.damping * h)
		end
		self.time += h
	end
	return self
end
function Sim.fromMesh(mesh, options)
	options = options or {}
	local s = Sim.new(options)
	s.vertexMap = {}
	s.source = mesh:clone()
	for _, id in U.keys(mesh.vertices) do
		s.vertexMap[id] = s:addParticle(mesh.vertices[id], options.mass or 1)
	end
	local edges = {}
	local function spring(a, b, compliance)
		local key = U.edge(a, b)
		if not edges[key] then
			edges[key] = true
			s:addDistance(s.vertexMap[a], s.vertexMap[b], compliance)
		end
	end
	for _, e in mesh:topology().edges do
		spring(e.a, e.b, options.stretchCompliance or 0)
	end
	for _, f in mesh.faces do
		if #f.vertices == 4 then
			spring(f.vertices[1], f.vertices[3], options.shearCompliance or 0)
			spring(f.vertices[2], f.vertices[4], options.shearCompliance or 0)
		end
	end
	if options.bendCompliance then
		local triangles = require(script.Parent.Topology).triangulate(mesh)
		for _, e in triangles:topology().edges do
			if #e.faces == 2 then
				local opposite = {}
				for i, fid in e.faces do
					for _, v in triangles.faces[fid].vertices do
						if v ~= e.a and v ~= e.b then
							opposite[i] = v
						end
					end
				end
				if opposite[1] and opposite[2] then
					spring(opposite[1], opposite[2], options.bendCompliance)
				end
			end
		end
	end
	return s
end
function Sim:toMesh()
	assert(self.source, "Simulation not created from mesh")
	local m = self.source:clone()
	for v, p in self.vertexMap do
		m.vertices[v] = self.particles[p].position
	end
	return m:recalculateNormals()
end
return Sim
