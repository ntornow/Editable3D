-- Native classification first; exact rational samples recover precision failures.
local U = require(script.Parent.Util)
return function(data, options, regions)
	options = options or {}
	local precision = options.windingPrecision or "auto"
	assert(
		precision == "auto" or precision == "native" or precision == "exact",
		"Winding precision must be auto, native or exact"
	)
	local bits = U.integer(options.maxExactBits == nil and 8192 or options.maxExactBits, 1)
	local coefficients =
		U.integer(options.maxExactCoefficients == nil and 1000000 or options.maxExactCoefficients, 1)
	local failure
	if precision ~= "exact" then
		-- The private identity separates precision failures from callbacks and caps.
		local token = {}
		local ok, selection, report = pcall(
			require(script.Parent.MeshWindingBoundaryNative),
			data,
			options,
			regions,
			function(reason)
				error({ token = token, reason = reason }, 0)
			end
		)
		if ok then
			report.windingPrecision, report.sampleMethod = precision, "native"
			report.exactFragments, report.exactWork, report.exactSamples = 0, 0, false
			return selection, report
		end
		if type(selection) ~= "table" or selection.token ~= token then
			error(selection, 0)
		end
		failure = selection.reason
		assert(precision ~= "native", "Native winding classification precision failure: " .. failure)
	end
	local selection, report =
		require(script.Parent.MeshWindingBoundaryExact)(data, options, regions, bits, coefficients)
	report.windingPrecision, report.nativeFailure = precision, failure
	return selection, report
end
