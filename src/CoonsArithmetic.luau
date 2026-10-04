-- Private scalar arithmetic with conservative absolute floating-point allowances.
-- These are propagated error estimates, not hardware-directed interval rounding.
local EPS = 2.220446049250313e-16
local TINY = 5e-324
return function(visit)
	local O = {}
	function O.value(x, e)
		return { x, e or 0 }
	end
	function O.add(a, b)
		visit()
		return { a[1] + b[1], a[2] + b[2] + 4 * EPS * (math.abs(a[1]) + math.abs(b[1])) + TINY }
	end
	function O.neg(a)
		return { -a[1], a[2] }
	end
	function O.sub(a, b)
		return O.add(a, O.neg(b))
	end
	function O.mul(a, b)
		visit()
		local v = a[1] * b[1]
		return {
			v,
			math.abs(a[1]) * b[2] + math.abs(b[1]) * a[2] + a[2] * b[2] + 4 * EPS * math.abs(v) + TINY,
		}
	end
	function O.div(a, b)
		visit()
		local v = a[1] / b[1]
		local lower = math.abs(b[1]) - b[2]
		return {
			v,
			lower > 0 and (a[2] + math.abs(v) * b[2]) / lower + 4 * EPS * math.abs(v) + TINY or math.huge,
		}
	end
	function O.mix(a, b, t)
		return O.add(O.mul(a, O.sub(O.value(1), t)), O.mul(b, t))
	end
	return O
end
