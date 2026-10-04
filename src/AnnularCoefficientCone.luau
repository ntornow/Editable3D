-- Positive Bernstein weights preserve a finite cone of asymptotic directions.
return function(R, P, F, reference, leading, w, powers, rows, filtered, options, visit)
	local zero = R.number(0)
	local axis = 1
	while F.sign(reference[axis]) == 0 do
		axis += 1
	end
	local function actualCorner(index)
		local i = (index - 1) % 36
		return (i == 0 or i == 5 or i == 30 or i == 35)
	end
	local active, lower = 0, 0
	for index, row in rows do
		if options.checkpoint then
			options.checkpoint({ stage = "annularCoefficientCone", coefficient = index })
		end
		local a = { leading[(index - 1) * 3 + 1], leading[(index - 1) * 3 + 2], leading[(index - 1) * 3 + 3] }
		local nonzero = false
		for _, p in a do
			if F.sign(p) ~= 0 then
				nonzero = true
				break
			end
		end
		if nonzero then
			if
				not require(script.Parent.CompareAlgebraicDirections)(
					R,
					P,
					F,
					reference,
					F,
					a,
					visit,
					options.normalAllocate
				)
			then
				local report =
					{ normalCertified = false, reason = "coefficientConeOrientation", coefficient = index }
				if actualCorner(index) then
					report.normalExists = false
				end
				return nil, report
			end
			active += 1
			continue
		end
		lower += 1
		local sequence = {}
		for k = 1, #w - 1 do
			local v = { zero, zero, zero }
			for j, x in row do
				if x.sign ~= 0 then
					for component = 1, 3 do
						v[component] = R.add(v[component], R.mul(x, powers[k][(j - 1) * 3 + component]))
					end
				end
			end
			sequence[k] = v
		end
		local q = require(script.Parent.ExactObservedRecurrence)(R, P, w, sequence, visit)
		if #q <= 1 then
			if filtered then
				return nil, { normalCertified = false, reason = "coefficientNeedsHalo" }
			end
			continue
		end
		local field, direction
		if F.sign(q) == 0 then
			-- Same exponential rate; an erased leading Jordan coefficient exposes a
			-- lower power of k. Synthetic division gives that coefficient directly.
			field = F
			direction = {}
			for component = 1, 3 do
				local sum = {}
				for k = 1, #q - 1 do
					local f = {}
					for j = k + 1, #q do
						f[#f + 1] = q[j]
					end
					sum = P.add(sum, P.scale(f, sequence[k][component]))
				end
				direction[component] = F.reduce and F.reduce(sum) or sum
			end
		else
			local mode, reason = require(script.Parent.ExactDominantMode)(R, P, q, options, visit)
			if not mode then
				if reason == "nilpotentSequence" or reason == "zeroSequence" then
					if filtered then
						return nil, { normalCertified = false, reason = "coefficientNeedsHalo" }
					end
					continue
				end
				return nil, { normalCertified = false, reason = reason }
			end
			field = mode.value
			direction = mode.leading(sequence)
		end
		if filtered and field.sign({ R.number(-0.125), R.number(1) }) <= 0 then
			return nil, { normalCertified = false, reason = "coefficientNeedsHalo" }
		end
		if
			not require(script.Parent.CompareAlgebraicDirections)(
				R,
				P,
				F,
				reference,
				field,
				direction,
				visit,
				options.normalAllocate
			)
		then
			local report = {
				normalCertified = false,
				reason = actualCorner(index) and "differentBoundaryNormal" or "coefficientConeDirection",
				coefficient = index,
			}
			if actualCorner(index) then
				report.normalExists = false
			end
			return nil, report
		end
		active += 1
	end
	if active == 0 then
		return nil, { normalCertified = false, reason = "noRegularAnnularSequence" }
	end
	return reference,
		{
			normalCertified = true,
			normalExists = true,
			coefficientCone = true,
			activeCoefficients = active,
			lowerCoefficients = lower,
		}
end
