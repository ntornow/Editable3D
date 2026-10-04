-- Compare directions represented at two independently isolated real roots.
-- The recursive self-require is deferred; the analyzer does not follow it.
local deferredRequire = require :: any
return function(R, P, F, a, G, b, visit, allocate)
	local minus = R.number(-1)
	if G == F then
		for _, pair in { { 1, 2 }, { 2, 3 }, { 3, 1 } } do
			if
				F.sign(
					P.add(
						P.product(a[pair[1]], b[pair[2]]),
						P.scale(P.product(a[pair[2]], b[pair[1]]), minus)
					)
				) ~= 0
			then
				return false
			end
		end
		local axis = 1
		while F.sign(a[axis]) == 0 do
			axis += 1
		end
		return F.sign(a[axis]) * F.sign(b[axis]) > 0
	end
	local rational = true
	for _, p in a do
		if #p > 1 then
			rational = false
			break
		end
	end
	if rational then
		for _, pair in { { 1, 2 }, { 2, 3 }, { 3, 1 } } do
			if
				G.sign(
					P.add(
						P.scale(b[pair[2]], a[pair[1]][1] or R.number(0)),
						P.scale(b[pair[1]], R.neg(a[pair[2]][1] or R.number(0)))
					)
				) ~= 0
			then
				return false
			end
		end
		local axis = 1
		while #a[axis] == 0 or a[axis][1].sign == 0 do
			axis += 1
		end
		return a[axis][1].sign * G.sign(b[axis]) > 0
	end
	if G.root.exact then
		local c = {}
		for i, p in b do
			c[i] = { P.evaluate(p, G.root.low) }
		end
		return deferredRequire(script.Parent.CompareAlgebraicDirections)(R, P, F, a, F, c, visit, allocate)
	end
	-- Build a separate coefficient-field facade so local denominator reductions
	-- cannot change either root's original isolating polynomial.
	local facade = table.clone(F)
	facade.root = setmetatable(
		{ analysis = { squarefree = F.modulus and F.modulus() or F.root.analysis.squarefree } },
		{ __index = F.root }
	)
	local K = require(script.Parent.ReducedAlgebraicField)(R, P, facade, allocate)
	local degree = #G.root.analysis.squarefree - 1
	local Q = require(script.Parent.ExactPolynomialRoots)(K, visit, 2 * degree + 2, allocate)
	local root = {
		low = K.rational(G.root.low),
		high = K.rational(G.root.high),
		exact = false,
		analysis = {
			squarefree = {},
		},
	}
	for i, x in G.root.analysis.squarefree do
		root.analysis.squarefree[i] = K.rational(x)
	end
	local aa = {}
	for i, p in a do
		aa[i] = K.fromPolynomial(p)
	end
	local function signDifference(i, j)
		local g = {}
		for k = 1, math.max(#b[i], #b[j]) do
			g[k] = K.sub(
				K.mul(aa[i], K.rational(b[j][k] or R.number(0))),
				K.mul(aa[j], K.rational(b[i][k] or R.number(0)))
			)
		end
		return require(script.Parent.SturmTarskiSign)(K, Q, root, Q.trim(g))
	end
	for _, pair in { { 1, 2 }, { 2, 3 }, { 3, 1 } } do
		if signDifference(pair[1], pair[2]) ~= 0 then
			return false
		end
	end
	local axis = 1
	while aa[axis].sign == 0 do
		axis += 1
	end
	return aa[axis].sign * G.sign(b[axis]) > 0
end
