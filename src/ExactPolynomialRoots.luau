-- Private bounded rational polynomial arithmetic; coefficients low degree first.
-- Endpoint convention: https://arxiv.org/html/2208.07904v1 (Theorem 1.2).
return function(R, visit, maximumDegree, allocate)
	allocate = allocate or function() end
	local function storage(n)
		assert(n <= maximumDegree + 1, "Polynomial degree budget exceeded")
		allocate(n)
	end
	local zero, two = R.number(0), R.number(2)
	local P = {}
	local function trim(p)
		while #p > 0 and p[#p].sign == 0 do
			table.remove(p)
		end
		return p
	end
	P.trim = trim
	function P.scale(p, s)
		storage(#p)
		local out = {}
		for i, x in p do
			visit(1)
			out[i] = R.mul(x, s)
		end
		return trim(out)
	end
	function P.add(a, b)
		storage(math.max(#a, #b))
		local out = {}
		for i = 1, math.max(#a, #b) do
			visit(1)
			out[i] = R.add(a[i] or zero, b[i] or zero)
		end
		return trim(out)
	end
	function P.product(a, b)
		if #a == 0 or #b == 0 then
			return {}
		end
		storage(#a + #b - 1)
		local out = table.create(#a + #b - 1, zero)
		for i, x in a do
			for j, y in b do
				visit(1)
				out[i + j - 1] = R.add(out[i + j - 1], R.mul(x, y))
			end
		end
		return trim(out)
	end
	function P.evaluate(p, x)
		local out = zero
		for i = #p, 1, -1 do
			visit(1)
			out = R.add(R.mul(out, x), p[i])
		end
		return out
	end
	function P.derivative(p)
		storage(math.max(0, #p - 1))
		local out = {}
		for i = 2, #p do
			visit(1)
			out[i - 1] = R.mul(p[i], R.number(i - 1))
		end
		return trim(out)
	end
	function P.divide(p, d)
		assert(#d > 0, "Polynomial zero divisor")
		storage(#p)
		storage(math.max(0, #p - #d + 1))
		local rest = table.clone(p)
		local q = table.create(math.max(0, #p - #d + 1), zero)
		while #rest >= #d do
			local k = #rest - #d
			local a = R.div(rest[#rest], d[#d])
			q[k + 1] = a
			for j = 1, #d do
				visit(1)
				rest[k + j] = R.sub(rest[k + j], R.mul(a, d[j]))
			end
			trim(rest)
		end
		return trim(q), rest
	end
	local function quotient(a, b)
		local q, r = P.divide(a, b)
		assert(#r == 0, "Inexact polynomial quotient")
		return q
	end
	P.quotient = quotient
	local function normalize(p, positiveOnly)
		if #p == 0 then
			return {}
		end
		local scalar = p[#p]
		if positiveOnly and scalar.sign < 0 then
			scalar = R.neg(scalar)
		end
		storage(#p)
		local out = {}
		for i, x in p do
			visit(1)
			out[i] = R.div(x, scalar)
		end
		return out
	end
	function P.gcd(a, b)
		while #b > 0 do
			visit(1)
			local _, r = P.divide(a, b)
			a, b = b, normalize(r, false)
		end
		return normalize(a, false)
	end
	local function sequence(p)
		if #p <= 1 then
			return { p }
		end
		local seq = { p, P.derivative(p) }
		while #seq[#seq] > 1 do
			local _, r = P.divide(seq[#seq - 1], seq[#seq])
			if #r == 0 then
				break
			end
			for i, x in r do
				r[i] = R.neg(x)
			end
			table.insert(seq, normalize(r, true))
		end
		return seq
	end
	local function variation(seq, x)
		local previous, count = 0, 0
		for _, p in seq do
			local sign = P.evaluate(p, x).sign
			if sign ~= 0 then
				if previous ~= 0 and previous ~= sign then
					count += 1
				end
				previous = sign
			end
		end
		return count
	end
	function P.analyze(source)
		storage(#source)
		local p = trim(table.clone(source))
		if #p <= 1 then
			return { polynomial = p, identity = #p == 0, factors = {}, squarefree = p, sequence = { p } }
		end
		p = normalize(p, false)
		local g = P.gcd(p, P.derivative(p))
		local w = quotient(p, g)
		local squarefree = w
		local factors = {}
		local multiplicity = 1
		while #w > 1 do
			visit(1)
			assert(multiplicity <= #p, "Square-free decomposition did not terminate")
			local y = P.gcd(w, g)
			local f = quotient(w, y)
			if #f > 1 then
				table.insert(factors, { polynomial = f, multiplicity = multiplicity, sequence = sequence(f) })
			end
			w, g = y, quotient(g, y)
			multiplicity += 1
		end
		return {
			identity = false,
			polynomial = source,
			squarefree = squarefree,
			factors = factors,
			sequence = sequence(squarefree),
		}
	end
	function P.count(analysis, a, b)
		-- Half-open (a,b], including a simple root at b. Analyze removes repeats.
		return variation(analysis.sequence, a) - variation(analysis.sequence, b)
	end
	function P.atRoot(analysis, root)
		-- The caller must isolate the union of every participating polynomial's roots.
		local sign = P.evaluate(analysis.polynomial, root.low).sign
		if analysis.identity then
			return 0, 0
		end
		if not root.exact and P.count(analysis, root.low, root.high) == 1 then
			sign = 0
		end
		if sign ~= 0 then
			return sign, 0
		end
		local found
		for _, f in analysis.factors do
			local count = root.exact and (P.evaluate(f.polynomial, root.low).sign == 0 and 1 or 0)
				or variation(f.sequence, root.low) - variation(f.sequence, root.high)
			assert(count == 0 or count == 1, "Root interval is not isolating")
			if count == 1 then
				assert(not found)
				found = f.multiplicity
			end
		end
		assert(found, "Missing algebraic root multiplicity")
		return 0, found
	end
	function P.refine(analysis, root, settings)
		if root.exact then
			return
		end
		assert(root.depth < settings.maxDepth, "Polynomial root depth budget exceeded")
		settings.nodes = (settings.nodes or 0) + 1
		assert(settings.nodes <= settings.maxNodes, "Polynomial root node budget exceeded")
		local mid = R.div(R.add(root.low, root.high), two)
		local sign = P.evaluate(analysis.squarefree, mid).sign
		if sign == 0 then
			root.low, root.high, root.exact = mid, mid, true
		elseif P.count(analysis, root.low, mid) == 1 then
			root.high = mid
		else
			root.low = mid
		end
		root.depth += 1
		visit(1)
	end
	function P.isolate(source, low, high, settings)
		assert(R.compare(low, high) < 0 and settings.tolerance.sign > 0)
		local analysis = P.analyze(source)
		if #analysis.polynomial <= 1 then
			return {
				identity = analysis.identity,
				complete = true,
				roots = {},
				analysis = analysis,
				nodes = 0,
			}
		end
		local squarefree, factors, seq = analysis.squarefree, analysis.factors, analysis.sequence
		local roots = {}
		local function add(a, b, exact, depth)
			local found
			for _, f in factors do
				local count = exact and (P.evaluate(f.polynomial, a).sign == 0 and 1 or 0)
					or variation(f.sequence, a) - variation(f.sequence, b)
				assert(count == 0 or count == 1)
				if count == 1 then
					assert(not found)
					found = f.multiplicity
				end
			end
			assert(found, "Isolated root has no square-free factor")
			table.insert(
				roots,
				{ low = a, high = b, exact = exact, multiplicity = found, depth = depth or 0 }
			)
		end
		local function endpoint(x)
			return { x = x, variation = variation(seq, x), root = P.evaluate(squarefree, x).sign == 0 }
		end
		local first, last = endpoint(low), endpoint(high)
		if first.root then
			add(low, low, true)
		end
		if last.root then
			add(high, high, true)
		end
		local stack = { { a = first, b = last, depth = 0 } }
		local nodes = 0
		while #stack > 0 do
			local node = table.remove(stack)
			nodes += 1
			visit(1)
			settings.nodes = (settings.nodes or 0) + 1
			assert(settings.nodes <= settings.maxNodes, "Polynomial root node budget exceeded")
			local a, b = node.a, node.b
			local count = a.variation - b.variation - (b.root and 1 or 0)
			assert(count >= 0, "Negative interior root count")
			if count == 0 then
				continue
			end
			if
				count == 1
				and not a.root
				and not b.root
				and R.compare(R.sub(b.x, a.x), settings.tolerance) <= 0
			then
				add(a.x, b.x, false, node.depth)
				continue
			end
			assert(node.depth < settings.maxDepth, "Polynomial root depth budget exceeded")
			local mid = endpoint(R.div(R.add(a.x, b.x), two))
			if mid.root then
				add(mid.x, mid.x, true, node.depth + 1)
			end
			table.insert(stack, { a = mid, b = b, depth = node.depth + 1 })
			table.insert(stack, { a = a, b = mid, depth = node.depth + 1 })
		end
		-- Rational comparisons may invoke a yielding work callback.
		for i = 2, #roots do
			local root = roots[i]
			local j = i - 1
			while j >= 1 and R.compare(root.low, roots[j].low) < 0 do
				roots[j + 1] = roots[j]
				j -= 1
			end
			roots[j + 1] = root
		end
		local count = first.variation - last.variation + (first.root and 1 or 0)
		assert(#roots == count, "Root coverage mismatch")
		return {
			identity = false,
			complete = true,
			roots = roots,
			distinctRoots = count,
			nodes = nodes,
			squarefree = squarefree,
			factors = factors,
			analysis = analysis,
		}
	end
	return P
end
