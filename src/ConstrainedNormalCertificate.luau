-- Bounded normal proof, separate from finite chart-derivative existence.
local U = require(script.Parent.Util)
return function(source, top, sector, vertex, target, config, settings, visit)
	if sector.closed or (sector.kind ~= "crease" and sector.kind ~= "corner") then
		return nil, { normalCertified = false, reason = "nonstationarySector" }
	end
	local options = table.clone(settings)
	local maximum = options.maxExactCoefficients or 1000000
	local count = 6 * sector.count + 3
	local preflight = 24 * count * count
	assert(preflight <= maximum, "Annular normal coefficient preflight exceeded")
	local allocated = 0
	local function allocate(n)
		allocated += n
		assert(allocated <= maximum, "Annular normal coefficient budget exceeded")
	end
	options.normalAllocate = allocate
	options.normalRecurrenceScale = 4096
	local R = require(script.Parent.ExactRational)(visit, options.maxExactBits or 8192)
	local cfg = table.clone(config)
	cfg.normalAllocate = allocate
	local exactSource, historyReason, historySteps =
		require(script.Parent.ExactSubdivisionHistory)(R, source, cfg, visit)
	if not exactSource then
		return nil, { normalCertified = false, reason = historyReason }
	end
	-- A rounded finite sharpness must never silently become an exact stationary
	-- mask. Reclassify the selected sector from exact propagated sharpness.
	local classified = { vertices = exactSource.vertices, faces = exactSource.faces, edges = {}, sharp = {} }
	local ten = R.number(10)
	for _, name in { "edges", "sharp" } do
		for key, value in exactSource[name] do
			classified[name][key] = value.sign == 0 and 0 or (R.equal(value, ten) and 10 or 1)
		end
	end
	local exactSector =
		require(script.Parent.SubdivisionFeaturePatch).sector(classified, top, vertex, target, visit)
	if not exactSector or exactSector.kind ~= sector.kind or exactSector.count ~= sector.count then
		return nil, { normalCertified = false, reason = "nonstationaryExactMasks" }
	end
	for _, name in { "faces", "edges", "diagonals" } do
		for i, id in sector[name] do
			assert(exactSector[name][i] == id, "Exact sector incidence mismatch")
		end
	end
	local fixed = {
		start = config.boundary == "fixed" and #top.edges[U.edge(vertex, sector.edges[1])].faces == 1,
		finish = config.boundary == "fixed"
			and #top.edges[U.edge(vertex, sector.edges[#sector.edges])].faces == 1,
	}
	local masks =
		require(script.Parent.AnnularControlMasks)(R, sector.count, sector.kind, fixed, visit, allocate)
	local points, reason = require(script.Parent.ExactAnnularNeighborhood)(R, visit)(
		source,
		sector,
		vertex,
		cfg,
		masks,
		exactSource
	)
	if not points then
		return nil, { normalCertified = false, reason = reason }
	end
	local normal, report = require(script.Parent.ExactAnnularNormal)(
		R,
		masks,
		points,
		assert(table.find(sector.faces, target)),
		sector.kind,
		options,
		visit
	)
	report.decisionCertified = report.normalCertified or report.normalExists == false
	report.coefficientPreflight = preflight
	report.allocatedCoefficients = allocated
	report.sectorFaces = sector.count
	report.annularControls = count
	report.exactHistorySteps = historySteps
	return normal, report
end
