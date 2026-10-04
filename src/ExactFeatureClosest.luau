-- Exact closest eligible vertex, open edge or triangle interior.
return function(R, visit)
	local zero, one = R.number(0), R.number(1)
	local G = {}
	function G.add(a, b)
		local out = {}
		for i = 1, 3 do
			out[i] = R.add(a[i], b[i])
		end
		return out
	end
	function G.sub(a, b)
		local out = {}
		for i = 1, 3 do
			out[i] = R.sub(a[i], b[i])
		end
		return out
	end
	function G.scale(a, s)
		local out = {}
		for i = 1, 3 do
			out[i] = R.mul(a[i], s)
		end
		return out
	end
	function G.dot(a, b)
		local out = zero
		for i = 1, 3 do
			out = R.add(out, R.mul(a[i], b[i]))
		end
		return out
	end
	function G.cross(a, b)
		local out = {}
		for i = 1, 3 do
			local j, k = i % 3 + 1, (i + 1) % 3 + 1
			out[i] = R.sub(R.mul(a[j], b[k]), R.mul(a[k], b[j]))
		end
		return out
	end
	function G.squared(a, b)
		local delta = G.sub(a, b)
		return G.dot(delta, delta)
	end
	function G.blend(points, weights)
		local out = { zero, zero, zero }
		for i = 1, 3 do
			out = G.add(out, G.scale(points[i], weights[i]))
		end
		return out
	end
	function G.triangle(p, points, allowed)
		allowed = allowed or { true, true, true }
		local selected
		local function offer(weights, dimension, indices)
			visit(1)
			local position = G.blend(points, weights)
			local distance = G.squared(p, position)
			if not selected or R.compare(distance, selected.squared) < 0 then
				selected = {
					position = position,
					squared = distance,
					weights = weights,
					dimension = dimension,
					indices = indices,
				}
			end
		end
		for i = 1, 3 do
			if allowed[i] then
				local weights = { zero, zero, zero }
				weights[i] = one
				offer(weights, 0, { i })
			end
		end
		for i = 1, 3 do
			local j = i % 3 + 1
			if not allowed[i] or not allowed[j] then
				continue
			end
			local e, ap = G.sub(points[j], points[i]), G.sub(p, points[i])
			local d = G.dot(e, e)
			assert(d.sign > 0, "Degenerate feature edge")
			local t = R.div(G.dot(ap, e), d)
			if t.sign > 0 and R.compare(t, one) < 0 then
				local weights = { zero, zero, zero }
				weights[i] = R.sub(one, t)
				weights[j] = t
				offer(weights, 1, { i, j })
			end
		end
		if allowed[1] and allowed[2] and allowed[3] then
			local e, f, q = G.sub(points[2], points[1]), G.sub(points[3], points[1]), G.sub(p, points[1])
			local ee, ef, ff, eq, fq = G.dot(e, e), G.dot(e, f), G.dot(f, f), G.dot(e, q), G.dot(f, q)
			local determinant = R.sub(R.mul(ee, ff), R.mul(ef, ef))
			assert(determinant.sign > 0, "Degenerate feature triangle")
			local u = R.div(R.sub(R.mul(ff, eq), R.mul(ef, fq)), determinant)
			local v = R.div(R.sub(R.mul(ee, fq), R.mul(ef, eq)), determinant)
			local w = R.sub(one, R.add(u, v))
			if u.sign > 0 and v.sign > 0 and w.sign > 0 then
				offer({ w, u, v }, 2, { 1, 2, 3 })
			end
		end
		return selected
	end
	-- Interior closest pair; parallel overlap uses its exact projected midpoint.
	function G.edgePair(a, b)
		local e, f, r = G.sub(a[2], a[1]), G.sub(b[2], b[1]), G.sub(b[1], a[1])
		local ee, ef, ff, er, fr = G.dot(e, e), G.dot(e, f), G.dot(f, f), G.dot(e, r), G.dot(f, r)
		local determinant = R.sub(R.mul(ee, ff), R.mul(ef, ef))
		assert(ee.sign > 0 and ff.sign > 0, "Degenerate feature edge")
		local s, t
		if determinant.sign == 0 then
			local alpha, beta = R.div(er, ee), R.div(ef, ee)
			local finish = R.add(alpha, beta)
			local lo, hi = alpha, finish
			if R.compare(lo, hi) > 0 then
				lo, hi = hi, lo
			end
			if R.compare(lo, zero) < 0 then
				lo = zero
			end
			if R.compare(hi, one) > 0 then
				hi = one
			end
			if R.compare(lo, hi) >= 0 then
				return nil
			end
			s = R.div(R.add(lo, hi), R.number(2))
			t = R.div(R.sub(s, alpha), beta)
		else
			assert(determinant.sign > 0, "Invalid edge Gram determinant")
			s = R.div(R.sub(R.mul(ff, er), R.mul(ef, fr)), determinant)
			t = R.div(R.sub(R.mul(ef, er), R.mul(ee, fr)), determinant)
		end
		if s.sign <= 0 or t.sign <= 0 or R.compare(s, one) >= 0 or R.compare(t, one) >= 0 then
			return nil
		end
		local pa, pb = G.add(a[1], G.scale(e, s)), G.add(b[1], G.scale(f, t))
		return {
			a = s,
			b = t,
			first = pa,
			second = pb,
			squared = G.squared(pa, pb),
			parallel = determinant.sign == 0,
		}
	end
	function G.orientation(reference, current)
		local e0, f0 = G.sub(reference[2], reference[1]), G.sub(reference[3], reference[1])
		local e1, f1 = G.sub(current[2], current[1]), G.sub(current[3], current[1])
		local normal = G.cross(e0, f0)
		local coefficients = {
			G.dot(normal, normal),
			G.dot(normal, G.add(G.cross(e0, f1), G.cross(e1, f0))),
			G.dot(normal, G.cross(e1, f1)),
		}
		return coefficients[1].sign > 0 and coefficients[2].sign > 0 and coefficients[3].sign > 0,
			coefficients
	end
	return G
end
