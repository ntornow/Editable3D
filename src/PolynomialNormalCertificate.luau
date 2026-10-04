-- Reconstruct exact tensor controls before deciding a degenerate patch normal.
return function(source, top, target, grid, u, v, jacobian, config, settings, visit)
	local options = table.clone(settings)
	local allocated = 0
	local function allocate(n)
		allocated += n
		assert(
			allocated <= (options.maxExactCoefficients or 20000000),
			"Polynomial normal coefficient budget exceeded"
		)
	end
	options.normalAllocate = allocate
	local R = require(script.Parent.ExactRational)(visit, options.maxExactBits or 8192)
	local cfg = table.clone(config)
	cfg.normalAllocate = allocate
	local exact, reason, steps = require(script.Parent.ExactSubdivisionHistory)(R, source, cfg, visit)
	if not exact then
		return nil, { normalCertified = false, reason = reason }
	end
	local classified = { vertices = exact.vertices, faces = exact.faces, edges = {}, sharp = {} }
	for _, name in { "edges", "sharp" } do
		for key, q in exact[name] do
			local c = q.sign == 0 and 0 or R.equal(q, R.number(10)) and 10 or 1
			local native = source[name][key] or 0
			local nc = native == 0 and 0 or native == 10 and 10 or 1
			if c ~= nc then
				return nil, { normalCertified = false, reason = "nonstationaryExactMasks" }
			end
			classified[name][key] = c
		end
	end
	local controls = {}
	if grid then
		for key, id in grid do
			controls[key] = exact.vertices[id]
		end
	else
		local function blend(points, weights)
			local out = { R.number(0), R.number(0), R.number(0) }
			for i, p in points do
				for axis = 1, 3 do
					out[axis] = R.add(out[axis], R.mul(R.number(weights[i]), p[axis]))
				end
			end
			return out
		end
		controls =
			require(script.Parent.SubdivisionFeaturePatch).controls(classified, top, target, blend, visit)
		if not controls then
			return nil, { normalCertified = false, reason = "nonstationaryExactMasks" }
		end
	end
	local determinant = R.sub(
		R.mul(R.number(jacobian[1]), R.number(jacobian[4])),
		R.mul(R.number(jacobian[2]), R.number(jacobian[3]))
	)
	assert(determinant.sign ~= 0, "Singular subdivision chart")
	local normal, report =
		require(script.Parent.PolynomialNormalProof)(R, controls, u, v, determinant.sign, options, visit)
	report.exactHistorySteps = steps
	report.allocatedCoefficients = allocated
	return normal, report
end
