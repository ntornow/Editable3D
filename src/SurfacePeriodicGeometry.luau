-- Exact C0 seam identity for the expanded stored-knot model, with cheap shortcuts.
-- This is not a proximity test and does not assume rounded knots are periodic.
local X = require(script.Parent.ExpansionArithmetic)
local function fast(input, source, direction, ctx)
	local alongU = direction == 1
	local degree = alongU and source.degreeU or source.degreeV
	local count = alongU and #input.control or #input.control[1]
	local other = alongU and #source.control[1] or #source.control
	for i = 1, degree do
		for j = 1, other do
			local a, b, c, d =
				alongU and i or j, alongU and j or i, alongU and i + count or j, alongU and j or i + count
			ctx.visit(2)
			if
				source.control[a][b] ~= source.control[c][d]
				or source.weights[a][b] ~= source.weights[c][d]
			then
				return false, "controlIdentity"
			end
		end
	end
	-- A degree-one span interpolates its endpoint homogeneous controls, even
	-- when its neighboring positive knot intervals have different lengths.
	if degree == 1 then
		return true, "repeatedEndpointControls"
	end
	local knots = alongU and source.knotsU or source.knotsV
	-- twoSum expansions are exact on this common dyadic lattice. These limits
	-- keep every possible residual normal and every sum finite, including FTZ.
	for _, value in knots do
		ctx.visit()
		if math.abs(value) > 2 ^ 900 or (value ~= 0 and math.abs(value) < 2 ^ -900) then
			return false, "knotExponentRange"
		end
	end
	local period = X.difference(knots[count + degree + 1], knots[degree + 1])
	for i = 1, 2 * degree + 1 do
		ctx.visit(16)
		if X.sign(X.subtract(X.difference(knots[i + count], knots[i]), period)) ~= 0 then
			return false, "storedKnotsNotExactTranslates"
		end
	end
	-- Translated local knot neighborhoods and repeated homogeneous controls
	-- give equal boundary basis values. Valid cyclic multiplicity is <= degree,
	-- hence at least C0. Higher derivative continuity is not claimed here.
	return true, "exactKnotTranslation"
end

return function(input, source, direction, ctx)
	local certified, reason = fast(input, source, direction, ctx)
	if certified then
		return true, reason
	end
	ctx.check("seamIdentity")
	local same, identity = require(script.Parent.SurfaceBoundaryIdentity)(source, direction, ctx)
	ctx.check("seamIdentity")
	return same, same and identity.reason or reason, identity
end
