-- Whole-chart UV edits preserve every geometry/data channel and invalidate changed tangents.
local Core = require(script.Parent.UVIslandCore)
local P = require(script.Parent.Predicates)
local U = require(script.Parent.Util)
local E = {}
function E.requireChart(island)
	assert(
		#island.missing == 0 and island.degenerateTriangles == 0 and island.uvArea > 0,
		"UV edit requires complete nondegenerate selected charts"
	)
end
function E.apply(context, plans)
	local out = context.mesh:clone()
	local report = { complete = true, changedCorners = 0, islands = {}, maximumNativeError = 0 }
	for _, island in context.islands do
		local plan = plans[island.id]
		if plan then
			E.requireChart(island)
			local result = {
				id = island.id,
				nativeOrientationChanges = 0,
				maximumNativeError = 0,
				uvArea = 0,
				density = 0,
			}
			for _, ref in island.corners do
				context.visit(1)
				local source = context.mesh.faces[ref.face].corners[ref.corner].uv
				local x, y = plan.map(source.X, source.Y)
				local uv = Vector2.new(x, y)
				if not Core.vector(uv) then
					report.complete, report.reason, report.work = false, "nativeOverflow", context.work
					assert(not context.options.requireComplete, "UV edit native coordinate overflow")
					return context.mesh:clone(), report
				end
				local errorX, errorY = (uv.X - x) * context.size.X, (uv.Y - y) * context.size.Y
				result.maximumNativeError =
					math.max(result.maximumNativeError, math.sqrt(errorX * errorX + errorY * errorY))
				local corner = out.faces[ref.face].corners[ref.corner]
				if uv ~= source then
					corner.uv, corner.tangent, corner.tangentSign = uv, nil, nil
					report.changedCorners += 1
				end
			end
			for _, triangle in island.triangles do
				context.visit(1)
				local corners = out.faces[triangle.face].corners
				local sign, area = P.orient2D(
					corners[triangle.corners[1]].uv,
					corners[triangle.corners[2]].uv,
					corners[triangle.corners[3]].uv
				)
				result.uvArea += math.abs(area) / 2
				if sign ~= triangle.orientation * plan.orientation then
					result.nativeOrientationChanges += 1
				end
			end
			result.density = math.sqrt(result.uvArea * context.size.X * context.size.Y / island.surfaceArea)
			result.expectedDensity = plan.expectedDensity
			report.maximumNativeError = math.max(report.maximumNativeError, result.maximumNativeError)
			report.complete = report.complete and result.nativeOrientationChanges == 0
			table.insert(report.islands, result)
		end
	end
	if not report.complete then
		report.reason = "nativeOrientation"
	end
	context.checkpoint("edited")
	report.work = context.work
	assert(not context.options.requireComplete or report.complete, "UV edit incomplete after native rounding")
	return out, report
end
function E.transform(source, transforms, settings)
	assert(type(transforms) == "table", "UV island transforms must be a dictionary")
	local copied = U.copy(transforms)
	local context = Core.prepare(source, settings)
	local plans = {}
	for id, transform in copied do
		local island = assert(context.byId[id], "Invalid UV transform island ID")
		assert(island.selected and type(transform) == "table", "UV transform must name a selected island")
		E.requireChart(island)
		local translation = transform.translation or Vector2.zero
		local scale = transform.scale or 1
		if type(scale) == "number" then
			assert(U.finite(scale) and scale ~= 0, "UV scale must be finite and nonzero")
			scale = { scale, scale }
		else
			assert(
				Core.vector(scale) and scale.X ~= 0 and scale.Y ~= 0,
				"UV scale must be finite and nonzero"
			)
			scale = { scale.X, scale.Y }
		end
		local angle = transform.rotation or 0
		assert(
			Core.vector(translation) and type(angle) == "number" and U.finite(angle),
			"Invalid UV transform"
		)
		local pivot = transform.pivot
		assert(pivot == nil or Core.vector(pivot), "Invalid UV pivot")
		local px = pivot and pivot.X or (island.minimum[1] + island.maximum[1]) / 2
		local py = pivot and pivot.Y or (island.minimum[2] + island.maximum[2]) / 2
		local cosine, sine = math.cos(angle), math.sin(angle)
		plans[id] = {
			orientation = (scale[1] > 0) == (scale[2] > 0) and 1 or -1,
			map = function(x, y)
				local a, b = (x - px) * scale[1], (y - py) * scale[2]
				return px + cosine * a - sine * b + translation.X, py + sine * a + cosine * b + translation.Y
			end,
		}
	end
	return E.apply(context, plans)
end
function E.density(source, settings)
	local context = Core.prepare(source, settings)
	local options, area, surface = context.options, 0, 0
	for _, island in context.islands do
		if island.selected then
			E.requireChart(island)
			area += island.uvArea * context.size.X * context.size.Y
			surface += island.surfaceArea
		end
	end
	local density = options.density
	if density == nil then
		density = surface > 0 and math.sqrt(area / surface) or 1
	end
	assert(
		type(density) == "number" and U.finite(density) and density > 0,
		"Positive finite UV density required"
	)
	local plans = {}
	for _, island in context.islands do
		if island.selected then
			local factor = density / island.density
			local px, py =
				(island.minimum[1] + island.maximum[1]) / 2, (island.minimum[2] + island.maximum[2]) / 2
			plans[island.id] = {
				orientation = 1,
				expectedDensity = density,
				map = function(x, y)
					return px + (x - px) * factor, py + (y - py) * factor
				end,
			}
		end
	end
	local out, report = E.apply(context, plans)
	report.targetDensity = density
	return out, report
end
return E
