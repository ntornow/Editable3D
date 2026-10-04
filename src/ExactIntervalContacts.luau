-- Intersections of owned algebraic intervals, with either closed or open ends.
return function(a, b, compare, visit, allocate)
	local out = {}
	local function contains(interval, point)
		local lo, hi = compare(point, interval.low), compare(point, interval.high)
		return interval.open and lo > 0 and hi < 0 or not interval.open and lo >= 0 and hi <= 0
	end
	for _, x in a do
		for _, y in b do
			visit()
			local low = compare(x.low, y.low) >= 0 and x.low or y.low
			local high = compare(x.high, y.high) <= 0 and x.high or y.high
			local order = compare(low, high)
			if order < 0 or order == 0 and contains(x, low) and contains(y, low) then
				allocate()
				table.insert(out, {
					first = x,
					second = y,
					low = low,
					high = high,
					openLow = not (contains(x, low) and contains(y, low)),
					openHigh = not (contains(x, high) and contains(y, high)),
				})
			end
		end
	end
	return out
end
