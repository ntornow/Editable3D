-- Internal real-root sections via signed remainder queries over ordered K.
return function(R, polynomials, ctx, options)
	options = options or {}
	local visit, allocate = ctx.visit, ctx.allocate
	local P = require(script.Parent.ExactPolynomialRoots)(R, visit, ctx.maxDegree or 128, allocate)
	local zero, one, minus = R.number(0), R.number(1), R.number(-1)
	local product = { one }
	local input = table.clone(polynomials)
	for _, source in input do
		local p = source
		for _, bound in { zero, one } do
			while #p > 1 and P.evaluate(p, bound).sign == 0 do
				p = P.quotient(p, { R.neg(bound), one })
			end
		end
		if #p > 1 and P.count(P.analyze(p), zero, one) > 0 then
			local gcd = P.gcd(product, p)
			product = P.product(product, P.quotient(p, gcd))
		end
	end
	local f = P.quotient(product, P.gcd(product, P.derivative(product)))
	for _, bound in { zero, one } do
		if #f > 1 and P.evaluate(f, bound).sign == 0 then
			f = P.quotient(f, { R.neg(bound), one })
		end
	end
	f = P.scale(f, R.div(one, f[#f]))
	local degree = #f - 1
	local function reduce(p)
		if #p < #f then
			return p
		end
		local _, r = P.divide(p, f)
		return r
	end
	local function mulMod(a, b)
		local out = {}
		for i = #b, 1, -1 do
			out = reduce(P.add(P.product(out, { zero, one }), P.scale(a, b[i])))
		end
		return out
	end
	local function endpoint(x)
		return {
			field = R,
			coordinate = x,
			embed = function(a)
				return a
			end,
			lowSign = x.sign,
			highSign = R.sub(x, one).sign,
			value = {
				root = { exact = true, low = x, high = x },
				sign = function(p)
					return P.evaluate(p, x).sign
				end,
			},
		}
	end
	if degree == 0 then
		return { endpoint(zero), endpoint(one) }, { queries = 0, degree = 0 }
	end
	local derivative = P.derivative(f)
	local queryCount = 0
	local function tarski(g)
		queryCount += 1
		ctx.tarskiQueries = (ctx.tarskiQueries or 0) + 1
		visit(1)
		assert(ctx.tarskiQueries <= (options.maxTarskiQueries or 20000), "Thom query budget exceeded")
		local function normalize(p)
			if #p == 0 then
				return p
			end
			local lead = p[#p]
			if lead.sign < 0 then
				lead = R.neg(lead)
			end
			return P.scale(p, R.div(one, lead))
		end
		local a, b = f, normalize(mulMod(derivative, g))
		local sequence = { a }
		while #b > 0 do
			table.insert(sequence, b)
			local _, r = P.divide(a, b)
			a, b = b, normalize(P.scale(r, minus))
		end
		local function variation(negative)
			local old, count = 0, 0
			for _, p in sequence do
				local sign = p[#p].sign
				if negative and (#p - 1) % 2 == 1 then
					sign = -sign
				end
				if old ~= 0 and sign ~= old then
					count += 1
				end
				old = sign
			end
			return count
		end
		return variation(true) - variation(false)
	end
	local derivatives = {}
	local d = f
	for i = 1, degree - 1 do
		d = P.derivative(d)
		derivatives[i] = d
	end
	local function weightedQuery(selector, g)
		assert(#selector * degree <= 2 ^ 52, "Thom selector exact summation budget exceeded")
		local numerator = 0
		local magnitude = math.abs(selector[1].weight)
		assert(magnitude >= 2 ^ -512, "Thom selector dyadic precision budget exceeded")
		for _, term in selector do
			assert(math.abs(term.weight) == magnitude)
			numerator += term.weight * tarski(mulMod(term.polynomial, g))
		end
		return numerator
	end
	local roots =
		{ { signs = {}, selector = { { weight = 1, polynomial = { one } } }, count = tarski({ one }) } }
	for j = degree - 1, 1, -1 do
		local nextRoots = {}
		local g = derivatives[j]
		local square = mulMod(g, g)
		for _, root in roots do
			local signed = weightedQuery(root.selector, g)
			local nonzero = weightedQuery(root.selector, square)
			for _, sign in { -1, 0, 1 } do
				local count = sign == 0 and root.count - nonzero or (nonzero + sign * signed) / 2
				assert(count >= 0 and count % 1 == 0, "Invalid Thom sign count")
				if count == 0 then
					continue
				end
				local selector = {}
				for _, term in root.selector do
					if sign == 0 then
						table.insert(selector, term)
						table.insert(
							selector,
							{ weight = -term.weight, polynomial = mulMod(term.polynomial, square) }
						)
					else
						table.insert(
							selector,
							{ weight = term.weight / 2, polynomial = mulMod(term.polynomial, square) }
						)
						table.insert(
							selector,
							{ weight = term.weight * sign / 2, polynomial = mulMod(term.polynomial, g) }
						)
					end
				end
				allocate(#selector)
				local signs = table.clone(root.signs)
				signs[j] = sign
				table.insert(nextRoots, { signs = signs, selector = selector, count = count })
			end
		end
		roots = nextRoots
	end
	for _, r in roots do
		assert(r.count == 1, "Thom code must select one root")
		r.signs[degree] = 1
		local F = { root = { exact = false, analysis = { squarefree = f } } }
		function F.sign(p)
			if #p <= 1 then
				return p[1] and p[1].sign or 0
			end
			local sign = weightedQuery(r.selector, reduce(p))
			assert(sign >= -1 and sign <= 1 and sign % 1 == 0, "Invalid selected-root sign")
			return sign
		end
		r.value = F
		r.field = require(script.Parent.ReducedAlgebraicField)(R, P, F, allocate)
		r.coordinate = r.field.fromPolynomial({ zero, one })
		r.lowSign = F.sign({ zero, one })
		r.highSign = F.sign({ minus, one })
	end
	table.sort(roots, function(a, b)
		for j = degree - 1, 1, -1 do
			if a.signs[j] ~= b.signs[j] then
				assert(a.signs[j + 1] ~= 0 and a.signs[j + 1] == b.signs[j + 1])
				return a.signs[j + 1] > 0 and a.signs[j] < b.signs[j]
					or a.signs[j + 1] < 0 and a.signs[j] > b.signs[j]
			end
		end
		error("Duplicate Thom code")
	end)
	local out = { endpoint(zero) }
	for _, root in roots do
		if root.lowSign > 0 and root.highSign < 0 then
			root.embed = root.field.rational
			table.insert(out, root)
		end
	end
	table.insert(out, endpoint(one))
	return out, { queries = queryCount, degree = degree }
end
