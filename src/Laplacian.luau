--!strict
-- Harmonic/biharmonic displacement interpolation with exact positional anchors.
-- Sparse matrix-free PCG; rotations are not estimated (not ARAP).
local U = require(script.Parent.Util)
local Types = require(script.Parent.Types)
type Mesh = Types.Mesh
export type BindOptions = { maxVertices: number?, weights: string? }
export type SolveOptions = {
	order: number?,
	maxIterations: number?,
	tolerance: number?,
	checkpoint: ((fraction: number) -> ())?,
	requireConvergence: boolean?,
	recalculateNormals: boolean?,
}
export type AxisReport = {
	axis: string,
	iterations: number,
	residual: number,
	relativeResidual: number,
	converged: boolean,
}
export type SolveReport = {
	axes: { AxisReport },
	converged: boolean,
	anchors: number,
	freeVertices: number,
	inactiveVertices: number,
	order: number,
}
export type Graph = {
	source: Mesh,
	ids: { number },
	index: { [number]: number },
	rows: { { [number]: number } },
	diagonal: { number },
	components: { { number } },
	solve: (Graph, { [number]: Vector3 }, SolveOptions?) -> (Mesh, SolveReport),
}
type Self = Graph
local L = {}
L.__index = L

function L.bind(mesh: Mesh, options: BindOptions?): Graph
	local options: BindOptions = options or {}
	local ids = U.keys(mesh.vertices)
	assert(#ids <= (options.maxVertices or 100000), "Laplacian vertex budget exceeded")
	local mode = options.weights or "UNIFORM"
	assert(mode == "UNIFORM" or mode == "COTANGENT", "Unknown Laplacian weights")
	local self: Graph = setmetatable(
		{ source = mesh:clone(), ids = ids, index = {}, rows = {}, diagonal = {}, components = {} },
		L
	) :: any
	for i, id in ids do
		assert(U.vector(mesh.vertices[id]), "Invalid vertex position")
		self.index[id] = i
		self.rows[i] = {}
		self.diagonal[i] = 0
	end
	local weights: { [string]: { a: number, b: number, w: number } } = {}
	for key, edge in mesh:topology().edges do
		weights[key] = { a = edge.a, b = edge.b, w = mode == "UNIFORM" and 1 or 0 }
	end
	if mode == "COTANGENT" then
		for _, t in mesh:triangles() do
			for j = 1, 3 do
				local a, b, c = t[j], t[j % 3 + 1], t[(j + 1) % 3 + 1]
				local u, v = mesh.vertices[a] - mesh.vertices[c], mesh.vertices[b] - mesh.vertices[c]
				local area = u:Cross(v).Magnitude
				assert(area > 1e-12, "Cotangent operator requires nondegenerate triangles")
				local key = U.edge(a, b)
				weights[key] = weights[key] or { a = a, b = b, w = 0 }
				weights[key].w += 0.5 * u:Dot(v) / area
			end
		end
	end
	for _, key in U.keys(weights) do
		local edge = weights[key]
		-- Nonnegative conductance keeps the operator positive semidefinite on obtuse meshes.
		local w = math.max(1e-8, edge.w)
		local a, b = self.index[edge.a], self.index[edge.b]
		self.rows[a][b] = w
		self.rows[b][a] = w
		self.diagonal[a] += w
		self.diagonal[b] += w
	end
	local seen: { [number]: boolean } = {}
	for i = 1, #ids do
		if not seen[i] then
			local component, cursor = { i }, 1
			seen[i] = true
			while cursor <= #component do
				for j in self.rows[component[cursor]] do
					if not seen[j] then
						seen[j] = true
						table.insert(component, j)
					end
				end
				cursor += 1
			end
			table.sort(component)
			table.insert(self.components, component)
		end
	end
	return self
end

function L.solve(self: Self, anchors: { [number]: Vector3 }, options: SolveOptions?): (Mesh, SolveReport)
	local options: SolveOptions = options or {}
	local order = options.order or 2
	assert(order == 1 or order == 2, "Laplacian order must be 1 or 2")
	local iterations = options.maxIterations or 512
	U.integer(iterations, 1)
	local tolerance = options.tolerance or 1e-7
	assert(U.finite(tolerance) and tolerance > 0, "Positive tolerance required")
	local n = #self.ids
	local fixed: { [number]: boolean }, target: { [number]: Vector3 }, count, inactive = {}, {}, 0, 0
	for id, p in anchors do
		local i = assert(self.index[id], "Unknown anchor vertex")
		assert(U.vector(p), "Invalid anchor position")
		fixed[i] = true
		target[i] = p - self.source.vertices[id]
		count += 1
	end
	for _, component in self.components do
		local constrained = false
		for _, i in component do
			constrained = constrained or fixed[i] == true
		end
		if not constrained then
			for _, i in component do
				fixed[i] = true
				inactive += 1
			end
		end
	end
	local free: { number }, diagonal: { number } = {}, {}
	for i = 1, n do
		if not fixed[i] then
			table.insert(free, i)
		end
		local d = self.diagonal[i]
		if order == 2 then
			d = d * d
			for _, w in self.rows[i] do
				d += w * w
			end
		end
		diagonal[i] = math.max(d, 1e-20)
	end
	local function laplace(v: { number }): { number }
		local out = table.create(n, 0)
		for i = 1, n do
			local sum = self.diagonal[i] * v[i]
			for j, w in self.rows[i] do
				sum -= w * v[j]
			end
			out[i] = sum
		end
		return out
	end
	local function apply(v: { number }): { number }
		local out = laplace(v)
		return order == 2 and laplace(out) or out
	end
	local coordinates: { { number } }, reports: { AxisReport } = {}, {}
	for axisIndex, axis in { "X", "Y", "Z" } do
		local prescribed = table.create(n, 0)
		for i, d in target do
			prescribed[i] = (d :: any)[axis]
		end
		local rhs = apply(prescribed)
		local x, r, z, p = table.create(n, 0), table.create(n, 0), table.create(n, 0), table.create(n, 0)
		local rhsNorm, rz = 0, 0
		for _, i in free do
			r[i] = -rhs[i]
			z[i] = r[i] / diagonal[i]
			p[i] = z[i]
			rhsNorm += r[i] * r[i]
			rz += r[i] * z[i]
		end
		local residual, used = math.sqrt(rhsNorm), 0
		local threshold = math.max(1e-10, tolerance * math.sqrt(rhsNorm))
		for step = 1, iterations do
			if residual <= threshold then
				break
			end
			local ap = apply(p)
			local pap = 0
			for _, i in free do
				pap += p[i] * ap[i]
			end
			if pap <= 0 or not U.finite(pap) then
				break
			end
			local alpha = rz / pap
			local newRz, squared = 0, 0
			for _, i in free do
				x[i] += alpha * p[i]
				r[i] -= alpha * ap[i]
				z[i] = r[i] / diagonal[i]
				squared += r[i] * r[i]
				newRz += r[i] * z[i]
			end
			local beta = newRz / rz
			for _, i in free do
				p[i] = z[i] + beta * p[i]
			end
			rz = newRz
			residual = math.sqrt(squared)
			used = step
			if options.checkpoint and step % 16 == 0 then
				options.checkpoint(((axisIndex - 1) + step / iterations) / 3)
			end
		end
		-- Report the true residual, rather than trusting recursively accumulated roundoff.
		local ax, squared = apply(x), 0
		for _, i in free do
			squared += (ax[i] + rhs[i]) ^ 2
		end
		residual = math.sqrt(squared)
		for i, d in target do
			x[i] = (d :: any)[axis]
		end
		coordinates[axisIndex] = x
		table.insert(reports, {
			axis = axis,
			iterations = used,
			residual = residual,
			relativeResidual = residual / math.max(math.sqrt(rhsNorm), 1e-20),
			converged = residual <= threshold * 1.01,
		})
	end
	local out = self.source:clone()
	local report: SolveReport = {
		axes = reports,
		converged = true,
		anchors = count,
		freeVertices = #free,
		inactiveVertices = inactive,
		order = order,
	}
	for _, r in reports do
		report.converged = report.converged and r.converged
	end
	for i, id in self.ids do
		out.vertices[id] = anchors[id]
			or (out.vertices[id] + Vector3.new(coordinates[1][i], coordinates[2][i], coordinates[3][i]))
		assert(U.vector(out.vertices[id]), "Laplacian solve produced invalid positions")
	end
	if options.requireConvergence ~= false then
		assert(
			report.converged,
			"Laplacian solve did not converge; increase iteration budget or use a coarser control mesh"
		)
	end
	if options.recalculateNormals ~= false then
		out:recalculateNormals()
	end
	return out, report
end
return L
