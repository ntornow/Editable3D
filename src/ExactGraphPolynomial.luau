return function(R, P, T, ctx)
	local G = {}
	local zero, one, minus = R.number(0), R.number(1), R.number(-1)
	function G.constant(x)
		return x.sign == 0 and {} or { { x } }
	end
	function G.add(a, b)
		ctx.allocate(math.max(#a, #b))
		local out = {}
		for i = 1, math.max(#a, #b) do
			out[i] = P.add(a[i] or {}, b[i] or {})
		end
		return T.trim(out)
	end
	function G.scale(a, k)
		ctx.allocate(#a)
		local out = {}
		for i, c in a do
			out[i] = P.scale(c, k)
		end
		return T.trim(out)
	end
	function G.sub(a, b)
		return G.add(a, G.scale(b, minus))
	end
	function G.affine(row)
		return T.trim({ P.trim({ row[1], row[2] }), P.trim({ row[3] }) })
	end
	function G.compose(p, x, y)
		local out = {}
		for i = #p, 1, -1 do
			local row = {}
			for j = #p[i], 1, -1 do
				row = G.add(T.product(row, x), G.constant(p[i][j]))
			end
			out = G.add(T.product(out, y), row)
		end
		return out
	end
	function G.coefficient(p, i, j)
		return p[j] and p[j][i] or zero
	end
	function G.affineRatio(q, w)
		local w0 = G.coefficient(w, 1, 1)
		assert(w0.sign > 0, "Positive span endpoint weight required")
		local c = R.div(G.coefficient(q, 1, 1), w0)
		local x = R.div(R.sub(G.coefficient(q, 2, 1), R.mul(c, G.coefficient(w, 2, 1))), w0)
		local y = R.div(R.sub(G.coefficient(q, 1, 2), R.mul(c, G.coefficient(w, 1, 2))), w0)
		local row = { c, x, y }
		assert(
			#G.sub(q, T.product(w, G.affine(row))) == 0,
			"Projected surface coordinates are not affine in parameters"
		)
		return row
	end
	function G.global(row, span)
		local x, y = R.div(row[2], span.scale[1]), R.div(row[3], span.scale[2])
		return { R.sub(R.sub(row[1], R.mul(x, span.offset[1])), R.mul(y, span.offset[2])), x, y }
	end
	function G.localMap(row, offset, scale)
		return { R.div(R.sub(row[1], offset), scale), R.div(row[2], scale), R.div(row[3], scale) }
	end
	function G.pool(options)
		local sources, keys = {}, {}
		local function reference(p)
			if #p == 0 then
				return { constant = 0 }
			end
			if #p == 1 and #p[1] == 1 then
				return { constant = p[1][1].sign }
			end
			local leading = p[#p][#p[#p]]
			p = G.scale(p, R.div(one, leading))
			local parts = {}
			for _, row in p do
				local cs = {}
				for _, r in row do
					ctx.visit(1)
					table.insert(cs, r.sign .. ":" .. table.concat(r.n, ",") .. "/" .. table.concat(r.d, ","))
				end
				table.insert(parts, table.concat(cs, ";"))
			end
			local key = table.concat(parts, "|")
			local id = keys[key]
			if not id then
				assert(
					#sources < (options.maxGraphPolynomials or 1024),
					"Graph constraint allocation budget exceeded"
				)
				id = #sources + 1
				keys[key] = id
				table.insert(sources, { p = p, relation = "measure" })
			end
			return { index = id, orientation = leading.sign }
		end
		local function sign(ref, signs)
			return ref.index and ref.orientation * signs[ref.index] or ref.constant
		end
		return sources, reference, sign
	end
	return G
end
