-- Pure-data fitting/editing example; creates no scene instances.
return function(API)
	local E = API or require(script.Parent.Parent)
	local samples, pu, pv = {}, {}, {}
	for i = 1, 8 do
		local u = (i - 1) / 7
		pu[i], samples[i] = u, {}
		for j = 1, 7 do
			local v = (j - 1) / 6
			pv[j] = v
			samples[i][j] = Vector3.new(4 * u, 3 * v, 0.6 * u * u + 0.4 * u * v - 0.3 * v * v)
		end
	end
	local surface, fit = E.SplineFit.surface(samples, 2, 2, 3, 3, { parametersU = pu, parametersV = pv })
	assert(fit.maximumError < 0.0001)
	local elevated = E.NURBS.elevateSurfaceDegree(surface, "U", 1)
	local refined = E.NURBS.insertSurfaceKnot(elevated, "V", 0.5)
	local simplified, removal = E.NURBS.removeSurfaceKnot(refined, "V", 0.5)
	assert(removal.complete)
	return {
		surface = simplified,
		mesh = E.NURBS.tessellate(simplified, 24, 24),
		fit = fit,
		removal = removal,
	}
end
