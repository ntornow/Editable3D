-- Private distance-driven curve deformation with discrete parallel-transport frames.
local U = require(script.Parent.Util)
local Core = require(script.Parent.DeformCore)
local N = require(script.Parent.NURBS)
local function transport(normal, a, b)
	local dot = math.clamp(a:Dot(b), -1, 1)
	assert(dot > -1 + 1e-6, "Curve frame reverses direction; a unique transport rotation is unavailable")
	local cross = a:Cross(b)
	local moved = normal + cross:Cross(normal) + cross:Cross(cross:Cross(normal)) / (1 + dot)
	moved -= b * moved:Dot(b)
	assert(moved.Magnitude > 0, "Curve frame collapsed at native precision")
	return moved.Unit
end
local function rotate(v, t, angle)
	return v * math.cos(angle) + t:Cross(v) * math.sin(angle) + t * t:Dot(v) * (1 - math.cos(angle))
end
return function(mesh, curve, options)
	options = options or {}
	local ctx = Core.prepare(mesh, options)
	assert(
		type(curve) == "table",
		"Curve deformation requires a rational, Bezier, cyclic or polyline descriptor"
	)
	local closed = curve.kind == "cyclicCurve" or curve.kind == "bezier" and curve.closed
	if options.closed ~= nil then
		assert(type(options.closed) == "boolean", "Curve closed option must be boolean")
		closed = options.closed
	end
	if curve.kind == "bezier" then
		curve = require(script.Parent.Bezier).toNURBS(curve)
	elseif curve.kind == "cyclicCurve" then
		curve = require(script.Parent.Cyclic).toNURBS(curve)
	elseif not curve.kind then
		curve = N.curve(curve, 1)
	end
	assert(curve.kind == "curve", "Curve deformation requires a curve")
	curve = N.clamp(curve)
	local pathFrame = Core.frame(options.pathFrame or CFrame.identity)
	for i, p in curve.points do
		curve.points[i] = pathFrame:PointToWorldSpace(p)
	end
	local tolerance = Core.scalar(options.tolerance or 1e-4)
	assert(tolerance > 0, "Positive curve deformation tolerance required")
	local maxAngle = Core.scalar(options.maxAngle or math.rad(5))
	local sampleLimit = U.integer(options.maxFrameSamples or 8192, 2)
	local sampleOptions = {
		tolerance = tolerance,
		maxAngle = maxAngle,
		maxNodes = options.maxCurveNodes or 10000,
		maxDepth = options.maxCurveDepth or 24,
		checkpoint = function()
			ctx.visit()
			ctx.checkpoint("curveFrames")
		end,
	}
	local points, sampling = require(script.Parent.SplineQuery).sample(curve, sampleOptions)
	assert(sampling.converged, "Curve frame sampling did not converge: " .. tostring(sampling.reason))
	assert(#points <= sampleLimit, "Curve frame sample budget exceeded")
	local prepared = N.compileCurve(curve)
	local frames = {}
	local axis, u, v, sign = Core.axis(options.axis or "X", true)
	local up = options.up or ctx.frame:VectorToWorldSpace(Core.axes[u])
	assert(U.vector(up) and up.Magnitude > 0, "Finite nonzero curve up direction required")
	local stationary, upFallback = 0, false
	for i, t in sampling.parameters do
		ctx.visit()
		local derivative = prepared.derivatives(t)
		local tangent = derivative.first
		if tangent.Magnitude == 0 then
			stationary += 1
			for j = i + 1, #points do
				ctx.visit()
				tangent = points[j] - points[i]
				if tangent.Magnitude > 0 then
					break
				end
			end
			if tangent.Magnitude == 0 then
				for j = i - 1, 1, -1 do
					ctx.visit()
					tangent = points[i] - points[j]
					if tangent.Magnitude > 0 then
						break
					end
				end
			end
		end
		assert(tangent.Magnitude > 0, "Curve has no defined forward direction")
		tangent = tangent.Unit
		local normal
		if i == 1 then
			normal = up - tangent * up:Dot(tangent)
			if normal.Magnitude <= up.Magnitude * 1e-6 then
				upFallback = true
				local candidate = Vector3.xAxis
				for _, other in { Vector3.yAxis, Vector3.zAxis } do
					if math.abs(other:Dot(tangent)) < math.abs(candidate:Dot(tangent)) then
						candidate = other
					end
				end
				normal = candidate - tangent * candidate:Dot(tangent)
			end
			normal = normal.Unit
		else
			normal = transport(frames[i - 1].normal, frames[i - 1].tangent, tangent)
		end
		frames[i] = { parameter = t, position = derivative.position, tangent = tangent, normal = normal }
	end
	local correction = 0
	if closed then
		local first, last = frames[1], frames[#frames]
		assert((first.position - last.position).Magnitude <= tolerance, "Closed curve endpoints do not meet")
		assert(
			first.tangent:Dot(last.tangent) >= 1 - 1e-5,
			"Closed curve deformation requires matching seam tangents"
		)
		local endNormal = transport(last.normal, last.tangent, first.tangent)
		correction = math.atan2(first.tangent:Dot(endNormal:Cross(first.normal)), endNormal:Dot(first.normal))
	end
	local lengthOptions = table.clone(options.arcLength or {})
	lengthOptions.tolerance = lengthOptions.tolerance or tolerance
	lengthOptions.maxNodes = lengthOptions.maxNodes or options.maxCurveNodes
	lengthOptions.maxDepth = lengthOptions.maxDepth or options.maxCurveDepth
	local callerCheckpoint = lengthOptions.checkpoint
	lengthOptions.checkpoint = function(progress)
		ctx.visit()
		ctx.checkpoint("curveLength")
		if callerCheckpoint then
			callerCheckpoint(progress)
		end
	end
	local length = require(script.Parent.ArcLength).prepare(curve, lengthOptions)
	assert(
		length.converged and length.length > 0,
		"Curve length map did not converge or the curve has zero length"
	)
	local outside = options.outside or (closed and "wrap" or "extend")
	assert(
		outside == "extend" or outside == "clamp" or outside == "wrap" or outside == "error",
		"Unknown curve endpoint mode"
	)
	assert(outside ~= "wrap" or closed, "Curve wrapping requires a closed curve")
	local sourceLo, sourceHi
	if options.fit or options.sourceRange then
		sourceLo, sourceHi = ctx.range(axis, options.sourceRange)
	end
	local scale = Core.scalar(options.lengthScale or 1)
	assert(scale > 0, "Positive curve length scale required; use a negative deformation axis to reverse")
	local offset = Core.scalar(options.offset or 0)
	local radius = require(script.Parent.DeformProfile)(options.radiusProfile or 1, ctx)
	local roll = options.roll or 0
	assert(
		type(roll) == "function" or type(roll) == "number" and U.finite(roll),
		"Curve roll must be a number or callback"
	)
	local queryLimit = U.integer(options.maxCurveQueries or 10000, 1)
	local cache, queries, maxError = {}, 0, 0
	ctx.report.curve = {
		length = length.length,
		lengthLowerBound = length.lowerBound,
		lengthUpperBound = length.upperBound,
		frameSamples = #frames,
		frameChordErrorBound = sampling.errorBound,
		tangentConeBound = sampling.tangentErrorBound,
		stationarySamples = stationary,
		upFallback = upFallback,
		closed = closed == true,
		seamTwist = correction,
		queries = 0,
		maximumDistanceError = 0,
	}
	local function at(fraction)
		if cache[fraction] then
			return cache[fraction]
		end
		queries += 1
		assert(queries <= queryLimit, "Curve deformation query budget exceeded")
		local result = length.atFraction(fraction)
		assert(result.converged, "Curve distance inversion did not converge: " .. tostring(result.reason))
		maxError = math.max(maxError, result.errorBound)
		local t = result.parameter
		local lo, hi = 1, #frames
		while lo < hi do
			ctx.visit()
			local mid = math.ceil((lo + hi) / 2)
			if frames[mid].parameter <= t then
				lo = mid
			else
				hi = mid - 1
			end
		end
		local base = frames[lo]
		local tangent = result.tangent.Magnitude > 0 and result.tangent.Unit or base.tangent
		local normal = transport(base.normal, base.tangent, tangent)
		local angle = type(roll) == "function" and roll(fraction) or roll
		Core.scalar(angle, "Finite curve roll required")
		normal = rotate(normal, tangent, correction * t + angle)
		local value = {
			position = result.position,
			tangent = tangent,
			normal = normal,
			binormal = tangent:Cross(normal),
			radius = radius(fraction),
		}
		cache[fraction] = value
		ctx.report.curve.queries = queries
		ctx.report.curve.maximumDistanceError = maxError
		return value
	end
	return ctx.run(function(p, _, w)
		local distance = p[axis] * sign
		if sourceLo then
			distance = (
				sign > 0 and (p[axis] - sourceLo) / (sourceHi - sourceLo)
				or (sourceHi - p[axis]) / (sourceHi - sourceLo)
			) * length.length
		end
		distance = distance * scale + offset
		local fraction = distance / length.length
		assert(
			outside ~= "error" or fraction >= 0 and fraction <= 1,
			"Curve deformation exceeds the path endpoints"
		)
		local extra = 0
		if outside == "wrap" then
			fraction = fraction % 1
		else
			local clamped = math.clamp(fraction, 0, 1)
			if outside == "extend" then
				extra = (fraction - clamped) * length.length
			end
			fraction = clamped
		end
		local sample = at(fraction)
		local world = sample.position
			+ sample.tangent * extra
			+ sample.normal * (p[u] * sample.radius.X)
			+ sample.binormal * (p[v] * sign * sample.radius.Y)
		return p:Lerp(ctx.frame:PointToObjectSpace(world), w)
	end)
end
