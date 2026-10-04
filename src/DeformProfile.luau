-- Private scalar/two-axis scale profiles with bounded monotone rational graph inversion.
local U = require(script.Parent.Util)
local Core = require(script.Parent.DeformCore)
local N = require(script.Parent.NURBS)
local function valid(value)
	if typeof(value) == "Vector2" then
		assert(U.finite(value.X) and U.finite(value.Y), "Finite taper scales required")
		return value
	end
	Core.scalar(value, "Taper profile must return a number or Vector2")
	return Vector2.one * value
end
return function(profile, ctx)
	if type(profile) == "number" or typeof(profile) == "Vector2" then
		local v = valid(profile)
		return function()
			return v
		end
	end
	if type(profile) == "function" then
		return function(t)
			ctx.visit()
			return valid(profile(t))
		end
	end
	assert(type(profile) == "table", "Taper profile must be a value, callback, knot array or rational curve")
	if profile.kind then
		if profile.kind == "bezier" then
			profile = require(script.Parent.Bezier).toNURBS(profile)
		end
		assert(profile.kind == "curve", "Taper graph must be a nonperiodic rational curve")
		profile = N.clamp(profile)
		for i = 2, #profile.points do
			assert(
				profile.points[i].X >= profile.points[i - 1].X,
				"Taper graph controls must be monotone in X"
			)
		end
		local lo, hi = profile.points[1].X, profile.points[#profile.points].X
		assert(hi > lo, "Taper graph must have positive X extent")
		local prepared = N.compileCurve(profile)
		local limit = U.integer(ctx.options.maxProfileIterations or 48, 1)
		assert(limit <= 64, "Profile iteration limit exceeds parameter precision")
		local tolerance = Core.scalar(ctx.options.profileTolerance or 1e-6)
		assert(tolerance > 0, "Positive profile tolerance required")
		return function(t)
			assert(t >= 0 and t <= 1, "Rational taper graph requires a fraction in [0,1]")
			if t == 0 or t == 1 then
				return valid(prepared.evaluate(t).Y)
			end
			local a, b = 0, 1
			for _ = 1, limit do
				ctx.visit()
				local u = (a + b) / 2
				local p = prepared.evaluate(u)
				local x = (p.X - lo) / (hi - lo)
				if math.abs(x - t) <= tolerance then
					return valid(p.Y)
				end
				if x < t then
					a = u
				else
					b = u
				end
			end
			error("Taper graph inversion did not converge")
		end
	end
	assert(#profile >= 2, "Taper knot array requires at least two samples")
	local knots = {}
	for i, p in profile do
		assert(
			typeof(p) == "Vector2" and U.finite(p.X) and U.finite(p.Y),
			"Taper knots must be Vector2(fraction,scale)"
		)
		assert(
			(i == 1 and p.X == 0) or (i > 1 and p.X > knots[i - 1].X),
			"Increasing taper fractions required"
		)
		knots[i] = p
	end
	assert(knots[#knots].X == 1, "Taper knots must span [0,1]")
	return function(t)
		local lo, hi = 1, #knots - 1
		while lo < hi do
			ctx.visit()
			local mid = math.floor((lo + hi) / 2)
			if knots[mid + 1].X < t then
				lo = mid + 1
			else
				hi = mid
			end
		end
		local a, b = knots[lo], knots[lo + 1]
		return valid(a.Y + (b.Y - a.Y) * (t - a.X) / (b.X - a.X))
	end
end
