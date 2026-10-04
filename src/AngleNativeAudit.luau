-- Private post-construction audit, reusable after chart layout changes native UVs.
local P = require(script.Parent.Predicates)
local Analysis = require(script.Parent.UVAnalysis)
local N = {}
function N.run(mesh, records, angles, size, options, visit)
	local report = {
		positiveTriangles = 0,
		negativeTriangles = 0,
		degenerateTriangles = 0,
		maximumAngleResidual = 0,
		overlapChecked = options.checkOverlaps ~= false,
	}
	local audit = { triangles = {}, options = { maxOverlaps = options.maxOverlaps }, visit = visit }
	for i, record in records do
		local corners = mesh.faces[record.face].corners
		local coords =
			{ corners[record.corners[1]].uv, corners[record.corners[2]].uv, corners[record.corners[3]].uv }
		local orientation = P.orient2D(coords[1], coords[2], coords[3])
		local name = orientation > 0 and "positiveTriangles"
			or orientation < 0 and "negativeTriangles"
			or "degenerateTriangles"
		report[name] += 1
		local minimum = {
			math.min(coords[1].X, coords[2].X, coords[3].X),
			math.min(coords[1].Y, coords[2].Y, coords[3].Y),
		}
		local maximum = {
			math.max(coords[1].X, coords[2].X, coords[3].X),
			math.max(coords[1].Y, coords[2].Y, coords[3].Y),
		}
		table.insert(audit.triangles, {
			uv = coords,
			orientation = orientation,
			minimum = minimum,
			maximum = maximum,
			index = i,
			face = record.face,
			island = record.island or 1,
		})
		for k, a in coords do
			visit(1)
			local b, c = coords[k % 3 + 1], coords[(k + 1) % 3 + 1]
			local x, y, u, v =
				(b.X - a.X) * size.X, (b.Y - a.Y) * size.Y, (c.X - a.X) * size.X, (c.Y - a.Y) * size.Y
			local measured = math.atan2(math.abs(x * v - y * u), x * u + y * v)
			local error = orientation == 0 and math.huge or math.abs(measured - angles[3 * i - 3 + k])
			report.maximumAngleResidual = math.max(report.maximumAngleResidual, error)
		end
	end
	report.nativeOrientation = report.negativeTriangles == 0 and report.degenerateTriangles == 0
	if report.overlapChecked then
		local overlap = Analysis.scan(audit)
		report.overlapCount, report.overlaps, report.overlapsTruncated =
			overlap.overlapCount, overlap.overlaps, overlap.overlapsTruncated
		report.overlapFree = overlap.overlapCount == 0
	end
	return report
end
return N
