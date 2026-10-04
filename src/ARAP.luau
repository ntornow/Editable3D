--!strict
-- Local/global edge-spoke ARAP with exact positional anchors and sparse PCG.
local U = require(script.Parent.Util)
local Laplacian = require(script.Parent.Laplacian)
local Registration = require(script.Parent.Registration)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
export type BindOptions = Laplacian.BindOptions
export type SolveOptions = {
	maxIterations: number?,
	linearIterations: number?,
	tolerance: number?,
	linearTolerance: number?,
	initial: Mesh?,
	requireLinearConvergence: boolean?,
	requireConvergence: boolean?,
	recalculateNormals: boolean?,
	checkpoint: ((fraction: number) -> ())?,
}
export type LinearReport = { iterations: number, residual: number, converged: boolean }
export type SolveReport = {
	iterations: number,
	converged: boolean,
	linearConverged: boolean,
	energyHistory: { number },
	linearReports: { LinearReport },
	inactiveVertices: number,
	freeVertices: number,
	anchors: number,
	maximumStep: number?,
	energy: number?,
}
export type Deformer = {
	graph: Laplacian.Graph,
	source: Mesh,
	solve: (Deformer, { [number]: Vector3 }, SolveOptions?) -> (Mesh, SolveReport),
}
type Self = Deformer
local A = {}
A.__index = A

function A.bind(mesh: Mesh, options: BindOptions?): Deformer
	local options: BindOptions = table.clone(options or {})
	options.maxVertices = options.maxVertices or 5000
	local graph = Laplacian.bind(mesh, options)
	return setmetatable({ graph = graph, source = graph.source }, A) :: any
end

