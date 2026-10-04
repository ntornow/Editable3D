-- Internal finite serialization of a CAD and its exact component decisions.
return function(prepared, cad, components, vertices, quotient)
	local function scalar(value)
		prepared.data.ctx.visit(1)
		prepared.data.ctx.allocate(#value.n + #value.d + 1)
		local rational = type(value.d[1]) == "number"
		if rational then
			return {
				sign = value.sign == 0 and 0 or value.sign,
				numerator = table.clone(value.n),
				denominator = table.clone(value.d),
			}
		end
		local n, d = {}, {}
		for _, v in value.n do
			n[#n + 1] = scalar(v)
		end
		for _, v in value.d do
			d[#d + 1] = scalar(v)
		end
		return { sign = value.sign == 0 and 0 or value.sign, numerator = n, denominator = d, algebraic = true }
	end
	local function polynomial(p)
		local out = {}
		for _, value in p do
			out[#out + 1] = scalar(value)
		end
		return out
	end
	local function sparse(p)
		local out = {}
		for _, term in p do
			out[#out + 1] = { powers = table.clone(term.powers), value = scalar(term.value) }
		end
		return out
	end
	local function root(r)
		local out = { low = scalar(r.low), high = scalar(r.high), exact = r.exact, depth = r.depth }
		if r.analysis then
			out.polynomial = polynomial(r.analysis.squarefree)
		end
		if r.definingPolynomial then
			out.definingPolynomial = polynomial(r.definingPolynomial)
		end
		if r.modulusReductions then
			out.modulusReductions = {}
			for _, step in r.modulusReductions do
				out.modulusReductions[#out.modulusReductions + 1] = {
					before = polynomial(step.before),
					discarded = polynomial(step.discarded),
					after = polynomial(step.after),
				}
			end
		end
		return out
	end
	local function encodeCAD(value)
		local nodes, index = {}, {}
		local function walk(node, parent)
			local id = #nodes + 1
			index[node] = id
			local out = {
				index = id,
				parent = parent,
				axis = node.axis,
				dimension = node.dimension,
				kind = node.kind,
				stackIndex = node.index,
				result = node.result,
				early = node.early,
				feasible = node.feasible,
				fieldDepth = node.model and node.model.depth or 0,
				children = {},
			}
			nodes[id] = out
			if node.root then
				out.root = root(node.root)
			end
			if node.sample then
				out.sample = scalar(node.sample)
			end
			if node.signs then
				out.signs = table.clone(node.signs)
			end
			if node.originalSigns then
				out.sourceSigns = {}
				local keys = {}
				for i in node.originalSigns do
					keys[#keys + 1] = i
				end
				table.sort(keys)
				for _, i in keys do
					out.sourceSigns[#out.sourceSigns + 1] = { constraint = i, sign = node.originalSigns[i] }
				end
			end
			if node.values then
				out.values = {}
				for _, v in node.values do
					out.values[#out.values + 1] = scalar(v)
				end
			end
			if node.stack then
				out.stack = { axis = node.stack.axis, requiredZero = node.stack.requiredZero, roots = {} }
				for _, r in node.stack.roots do
					out.stack.roots[#out.stack.roots + 1] = root(r)
				end
			end
			for _, child in node.children or {} do
				out.children[#out.children + 1] = walk(child, id)
			end
			return id
		end
		walk(value.tree, nil)
		local levels, labels = {}, {}
		for axis, list in value.levels do
			levels[axis] = {}
			for _, p in list do
				levels[axis][#levels[axis] + 1] = sparse(p)
			end
		end
		for axis, list in value.labels do
			labels[axis] = {}
			for _, p in list do
				labels[axis][#labels[axis] + 1] = sparse(p)
			end
		end
		return {
			nodes = nodes,
			levels = levels,
			labels = labels,
			projection = value.projectionMethod,
			fallback = value.projectionFallback,
			baseField = "rational",
		},
			index
	end
	local function bivariate(p)
		local out = {}
		for _, row in p do
			out[#out + 1] = polynomial(row)
		end
		return out
	end
	local function encodePlanar(value)
		local out =
			{ basis = {}, projection = {}, constraints = {}, events = {}, slabs = {}, neighborhoods = {} }
		for _, p in value.basis do
			out.basis[#out.basis + 1] = bivariate(p)
		end
		for _, p in value.projection do
			out.projection[#out.projection + 1] = polynomial(p)
		end
		for _, c in value.original do
			out.constraints[#out.constraints + 1] = { polynomial = bivariate(c.p), relation = c.relation }
		end
		local function lift(l)
			local encoded = { points = {}, sectors = {} }
			for _, p in l.points do
				encoded.points[#encoded.points + 1] = { root = root(p.root), signs = table.clone(p.signs) }
			end
			for _, s in l.sectors do
				encoded.sectors[#encoded.sectors + 1] =
					{ sample = scalar(s.sample), signs = table.clone(s.signs) }
			end
			return encoded
		end
		for _, event in value.events do
			out.events[#out.events + 1] = { root = root(event.root), lift = lift(event.lift) }
		end
		for _, slab in value.slabs do
			out.slabs[#out.slabs + 1] =
				{ first = slab.first, last = slab.last, sample = scalar(slab.sample), lift = lift(slab.lift) }
		end
		for i, n in value.neighborhoods do
			local q =
				{ low = scalar(n.low), high = scalar(n.high), cuts = {}, crossing = {}, depth = n.depth }
			for _, v in n.cuts do
				q.cuts[#q.cuts + 1] = scalar(v)
			end
			for _, p in n.crossing do
				q.crossing[#q.crossing + 1] = polynomial(p)
			end
			for _, side in { "left", "right" } do
				if n[side] then
					q[side] = { sample = scalar(n[side].sample), rootMap = table.clone(n[side].rootMap) }
				end
			end
			out.neighborhoods[i] = q
		end
		return out
	end
	local function proof(value)
		local out = {
			method = value.method,
			from = value.from,
			to = value.to,
			connected = value.connected,
			sampleWitness = value.sampleWitness,
			nodes = value.nodes,
			roots = value.roots,
			projection = value.projection,
			radius = value.radius,
			event = value.event,
			slab = value.slab,
			expected = value.expected and table.clone(value.expected),
			axes = value.axes and table.clone(value.axes),
		}
		if value.equation then
			out.equation = sparse(value.equation)
		end
		if value.graphProof then
			out.graphProof = { method = value.graphProof.method, steps = {} }
			for _, step in value.graphProof.steps or {} do
				out.graphProof.steps[#out.graphProof.steps + 1] = {
					axis = step.axis,
					equation = sparse(step.equation),
					numerator = sparse(step.numerator),
					denominator = sparse(step.denominator),
				}
			end
		end
		if value.factors then
			out.factors = {}
			for _, factor in value.factors do
				local f = {
					axis = factor.axis,
					relations = table.clone(factor.relations),
					contains = factor.contains,
					polynomials = {},
					roots = {},
					pointSigns = factor.pointSigns,
					sectorSigns = factor.sectorSigns,
				}
				for _, p in factor.polynomials do
					f.polynomials[#f.polynomials + 1] = polynomial(p)
				end
				for _, r in factor.roots do
					f.roots[#f.roots + 1] = root(r)
				end
				out.factors[#out.factors + 1] = f
			end
		end
		if value.planar then
			out.planar = encodePlanar(value.planar)
		end
		if value.decision then
			local d = value.decision
			out.decision = {
				cad = encodeCAD(d.cad),
				polynomials = {},
				relations = table.clone(d.relations),
				targets = table.clone(d.targets),
				origins = table.clone(d.origins),
				epsilon = d.epsilon,
				quantifiers = table.clone(d.quantifiers),
				fixed = d.fixed,
			}
			if d.fixed then
				out.decision.cad.baseField = { sourceCell = value.to }
			end
			for _, p in d.polynomials do
				out.decision.polynomials[#out.decision.polynomials + 1] = sparse(p)
			end
		end
		return out
	end
	local proofObjects, proofIndex = {}, {}
	local function referenceProof(value)
		if proofIndex[value] then
			return proofIndex[value]
		end
		local id = #proofObjects + 1
		proofIndex[value] = id
		proofObjects[id] = proof(value)
		return id
	end
	local encoded, nodeIndex = encodeCAD(cad)
	local out = {
		algorithm = "exactGeneralTensorPrototype",
		prototype = true,
		coverageCertified = false,
		parameterComponentsCertified = false,
		decomposition = encoded,
		cells = {},
		components = {},
		connections = {},
		pairAudit = {},
		vertices = vertices,
		parameterOrder = table.clone(prepared.parameterOrder),
		parameterBox = prepared.data.report.parameterBox,
		sourceSpans = { {}, {} },
		spanPairs = {},
		constraints = {},
		domain = prepared.domain,
		work = prepared.data.report.work,
		coefficientsAllocated = prepared.data.report.coefficientsAllocated,
		proofs = proofObjects,
	}
	for _, p in prepared.polynomials do
		out.constraints[#out.constraints + 1] = sparse(p)
	end
	for operand, spans in prepared.spans do
		for _, span in spans do
			local s = {
				index = span.index,
				indices = table.clone(span.indices),
				knotSpans = table.clone(span.knotSpans),
				offset = polynomial(span.offset),
				scale = polynomial(span.scale),
				weightBounds = polynomial(span.weightBounds),
				guards = span.guards,
				homogeneous = {},
				original = {},
			}
			for axis = 1, 4 do
				s.homogeneous[axis] = sparse(span.h[axis])
				s.original[axis] = bivariate(span.original[axis])
			end
			out.sourceSpans[operand][#out.sourceSpans[operand] + 1] = s
		end
	end
	for _, pair in prepared.pairs do
		local p = { a = pair.a, b = pair.b, refs = pair.refs, equations = {}, reduced = {}, rewrites = {} }
		p.alternatives = pair.alternatives
		p.remainingCoordinates = pair.remainingCoordinates
		p.signProof = {
			applied = pair.signProof.applied,
			method = pair.signProof.method,
			degrees = table.clone(pair.signProof.degrees),
			faces = {},
			coordinates = {},
		}
		for _, face in pair.signProof.faces do
			local fixed = {}
			for axis = 1, 4 do
				if face[axis] ~= nil then
					fixed[#fixed + 1] = { axis = axis, value = face[axis] }
				end
			end
			p.signProof.faces[#p.signProof.faces + 1] = fixed
		end
		for _, entry in pair.signProof.coordinates do
			local e = { coordinate = entry.coordinate, sign = entry.sign, coefficients = {} }
			for _, c in entry.coefficients do
				e.coefficients[#e.coefficients + 1] =
					{ index = table.clone(c.index), value = scalar(c.value) }
			end
			p.signProof.coordinates[#p.signProof.coordinates + 1] = e
		end
		for _, q in pair.equations do
			p.equations[#p.equations + 1] = sparse(q)
		end
		for _, q in pair.reduced do
			p.reduced[#p.reduced + 1] = sparse(q)
		end
		for _, step in pair.rewrite.steps do
			local e = {
				index = step.index,
				before = sparse(step.before),
				after = sparse(step.after),
				scale = scalar(step.scale),
				quotients = {},
			}
			for _, q in step.quotients do
				e.quotients[#e.quotients + 1] = sparse(q)
			end
			p.rewrites[#p.rewrites + 1] = e
		end
		out.spanPairs[#out.spanPairs + 1] = p
	end
	for i, cell in components.cells do
		out.cells[i] = {
			index = i,
			node = nodeIndex[cell],
			dimension = cell.dimension,
			vertex = i,
			spanPair = assert(prepared.owner(cell.originalSigns)),
		}
	end
	for i, component in components.components do
		out.components[i] =
			{ index = i, cells = table.clone(component.cells), parameterDimension = component.dimension }
		for _, j in component.cells do
			out.cells[j].component = i
		end
	end
	for _, edge in components.connections do
		out.connections[#out.connections + 1] =
			{ from = edge.from, to = edge.to, proof = referenceProof(edge) }
	end
	for _, audit in components.audits do
		local a = { first = audit.first, second = audit.second, directions = {} }
		for _, decision in audit.directions do
			a.directions[#a.directions + 1] = referenceProof(decision)
		end
		out.pairAudit[#out.pairAudit + 1] = a
	end
	out.auditSummary = {
		pairs = components.pairs,
		queries = components.queries,
		skippedConnected = components.skippedConnected,
	}
	if quotient then
		local function finite(value)
			if type(value) ~= "table" then
				assert(
					type(value) ~= "function" and type(value) ~= "thread",
					"Private quotient value cannot be serialized"
				)
				return value
			end
			if value.n and value.d then
				return scalar(value)
			end
			local copy = {}
			for key, item in value do
				prepared.data.ctx.visit(1)
				prepared.data.ctx.allocate(1)
				copy[key] = finite(item)
			end
			return copy
		end
		out.periodicQuotient = finite(quotient)
	end

	out.work = prepared.data.report.work
	out.coefficientsAllocated = prepared.data.report.coefficientsAllocated
	out.visited = prepared.data.ctx.isolation and prepared.data.ctx.isolation.nodes or 0
	out.liftedRoots = prepared.data.ctx.liftedRoots or 0
	return out
end
