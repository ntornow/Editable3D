-- Exact common affine projection and closed original-span pair guards.
local N = require(script.Parent.NURBS)
local U = require(script.Parent.Util)
local setup = require(script.Parent.ExactIntersectionSetup)
local extract = require(script.Parent.ExactSurfacePower)
return function(surfaceA, surfaceB, settings)
	local data = setup({ surfaceA, surfaceB }, settings or {})
	local R, P, ctx, options = data.R, data.P, data.ctx, data.options
	ctx.maxDegree = U.integer(options.maxPolynomialDegree or 96, 1)
	ctx.maxPolynomials = U.integer(options.maxPolynomials or 64, 1)
	U.integer(options.maxGraphPolynomials or 1024, 1)
	for _, name in
		{
			"maxMatrixEntries",
			"maxLiftedRoots",
			"maxConnections",
			"maxConnectionPairs",
			"maxSeamNodes",
			"maxSeamPairs",
		}
	do
		if options[name] ~= nil then
			U.integer(options[name], 0)
		end
	end
	local T = require(script.Parent.ExactBivariatePolynomial)(R, P, ctx)
	local G = require(script.Parent.ExactGraphPolynomial)(R, P, T, ctx)
	local zero, one = R.number(0), R.number(1)
	local direction = options.graphDirection == nil and Vector3.zAxis or options.graphDirection
	assert(U.vector(direction), "Finite graph direction required")
	local d = { R.number(direction.X), R.number(direction.Y), R.number(direction.Z) }
	local drop
	for axis = 1, 3 do
		if d[axis].sign ~= 0 then
			drop = axis
			break
		end
	end
	assert(drop, "Nonzero graph direction required")
	local projected = {}
	for axis = 1, 3 do
		if axis ~= drop then
			table.insert(projected, axis)
		end
	end
	local sources, spans, forms = {}, {}, {}
	for operand, input in data.sources do
		assert(type(input) == "table" and input.kind == "surface", "Ordinary graph tensor surface required")
		input.maxControls = data.limits.maxControls
		sources[operand] = N.surface(input.control, input.degreeU, input.degreeV, input)
		spans[operand] = extract(sources[operand], R, P, ctx)
		for _, span in spans[operand] do
			local rows = {}
			for k, axis in projected do
				local q = G.sub(G.scale(span.h[axis], d[drop]), G.scale(span.h[drop], d[axis]))
				rows[k] = G.global(G.affineRatio(q, span.h[4]), span)
			end
			if not forms[operand] then
				forms[operand] = rows
			else
				for i = 1, 2 do
					for j = 1, 3 do
						assert(
							R.equal(rows[i][j], forms[operand][i][j]),
							"Projected affine map differs across original knots"
						)
					end
				end
			end
		end
		local f = forms[operand]
		local determinant = R.sub(R.mul(f[1][2], f[2][3]), R.mul(f[1][3], f[2][2]))
		assert(determinant.sign ~= 0, "Graph projection must have parameter rank two")
	end
	local a, b = forms[1], forms[2]
	local determinant = R.sub(R.mul(b[1][2], b[2][3]), R.mul(b[1][3], b[2][2]))
	local map = { {}, {} }
	for j = 1, 3 do
		local x = j == 1 and R.sub(a[1][j], b[1][j]) or a[1][j]
		local y = j == 1 and R.sub(a[2][j], b[2][j]) or a[2][j]
		map[1][j] = R.div(R.sub(R.mul(x, b[2][3]), R.mul(y, b[1][3])), determinant)
		map[2][j] = R.div(R.sub(R.mul(y, b[1][2]), R.mul(x, b[2][2])), determinant)
	end
	local variables = { { zero, one, zero }, { zero, zero, one } }
	local maps = { variables, map }
	local polys, reference, sign = G.pool(options)
	local domainRefs = {}
	for axis = 1, 2 do
		local p = G.affine(map[axis])
		table.insert(domainRefs, reference(G.sub(p, G.constant(data.bounds[axis + 2][1]))))
		table.insert(domainRefs, reference(G.sub(G.constant(data.bounds[axis + 2][2]), p)))
	end
	for operand, tiles in spans do
		for _, span in tiles do
			span.original = span.h
			span.h = {}
			local localMap = {}
			span.bounds = {}
			for axis = 1, 2 do
				localMap[axis] =
					G.affine(G.localMap(maps[operand][axis], span.offset[axis], span.scale[axis]))
				table.insert(span.bounds, reference(localMap[axis]))
				table.insert(span.bounds, reference(G.sub({ { one } }, localMap[axis])))
			end
			for axis = 1, 4 do
				span.h[axis] = G.compose(span.original[axis], localMap[1], localMap[2])
			end
			span.u = T.product(span.h[4], G.affine(map[1]))
			span.v = T.product(span.h[4], G.affine(map[2]))
		end
	end
	assert(#spans[1] * #spans[2] <= ctx.maxPieces, "Graph span-pair budget exceeded")
	local pairs = {}
	for ai, sa in spans[1] do
		for bi, sb in spans[2] do
			local height = G.sub(T.product(sa.h[drop], sb.h[4]), T.product(sb.h[drop], sa.h[4]))
			table.insert(pairs, { a = ai, b = bi, height = reference(height), heightPolynomial = height })
		end
	end
	local function inside(bounds, signs)
		for _, ref in bounds do
			if sign(ref, signs) < 0 then
				return false
			end
		end
		return true
	end
	local function owner(signs)
		if not inside(domainRefs, signs) then
			return nil
		end
		for i, pair in pairs do
			if
				sign(pair.height, signs) == 0
				and inside(spans[1][pair.a].bounds, signs)
				and inside(spans[2][pair.b].bounds, signs)
			then
				return i
			end
		end
		return nil
	end
	return {
		data = data,
		spans = spans,
		projectionForms = forms,
		parameterMap = map,
		polynomials = polys,
		pairs = pairs,
		owner = owner,
		domainRefs = domainRefs,
		direction = direction,
		drop = drop,
	}
end
