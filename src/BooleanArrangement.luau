-- Private Boolean occupancy over a shared, audited triangle arrangement.
local U = require(script.Parent.Util)
local I = require(script.Parent.Intersections)
return function(a, b, operation, options, inputIntersections)
	local config = table.clone(options)
	if config.epsilon ~= nil then
		assert(
			type(config.epsilon) == "number" and U.finite(config.epsilon) and config.epsilon > 0,
			"Positive finite epsilon required"
		)
		config.tolerance = config.tolerance or config.epsilon
	end
	config.maxFaces = config.maxFaces or config.maxPolygons
	if options.cancelled or options.yieldEvery or options.checkpoint then
		config.checkpoint = function(state)
			assert(not options.cancelled or not options.cancelled(), "Boolean cancelled")
			if options.checkpoint then
				options.checkpoint(state)
			end
			if options.yieldEvery then
				task.wait()
			end
		end
	end
	for _, source in { a, b } do
		local v = source:validate()
		assert(
			v.valid and (v.closed or not next(source.faces)),
			"Arrangement Boolean requires closed oriented input sheets"
		)
	end
	local rules = {
		options.windingRuleA or options.windingRule or "nonzero",
		options.windingRuleB or options.windingRule or "nonzero",
	}
	for _, rule in rules do
		assert(
			rule == "nonzero" or rule == "positive" or rule == "odd",
			"Winding rule must be nonzero, positive or odd"
		)
	end
	local function inside(number, rule)
		if rule == "positive" then
			return number > 0
		end
		if rule == "odd" then
			return math.abs(number) % 2 == 1
		end
		return number ~= 0
	end
	local source, _, inputMaps = require(script.Parent.BooleanSources)(a, b, options.materialOffsetB)
	local groups = {}
	for fid, origin in inputMaps.face do
		groups[fid] = origin.operand == "a" and 1 or 2
	end
	local data = require(script.Parent.MeshArrangement)(source, config)
	if data.report.regularization and data.report.regularization.maps then
		local remapped = {}
		for fid, refs in data.report.regularization.maps.face do
			assert(#refs == 1 and groups[refs[1][1]], "Regularized Boolean face has no source operand")
			remapped[fid] = groups[refs[1][1]]
		end
		groups = remapped
	end
	local selection, classification = require(script.Parent.MeshWindingBoundary)(data, config, {
		count = 2,
		groups = groups,
		contains = function(numbers)
			local left, right = inside(numbers[1], rules[1]), inside(numbers[2], rules[2])
			if operation == "union" then
				return left or right
			end
			if operation == "subtract" then
				return left and not right
			end
			return left and right
		end,
	})
	local conformity = require(script.Parent.MeshArrangementConform)(data, selection, config)
	local mesh, report = require(script.Parent.MeshArrangementBuild)(data, selection, false, config)
	local scan = table.clone(options.intersectionOptions or {})
	scan.maxWork = scan.maxWork or options.maxWork
	scan.includeAdjacent, scan.includeContacts = false, true
	scan.checkpoint = scan.checkpoint or config.checkpoint
	local _, audit = I.mesh(mesh, scan)
	report.method, report.operation = "arrangement", operation
	report.windingRules = { a = rules[1], b = rules[2] }
	report.arrangement, report.classification, report.conformity = data.report, classification, conformity
	report.intersections, report.inputIntersections, report.inputMaps = audit, inputIntersections, inputMaps
	report.work = data.getWork()
	report.empty = not next(mesh.faces)
	report.complete = report.validation.valid
		and (report.empty or report.validation.closed)
		and audit.complete
		and audit.intersectionFree
	if not report.complete then
		report.reason = not report.validation.valid and "invalid_topology"
			or not (report.empty or report.validation.closed) and "open_boundary"
			or not audit.complete and "incomplete_audit"
			or "remaining_intersections"
	end
	assert(
		report.complete or options.allowInvalid and not options.checkIntersections,
		"Arrangement Boolean unresolved: " .. tostring(report.reason)
	)
	return mesh, report
end
