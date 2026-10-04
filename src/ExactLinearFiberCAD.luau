-- Exact cylindrical cells for linear-in-t polynomial inequalities on a rectangle.
-- Event fibers own every s boundary; open slabs have a continuous closed t fiber.
local rootUnion = require(script.Parent.ExactRootUnion)
local algebraic = require(script.Parent.ExactAlgebraicValue)
return function(constraints, domain, R, P, B, settings, ctx)
	local one = R.number(1)
	local minus = R.number(-1)
	local function constant(value)
		return { n = { value }, d = { one } }
	end
	local lower, upper = constant(domain[2][1]), constant(domain[2][2])
	local equations = table.clone(constraints)
	table.insert(equations, { a = { R.neg(domain[2][1]) }, b = { one }, label = "linearMin" })
	table.insert(equations, { a = { domain[2][2] }, b = { minus }, label = "linearMax" })
	local projection, bounds = {}, {}
	for i, e in equations do
		table.insert(projection, e.a)
		table.insert(projection, e.b)
		if #e.b > 0 then
			local common = P.gcd(e.a, e.b)
			bounds[i] = { n = P.scale(P.quotient(e.a, common), minus), d = P.quotient(e.b, common) }
		end
		for j = 1, i - 1 do
			local other = equations[j]
			table.insert(projection, P.add(P.product(e.a, other.b), P.scale(P.product(other.a, e.b), minus)))
		end
	end
	local roots = rootUnion(projection, domain[1][1], domain[1][2], R, P, settings, ctx)
	local function clip(F)
		local low, high = lower, upper
		local lowConstraint, highConstraint = #equations - 1, #equations
		for i, e in equations do
			local sign = F.sign(e.b)
			if sign == 0 then
				if F.sign(e.a) < 0 then
					return nil
				end
			else
				local candidate = bounds[i]
				assert(candidate and F.sign(candidate.d) ~= 0, "Missing finite active bound")
				if sign > 0 and F.compare(candidate, low) > 0 then
					low, lowConstraint = candidate, i
				elseif sign < 0 and F.compare(candidate, high) < 0 then
					high, highConstraint = candidate, i
				end
			end
		end
		local order = F.compare(low, high)
		if order > 0 then
			return nil
		end
		return {
			low = low,
			high = high,
			dimension = order == 0 and 0 or 1,
			lowConstraint = lowConstraint,
			highConstraint = highConstraint,
		}
	end
	local events, slabs = {}, {}
	for i, root in roots do
		local field = algebraic(R, P, B, root, settings)
		events[i] = { root = root, field = field, fiber = clip(field), index = i }
	end
	for i = 1, #events - 1 do
		local a, b = events[i], events[i + 1]
		local x = R.div(R.add(a.root.high, b.root.low), R.number(2))
		assert(R.compare(a.root.high, b.root.low) < 0, "Unordered exact event isolators")
		local field = algebraic(R, P, B, { low = x, high = x, exact = true, depth = 0 }, settings)
		local fiber = clip(field)
		if fiber then
			assert(a.fiber and b.fiber, "Compact feasible slab has a missing endpoint fiber")
			if fiber.dimension == 0 then
				assert(
					#P.add(
							P.product(fiber.low.n, fiber.high.d),
							P.scale(P.product(fiber.high.n, fiber.low.d), minus)
						) == 0,
					"Active graph bounds differ inside a sign-invariant slab"
				)
			end
			local slab = {
				first = i,
				last = i + 1,
				low = fiber.low,
				high = fiber.high,
				dimension = fiber.dimension + 1,
				sample = x,
				lowConstraint = fiber.lowConstraint,
				highConstraint = fiber.highConstraint,
			}
			for _, event in { a, b } do
				local F = event.field
				assert(
					F.sign(slab.low.d) ~= 0 and F.sign(slab.high.d) ~= 0,
					"Bounded slab limit has an uncancelled pole"
				)
				assert(
					F.compare(slab.low, slab.high) <= 0
						and F.compare(slab.low, event.fiber.low) >= 0
						and F.compare(slab.high, event.fiber.high) <= 0,
					"Slab closure is outside its exact endpoint fiber"
				)
			end
			table.insert(slabs, slab)
		end
	end
	return { events = events, slabs = slabs, constraints = equations }
end
