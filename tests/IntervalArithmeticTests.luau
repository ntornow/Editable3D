return function()
	local I = require(script.Parent.DirectedInterval)
	local fixtures: any = { steps = {}, arithmetic = {} }
	for i = 1, 3 do
		local part = require(script.Parent["IntervalFixtures" .. i])
		fixtures.counts = part.counts
		for _, row in part.steps do
			table.insert(fixtures.steps, row)
		end
		for _, row in part.arithmetic do
			table.insert(fixtures.arithmetic, row)
		end
	end
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local scratch = buffer.create(8)
	local function decode(s)
		buffer.writeu32(scratch, 0, assert(tonumber(s:sub(9, 16), 16)))
		buffer.writeu32(scratch, 4, assert(tonumber(s:sub(1, 8), 16)))
		return buffer.readf64(scratch, 0)
	end
	local function interval(p)
		return { decode(p[1]), decode(p[2]) }
	end
	local function encode(value)
		buffer.writef64(scratch, 0, value)
		return string.format("%08x%08x", buffer.readu32(scratch, 4), buffer.readu32(scratch, 0))
	end
	local function ordered(a, b)
		local x, y = encode(a), encode(b)
		if x == "8000000000000000" then
			x = "0000000000000000"
		end
		if y == "8000000000000000" then
			y = "0000000000000000"
		end
		local xn, yn = x:sub(1, 1) >= "8", y:sub(1, 1) >= "8"
		if xn ~= yn then
			return xn
		end
		return xn and x >= y or not xn and x <= y
	end
	test("Adjacent IEEE754 doubles match 1020 independent Python nextafter results", function()
		assert(#fixtures.steps == 510)
		for _, v in fixtures.steps do
			local x = decode(v[1])
			assert(encode(I.up(x)) == v[2], "nextUp " .. v[1])
			assert(encode(I.down(x)) == v[3], "nextDown " .. v[1])
		end
	end)
	for _, operation in { "add", "sub", "mul", "div" } do
		test("Directed interval " .. operation .. " encloses independent exact Fraction endpoints", function()
			local count = 0
			for i, v in fixtures.arithmetic do
				if v[1] == operation then
					local result = I[operation](interval(v[2]), interval(v[3]))
					local expected = interval(v[4])
					assert(
						ordered(result[1], expected[1]) and ordered(expected[2], result[2]),
						operation .. " fixture " .. i
					)
					count += 1
				end
			end
			assert(count == fixtures.counts[operation] and count >= (operation == "div" and 253 or 500))
		end)
	end
	test("Zero unbounded arithmetic subnormal squares and interval sets remain conservative", function()
		local z = I.mul({ 0, 0 }, I.whole())
		assert(z[1] == 0 and z[2] == 0)
		assert(I.div({ 1, 2 }, { -1, 1 })[1] == -math.huge)
		local squared = I.square({ -0.3, 0.2 })
		assert(squared[1] == 0 and squared[2] >= 0.09)
		local subnormal = decode("0000000000000001")
		local tiny = I.square({ subnormal, subnormal })
		assert(tiny[1] == 0 and tiny[2] > 0)
		assert(not I.isNormal(subnormal) and I.isNormal(0) and I.isNormal(decode("0010000000000000")))
		assert(not I.contains({ 0, 0 }, subnormal) and I.contains(I.new(subnormal), subnormal))
		local root = I.sqrt({ 0, 4 })
		assert(root[1] == 0 and root[2] >= 2)
		assert(I.intersect({ 1, 2 }, { 3, 4 }) == nil and I.intersect({ 1, 2 }, { 2, 3 })[1] == 2)
		assert(I.contains(I.hull({ -1, 0 }, { 2, 3 }), 1) and I.zero({ 0, 1 }))
	end)
	test("Invalid interval endpoints square roots and NaN steps reject", function()
		assert(not pcall(I.up, 0 / 0) and not pcall(I.new, 2, 1) and not pcall(I.new, 0 / 0, 1))
		assert(not pcall(I.sqrt, { -1, 2 }) and not pcall(I.mid, { -math.huge, 1 }))
	end)
	report.success = report.failed == 0
	return report
end
