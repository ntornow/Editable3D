-- Internal complete closed-annulus normal decision over positive-spectrum germs.
return function(R, masks, points, sector, kind, options, visit, knownRecurrence)
	options = options or {}
	local allocated = 0
	local function allocate(n)
		allocated += n
		assert(
			allocated <= (options.maxExactCoefficients or 20000000),
			"Germ proof allocation budget exceeded"
		)
		if options.normalAllocate then
			options.normalAllocate(n)
		end
	end
	local ctx = { visit = visit, allocate = allocate, maxDegree = options.maxNormalPolynomialDegree or 128 }
	local n = (masks.size - 3) / 6
	local initial = {}
	for axis = 1, 3 do
		local center = points[1][axis]
		if kind == "crease" then
			center = R.div(
				R.add(
					R.mul(R.number(4), center),
					R.add(points[masks.vertex(0, 1, 0)][axis], points[masks.vertex(n - 1, 0, 1)][axis])
				),
				R.number(6)
			)
		end
		for i, p in points do
			initial[(i - 1) * 3 + axis] = R.sub(p[axis], center)
		end
	end
	local function advance(value)
		local out = table.create(#value, R.number(0))
		for i, row in masks.matrix do
			for j, w in row do
				for axis = 1, 3 do
					local k = (i - 1) * 3 + axis
					out[k] = R.add(out[k], R.mul(w, value[(j - 1) * 3 + axis]))
				end
			end
		end
		return out
	end
	local polynomial, powers
	if knownRecurrence then
		polynomial, powers = knownRecurrence.polynomial, knownRecurrence.powers
	else
		polynomial, powers =
			require(script.Parent.ExactVectorRecurrence)(R, initial, advance, masks.size, options, visit)
	end
	if #polynomial <= 1 then
		return { normalExists = false, reason = "noRegularPoints", allocated = allocated }
	end
	local K, embed, modes, spectrum =
		require(script.Parent.ExactSpectralModes)(R, polynomial, powers, ctx, options)
	if options.checkpoint then
		options.checkpoint({ stage = "germModes", modes = #modes, allocated = allocated })
	end
	local bases = {}
	for i, mode in modes do
		bases[i] = mode.base
	end
	local G = require(script.Parent.FormalExponentialGermField)(K, bases, ctx, options)
	local T = G.coefficientField
	local controls = {}
	for i = 1, masks.size do
		controls[i] = {}
		for axis = 1, 3 do
			local terms = {}
			for _, mode in modes do
				for j, c in mode.coefficients[(i - 1) * 3 + axis] do
					if c.sign ~= 0 then
						terms[#terms + 1] = { base = mode.base, power = j - 1, coefficient = T.rational(c) }
					end
				end
			end
			controls[i][axis] = G.fromTerms(terms)
		end
	end
	local lifted = { patches = {} }
	for i, p in masks.patches do
		local target = { sector = p.sector, cell = p.cell }
		for _, name in { "du", "dv" } do
			target[name] = {}
			for j, row in p[name] do
				target[name][j] = {}
				for k, mask in row do
					local out = {}
					for id, w in mask do
						out[id] = G.rational(embed(w))
					end
					target[name][j][k] = out
				end
			end
		end
		lifted.patches[i] = target
	end
	local coefficients =
		require(script.Parent.AnnularJacobianCoefficients)(G, lifted, controls, sector, visit)
	if options.checkpoint then
		options.checkpoint({ stage = "germCross", allocated = allocated })
	end
	local top
	for _, value in coefficients do
		local leading = G.leading(value)
		if leading then
			if not top then
				top = leading
			else
				local c = K.compare(leading.base, top.base)
				if c > 0 or c == 0 and leading.power > top.power then
					top = leading
				end
			end
		end
	end
	if not top then
		return { normalExists = false, reason = "noRegularPoints", allocated = allocated }
	end
	local N
	local values = {}
	for i, value in coefficients do
		values[i] = G.coefficient(value, top.base, top.power)
	end
	for i = 1, #values, 3 do
		if values[i].sign ~= 0 or values[i + 1].sign ~= 0 or values[i + 2].sign ~= 0 then
			N = { values[i], values[i + 1], values[i + 2] }
			break
		end
	end
	assert(N)
	local axis = 1
	while N[axis].sign == 0 do
		axis += 1
	end
	for i = 1, #values, 3 do
		for j = 1, 3 do
			if not K.equal(K.mul(values[i + j - 1], N[axis]), K.mul(values[i + axis - 1], N[j])) then
				return { normalExists = false, reason = "varyingAnnularDirection", allocated = allocated }
			end
		end
	end
	local M = require(script.Parent.ExactSparsePolynomial)(G, 2, ctx)
	local binomial =
		{ { 1 }, { 1, 1 }, { 1, 2, 1 }, { 1, 3, 3, 1 }, { 1, 4, 6, 4, 1 }, { 1, 5, 10, 10, 5, 1 } }
	local function powerCoefficients(patch, component)
		local terms = {}
		for i = 0, 5 do
			for j = 0, 5 do
				local value = coefficients[patch * 108 + (i * 6 + j) * 3 + component]
				for a = i, 5 do
					for b = j, 5 do
						local integer = binomial[6][i + 1]
							* binomial[6 - i][a - i + 1]
							* binomial[6][j + 1]
							* binomial[6 - j][b - j + 1]
							* (-1) ^ (a - i + b - j)
						terms[#terms + 1] = { powers = { a, b }, value = G.mul(value, G.number(integer)) }
					end
				end
			end
		end
		return M.make(terms)
	end
	local patches = {}
	for patch = 1, 3 do
		patches[patch] = {}
	end
	local cells = 0
	for _, orientation in { 1, -1 } do
		local candidate = {}
		for i, x in N do
			candidate[i] = orientation == 1 and x or K.neg(x)
		end
		local valid = true
		for index, patch in patches do
			for component = 1, 3 do
				if component == axis then
					continue
				end
				for _, side in { -1, 1 } do
					local nonnegative = true
					for slot = 0, 35 do
						local offset = (index - 1) * 108 + slot * 3
						local D = G.mul(coefficients[offset + axis], G.rational(candidate[axis]))
						local difference = G.sub(
							G.mul(coefficients[offset + component], G.rational(candidate[axis])),
							G.mul(coefficients[offset + axis], G.rational(candidate[component]))
						)
						local cone = G.add(G.mul(D, G.tolerance), G.mul(difference, G.number(side)))
						if cone.sign < 0 then
							nonnegative = false
							break
						end
					end
					if not nonnegative then
						for j = 1, 3 do
							if not patch[j] then
								patch[j] = powerCoefficients(index - 1, j)
							end
						end
						local D = M.scale(patch[axis], G.rational(candidate[axis]))
						local difference = M.sub(
							M.scale(patch[component], G.rational(candidate[axis])),
							M.scale(patch[axis], G.rational(candidate[component]))
						)
						local cone = M.add(M.scale(D, G.tolerance), M.scale(difference, G.number(side)))
						local result = require(script.Parent.ThomCAD)({ cone }, 2, G, ctx, {
							quantifiers = { "forall", "forall" },
							maxTarskiQueries = options.maxNormalTarskiQueries or 100000,
							maxCells = options.maxNormalCells or 10000,
							maxProjectionPolynomials = options.maxNormalProjectionPolynomials or 256,
						}, function(signs)
							if signs[1] ~= nil then
								return signs[1] >= 0
							end
							return nil
						end)
						cells += result.cells
						if not result.result then
							valid = false
							break
						end
					end
				end
				if not valid then
					break
				end
			end
			if options.checkpoint then
				options.checkpoint({
					stage = "germAnnulus",
					annulus = index,
					orientation = orientation,
					valid = valid,
					allocated = allocated,
				})
			end
			if not valid then
				break
			end
		end
		if valid then
			return {
				normalExists = true,
				candidate = candidate,
				field = K,
				spectrum = spectrum,
				allocated = allocated,
				cells = cells,
				coordinateDegree = #polynomial - 1,
			}
		end
	end
	return { normalExists = false, reason = "nonuniformAnnularNormal", allocated = allocated, cells = cells }
end
