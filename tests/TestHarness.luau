-- Shared runner for deterministic regression suites; errors remain attached to cases.
return function()
	local report = { passed = 0, failed = 0, results = {} }
	local function test(name, fn)
		local ok, err = pcall(fn)
		report[ok and "passed" or "failed"] += 1
		table.insert(report.results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
	end
	local function rejects(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok, "Expected failure")
		assert(not pattern or string.find(tostring(err), pattern, 1, true), tostring(err))
	end
	return report, test, rejects
end