function A.solve(self: Self, anchors: { [number]: Vector3 }, options: SolveOptions?): (Mesh, SolveReport)
	local options: SolveOptions = options or {}
	local graph, source = self.graph, self.source
	local n, free: { number }, fixed: { [number]: Vector3 }, inactive = #graph.ids, {}, {}, 0
	local maxIterations = options.maxIterations or 30
	U.integer(maxIterations, 1)
	local linearIterations = options.linearIterations or 512
	U.integer(linearIterations, 1)
	local tolerance, linearTolerance = options.tolerance or 1e-5, options.linearTolerance or 1e-8
	assert(U.finite(tolerance) and tolerance > 0 and U.finite(linearTolerance) and linearTolerance > 0)
	for id, p in anchors do
		assert(graph.index[id], "Unknown ARAP anchor")
		assert(U.vector(p))
		fixed[graph.index[id]] = p
	end
	for _, component in graph.components do
		local found = false
		for _, i in component do
			found = found or (fixed[i] :: Vector3?) ~= nil
		end
		if not found then
			for _, i in component do
				fixed[i] = source.vertices[graph.ids[i]]
				inactive += 1
			end
		end
	end
	for i = 1, n do
		if not fixed[i] then
			table.insert(free, i)
		end
	end
	-- Solve around a local origin so world placement does not loosen residual tolerances.
	local lo, hi = source:bounds()
	local origin = n > 0 and (lo + hi) * 0.5 or Vector3.zero
	local fixedWorld = table.clone(fixed)
	for i, p in fixed do
		fixed[i] = p - origin
	end
	local initial = options.initial or source
	assert(U.count(initial.vertices) == n, "Initial mesh must have identical vertex IDs and topology")
	assert(U.count(initial.faces) == U.count(source.faces), "Initial topology changed")
	for fid, f in source.faces do
		local other = assert(initial.faces[fid], "Initial topology changed")
		assert(#f.vertices == #other.vertices)
		for j, id in f.vertices do
			assert(other.vertices[j] == id, "Initial topology changed")
		end
	end
	local p: { Vector3 }, rest: { Vector3 }, rotations: { CFrame } = {}, {}, {}
	for i, id in graph.ids do
		assert(U.vector(initial.vertices[id]), "Initial position missing or invalid")
		rest[i] = source.vertices[id] - origin
		p[i] = fixed[i] or (initial.vertices[id] - origin)
		rotations[i] = CFrame.identity
	end
	local function localStep()
		for i = 1, n do
			local a: { Vector3 }, b: { Vector3 }, w: { number } = {}, {}, {}
			for _, j in U.keys(graph.rows[i]) do
				table.insert(a, rest[i] - rest[j])
				table.insert(b, p[i] - p[j])
				table.insert(w, graph.rows[i][j])
			end
			if #a > 0 then
				rotations[i] = Registration.rotation(a, b, { weights = w, reference = rotations[i] })
			end
		end
	end
	local function energy(): number
		local value = 0
		for i = 1, n do
			for j, w in graph.rows[i] do
				local d = p[i] - p[j] - rotations[i]:VectorToWorldSpace(rest[i] - rest[j])
				value += w * d:Dot(d) * 0.5
			end
		end
		return value
	end
	-- Vectors are indexed by axis name below.
	local function linearSolve(rhs: { Vector3 }, axis: string): ({ number }, LinearReport)
		local x: { number }, b: { number }, r: { number }, z: { number }, d: { number } = {}, {}, {}, {}, {}
		for i = 1, n do
			x[i] = (p[i] :: any)[axis]
			d[i] = 0
		end
		local function apply(v: { number }): { number }
			local out: { number } = {}
			for _, i in free do
				local sum = graph.diagonal[i] * v[i]
				for j, w in graph.rows[i] do
					if not fixed[j] then
						sum -= w * v[j]
					end
				end
				out[i] = sum
			end
			return out
		end
		local norm = 0
		for _, i in free do
			local value = (rhs[i] :: any)[axis]
			for j, w in graph.rows[i] do
				if fixed[j] then
					value += w * (fixed[j] :: any)[axis]
				end
			end
			b[i] = value
			norm += value * value
		end
		local ax, rz, squared = apply(x), 0, 0
		for _, i in free do
			r[i] = b[i] - ax[i]
			z[i] = r[i] / graph.diagonal[i]
			d[i] = z[i]
			rz += r[i] * z[i]
			squared += r[i] * r[i]
		end
		local threshold = math.max(1e-10, linearTolerance * math.sqrt(norm))
		local used = 0
		for step = 1, linearIterations do
			if math.sqrt(squared) <= threshold then
				break
			end
			local ad = apply(d)
			local dad = 0
			for _, i in free do
				dad += d[i] * ad[i]
			end
			if dad <= 0 or not U.finite(dad) then
				break
			end
			local alpha = rz / dad
			local nextRz = 0
			squared = 0
			for _, i in free do
				x[i] += alpha * d[i]
				r[i] -= alpha * ad[i]
				z[i] = r[i] / graph.diagonal[i]
				squared += r[i] * r[i]
				nextRz += r[i] * z[i]
			end
			local beta = nextRz / rz
			for _, i in free do
				d[i] = z[i] + beta * d[i]
			end
			rz = nextRz
			used = step
		end
		ax = apply(x)
		squared = 0
		for _, i in free do
			squared += (b[i] - ax[i]) ^ 2
		end
		return x,
			{
				iterations = used,
				residual = math.sqrt(squared),
				converged = math.sqrt(squared) <= threshold * 1.01,
			}
	end
	localStep()
	local report: SolveReport = {
		iterations = 0,
		converged = false,
		linearConverged = true,
		energyHistory = { energy() },
		linearReports = {},
		inactiveVertices = inactive,
		freeVertices = #free,
		anchors = U.count(anchors),
	}
	for step = 1, maxIterations do
		local rhs: { Vector3 } = {}
		for i = 1, n do
			local sum = Vector3.zero
			for j, w in graph.rows[i] do
				local e = rest[i] - rest[j]
				sum += (rotations[i]:VectorToWorldSpace(e) + rotations[j]:VectorToWorldSpace(e)) * (w * 0.5)
			end
			rhs[i] = sum
		end
		local coords: { { number } }, linear: { LinearReport } = {}, {}
		for j, axis in { "X", "Y", "Z" } do
			coords[j], linear[j] = linearSolve(rhs, axis)
			report.linearConverged = report.linearConverged and linear[j].converged
		end
		assert(
			report.linearConverged or options.requireLinearConvergence == false,
			"ARAP linear solve did not converge"
		)
		local maximum = 0
		for _, i in free do
			local q = Vector3.new(coords[1][i], coords[2][i], coords[3][i])
			assert(U.vector(q))
			maximum = math.max(maximum, (q - p[i]).Magnitude)
			p[i] = q
		end
		localStep()
		local current = energy()
		table.insert(report.energyHistory, current)
		report.iterations = step
		report.maximumStep = maximum
		report.linearReports = linear
		if options.checkpoint then
			options.checkpoint(step / maxIterations)
		end
		if maximum <= tolerance then
			report.converged = true
			break
		end
	end
	if options.requireConvergence then
		assert(report.converged, "ARAP iteration budget exhausted")
	end
	local out = source:clone()
	for i, id in graph.ids do
		out.vertices[id] = fixedWorld[i] or (p[i] + origin)
	end
	if options.recalculateNormals ~= false then
		out:recalculateNormals()
	end
	report.energy = report.energyHistory[#report.energyHistory]
	return out, report
end
return A
