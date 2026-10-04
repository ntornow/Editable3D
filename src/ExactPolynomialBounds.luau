-- Rational interval Horner bounds; outward float conversion happens only at the end.
return function(R, P, visit)
	local zero = R.number(0)
	local B = {}
	local function hull(values)
		local lo, hi = values[1], values[1]
		for _, x in values do
			if R.compare(x, lo) < 0 then
				lo = x
			end
			if R.compare(x, hi) > 0 then
				hi = x
			end
		end
		return { lo, hi }
	end
	function B.neg(a)
		return { R.neg(a[2]), R.neg(a[1]) }
	end
	function B.add(a, b)
		return { R.add(a[1], b[1]), R.add(a[2], b[2]) }
	end
	function B.mul(a, b)
		return hull({ R.mul(a[1], b[1]), R.mul(a[1], b[2]), R.mul(a[2], b[1]), R.mul(a[2], b[2]) })
	end
	function B.evaluate(p, range)
		if R.equal(range[1], range[2]) then
			local x = P.evaluate(p, range[1])
			return { x, x }
		end
		local out = { zero, zero }
		for i = #p, 1, -1 do
			out = hull({
				R.mul(out[1], range[1]),
				R.mul(out[1], range[2]),
				R.mul(out[2], range[1]),
				R.mul(out[2], range[2]),
			})
			out = { R.add(out[1], p[i]), R.add(out[2], p[i]) }
			visit(1)
		end
		return out
	end
	function B.intersect(a, b)
		local lo = R.compare(a[1], b[1]) > 0 and a[1] or b[1]
		local hi = R.compare(a[2], b[2]) < 0 and a[2] or b[2]
		assert(R.compare(lo, hi) <= 0, "Disjoint proved rational enclosures")
		return { lo, hi }
	end
	function B.divide(a, b)
		assert(b[1].sign > 0, "Positive rational interval denominator required")
		return hull({ R.div(a[1], b[1]), R.div(a[1], b[2]), R.div(a[2], b[1]), R.div(a[2], b[2]) })
	end
	return B
end
