-- Shared endpoint geometry, intersection and normal audits for positional sculpt edits.
local U = require(script.Parent.Util)
local G = require(script.Parent.PlanarReduceGeometry)
local S = {}
function S.attach(context, limits)
	local mesh, options, triangles = context.mesh, context.options, context.triangles
	local maxWork, maxTriangles = limits.maxWork, limits.maxTriangles
	local maxVertices, maxFaces, maxCorners = limits.maxVertices, limits.maxFaces, limits.maxCorners
	local normalLimit = context.normalLimit
	function context.audit(object, stage)
		local config = U.copy(options.intersectionOptions or {})
		local callback, additionalCancel = config.checkpoint, config.cancelled
		config.maxWork = math.min(config.maxWork or maxWork, maxWork - context.work)
		config.maxTriangles = math.min(config.maxTriangles or maxTriangles, maxTriangles)
		config.requireComplete = false
		local used = 0
		config.cancelled = function()
			return options.cancelled and options.cancelled() or additionalCancel and additionalCancel()
		end
		config.checkpoint = function(status)
			assert(not config.cancelled(), "Sculpt intersection audit cancelled")
			context.visit(math.max(0, (status.work or 0) - used))
			used = status.work or used
			if callback then
				callback(status)
			end
			context.checkpoint(stage)
		end
		local _, result = require(script.Parent.Intersections).mesh(object, config)
		assert(not config.cancelled(), "Sculpt intersection audit cancelled")
		context.visit(math.max(0, (result.work or used) - used))
		return result
	end
	function context.geometry(object)
		local result = { valid = true, maximumNormalAngle = 0 }
		for _, face in object.faces do
			local plane = G.plane(object, face.vertices, context.visit)
			if not plane then
				result.valid = false
				result.reason = "degenerateFace"
				return result
			end
			local valid = G.polygon(object, face.vertices, plane, context.visit)
			if not valid then
				result.valid = false
				result.reason = "faceProjection"
				return result
			end
		end
		local function normal(m, t)
			local a, b, c = m.vertices[t[1]], m.vertices[t[2]], m.vertices[t[3]]
			local x, y, z = b.X - a.X, b.Y - a.Y, b.Z - a.Z
			local u, v, w = c.X - a.X, c.Y - a.Y, c.Z - a.Z
			local cx, cy, cz = y * w - z * v, z * u - x * w, x * v - y * u
			local length = math.sqrt(cx * cx + cy * cy + cz * cz)
			if length == 0 or not U.finite(length) then
				return nil
			end
			return { cx / length, cy / length, cz / length }
		end
		local threshold = math.cos(normalLimit)
		for _, triangle in triangles do
			context.visit(1)
			local a, b = normal(mesh, triangle), normal(object, triangle)
			if not a or not b then
				result.valid = false
				result.reason = "degenerateTriangle"
				return result
			end
			local dot = math.clamp(a[1] * b[1] + a[2] * b[2] + a[3] * b[3], -1, 1)
			result.maximumNormalAngle = math.max(result.maximumNormalAngle, math.acos(dot))
			if dot < threshold - 2 ^ -45 then
				result.valid = false
				result.reason = "normalLimit"
				return result
			end
		end
		result.validation = object:validate({ minimumFaceArea = 0 })
		result.valid = result.validation.valid
		if not result.valid then
			result.reason = "invalidTopology"
		end
		return result
	end
	function context.normals(object)
		local remaining = maxWork - context.work
		assert(remaining >= 1, "Sculpt work budget exceeded")
		local used = 0
		local config = {
			angle = options.normalAngle,
			minimumFaceArea = 0,
			maxWork = remaining,
			maxElements = maxVertices + maxFaces + 3 * maxCorners,
		}
		config.checkpoint = function(fraction)
			local work = math.floor(fraction * remaining + 0.5)
			context.visit(math.max(0, work - used))
			used = work
			context.checkpoint("normals")
		end
		context.checkpoint("normals")
		local out, result = require(script.Parent.Normals).recalculate(object, config)
		context.visit(math.max(0, result.work - used))
		return out, result
	end
end
return S
