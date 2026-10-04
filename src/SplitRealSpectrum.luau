-- Internal common ordered algebraic field containing every active positive root.
return function(R, polynomial, ctx, options)
	options = options or {}
	local P = require(script.Parent.ExactPolynomialRoots)(R, ctx.visit, ctx.maxDegree or 128, ctx.allocate)
	local settings = {
		tolerance = R.number(1 / 1024),
		maxDepth = options.maxRootDepth or 128,
		maxNodes = options.maxRootNodes or 100000,
	}
	local isolated = P.isolate(polynomial, R.number(0), R.number(1), settings)
	local B = require(script.Parent.ExactPolynomialBounds)(R, P, ctx.visit)
	local bound = function(value)
		return { value, value }
	end
	local I = require(script.Parent.DirectedInterval)
	local nativeBound = require(script.Parent.ExactRationalBounds)(R, ctx.visit)
	local roots = isolated.roots
	for _, root in roots do
		while not root.exact and root.depth < math.min(40, settings.maxDepth) do
			P.refine(isolated.analysis, root, settings)
		end
	end
	assert(#roots == #isolated.analysis.squarefree - 1, "Active spectrum must be wholly real and in [0,1]")
	local remaining = isolated.analysis.squarefree
	for _, root in roots do
		if root.exact then
			remaining = P.quotient(remaining, { R.neg(root.low), R.number(1) })
		end
	end
	local K = R
	local embed = function(x)
		return x
	end
	local known = {}
	local processed = {}
	local extensions = 0
	for _, root in roots do
		if root.exact then
			processed[root] = true
			table.insert(known, { value = root.low, multiplicity = root.multiplicity, source = root })
		end
	end
	for i = #roots, 1, -1 do
		local source = roots[i]
		if processed[source] then
			continue
		end
		if options.checkpoint then
			options.checkpoint({ stage = "spectrumRoot", degree = #remaining - 1, root = i })
		end
		local PK =
			require(script.Parent.ExactPolynomialRoots)(K, ctx.visit, ctx.maxDegree or 128, ctx.allocate)
		local low, high = embed(source.low), embed(source.high)
		local modulus = remaining
		for _, trace in { 0.5, 0.5625, 0.625, 0.6875, 0.75 } do
			local hint = { K.number(1 / 16), K.number(-trace), K.number(1) }
			local g = PK.gcd(modulus, hint)
			if #g > 1 and #g < #modulus and PK.evaluate(g, low).sign * PK.evaluate(g, high).sign < 0 then
				modulus = g
				break
			end
		end
		local value
		if #modulus == 2 then
			value = K.div(K.neg(modulus[1]), modulus[2])
			assert(K.compare(value, low) > 0 and K.compare(value, high) < 0)
		else
			local root = { exact = false, low = low, high = high, analysis = { squarefree = modulus } }
			local F = { root = root }
			-- Bind the parent field in this closure before advancing the tower.
			local parentK, parentP = K, PK
			local parentNativeBound = nativeBound
			local lowNative, highNative =
				require(script.Parent.ExactRationalBounds)(R, ctx.visit)(source.low),
				require(script.Parent.ExactRationalBounds)(R, ctx.visit)(source.high)
			local nativeRange = { lowNative[1], highNative[2] }
			local function evaluateNative(poly)
				local out = { 0, 0 }
				for j = #poly, 1, -1 do
					ctx.visit(1)
					out = I.add(I.mul(out, nativeRange), parentNativeBound(poly[j]))
				end
				return out
			end
			function F.sign(p)
				if #p <= 1 then
					return p[1] and p[1].sign or 0
				end
				local interval = evaluateNative(p)
				if interval[1] > 0 then
					return 1
				elseif interval[2] < 0 then
					return -1
				end
				local sign = require(script.Parent.SturmTarskiSign)(parentK, parentP, root, p)
				if sign == 0 and #p > 0 then
					local factor = parentP.gcd(root.analysis.squarefree, p)
					if #factor > 1 and #factor < #root.analysis.squarefree then
						root.analysis = { squarefree = factor }
					end
				end
				return sign
			end
			local nextK = require(script.Parent.ReducedAlgebraicField)(parentK, PK, F, ctx.allocate)
			value = nextK.fromPolynomial({ parentK.number(0), parentK.number(1) })
			local previousEmbed = embed
			embed = function(q)
				return nextK.rational(previousEmbed(q))
			end
			for _, entry in known do
				entry.value = nextK.rational(entry.value)
			end
			local promoted = {}
			for j, q in remaining do
				promoted[j] = nextK.rational(q)
			end
			remaining = promoted
			local previousBound = bound
			bound = function(value)
				local range = { source.low, source.high }
				local function evaluate(poly)
					local out = { R.number(0), R.number(0) }
					for j = #poly, 1, -1 do
						local coefficient = previousBound(poly[j])
						if not coefficient then
							return nil
						end
						out = B.add(B.mul(out, range), coefficient)
					end
					return out
				end
				local a, b = evaluate(value.n), evaluate(value.d)
				if not a or not b or b[1].sign <= 0 and b[2].sign >= 0 then
					return nil
				end
				if b[2].sign < 0 then
					a, b = B.neg(a), B.neg(b)
				end
				return B.divide(a, b)
			end
			local nativeCache = setmetatable({}, { __mode = "k" })
			nativeBound = function(x)
				if nativeCache[x] then
					return nativeCache[x]
				end
				local value = I.div(evaluateNative(x.n), evaluateNative(x.d))
				ctx.allocate(2)
				nativeCache[x] = value
				return value
			end
			K = nextK
			extensions += 1
			PK = require(script.Parent.ExactPolynomialRoots)(K, ctx.visit, ctx.maxDegree or 128, ctx.allocate)
		end
		remaining = PK.quotient(remaining, { K.neg(value), K.number(1) })
		table.insert(known, { value = value, multiplicity = source.multiplicity, source = source })
		processed[source] = true
		-- Verified reciprocal eigenvalue pairing removes roots already in this field.
		if value.sign ~= 0 and #remaining > 1 then
			local partner = K.div(K.number(1 / 16), value)
			if PK.evaluate(remaining, partner).sign == 0 then
				local matched
				for _, other in roots do
					if
						not processed[other]
						and K.compare(partner, embed(other.low)) > 0
						and K.compare(partner, embed(other.high)) < 0
					then
						matched = other
						break
					end
				end
				assert(matched, "Reciprocal root has no isolated owner")
				remaining = PK.quotient(remaining, { K.neg(partner), K.number(1) })
				table.insert(
					known,
					{ value = partner, multiplicity = matched.multiplicity, source = matched }
				)
				processed[matched] = true
			end
		end
	end
	assert(#remaining == 1)
	-- Exact comparisons can invoke a yielding work checkpoint. Keep them out
	-- of table.sort's non-yieldable C comparator frame.
	for i = 2, #known do
		local value = known[i]
		local j = i - 1
		while j >= 1 and K.compare(value.value, known[j].value) < 0 do
			known[j + 1] = known[j]
			j -= 1
		end
		known[j + 1] = value
	end
	local function refine()
		local changed = false
		for _, root in roots do
			if not root.exact and root.depth < settings.maxDepth then
				P.refine(isolated.analysis, root, settings)
				changed = true
			end
		end
		return changed
	end
	return K, embed, known, { extensions = extensions, bound = bound, refine = refine }
end
