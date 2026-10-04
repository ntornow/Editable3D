-- Complete periodic identification of exact ruled contact event fibers.
local U = require(script.Parent.Util)
return function(data)
	local report, R, P, ctx = data.report, data.R, data.P, data.ctx
	local source, options = data.sources[1], data.options
	local stats = {
		requested = true,
		axes = {},
		joins = {},
		components = {},
		vertexClasses = {},
		vertexMap = {},
		unresolved = {},
		topologyCertified = false,
		complete = false,
		nodes = 0,
		pairs = 0,
	}
	report.periodicQuotient = stats
	report.quotientTopologyCertified, report.quotientComplete = false, false
	local maxNodes = U.integer(options.maxSeamNodes or 20000, 0)
	local maxPairs = U.integer(options.maxSeamPairs or 100000, 0)
	local function node()
		assert(stats.nodes < maxNodes, "Exact ruled seam node budget exceeded")
		stats.nodes += 1
		ctx.visit(1)
	end
	local function compare(a, b)
		assert(stats.pairs < maxPairs, "Exact ruled seam comparison budget exceeded")
		stats.pairs += 1
		return R.compare(a, b)
	end
	ctx.check("seamGeometry")
	local axis, linear = report.profileAxis, report.linearAxis
	local cyclic = source.kind == "cyclicSurface" and source[axis == 1 and "cyclicU" or "cyclicV"] ~= false
	local first, last = report.events[1], report.events[#report.events]
	local active = false
	if cyclic then
		active = report.parameterBox[axis][1] == 0 and report.parameterBox[axis][2] == 1
		local entry = { axis = axis, enabled = active, certified = false, reason = "restrictedRange" }
		table.insert(stats.axes, entry)
		if active then
			assert(
				first and last and first.parameterExact and last.parameterExact,
				"Missing exact source seam events"
			)
			assert(R.equal(first.parameterExact, R.number(0)) and R.equal(last.parameterExact, R.number(1)))
			local a, b = first.homogeneousExact, last.homogeneousExact
			local left, right = {}, {}
			for i = 1, 4 do
				left[i] = P.trim({ a[1][i], a[2][i] })
				right[i] = P.trim({ b[1][i], b[2][i] })
			end
			for i = 1, 3 do
				node()
				local difference =
					P.add(P.product(left[i], right[4]), P.scale(P.product(right[i], left[4]), R.number(-1)))
				if #difference > 0 then
					entry.reason = "differentBoundaryCurves"
					entry.identity =
						{ certified = true, equal = false, coordinate = i, difference = difference }
					stats.reason = "seamGeometry"
					table.insert(
						stats.unresolved,
						{ axis = axis, reason = entry.reason, identity = entry.identity }
					)
					return
				end
			end
			entry.certified, entry.reason = true, "exactRulingIdentity"
			entry.identity = { certified = true, equal = true, homogeneous = { left, right } }
			assert(first.feasible == last.feasible, "Periodic seam fiber feasibility differs")
			if first.feasible then
				node()
				for i = 1, 2 do
					assert(
						R.equal(first.linearBoundsExact[i], last.linearBoundsExact[i]),
						"Periodic seam fiber bounds differ"
					)
				end
				table.insert(stats.joins, {
					axis = axis,
					firstEvent = first.index,
					lastEvent = last.index,
					firstCell = first.cell,
					lastCell = last.cell,
					linearRangeExact = first.linearBoundsExact,
					parameterDimension = report.cells[first.cell].parameterDimension,
					certified = true,
					correspondence = "The full closed fibers are identified at equal normalized ruling parameter",
				})
			end
		end
	end
	ctx.check("seamComponents")
	local owners = {}
	for i in report.components do
		owners[i] = i
	end
	local function owner(i)
		while owners[i] ~= i do
			i = owners[i]
			ctx.visit(1)
		end
		return i
	end
	for _, join in stats.joins do
		local a = report.cells[join.firstCell].component
		local b = report.cells[join.lastCell].component
		owners[owner(b)] = owner(a)
	end
	local groups = {}
	for i, component in report.components do
		local key = owner(i)
		if not groups[key] then
			groups[key] = {
				index = #stats.components + 1,
				parameterComponentIndices = {},
				cellIndices = {},
				joinIndices = {},
				parameterDimension = 0,
				connected = true,
				certified = true,
			}
			table.insert(stats.components, groups[key])
		end
		local group = groups[key]
		table.insert(group.parameterComponentIndices, i)
		for _, cell in component.cellIndices do
			table.insert(group.cellIndices, cell)
			ctx.visit(1)
		end
		group.parameterDimension = math.max(group.parameterDimension, component.parameterDimension)
	end
	for i, join in stats.joins do
		table.insert(groups[owner(report.cells[join.firstCell].component)].joinIndices, i)
	end
	local seam = {}
	if active and first.feasible then
		for i, v in report.vertices do
			node()
			if v.event == first.index or v.event == last.index then
				assert(v.parametersExact, "Source seam anchors must have exact rational parameters")
				table.insert(seam, { index = i, t = v.parametersExact[linear] })
			end
		end
	end
	table.sort(seam, function(a, b)
		local order = compare(a.t, b.t)
		return order < 0 or order == 0 and a.index < b.index
	end)
	local representative, parameters = {}, {}
	local previous
	for _, entry in seam do
		ctx.visit(1)
		if previous and compare(entry.t, previous.t) == 0 then
			representative[entry.index] = representative[previous.index]
		else
			representative[entry.index] = entry.index
		end
		parameters[representative[entry.index]] = entry.t
		previous = entry
	end
	local classes = {}
	for i in report.vertices do
		ctx.visit(1)
		local key = representative[i] or i
		if not classes[key] then
			classes[key] = {
				index = #stats.vertexClasses + 1,
				representative = key,
				vertexIndices = {},
				seam = parameters[key] ~= nil,
				linearParameterExact = parameters[key],
			}
			table.insert(stats.vertexClasses, classes[key])
		end
		table.insert(classes[key].vertexIndices, i)
		stats.vertexMap[i] = classes[key].index
	end
	stats.componentCount = #stats.components
	stats.topologyCertified, stats.contactsCertified, stats.componentsCertified = true, true, true
	stats.complete = report.complete
	stats.reason = stats.complete and "complete" or "approximation"
	stats.representation =
		"Original exact parameter cells with full equal-ruling-parameter seam fiber identifications"
	report.quotientTopologyCertified, report.quotientComplete = true, stats.complete
	report.quotientComponentCount = stats.componentCount
	ctx.check("seamFinish")
end
