-- Exact positive-area UV overlap decisions; numerical distortion measurements.
local Core = require(script.Parent.UVIslandCore)
local P = require(script.Parent.Predicates)
local U = require(script.Parent.Util)
local D = {}
function D.overlap(a, b, visit)
	if a.orientation == 0 or b.orientation == 0 or not a.uv or not b.uv then
		return false
	end
	for _, pair in { { a, b }, { b, a } } do
		for i = 1, 3 do
			local inside = false
			for _, point in pair[2].uv do
				visit(1)
				if P.orient2D(pair[1].uv[i], pair[1].uv[i % 3 + 1], point) * pair[1].orientation > 0 then
					inside = true
				end
			end
			if not inside then
				return false
			end
		end
	end
	return true
end
function D.scan(context, withinOnly)
	local maxOverlaps = U.integer(context.options.maxOverlaps or 10000, 0)
	local ordered = {}
	for _, triangle in context.triangles do
		if triangle.uv and triangle.orientation ~= 0 then
			table.insert(ordered, triangle)
		end
	end
	table.sort(ordered, function(a, b)
		return a.minimum[1] == b.minimum[1] and a.index < b.index or a.minimum[1] < b.minimum[1]
	end)
	local overlaps, count, internal = {}, 0, {}
	for i, a in ordered do
		for j = i + 1, #ordered do
			context.visit(1)
			local b = ordered[j]
			if b.minimum[1] >= a.maximum[1] then
				break
			end
			if
				(not withinOnly or a.island == b.island)
				and b.minimum[2] < a.maximum[2]
				and a.minimum[2] < b.maximum[2]
				and D.overlap(a, b, context.visit)
			then
				count += 1
				if a.island == b.island then
					internal[a.island] = (internal[a.island] or 0) + 1
				end
				if #overlaps < maxOverlaps then
					table.insert(overlaps, {
						a = a.index,
						b = b.index,
						faceA = a.face,
						faceB = b.face,
						islandA = a.island,
						islandB = b.island,
					})
				end
			end
		end
	end
	return {
		overlaps = overlaps,
		overlapCount = count,
		overlapsTruncated = #overlaps < count,
		internalOverlaps = internal,
	}
end
function D.run(context)
	local report = Core.summary(context)
	report.triangles = U.copy(context.triangles)
	report.positiveTriangles, report.negativeTriangles, report.degenerateTriangles, report.missingCorners =
		0, 0, 0, 0
	report.surfaceArea, report.uvArea, report.maximumAnisotropy = 0, 0, 0
	report.mixedOrientationIslands = {}
	for _, island in context.islands do
		report.positiveTriangles += island.positiveTriangles
		report.negativeTriangles += island.negativeTriangles
		report.degenerateTriangles += island.degenerateTriangles
		report.missingCorners += #island.missing
		report.surfaceArea += island.surfaceArea
		report.uvArea += island.uvArea
		if island.mixedOrientation then
			table.insert(report.mixedOrientationIslands, island.id)
		end
	end
	for _, triangle in context.triangles do
		report.maximumAnisotropy = math.max(report.maximumAnisotropy, triangle.anisotropy or 0)
	end
	report.overlapChecked = context.options.checkOverlaps ~= false
	if report.overlapChecked then
		local scan = D.scan(context)
		for name, value in scan do
			report[name] = value
		end
		report.overlapFree = scan.overlapCount == 0 and report.missingCorners == 0
	end
	report.complete = report.missingCorners == 0
	report.consistentOrientation = report.complete
		and report.degenerateTriangles == 0
		and #report.mixedOrientationIslands == 0
	report.allPositive = report.complete and report.negativeTriangles == 0 and report.degenerateTriangles == 0
	context.checkpoint("analysis")
	report.work = context.work
	assert(
		not context.options.requireComplete or report.complete,
		"UV analysis incomplete: missing or nonfinite UVs"
	)
	return report
end
return D
