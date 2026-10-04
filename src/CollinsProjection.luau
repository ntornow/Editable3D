-- Bounded full coefficient/reductum/principal-subresultant projection.
local psc = require(script.Parent.PrincipalSubresultants)
return function(source, dimension, M, R, ctx, options)
	options = options or {}
	local limit = options.maxProjectionPolynomials or 256
	local function pool(cap)
		local list, keys = {}, {}
		local function add(p)
			if #p == 0 then
				return
			end
			p = M.normalize(p)
			if #p == 1 then
				local constant = true
				for _, d in p[1].powers do
					constant = constant and d == 0
				end
				if constant then
					return
				end
			end
			local key = M.key(p)
			if keys[key] then
				return keys[key]
			end
			assert(#list < (cap or limit), "CAD projection polynomial allocation budget exceeded")
			local index = #list + 1
			list[index] = p
			keys[key] = index
			return index
		end
		return list, add
	end
	local levels, labels = {}, {}
	local algebra = require(script.Parent.MultivariateBasis)(M, R, dimension, ctx, options)
	local current = source
	for axis = dimension, 1, -1 do
		local expanded, add = pool(options.maxProjectionCandidates or 4096)
		for _, p in algebra.basis(current) do
			while #p > 0 do
				add(p)
				if options.quantifiers then
					break
				end
				p = M.derivative(p, axis)
			end
		end
		labels[axis] = expanded
		expanded = algebra.basis(expanded)
		local parts = {}
		for _, p in expanded do
			local primitive, content = algebra.split(p, axis)
			table.insert(parts, primitive)
			table.insert(parts, content)
		end
		expanded = algebra.basis(parts)
		levels[axis] = expanded
		if axis == 1 then
			break
		end
		local projected, push = pool(options.maxProjectionCandidates or 4096)
		if options.projection == "mccallum" then
			local active = {}
			for _, p in expanded do
				local degree = M.degree(p, axis)
				for j = 0, degree do
					push(M.coefficient(p, axis, j))
				end
				if degree > 0 then
					table.insert(active, p)
				end
			end
			for i, p in active do
				push(psc(p, M.derivative(p, axis), axis, M, R, ctx, options.maxMatrixEntries or 4096)[1])
				for j = 1, i - 1 do
					push(psc(p, active[j], axis, M, R, ctx, options.maxMatrixEntries or 4096)[1])
				end
			end
			current = projected
			continue
		end
		local reducta, reductumKeys = {}, {}
		for _, p in expanded do
			local degree = M.degree(p, axis)
			for j = 0, degree do
				push(M.coefficient(p, axis, j))
			end
			for j = 1, degree do
				local q = M.truncate(p, axis, j)
				if M.degree(q, axis) < 1 then
					continue
				end
				q = M.normalize(q)
				local key = M.key(q)
				if not reductumKeys[key] then
					reductumKeys[key] = true
					table.insert(reducta, q)
					assert(
						#reducta <= limit * (ctx.maxDegree or 96),
						"CAD reductum allocation budget exceeded"
					)
				end
			end
		end
		local function coefficients(a, b)
			for _, p in psc(a, b, axis, M, R, ctx, options.maxMatrixEntries or 4096) do
				push(p)
			end
		end
		for i, p in reducta do
			coefficients(p, M.derivative(p, axis))
			for j = 1, i - 1 do
				coefficients(p, reducta[j])
			end
		end
		current = projected
	end
	return levels, labels
end
