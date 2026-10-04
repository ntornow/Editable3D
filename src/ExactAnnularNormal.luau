-- Exact source-specific normal proof on complete stationary annuli.
return function(R, masks, source, sector, kind, options, visit)
	local zero, one = R.number(0), R.number(1)
	local allocate = options.normalAllocate or function() end
	local P = require(script.Parent.ExactPolynomialRoots)(
		R,
		visit,
		2 * (options.maxNormalKrylovDegree or 128) + 2,
		allocate
	)
	P = require(script.Parent.RealSpectrumPolynomial)(R, P, visit, allocate)
	P.gcd = require(script.Parent.ExactModularPolynomialGCD)(R, P, visit, options)
	-- The scaled full coordinate operator is integral; its exterior square is
	-- integral at scale4096. Monic minimal recurrence coefficients at that scale
	-- are integers, which supplies the modular reconstruction degree proof.
	for _, row in masks.matrix do
		for _, x in row do
			local scaled = R.mul(R.number(64), x)
			assert(#scaled.d == 1 and scaled.d[1] == 1, "Nonintegral stationary annular operator")
		end
	end

	local recurrence = require(script.Parent.ExactVectorRecurrence)
	local initial = {}
	local n = (masks.size - 3) / 6
	for axis = 1, 3 do
		local center = source[1][axis]
		if kind == "crease" then
			center = R.div(
				R.add(
					R.mul(R.number(4), center),
					R.add(source[masks.vertex(0, 1, 0)][axis], source[masks.vertex(n - 1, 0, 1)][axis])
				),
				R.number(6)
			)
		end
		for i, p in source do
			initial[(i - 1) * 3 + axis] = R.sub(p[axis], center)
		end
	end
	local function advance(v)
		local out = table.create(#v, zero)
		for i, row in masks.matrix do
			for j, x in row do
				for axis = 1, 3 do
					local k = (i - 1) * 3 + axis
					out[k] = R.add(out[k], R.mul(x, v[(j - 1) * 3 + axis]))
				end
			end
		end
		return out
	end
	local p, powers = recurrence(R, initial, advance, masks.size, options, visit)
	local function completeGerm()
		local proof = require(script.Parent.AnnularGermProof)(
			R,
			masks,
			source,
			sector,
			kind,
			options,
			visit,
			{ polynomial = p, powers = powers }
		)
		local normal, error, reason
		if proof.normalExists then
			normal, error, reason = require(script.Parent.GenericNormalBounds)(
				R,
				proof.field,
				proof.candidate,
				proof.spectrum.bound,
				proof.spectrum.refine,
				options.normalTolerance or 1e-5,
				visit
			)
		end
		return normal,
			{
				normalCertified = proof.normalExists,
				normalExists = proof.normalExists,
				decisionCertified = true,
				reason = reason or proof.reason,
				method = "exactAnnularGerms",
				nativeAvailable = normal ~= nil,
				normalErrorBound = error,
				coordinateDegree = #p - 1,
				cells = proof.cells,
				completeDecision = true,
			}
	end
	local analysis = P.analyze(p)
	assert(
		P.count(analysis, zero, one) + (P.evaluate(analysis.squarefree, zero).sign == 0 and 1 or 0)
				== #analysis.squarefree - 1
			and P.evaluate(analysis.squarefree, one).sign ~= 0,
		"Annular coordinates are not strictly contracting with nonnegative real spectrum"
	)
	-- The coordinate relation proves that the active operator has only real
	-- nonnegative roots below1. The minimal exterior recurrence has products
	-- of those roots, so Descartes interval counts are exact here.
	P.realSpectrum = true

	local projected = require(script.Parent.ExactHaloProjection)(R, P, p, powers, visit)
	local function wedge(v)
		local out = {}
		for i = 1, #v / 3 - 1 do
			for j = i + 1, #v / 3 do
				for _, axes in { { 2, 3 }, { 3, 1 }, { 1, 2 } } do
					out[#out + 1] = R.sub(
						R.mul(v[(i - 1) * 3 + axes[1]], v[(j - 1) * 3 + axes[2]]),
						R.mul(v[(i - 1) * 3 + axes[2]], v[(j - 1) * 3 + axes[1]])
					)
				end
			end
		end
		return out
	end
	local function crossRecurrence(start)
		local function scalarAdvance(v)
			local out = table.create(masks.size, zero)
			for i, row in masks.matrix do
				for j, x in row do
					out[i] = R.add(out[i], R.mul(x, v[j]))
				end
			end
			return out
		end
		local subspace =
			require(script.Parent.ExactInvariantSubspace)(R, start, scalarAdvance, options, visit)
		local current = subspace.initial
		local w, powersW = require(script.Parent.ExactModularRecurrence)(R, wedge(current), function()
			current = subspace.advance(current)
			return wedge(current)
		end, subspace.dimension * (subspace.dimension - 1) / 2, options, visit)
		return w, powersW, subspace
	end
	local function localize(mode)
		if mode.value.localize then
			for _, r in { 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625 } do
				if P.evaluate(p, R.number(r)).sign == 0 then
					local scaled = {}
					local factor = one
					for i, x in p do
						scaled[i] = R.mul(x, factor)
						factor = R.div(factor, R.number(r))
					end
					local degree = mode.value.localize(scaled)
					if options.checkpoint then
						options.checkpoint({ stage = "normalFieldLocalization", degree = degree })
					end
					if degree <= 2 then
						break
					end
				end
			end
		end
	end
	local function observe(start)
		local w, powersW, subspace = crossRecurrence(start)
		if #w == 1 then
			return w, nil, nil, "zeroSequence"
		end
		local mode, reason = require(script.Parent.ExactDominantMode)(R, P, w, options, visit)
		if not mode then
			return w, nil, nil, reason
		end
		localize(mode)
		local leadingW = mode.leading(powersW)
		local denominator
		for _, v in leadingW do
			if mode.value.sign(v) ~= 0 then
				denominator = v
				break
			end
		end
		if denominator then
			leadingW =
				require(script.Parent.NormalizeAlgebraicPolynomials)(R, P, mode.value, leadingW, denominator)
		end
		if options.checkpoint then
			options.checkpoint({ stage = "annularCrossMap" })
		end
		local extract, rows =
			require(script.Parent.AnnularCrossMap)(R, P, masks, subspace.basis, sector, visit, allocate)
		local leading = extract(leadingW)
		for _, v in leading do
			if mode.value.sign(v) ~= 0 then
				return w, mode, leading, nil, { powers = powersW, rows = rows }
			end
		end
		-- A full-state dominant mode can be unobservable on this face. Cancel the
		-- exact output resolvent poles before selecting the next root/Jordan order.
		local annular = {}
		for k = 1, #w - 1 do
			if options.checkpoint then
				options.checkpoint({ stage = "annularExtraction", power = k, total = #w - 1 })
			end
			local values = {}
			for i, x in powersW[k] do
				values[i] = x.sign == 0 and {} or { x }
			end
			local value = extract(values)
			annular[k] = {}
			for i, x in value do
				assert(#x <= 1)
				annular[k][i] = x[1] or zero
			end
		end
		w = require(script.Parent.ExactObservedRecurrence)(R, P, w, annular, visit)
		mode, reason = require(script.Parent.ExactDominantMode)(R, P, w, options, visit)
		if not mode then
			return w, nil, nil, reason
		end
		localize(mode)
		return w, mode, mode.leading(annular), nil, { powers = powersW, rows = rows }
	end
	local w, mode, leading, _reason, data = observe(projected)
	local filtered = mode and mode.value.sign({ R.number(-0.125), one }) > 0
	if not filtered then
		w, mode, leading, _reason, data = observe(initial)
	end
	if not mode then
		return completeGerm()
	end
	local function classify()
		local direction, report, candidate =
			require(script.Parent.AnnularNormalDirection)(R, P, mode.value, leading, options, visit)
		if not direction and candidate and data then
			direction, report = require(script.Parent.AnnularCoefficientCone)(
				R,
				P,
				mode.value,
				candidate,
				leading,
				w,
				data.powers,
				data.rows,
				filtered,
				options,
				visit
			)
		end
		return direction, report
	end
	local direction, report = classify()
	if filtered and report.reason == "coefficientNeedsHalo" then
		filtered = false
		w, mode, leading, _reason, data = observe(initial)
		if not mode then
			return completeGerm()
		end
		direction, report = classify()
	end
	report.coordinateDegree = #p - 1
	report.crossDegree = #w - 1
	report.haloFiltered = not not filtered
	report.dominantMultiplicity = mode.multiplicity
	local function encode(x)
		return { sign = x.sign, numerator = table.clone(x.n), denominator = table.clone(x.d) }
	end
	report.method = "exactAnnularRecurrence"
	report.base = 16777216
	report.polynomial = {}
	for i, x in w do
		report.polynomial[i] = encode(x)
	end
	report.dominantRoot =
		{ low = encode(mode.root.low), high = encode(mode.root.high), exact = mode.root.exact }
	if not direction then
		if report.normalExists == nil then
			return completeGerm()
		end
		return nil, report
	end
	local normal, error, precision = require(script.Parent.AlgebraicNormalBounds)(
		R,
		P,
		mode.value,
		direction,
		options.normalTolerance or 1e-5,
		visit
	)
	report.normalErrorBound = error
	report.nativeAvailable = normal ~= nil
	report.reason = precision
	return normal, report
end
